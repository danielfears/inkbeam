using System.Diagnostics;
using System.Net.NetworkInformation;
using System.Runtime.InteropServices;
using System.Text.Json;

namespace InkBeam.Core;

public sealed class AppPaths
{
    public AppPaths(string? localApplicationData = null, string? baseDirectory = null)
    {
        DataRoot = Path.Combine(
            localApplicationData ??
                Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
            "iPadWhiteboardReceiver");
        BaseDirectory = Path.GetFullPath(baseDirectory ?? AppContext.BaseDirectory);
    }

    public string DataRoot { get; }

    public string BaseDirectory { get; }

    public string RuntimeManifestPath =>
        Path.Combine(DataRoot, "runtime-current.json");

    public string ConfigurationPath =>
        Path.Combine(DataRoot, "config.json");

    public string ControllerPath =>
        Path.GetFullPath(Path.Combine(BaseDirectory, "..", "WhiteboardReceiver.ps1"));

    public string InstalledExecutablePath =>
        Path.Combine(DataRoot, "app", "desktop", "InkBeam.exe");
}

public static class ConfigurationReader
{
    public static async Task<ReceiverConfiguration> ReadAsync(
        string path,
        CancellationToken cancellationToken)
    {
        if (!File.Exists(path))
        {
            return ReceiverConfiguration.Default;
        }

        string json = await ReadSmallFileAsync(path, 64 * 1024, cancellationToken);
        using JsonDocument document = JsonDocument.Parse(json, new()
        {
            AllowTrailingCommas = false,
            CommentHandling = JsonCommentHandling.Disallow,
            MaxDepth = 16
        });

        JsonElement root = document.RootElement;
        string receiverName = GetString(root, "receiverName") ?? "InkBeam";
        string authentication =
            GetString(root, "authentication") ?? "every-connection";
        bool audio = GetBoolean(root, "audioEnabled") ?? false;
        bool fullscreen = GetBoolean(root, "fullscreen") ?? false;

        if (!ReceiverNameValidator.IsValid(receiverName))
        {
            throw new InvalidDataException(ReceiverNameValidator.ErrorMessage);
        }

        if (authentication is not ("every-connection" or "pair-once" or "open"))
        {
            throw new InvalidDataException(
                $"Unsupported authentication mode: {authentication}");
        }

        return new(receiverName, authentication, audio, fullscreen);
    }

    private static string? GetString(JsonElement root, string name)
    {
        if (!root.TryGetProperty(name, out JsonElement element))
        {
            return null;
        }

        if (element.ValueKind != JsonValueKind.String)
        {
            throw new InvalidDataException(
                $"The configuration property '{name}' must be text.");
        }

        return element.GetString();
    }

    private static bool? GetBoolean(JsonElement root, string name)
    {
        if (!root.TryGetProperty(name, out JsonElement element))
        {
            return null;
        }

        if (element.ValueKind is not (JsonValueKind.True or JsonValueKind.False))
        {
            throw new InvalidDataException(
                $"The configuration property '{name}' must be true or false.");
        }

        return element.GetBoolean();
    }

    internal static async Task<string> ReadSmallFileAsync(
        string path,
        int maximumBytes,
        CancellationToken cancellationToken)
    {
        FileInfo information = new(path);
        if (information.Length > maximumBytes)
        {
            throw new InvalidDataException(
                $"The file is larger than the supported {maximumBytes} bytes.");
        }

        return await File.ReadAllTextAsync(path, cancellationToken);
    }
}

public static class RuntimeManifestReader
{
    public static async Task<RuntimeManifest> ReadAsync(
        string path,
        CancellationToken cancellationToken)
    {
        if (!File.Exists(path))
        {
            throw new FileNotFoundException(
                "The receiver runtime manifest is not installed.",
                path);
        }

        string json = await ConfigurationReader.ReadSmallFileAsync(
            path,
            64 * 1024,
            cancellationToken);
        using JsonDocument document = JsonDocument.Parse(json, new()
        {
            AllowTrailingCommas = false,
            CommentHandling = JsonCommentHandling.Disallow,
            MaxDepth = 16
        });

        if (!document.RootElement.TryGetProperty(
                "executable",
                out JsonElement executableElement) ||
            executableElement.ValueKind != JsonValueKind.String ||
            string.IsNullOrWhiteSpace(executableElement.GetString()))
        {
            throw new InvalidDataException(
                "The receiver runtime manifest has no executable path.");
        }

        string executablePath = Path.GetFullPath(executableElement.GetString()!);
        return new(executablePath);
    }
}

public static class RuntimeInspector
{
    public static IReadOnlyList<int> FindExactReceiverProcesses(string executablePath)
    {
        if (!File.Exists(executablePath))
        {
            return [];
        }

        string expectedPath = Path.GetFullPath(executablePath);
        string processName = Path.GetFileNameWithoutExtension(expectedPath);
        List<int> processIds = [];

        foreach (Process process in Process.GetProcessesByName(processName))
        {
            using (process)
            {
                try
                {
                    string? actualPath = process.MainModule?.FileName;
                    if (actualPath is not null && PathsEqual(actualPath, expectedPath))
                    {
                        processIds.Add(process.Id);
                    }
                }
                catch (Exception exception) when (
                    exception is InvalidOperationException or
                    System.ComponentModel.Win32Exception or
                    NotSupportedException)
                {
                }
            }
        }

        return processIds;
    }

    public static bool PathsEqual(string first, string second) =>
        string.Equals(
            Path.GetFullPath(first).TrimEnd(Path.DirectorySeparatorChar),
            Path.GetFullPath(second).TrimEnd(Path.DirectorySeparatorChar),
            StringComparison.OrdinalIgnoreCase);
}

public static class PrerequisiteInspector
{
    private const uint ScManagerConnect = 0x0001;
    private const uint ServiceQueryStatus = 0x0004;
    private const int ServiceRunning = 0x00000004;
    private const int ErrorServiceDoesNotExist = 1060;

    public static PrerequisiteStatus GetBonjourStatus()
    {
        nint manager = OpenSCManager(null, null, ScManagerConnect);
        if (manager == 0)
        {
            return new(
                PrerequisiteState.Unknown,
                "Discovery unknown",
                "Windows did not allow the Bonjour service state to be read.");
        }

        try
        {
            nint service = OpenService(manager, "Bonjour Service", ServiceQueryStatus);
            if (service == 0)
            {
                return Marshal.GetLastWin32Error() == ErrorServiceDoesNotExist
                    ? new(
                        PrerequisiteState.Unavailable,
                        "Discovery not installed",
                        "Run the InkBeam installer to install Bonjour discovery.")
                    : new(
                        PrerequisiteState.Unknown,
                        "Discovery unknown",
                        "The Bonjour service state could not be read.");
            }

            try
            {
                int size = Marshal.SizeOf<ServiceStatusProcess>();
                nint buffer = Marshal.AllocHGlobal(size);
                try
                {
                    if (!QueryServiceStatusEx(
                            service,
                            0,
                            buffer,
                            size,
                            out _))
                    {
                        return new(
                            PrerequisiteState.Unknown,
                            "Discovery unknown",
                            "The Bonjour service state could not be read.");
                    }

                    ServiceStatusProcess status =
                        Marshal.PtrToStructure<ServiceStatusProcess>(buffer);
                    return status.CurrentState == ServiceRunning
                        ? new(
                            PrerequisiteState.Available,
                            "Discovery service running",
                            "Bonjour is running; this does not by itself prove iPad reachability.")
                        : new(
                            PrerequisiteState.Unavailable,
                            "Discovery service stopped",
                            "Run the InkBeam installer again to repair Bonjour discovery.");
                }
                finally
                {
                    Marshal.FreeHGlobal(buffer);
                }
            }
            finally
            {
                CloseServiceHandle(service);
            }
        }
        finally
        {
            CloseServiceHandle(manager);
        }
    }

    public static PrerequisiteStatus GetNetworkStatus()
    {
        try
        {
            NetworkInterface? active = NetworkInterface
                .GetAllNetworkInterfaces()
                .FirstOrDefault(IsUsablePhysicalInterface);

            return active is null
                ? new(
                    PrerequisiteState.Unavailable,
                    "No active local adapter",
                    "Connect this PC and the iPad to the same local network.")
                : new(
                    PrerequisiteState.Available,
                    "Active local adapter found",
                    $"{active.Name} is connected; confirm the iPad uses the same network.");
        }
        catch (NetworkInformationException)
        {
            return new(
                PrerequisiteState.Unknown,
                "Network state unknown",
                "Windows could not report the active network adapters.");
        }
    }

    private static bool IsUsablePhysicalInterface(NetworkInterface network)
    {
        if (network.OperationalStatus != OperationalStatus.Up ||
            network.NetworkInterfaceType is
                NetworkInterfaceType.Loopback or NetworkInterfaceType.Tunnel)
        {
            return false;
        }

        string description = $"{network.Name} {network.Description}";
        string[] virtualMarkers =
        [
            "virtual",
            "hyper-v",
            "vethernet",
            "wsl",
            "vpn",
            "loopback"
        ];
        if (virtualMarkers.Any(marker =>
                description.Contains(marker, StringComparison.OrdinalIgnoreCase)))
        {
            return false;
        }

        return network.GetIPProperties().UnicastAddresses.Any(address =>
            !System.Net.IPAddress.IsLoopback(address.Address));
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct ServiceStatusProcess
    {
        public int ServiceType;
        public int CurrentState;
        public int ControlsAccepted;
        public int Win32ExitCode;
        public int ServiceSpecificExitCode;
        public int CheckPoint;
        public int WaitHint;
        public int ProcessId;
        public int ServiceFlags;
    }

    [DllImport("advapi32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    private static extern nint OpenSCManager(
        string? machineName,
        string? databaseName,
        uint desiredAccess);

    [DllImport("advapi32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    private static extern nint OpenService(
        nint serviceManager,
        string serviceName,
        uint desiredAccess);

    [DllImport("advapi32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool QueryServiceStatusEx(
        nint service,
        int informationLevel,
        nint buffer,
        int bufferSize,
        out int bytesNeeded);

    [DllImport("advapi32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool CloseServiceHandle(nint handle);
}

