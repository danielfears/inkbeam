using System.IO;
using System.IO.Pipes;
using System.Runtime.InteropServices;
using System.Text;
using System.Windows.Resources;
using InkBeam.Core;
using DrawingIcon = System.Drawing.Icon;

namespace InkBeam;

internal sealed record DesktopSelfTestResult(
    int ExitCode,
    IReadOnlyList<string> Lines);

internal static class DesktopSelfTest
{
    public static async Task<DesktopSelfTestResult> RunAsync(
        string expectedAppId,
        int setAppIdResult)
    {
        List<string> lines = [];
        using CancellationTokenSource deadline = new(TimeSpan.FromSeconds(5));

        try
        {
            Assert(
                setAppIdResult == 0 &&
                TryGetCurrentAppId(out string? appId) &&
                string.Equals(appId, expectedAppId, StringComparison.Ordinal),
                "AppUserModelID");
            lines.Add("PASS AppUserModelID");

            AssertEmbeddedIcon();
            lines.Add("PASS embedded application icon");

            await AssertActivationPipeAsync(deadline.Token);
            lines.Add("PASS current-user activation IPC");

            await AssertStatePipeAsync(deadline.Token);
            lines.Add("PASS bounded state IPC");

            lines.Add("InkBeam self-test: PASS");
            return new(0, lines);
        }
        catch (Exception exception) when (
            exception is InvalidOperationException or IOException or
            TimeoutException or OperationCanceledException or
            UnauthorizedAccessException)
        {
            string safeMessage = exception.Message
                .Replace('\r', ' ')
                .Replace('\n', ' ');
            if (safeMessage.Length > 160)
            {
                safeMessage = safeMessage[..160];
            }

            lines.Add($"FAIL {safeMessage}");
            lines.Add("InkBeam self-test: FAIL");
            return new(1, lines);
        }
    }

    private static void AssertEmbeddedIcon()
    {
        StreamResourceInfo? resource = System.Windows.Application.GetResourceStream(
            new Uri("pack://application:,,,/Assets/InkBeam.ico"));
        Assert(resource is not null, "embedded application icon");

        using Stream stream = resource!.Stream;
        using DrawingIcon icon = new(stream);
        Assert(icon.Width > 0 && icon.Height > 0, "embedded application icon");
    }

    private static async Task AssertActivationPipeAsync(
        CancellationToken cancellationToken)
    {
        string pipeName = $"InkBeamSelfTestActivation-{Guid.NewGuid():N}";
        TaskCompletionSource<bool> activated = new(
            TaskCreationOptions.RunContinuationsAsynchronously);
        await using ActivationPipeServer server = new(
            pipeName,
            () =>
            {
                activated.TrySetResult(true);
                return Task.CompletedTask;
            });
        server.Start();

        bool sent = await ActivationPipeClient.TryActivateAsync(
            pipeName,
            TimeSpan.FromSeconds(2),
            cancellationToken);
        Assert(sent, "current-user activation IPC");
        await activated.Task.WaitAsync(
            TimeSpan.FromSeconds(2),
            cancellationToken);
    }

    private static async Task AssertStatePipeAsync(
        CancellationToken cancellationToken)
    {
        string pipeName = $"InkBeamSelfTestState-{Guid.NewGuid():N}";
        const string json =
            """{"version":1,"state":"Starting","pin":null,"revision":1,"receiverPid":1,"message":"Self-test."}""";

        Task server = Task.Run(async () =>
        {
            await using NamedPipeServerStream pipe = new(
                pipeName,
                PipeDirection.Out,
                1,
                PipeTransmissionMode.Byte,
                PipeOptions.Asynchronous | PipeOptions.CurrentUserOnly);
            await pipe.WaitForConnectionAsync(cancellationToken);
            byte[] payload = Encoding.UTF8.GetBytes(json + "\n");
            await pipe.WriteAsync(payload, cancellationToken);
            await pipe.FlushAsync(cancellationToken);
        }, cancellationToken);

        ReceiverStatePipeClient client = new(
            pipeName,
            TimeSpan.FromSeconds(2),
            TimeSpan.FromSeconds(2));
        ReceiverStateMessage? state =
            await client.TryReadAsync(cancellationToken);
        await server.WaitAsync(TimeSpan.FromSeconds(2), cancellationToken);
        Assert(
            state?.State == ReceiverDisplayState.Starting &&
            state.Pin is null,
            "bounded state IPC");
    }

    private static bool TryGetCurrentAppId(out string? appId)
    {
        appId = null;
        int result = GetCurrentProcessExplicitAppUserModelID(out nint pointer);
        if (result != 0 || pointer == 0)
        {
            return false;
        }

        try
        {
            appId = Marshal.PtrToStringUni(pointer);
            return appId is not null;
        }
        finally
        {
            Marshal.FreeCoTaskMem(pointer);
        }
    }

    private static void Assert(bool condition, string check)
    {
        if (!condition)
        {
            throw new InvalidOperationException($"{check} check failed.");
        }
    }

    [DllImport("shell32.dll")]
    private static extern int GetCurrentProcessExplicitAppUserModelID(
        out nint appId);
}

internal static class SelfTestConsole
{
    private const uint AttachParentProcess = 0xFFFFFFFF;

    public static void Write(IReadOnlyList<string> lines)
    {
        _ = AttachConsole(AttachParentProcess);
        try
        {
            using Stream output = Console.OpenStandardOutput();
            using StreamWriter writer = new(output)
            {
                AutoFlush = true
            };
            foreach (string line in lines.Take(8))
            {
                writer.WriteLine(line[..Math.Min(200, line.Length)]);
            }
        }
        catch (Exception exception) when (
            exception is IOException or UnauthorizedAccessException)
        {
        }
    }

    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool AttachConsole(uint processId);
}
