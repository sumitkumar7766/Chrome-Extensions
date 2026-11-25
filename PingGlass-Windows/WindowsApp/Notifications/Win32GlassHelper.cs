using System;
using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Interop;

namespace PingGlassWindows.Notifications;

/// <summary>
/// Configures Windows 10/11 Acrylic/Blur glass backdrops, rounded corners (DWM),
/// and non-activating WS_EX_NOACTIVATE floating styles so overlays never steal focus.
/// </summary>
public static class Win32GlassHelper
{
    private const int GWL_EXSTYLE = -20;
    private const int WS_EX_TOOLWINDOW = 0x00000080;
    private const int WS_EX_NOACTIVATE = 0x08000000;
    private const int DWMWA_WINDOW_CORNER_PREFERENCE = 33;

    [DllImport("user32.dll")]
    private static extern int GetWindowLong(IntPtr hWnd, int nIndex);

    [DllImport("user32.dll")]
    private static extern int SetWindowLong(IntPtr hWnd, int nIndex, int dwNewLong);

    [DllImport("dwmapi.dll")]
    private static extern int DwmSetWindowAttribute(IntPtr hwnd, int attr, ref int attrValue, int attrSize);

    [DllImport("user32.dll")]
    private static extern int SetWindowCompositionAttribute(IntPtr hwnd, ref WindowCompositionAttributeData data);

    private enum AccentState
    {
        ACCENT_DISABLED = 0,
        ACCENT_ENABLE_BLURBEHIND = 3,
        ACCENT_ENABLE_ACRYLICBLURBEHIND = 4
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct AccentPolicy
    {
        public AccentState AccentState;
        public int AccentFlags;
        public uint GradientColor;
        public int AnimationId;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct WindowCompositionAttributeData
    {
        public int Attribute;
        public IntPtr Data;
        public int SizeOfData;
    }

    public static void ApplyFloatingGlassWindowStyle(Window window, bool allowKeyFocus, bool enableBlur, bool isDark)
    {
        var hwnd = new WindowInteropHelper(window).Handle;
        if (hwnd == IntPtr.Zero) return;

        int exStyle = GetWindowLong(hwnd, GWL_EXSTYLE);
        exStyle |= WS_EX_TOOLWINDOW;
        if (!allowKeyFocus)
        {
            exStyle |= WS_EX_NOACTIVATE;
        }
        else
        {
            exStyle &= ~WS_EX_NOACTIVATE;
        }
        _ = SetWindowLong(hwnd, GWL_EXSTYLE, exStyle);

        int cornerPref = 2; // DWMWCP_ROUND
        _ = DwmSetWindowAttribute(hwnd, DWMWA_WINDOW_CORNER_PREFERENCE, ref cornerPref, sizeof(int));

        ApplyBlur(hwnd, enableBlur, isDark);
    }

    public static void ApplyBlur(IntPtr hwnd, bool enableBlur, bool isDark)
    {
        if (hwnd == IntPtr.Zero) return;
        uint tintColor = isDark ? 0xB8181A1Eu : 0xCCF4F6FAu; // ABGR subtle charcoal dark vs frosted light

        var accent = new AccentPolicy
        {
            AccentState = enableBlur ? AccentState.ACCENT_ENABLE_ACRYLICBLURBEHIND : AccentState.ACCENT_DISABLED,
            AccentFlags = 2,
            GradientColor = tintColor
        };

        int size = Marshal.SizeOf(accent);
        IntPtr ptr = Marshal.AllocHGlobal(size);
        try
        {
            Marshal.StructureToPtr(accent, ptr, false);
            var data = new WindowCompositionAttributeData
            {
                Attribute = 19, // WCA_ACCENT_POLICY
                Data = ptr,
                SizeOfData = size
            };
            _ = SetWindowCompositionAttribute(hwnd, ref data);
        }
        catch
        {
            // Software glass translucency fallback continues automatically.
        }
        finally
        {
            Marshal.FreeHGlobal(ptr);
        }
    }
}
