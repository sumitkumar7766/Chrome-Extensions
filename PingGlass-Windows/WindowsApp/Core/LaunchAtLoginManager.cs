using System;
using System.Diagnostics;
using Microsoft.Win32;

namespace PingGlassWindows.Core;

/// <summary>
/// Manages HKCU\Software\Microsoft\Windows\CurrentVersion\Run startup entry cleanly (no admin required).
/// </summary>
public sealed class LaunchAtLoginManager
{
    private const string RunKeyPath = @"Software\Microsoft\Windows\CurrentVersion\Run";
    private const string ValueName = "PingGlassWindows";

    public bool IsSupported => true;

    public bool IsEnabled
    {
        get
        {
            try
            {
                using var key = Registry.CurrentUser.OpenSubKey(RunKeyPath, writable: false);
                return key?.GetValue(ValueName) is string raw && !string.IsNullOrWhiteSpace(raw);
            }
            catch
            {
                return false;
            }
        }
    }

    public string StatusNote { get; private set; } = "Starts PingGlass silently in the Windows tray at sign-in.";

    public bool SetEnabled(bool enabled)
    {
        try
        {
            using var key = Registry.CurrentUser.OpenSubKey(RunKeyPath, writable: true)
                ?? Registry.CurrentUser.CreateSubKey(RunKeyPath, writable: true);
            if (key == null)
            {
                StatusNote = "Unable to access Windows startup registry key.";
                return false;
            }

            if (enabled)
            {
                var exePath = Environment.ProcessPath ?? Process.GetCurrentProcess().MainModule?.FileName;
                if (string.IsNullOrWhiteSpace(exePath))
                {
                    StatusNote = "Could not resolve executable path.";
                    return false;
                }
                key.SetValue(ValueName, $"\"{exePath}\"", RegistryValueKind.String);
                StatusNote = "Registered in HKCU Run startup key.";
            }
            else
            {
                key.DeleteValue(ValueName, throwOnMissingValue: false);
                StatusNote = "Removed from Windows startup.";
            }
            return true;
        }
        catch (Exception ex)
        {
            StatusNote = $"Startup toggle error: {ex.Message}";
            return false;
        }
    }
}
