using System.Text.Json;

namespace InkBeam.Core;

public enum ReceiverDisplayState
{
    SetupRequired,
    Disabled,
    Starting,
    Ready,
    Pairing,
    Casting,
    Error
}

public enum PrerequisiteState
{
    Available,
    Unavailable,
    Unknown
}

public sealed record ReceiverStateMessage(
    int Version,
    ReceiverDisplayState State,
    string? Pin,
    long Revision,
    int ReceiverPid,
    string Message);

public sealed record ReceiverConfiguration(
    string ReceiverName,
    string Authentication,
    bool AudioEnabled,
    bool Fullscreen)
{
    public static ReceiverConfiguration Default { get; } =
        new("InkBeam", "every-connection", false, false);
}

public sealed record RuntimeManifest(string ExecutablePath);

public sealed record PrerequisiteStatus(
    PrerequisiteState State,
    string Label,
    string Detail);

public sealed record ReceiverSnapshot(
    ReceiverDisplayState State,
    string Label,
    string Detail,
    string? Pin,
    long Revision,
    int ReceiverPid,
    ReceiverConfiguration Configuration,
    bool CanEnable,
    bool IsReceiverRunning,
    PrerequisiteStatus Discovery,
    PrerequisiteStatus Network);

public static class ReceiverNameValidator
{
    public const string ErrorMessage =
        "The AirPlay name must be 1–64 characters, cannot start with a hyphen, " +
        "and cannot contain whitespace, quotes, or percent signs.";

    public static bool IsValid(string? name)
    {
        if (string.IsNullOrWhiteSpace(name) || name.Length > 64 ||
            name.StartsWith('-'))
        {
            return false;
        }

        return !name.Any(character =>
            char.IsWhiteSpace(character) || character is '"' or '%');
    }
}

public static class ReceiverStateProtocol
{
    private static readonly HashSet<string> AllowedStates =
        new(StringComparer.Ordinal)
        {
            "Starting",
            "Ready",
            "Pairing",
            "Casting",
            "Error"
        };

    public static bool TryParse(
        string json,
        out ReceiverStateMessage? message,
        out string error)
    {
        message = null;
        error = string.Empty;

        if (string.IsNullOrWhiteSpace(json) || json.Length > 4096)
        {
            error = "The receiver state response was empty or too large.";
            return false;
        }

        try
        {
            using JsonDocument document = JsonDocument.Parse(json, new()
            {
                AllowTrailingCommas = false,
                CommentHandling = JsonCommentHandling.Disallow,
                MaxDepth = 8
            });

            JsonElement root = document.RootElement;
            if (root.ValueKind != JsonValueKind.Object ||
                !TryGetInt32(root, "version", out int version) ||
                version != 1 ||
                !TryGetString(root, "state", out string? stateText) ||
                !AllowedStates.Contains(stateText) ||
                !TryGetInt64(root, "revision", out long revision) ||
                revision < 0 ||
                !TryGetInt32(root, "receiverPid", out int receiverPid) ||
                receiverPid <= 0 ||
                !TryGetString(root, "message", out string? stateMessage) ||
                stateMessage.Length > 1024)
            {
                error = "The receiver state response did not match protocol version 1.";
                return false;
            }

            string? pin = null;
            if (!root.TryGetProperty("pin", out JsonElement pinElement))
            {
                error = "The receiver state response did not include a PIN field.";
                return false;
            }

            if (pinElement.ValueKind == JsonValueKind.String)
            {
                pin = pinElement.GetString();
                if (pin is null || pin.Length != 4 ||
                    pin.Any(character => character is < '0' or > '9'))
                {
                    error = "The receiver state response included an invalid PIN.";
                    return false;
                }
            }
            else if (pinElement.ValueKind != JsonValueKind.Null)
            {
                error = "The receiver state response included an invalid PIN.";
                return false;
            }

            ReceiverDisplayState state = Enum.Parse<ReceiverDisplayState>(
                stateText,
                ignoreCase: false);
            if (state != ReceiverDisplayState.Pairing && pin is not null)
            {
                error = "The receiver state response included a PIN outside pairing.";
                return false;
            }

            message = new(
                version,
                state,
                pin,
                revision,
                receiverPid,
                stateMessage);
            return true;
        }
        catch (JsonException)
        {
            error = "The receiver state response was not valid JSON.";
            return false;
        }
    }

    private static bool TryGetString(
        JsonElement root,
        string name,
        out string value)
    {
        value = string.Empty;
        if (!root.TryGetProperty(name, out JsonElement element) ||
            element.ValueKind != JsonValueKind.String)
        {
            return false;
        }

        value = element.GetString() ?? string.Empty;
        return true;
    }

    private static bool TryGetInt32(
        JsonElement root,
        string name,
        out int value)
    {
        value = 0;
        return root.TryGetProperty(name, out JsonElement element) &&
            element.ValueKind == JsonValueKind.Number &&
            element.TryGetInt32(out value);
    }

    private static bool TryGetInt64(
        JsonElement root,
        string name,
        out long value)
    {
        value = 0;
        return root.TryGetProperty(name, out JsonElement element) &&
            element.ValueKind == JsonValueKind.Number &&
            element.TryGetInt64(out value);
    }
}

public sealed record AppLaunchOptions(bool Background, bool SelfTest);

public sealed record ArgumentParseResult(
    bool IsValid,
    AppLaunchOptions Options,
    string Error)
{
    public static ArgumentParseResult Parse(IEnumerable<string> arguments)
    {
        bool background = false;
        bool selfTest = false;
        foreach (string argument in arguments)
        {
            if (string.Equals(
                    argument,
                    "--background",
                    StringComparison.OrdinalIgnoreCase) &&
                !background)
            {
                background = true;
                continue;
            }

            if ((string.Equals(
                    argument,
                    "--self-test",
                    StringComparison.OrdinalIgnoreCase) ||
                string.Equals(
                    argument,
                    "--smoke-test",
                    StringComparison.OrdinalIgnoreCase)) &&
                !selfTest)
            {
                selfTest = true;
                continue;
            }

            return new(
                false,
                new(background, selfTest),
                $"Unsupported InkBeam argument: {argument}");
        }

        if (background && selfTest)
        {
            return new(
                false,
                new(background, selfTest),
                "--background cannot be combined with a self-test.");
        }

        return new(true, new(background, selfTest), string.Empty);
    }
}
