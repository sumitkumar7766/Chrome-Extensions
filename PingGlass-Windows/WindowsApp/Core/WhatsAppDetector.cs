using System;
using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;

namespace PingGlassWindows.Core;

public sealed record WhatsAppProcessInfo(
    int Pid,
    string ProcessName,
    string? PackageId,
    string? Version,
    bool IsActive,
    IntPtr MainWindowHandle);

/// <summary>
/// Detects running WhatsApp Desktop for Windows (Microsoft Store UWP/WinUI3 or Desktop EXE)
/// using public Process & Win32 foreground window checks.
/// </summary>
public sealed class WhatsAppDetector : IDisposable
{
    private readonly System.Threading.Timer _pollTimer;
    private WhatsAppProcessInfo? _current;

    public WhatsAppProcessInfo? CurrentProcess => _current;
    public event Action<WhatsAppProcessInfo?>? OnProcessChanged;

    [DllImport("user32.dll")]
    private static extern IntPtr GetForegroundWindow();

    [DllImport("user32.dll")]
    private static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint processId);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern int GetWindowText(IntPtr hWnd, System.Text.StringBuilder text, int count);

    [DllImport("user32.dll")]
    private static extern bool EnumWindows(EnumWindowsProc lpEnumFunc, IntPtr lParam);

    private delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);

    public WhatsAppDetector()
    {
        RefreshNow();
        _pollTimer = new System.Threading.Timer(_ => RefreshNow(), null, TimeSpan.FromSeconds(2), TimeSpan.FromSeconds(2));
    }

    public void RefreshNow()
    {
        var detected = FindWhatsAppProcess();
        if (!Equals(detected, _current))
        {
            _current = detected;
            OnProcessChanged?.Invoke(detected);
        }
    }

    private static WhatsAppProcessInfo? FindWhatsAppProcess()
    {
        IntPtr fgHwnd = GetForegroundWindow();
        uint fgPid = 0;
        if (fgHwnd != IntPtr.Zero)
        {
            _ = GetWindowThreadProcessId(fgHwnd, out fgPid);
        }

        // Strategy 1: Direct WhatsApp.exe / WhatsAppBeta.exe process
        foreach (var procName in new[] { "WhatsApp", "WhatsApp.Root", "WhatsAppBeta" })
        {
            var procs = Process.GetProcessesByName(procName);
            foreach (var proc in procs)
            {
                try
                {
                    if (proc.HasExited) continue;
                    string? version = null;
                    try
                    {
                        var modulePath = proc.MainModule?.FileName;
                        if (!string.IsNullOrEmpty(modulePath) && File.Exists(modulePath))
                        {
                            version = FileVersionInfo.GetVersionInfo(modulePath).ProductVersion;
                        }
                    }
                    catch
                    {
                        // Store apps may block MainModule access without elevation; ignore cleanly.
                    }

                    var hwnd = proc.MainWindowHandle != IntPtr.Zero
                        ? proc.MainWindowHandle
                        : FindWindowForPid(proc.Id);

                    return new WhatsAppProcessInfo(
                        Pid: proc.Id,
                        ProcessName: proc.ProcessName,
                        PackageId: "5319275A.WhatsAppDesktop",
                        Version: version,
                        IsActive: fgPid == (uint)proc.Id || (hwnd != IntPtr.Zero && hwnd == fgHwnd),
                        MainWindowHandle: hwnd);
                }
                catch
                {
                    // Ignore inaccessible transient processes.
                }
            }
        }

        // Strategy 2: UWP ApplicationFrameHost hosting "WhatsApp" window
        IntPtr uwpHwnd = IntPtr.Zero;
        uint uwpPid = 0;
        EnumWindows((hWnd, _) =>
        {
            var sb = new System.Text.StringBuilder(256);
            if (GetWindowText(hWnd, sb, sb.Capacity) > 0)
            {
                var title = sb.ToString().Trim();
                if (string.Equals(title, "WhatsApp", StringComparison.OrdinalIgnoreCase) ||
                    title.StartsWith("WhatsApp", StringComparison.OrdinalIgnoreCase))
                {
                    _ = GetWindowThreadProcessId(hWnd, out uint pid);
                    try
                    {
                        using var p = Process.GetProcessById((int)pid);
                        if (p.ProcessName.Contains("ApplicationFrameHost", StringComparison.OrdinalIgnoreCase) ||
                            p.ProcessName.Contains("WhatsApp", StringComparison.OrdinalIgnoreCase))
                        {
                            uwpHwnd = hWnd;
                            uwpPid = pid;
                            return false;
                        }
                    }
                    catch
                    {
                        // Ignore closed processes
                    }
                }
            }
            return true;
        }, IntPtr.Zero);

        if (uwpHwnd != IntPtr.Zero && uwpPid != 0)
        {
            return new WhatsAppProcessInfo(
                Pid: (int)uwpPid,
                ProcessName: "WhatsAppDesktop",
                PackageId: "5319275A.WhatsAppDesktop",
                Version: null,
                IsActive: uwpHwnd == fgHwnd,
                MainWindowHandle: uwpHwnd);
        }

        return null;
    }

    private static IntPtr FindWindowForPid(int targetPid)
    {
        IntPtr found = IntPtr.Zero;
        EnumWindows((hWnd, _) =>
        {
            _ = GetWindowThreadProcessId(hWnd, out uint pid);
            if (pid == (uint)targetPid)
            {
                var sb = new System.Text.StringBuilder(256);
                GetWindowText(hWnd, sb, sb.Capacity);
                if (sb.Length > 0)
                {
                    found = hWnd;
                    return false;
                }
            }
            return true;
        }, IntPtr.Zero);
        return found;
    }

    public void Dispose()
    {
        _pollTimer.Dispose();
    }
}
