using System;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using PingGlassWindows.Core;
using PingGlassWindows.Models;
using PingGlassWindows.Notifications;

namespace PingGlassWindows.Views;

public partial class TrayControlWindow : Window
{
    private readonly AppState _appState;
    private bool _showingSettings;
    private bool _isLoadingSettings;

    public TrayControlWindow(AppState appState)
    {
        InitializeComponent();
        _appState = appState;
        SourceInitialized += (_, _) =>
        {
            Win32GlassHelper.ApplyFloatingGlassWindowStyle(this, allowKeyFocus: true, enableBlur: true, isDark: true);
        };
        Closing += (_, e) =>
        {
            e.Cancel = true;
            Hide();
        };
        _appState.StateChanged += () => Dispatcher.Invoke(RefreshUI);
        RefreshUI();
    }

    public void PositionNearTrayAndShow()
    {
        var workArea = DisplayScreenLocator.GetTargetWorkingAreaDip(PreferredDisplayMode.PrimaryDisplay);
        Left = Math.Max(workArea.Left + 8, workArea.Right - Width - 14);
        Top = Math.Max(workArea.Top + 8, workArea.Bottom - Height - 14);
        RefreshUI();
        Show();
        Activate();
    }

    public void RefreshUI()
    {
        var snap = _appState.CurrentSnapshot();
        LifecycleText.Text = _appState.LifecycleState.DisplayTitle();
        LifecycleText.Foreground = new SolidColorBrush(_appState.LifecycleState switch
        {
            MonitoringLifecycleState.MonitoringActive => System.Windows.Media.Color.FromRgb(37, 211, 102),
            MonitoringLifecycleState.MonitoringLimited => System.Windows.Media.Color.FromRgb(251, 191, 36),
            _ => System.Windows.Media.Color.FromArgb(200, 255, 255, 255)
        });

        WhatsAppRowText.Text = snap.WhatsAppRunning
            ? $"Running{(string.IsNullOrEmpty(snap.WhatsAppVersion) ? "" : $" ({snap.WhatsAppVersion})")}"
            : "Not Running";
        GlobalRowText.Text = _appState.PauseStatusSummary;
        BridgeRowText.Text = _appState.ConnectedBridgeClients > 0
            ? $"Connected ({_appState.ConnectedBridgeClients})"
            : "Not Required";
        ModeRowText.Text = snap.ExtractionMode;
        SessionRowText.Text = $"{snap.SessionMessagesForwarded} message{(snap.SessionMessagesForwarded == 1 ? "" : "s")}";
        StatusDetailText.Text = snap.StatusDetail;

        MonitoringBtn.Content = _appState.Config.MonitoringEnabled ? "❚❚ Stop Monitoring" : "▶ Start Monitoring";
        MonitoringBtn.Background = new SolidColorBrush(_appState.Config.MonitoringEnabled
            ? System.Windows.Media.Color.FromRgb(28, 173, 82)
            : System.Windows.Media.Color.FromRgb(59, 130, 246));

        ClearAllBtn.Content = _appState.TotalActiveAndQueued > 0
            ? $"Clear All ({_appState.TotalActiveAndQueued})"
            : "Clear All";
        PauseResumeBtn.Content = _appState.IsNotificationsPaused ? "Resume Notifs" : "Pause 15m";

        LoadSettingsControls();
    }

    private void LoadSettingsControls()
    {
        _isLoadingSettings = true;
        var c = _appState.Config;
        ChkGlobalEnabled.IsChecked = c.GlobalNotificationsEnabled;
        ChkChromeForward.IsChecked = c.ChromeForwardingEnabled;
        ChkGlassBlur.IsChecked = c.NativeGlassBlurEnabled;
        ChkAnimations.IsChecked = c.AnimationEnabled;
        ChkSound.IsChecked = c.SoundEnabled;
        ChkShowAvatar.IsChecked = c.ShowAvatar;
        ChkShowSender.IsChecked = c.ShowSender;
        ChkShowChatName.IsChecked = c.ShowChatName;
        ChkShowTimestamp.IsChecked = c.ShowTimestamp;
        ChkShowPreview.IsChecked = c.ShowPreview;
        ChkShowCopy.IsChecked = c.ShowCopyButton;
        ChkLaunchAtLogin.IsChecked = _appState.LaunchAtLogin.IsEnabled;

        SelectComboTag(ComboTheme, c.AppearanceMode.ToWire());
        SelectComboTag(ComboPosition, c.NotificationPosition.ToWire());
        SelectComboTag(ComboDuration, c.NotificationDurationSeconds.ToString());
        SelectComboTag(ComboClickAction, c.NotificationClickAction.ToWire());
        _isLoadingSettings = false;
    }

    private static void SelectComboTag(System.Windows.Controls.ComboBox combo, string tag)
    {
        foreach (ComboBoxItem item in combo.Items)
        {
            if (Equals(item.Tag?.ToString(), tag))
            {
                combo.SelectedItem = item;
                break;
            }
        }
    }

    private void SettingChanged(object sender, RoutedEventArgs e)
    {
        if (_isLoadingSettings) return;
        _appState.UpdateConfiguration(c =>
        {
            c.GlobalNotificationsEnabled = ChkGlobalEnabled.IsChecked == true;
            c.ChromeForwardingEnabled = ChkChromeForward.IsChecked == true;
            c.NativeGlassBlurEnabled = ChkGlassBlur.IsChecked == true;
            c.AnimationEnabled = ChkAnimations.IsChecked == true;
            c.SoundEnabled = ChkSound.IsChecked == true;
            c.ShowAvatar = ChkShowAvatar.IsChecked == true;
            c.ShowSender = ChkShowSender.IsChecked == true;
            c.ShowChatName = ChkShowChatName.IsChecked == true;
            c.ShowTimestamp = ChkShowTimestamp.IsChecked == true;
            c.ShowPreview = ChkShowPreview.IsChecked == true;
            c.ShowCopyButton = ChkShowCopy.IsChecked == true;

            if (ComboTheme.SelectedItem is ComboBoxItem t)
                c.AppearanceMode = EnumWireNames.ParseAppearance(t.Tag?.ToString());
            if (ComboPosition.SelectedItem is ComboBoxItem p)
                c.NotificationPosition = EnumWireNames.ParsePosition(p.Tag?.ToString());
            if (ComboDuration.SelectedItem is ComboBoxItem d && int.TryParse(d.Tag?.ToString(), out int sec))
                c.NotificationDurationSeconds = sec;
            if (ComboClickAction.SelectedItem is ComboBoxItem a)
                c.NotificationClickAction = EnumWireNames.ParseClickAction(a.Tag?.ToString());
        });
    }

    private void ChkLaunchAtLogin_Changed(object sender, RoutedEventArgs e)
    {
        if (_isLoadingSettings) return;
        _appState.LaunchAtLogin.SetEnabled(ChkLaunchAtLogin.IsChecked == true);
    }

    private void TabToggleBtn_Click(object sender, RoutedEventArgs e)
    {
        _showingSettings = !_showingSettings;
        StatusViewPanel.Visibility = _showingSettings ? Visibility.Collapsed : Visibility.Visible;
        SettingsViewPanel.Visibility = _showingSettings ? Visibility.Visible : Visibility.Collapsed;
        TabToggleBtn.Content = _showingSettings ? "←" : "⚙";
    }

    private void HideWindowBtn_Click(object sender, RoutedEventArgs e) => Hide();
    private void MonitoringBtn_Click(object sender, RoutedEventArgs e) => _appState.ToggleMonitoring();
    private void TestBtn_Click(object sender, RoutedEventArgs e) => _appState.SendTestNotification();
    private void ClearAllBtn_Click(object sender, RoutedEventArgs e) => _appState.ClearAllNotifications();

    private void PauseResumeBtn_Click(object sender, RoutedEventArgs e)
    {
        if (_appState.IsNotificationsPaused) _appState.ResumeNotifications();
        else _appState.PauseNotificationsForMinutes(15);
    }

    private void RefreshBtn_Click(object sender, RoutedEventArgs e) => _appState.RefreshAll();
    private void QuitBtn_Click(object sender, RoutedEventArgs e) => System.Windows.Application.Current.Shutdown();
}
