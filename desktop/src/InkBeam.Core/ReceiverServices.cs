using System.Diagnostics;
using System.Text;
using System.Text.Json;

namespace InkBeam.Core;

public sealed class ReceiverStatusService(
    AppPaths paths,
    ReceiverStatePipeClient statePipeClient)
{
    public async Task<ReceiverSnapshot> GetSnapshotAsync(
        CancellationToken cancellationToken)
    {
        Task<PrerequisiteStatus> discoveryTask = Task.Run(
            PrerequisiteInspector.GetBonjourStatus,
            cancellationToken);
        Task<PrerequisiteStatus> networkTask = Task.Run(
            PrerequisiteInspector.GetNetworkStatus,
            cancellationToken);

        ReceiverConfiguration configuration;
        try
        {
            configuration = await ConfigurationReader.ReadAsync(
                paths.ConfigurationPath,
                cancellationToken);
        }
        catch (Exception exception) when (
            exception is IOException or JsonException or UnauthorizedAccessException)
        {
            return new(
                ReceiverDisplayState.Error,
                "Configuration error",
                exception.Message,
                null,
                0,
                0,
                ReceiverConfiguration.Default,
                false,
                false,
                await discoveryTask,
                await networkTask);
        }

        RuntimeManifest manifest;
        try
        {
            manifest = await RuntimeManifestReader.ReadAsync(
                paths.RuntimeManifestPath,
                cancellationToken);
        }
        catch (Exception exception) when (
            exception is IOException or JsonException or
            UnauthorizedAccessException or ArgumentException)
        {
            return SetupRequired(
                configuration,
                "Run the InkBeam installer to add the receiver runtime.",
                await discoveryTask,
                await networkTask);
        }

        if (!File.Exists(paths.ControllerPath) ||
            !File.Exists(manifest.ExecutablePath))
        {
            return SetupRequired(
                configuration,
                "The installed runtime is incomplete. Run the InkBeam installer again.",
                await discoveryTask,
                await networkTask);
        }

        IReadOnlyList<int> processIds = await Task.Run(
            () => RuntimeInspector.FindExactReceiverProcesses(
                manifest.ExecutablePath),
            cancellationToken);
        PrerequisiteStatus discovery = await discoveryTask;
        PrerequisiteStatus network = await networkTask;

        if (processIds.Count == 0)
        {
            return new(
                ReceiverDisplayState.Disabled,
                "Receiver disabled",
                "Enable InkBeam when you are ready to mirror the iPad.",
                null,
                0,
                0,
                configuration,
                true,
                false,
                discovery,
                network);
        }

        ReceiverStateMessage? state =
            await statePipeClient.TryReadAsync(cancellationToken);
        if (state is null || !processIds.Contains(state.ReceiverPid))
        {
            return new(
                ReceiverDisplayState.Starting,
                "Receiver starting",
                "The receiver is running, but its authoritative state is not available yet.",
                null,
                0,
                processIds[0],
                configuration,
                true,
                true,
                discovery,
                network);
        }

        return new(
            state.State,
            LabelFor(state.State),
            string.IsNullOrWhiteSpace(state.Message)
                ? DetailFor(state.State)
                : state.Message,
            state.Pin,
            state.Revision,
            state.ReceiverPid,
            configuration,
            true,
            true,
            discovery,
            network);
    }

    private static ReceiverSnapshot SetupRequired(
        ReceiverConfiguration configuration,
        string detail,
        PrerequisiteStatus discovery,
        PrerequisiteStatus network) =>
        new(
            ReceiverDisplayState.SetupRequired,
            "Setup required",
            detail,
            null,
            0,
            0,
            configuration,
            false,
            false,
            discovery,
            network);

    private static string LabelFor(ReceiverDisplayState state) => state switch
    {
        ReceiverDisplayState.Starting => "Receiver starting",
        ReceiverDisplayState.Ready => "Ready to cast",
        ReceiverDisplayState.Pairing => "Pairing request",
        ReceiverDisplayState.Casting => "Casting now",
        ReceiverDisplayState.Error => "Receiver error",
        _ => "Receiver state unavailable"
    };

    private static string DetailFor(ReceiverDisplayState state) => state switch
    {
        ReceiverDisplayState.Starting =>
            "The receiver is preparing its local AirPlay listener.",
        ReceiverDisplayState.Ready =>
            "Choose this receiver from the iPad Screen Mirroring menu.",
        ReceiverDisplayState.Pairing =>
            "Enter the PIN on the iPad to approve this connection.",
        ReceiverDisplayState.Casting =>
            "The iPad stream is active in the AirPlay Video Stream window.",
        ReceiverDisplayState.Error =>
            "The receiver reported an error.",
        _ =>
            "The receiver state is unavailable."
    };
}

public sealed record ControllerCommandResult(
    bool Success,
    int ExitCode,
    string Message);

public sealed class ControllerClient(
    AppPaths paths,
    TimeSpan? commandTimeout = null)
{
    private readonly TimeSpan _commandTimeout =
        commandTimeout ?? TimeSpan.FromSeconds(45);
    private readonly SemaphoreSlim _operation = new(1, 1);

    public bool IsInstalled => File.Exists(paths.ControllerPath);

    public Task<ControllerCommandResult> StartAsync(
        CancellationToken cancellationToken) =>
        RunExclusiveAsync("start", [], cancellationToken);

    public Task<ControllerCommandResult> StopAsync(
        CancellationToken cancellationToken) =>
        RunExclusiveAsync("stop", [], cancellationToken);

    public Task<ControllerCommandResult> ConfigureAsync(
        ReceiverConfiguration configuration,
        CancellationToken cancellationToken)
    {
        if (!ReceiverNameValidator.IsValid(configuration.ReceiverName))
        {
            return Task.FromResult(new ControllerCommandResult(
                false,
                -1,
                ReceiverNameValidator.ErrorMessage));
        }

        if (configuration.Authentication is not (
                "every-connection" or "pair-once" or "open"))
        {
            return Task.FromResult(new ControllerCommandResult(
                false,
                -1,
                "Choose a supported authentication mode."));
        }

        string[] arguments =
        [
            "-ReceiverName",
            configuration.ReceiverName,
            "-Authentication",
            configuration.Authentication,
            "-Audio",
            configuration.AudioEnabled ? "on" : "off",
            "-Fullscreen",
            configuration.Fullscreen ? "on" : "off"
        ];
        return RunExclusiveAsync("configure", arguments, cancellationToken);
    }

    private async Task<ControllerCommandResult> RunExclusiveAsync(
        string command,
        IReadOnlyList<string> arguments,
        CancellationToken cancellationToken)
    {
        if (!await _operation.WaitAsync(0, cancellationToken))
        {
            return new(false, -1, "Another InkBeam action is already in progress.");
        }

        try
        {
            return await RunAsync(command, arguments, cancellationToken);
        }
        finally
        {
            _operation.Release();
        }
    }

    private async Task<ControllerCommandResult> RunAsync(
        string command,
        IReadOnlyList<string> arguments,
        CancellationToken cancellationToken)
    {
        if (!File.Exists(paths.ControllerPath))
        {
            return new(
                false,
                -1,
                "The installed controller is missing. Run the InkBeam installer again.");
        }

        string windowsRoot =
            Environment.GetEnvironmentVariable("SystemRoot") ?? @"C:\Windows";
        string powerShellPath = Path.Combine(
            windowsRoot,
            "System32",
            "WindowsPowerShell",
            "v1.0",
            "powershell.exe");

        ProcessStartInfo startInfo = new()
        {
            FileName = powerShellPath,
            UseShellExecute = false,
            CreateNoWindow = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            WorkingDirectory = Path.GetDirectoryName(paths.ControllerPath)!
        };
        foreach (string argument in new[]
                 {
                     "-NoProfile",
                     "-NonInteractive",
                     "-ExecutionPolicy",
                     "Bypass",
                     "-File",
                     paths.ControllerPath,
                     command
                 })
        {
            startInfo.ArgumentList.Add(argument);
        }
        foreach (string argument in arguments)
        {
            startInfo.ArgumentList.Add(argument);
        }

        using Process process = new() { StartInfo = startInfo };
        BoundedProcessOutput output = new(process);
        try
        {
            if (!process.Start())
            {
                return new(false, -1, "Windows PowerShell did not start.");
            }

            output.Begin();
            using CancellationTokenSource timeout =
                new(_commandTimeout);
            using CancellationTokenSource deadline =
                CancellationTokenSource.CreateLinkedTokenSource(
                    cancellationToken,
                    timeout.Token);

            try
            {
                await process.WaitForExitAsync(deadline.Token);
                output.Complete();
            }
            catch (OperationCanceledException)
            {
                TryKill(process);
                await process.WaitForExitAsync(CancellationToken.None);
                output.Complete();

                return cancellationToken.IsCancellationRequested
                    ? new(false, -1, "The InkBeam action was cancelled.")
                    : new(
                        false,
                        -1,
                        $"The InkBeam action exceeded {_commandTimeout.TotalSeconds:0} seconds and was stopped.");
            }

            string message = output.BestMessage;
            if (process.ExitCode != 0)
            {
                return new(
                    false,
                    process.ExitCode,
                    string.IsNullOrWhiteSpace(message)
                        ? $"The controller exited with code {process.ExitCode}."
                        : message);
            }

            return new(
                true,
                process.ExitCode,
                string.IsNullOrWhiteSpace(message)
                    ? "The InkBeam action completed."
                    : message);
        }
        catch (Exception exception) when (
            exception is InvalidOperationException or
            System.ComponentModel.Win32Exception or IOException)
        {
            TryKill(process);
            return new(false, -1, exception.Message);
        }
    }

    private static void TryKill(Process process)
    {
        try
        {
            if (!process.HasExited)
            {
                process.Kill(entireProcessTree: true);
            }
        }
        catch (InvalidOperationException)
        {
        }
    }

    private sealed class BoundedProcessOutput
    {
        private const int MaximumCharacters = 16 * 1024;
        private readonly Process _process;
        private readonly StringBuilder _standardOutput = new();
        private readonly StringBuilder _standardError = new();
        private readonly object _sync = new();

        public BoundedProcessOutput(Process process)
        {
            _process = process;
        }

        public string BestMessage
        {
            get
            {
                lock (_sync)
                {
                    string error = _standardError.ToString().Trim();
                    return string.IsNullOrWhiteSpace(error)
                        ? _standardOutput.ToString().Trim()
                        : error;
                }
            }
        }

        public void Begin()
        {
            _process.OutputDataReceived += (_, eventArgs) =>
                Append(_standardOutput, eventArgs.Data);
            _process.ErrorDataReceived += (_, eventArgs) =>
                Append(_standardError, eventArgs.Data);
            _process.BeginOutputReadLine();
            _process.BeginErrorReadLine();
        }

        public void Complete()
        {
            _process.WaitForExit();
        }

        private void Append(StringBuilder target, string? line)
        {
            if (line is null)
            {
                return;
            }

            lock (_sync)
            {
                int remaining = MaximumCharacters - target.Length;
                if (remaining <= 0)
                {
                    return;
                }

                target.AppendLine(
                    line.Length <= remaining ? line : line[..remaining]);
            }
        }
    }
}
