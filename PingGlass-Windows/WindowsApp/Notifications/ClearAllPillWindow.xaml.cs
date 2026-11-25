using System;
using System.Windows;
using System.Windows.Media;
using PingGlassWindows.Models;

namespace PingGlassWindows.Notifications;

public partial class ClearAllPillWindow : Window
{
    private Action _onClick;

    public ClearAllPillWindow(int totalCount, HelperConfiguration config, Action onClick)
    {
        InitializeComponent();
        _onClick = onClick;

        SourceInitialized += (_, _) =>
        {
            Win32GlassHelper.ApplyFloatingGlassWindowStyle(
                this,
                allowKeyFocus: false,
                enableBlur: config.NativeGlassBlurEnabled,
                isDark: config.AppearanceMode == GlassAppearanceMode.Dark);
        };

        UpdateState(totalCount, config, onClick);
    }

    public void UpdateState(int totalCount, HelperConfiguration config, Action onClick)
    {
        _onClick = onClick;
        PillText.Text = totalCount > 1 ? $"Clear All ({totalCount})" : "Clear All";
        bool isDark = config.AppearanceMode == GlassAppearanceMode.Dark;
        PillBorder.Background = new SolidColorBrush(isDark
            ? System.Windows.Media.Color.FromArgb(208, 22, 24, 30)
            : System.Windows.Media.Color.FromArgb(236, 246, 248, 252));
        PillBorder.BorderBrush = new SolidColorBrush(isDark
            ? System.Windows.Media.Color.FromArgb(64, 255, 255, 255)
            : System.Windows.Media.Color.FromArgb(40, 15, 23, 42));
        PillText.Foreground = isDark
            ? System.Windows.Media.Brushes.White
            : new SolidColorBrush(System.Windows.Media.Color.FromRgb(15, 23, 42));
    }

    public System.Windows.Size MeasurePreferredSize()
    {
        Measure(new System.Windows.Size(220, 48));
        return new System.Windows.Size(Math.Max(92, DesiredSize.Width), Math.Max(28, DesiredSize.Height));
    }

    private void PillBtn_Click(object sender, RoutedEventArgs e)
    {
        _onClick();
    }
}
