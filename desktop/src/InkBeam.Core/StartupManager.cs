using Microsoft.Win32;

namespace InkBeam.Core;

public sealed class StartupManager(AppPaths paths)
{
    private const string RunKeyPath =
        @"Software\Microsoft\Windows\CurrentVersion\Run";
    private const string PreferenceKeyPath = @"Software\InkBeam";
    private const string ValueName = "InkBeam";
    private const string PreferenceMarker = "StartAtSignInConfigured";

    public bool GetPreference()
    {
        using RegistryKey? runKey = Registry.CurrentUser.OpenSubKey(RunKeyPath);
        if (runKey?.GetValue(ValueName) is string value &&
            !string.IsNullOrWhiteSpace(value))
        {
            return true;
        }

        using RegistryKey? preference =
            Registry.CurrentUser.OpenSubKey(PreferenceKeyPath);
        return preference?.GetValue(PreferenceMarker) is null;
    }

    public void SetPreference(bool enabled)
    {
        using RegistryKey runKey =
            Registry.CurrentUser.CreateSubKey(RunKeyPath, writable: true);
        if (enabled)
        {
            runKey.SetValue(
                ValueName,
                BuildRunValue(paths.InstalledExecutablePath),
                RegistryValueKind.String);
        }
        else
        {
            runKey.DeleteValue(ValueName, throwOnMissingValue: false);
        }

        using RegistryKey preference =
            Registry.CurrentUser.CreateSubKey(
                PreferenceKeyPath,
                writable: true);
        preference.SetValue(
            PreferenceMarker,
            1,
            RegistryValueKind.DWord);
    }

    public static string BuildRunValue(string executablePath) =>
        $"\"{executablePath}\" --background";
}

