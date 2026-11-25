using System;
using System.Windows;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Media.Animation;
using PingGlassWindows.Models;

namespace PingGlassWindows.Notifications;

public partial class NotificationCardWindow : Window
{
    public WhatsAppMessage Message { get; }
    private HelperConfiguration _config;
    private bool _isExpanded;
    private readonly Action _onCardClick;
    private readonly Action _onOpenWhatsApp;
    private readonly Action _onCopy;
    private readonly Action _onDismiss;
    private readonly Action _onLayoutChanged;
    private readonly Action<bool> _onHoverChanged;

    public NotificationCardWindow(
        WhatsAppMessage message,
        HelperConfiguration config,
        Action onCardClick,
        Action onOpenWhatsApp,
        Action onCopy,
        Action onDismiss,
        Action onLayoutChanged,
        Action<bool> onHoverChanged)
    {
        InitializeComponent();
        Message = message;
        _config = config;
        _onCardClick = onCardClick;
        _onOpenWhatsApp = onOpenWhatsApp;
        _onCopy = onCopy;
        _onDismiss = onDismiss;
        _onLayoutChanged = onLayoutChanged;
        _onHoverChanged = onHoverChanged;

        SourceInitialized += (_, _) =>
        {
            Win32GlassHelper.ApplyFloatingGlassWindowStyle(
                this,
                allowKeyFocus: false,
                enableBlur: _config.NativeGlassBlurEnabled,
                isDark: _config.AppearanceMode == GlassAppearanceMode.Dark);
        };

        MouseEnter += (_, _) =>
        {
            HoverHintText.Opacity = 1.0;
            _onHoverChanged(true);
        };
        MouseLeave += (_, _) =>
        {
            HoverHintText.Opacity = 0.0;
            _onHoverChanged(false);
        };
        MouseLeftButtonUp += (_, e) =>
        {
            if (e.Handled) return;
            _onCardClick();
        };

        PopulateContent();
        ApplyAppearance(_config);
    }

    public void ApplyAppearance(HelperConfiguration config)
    {
        _config = config;
        bool isDark = config.AppearanceMode == GlassAppearanceMode.Dark;

        if (isDark)
        {
            CardRoot.Background = new LinearGradientBrush(
                new GradientStopCollection
                {
                    new(System.Windows.Media.Color.FromArgb(208, 24, 42, 33), 0.0),
                    new(System.Windows.Media.Color.FromArgb(214, 20, 23, 29), 0.34),
                    new(System.Windows.Media.Color.FromArgb(212, 16, 18, 23), 1.0)
                },
                new System.Windows.Point(0, 0),
                new System.Windows.Point(1, 1));
            CardRoot.BorderBrush = new SolidColorBrush(System.Windows.Media.Color.FromArgb(62, 255, 255, 255));
            WhatsAppLabel.Foreground = System.Windows.Media.Brushes.White;
            SenderText.Foreground = System.Windows.Media.Brushes.White;
            PreviewText.Foreground = new SolidColorBrush(System.Windows.Media.Color.FromArgb(232, 255, 255, 255));
            ChatNameText.Foreground = new SolidColorBrush(System.Windows.Media.Color.FromArgb(165, 255, 255, 255));
            TimeText.Foreground = new SolidColorBrush(System.Windows.Media.Color.FromArgb(150, 255, 255, 255));
            AvatarInitials.Foreground = System.Windows.Media.Brushes.White;
            VerticalDivider.Background = new SolidColorBrush(System.Windows.Media.Color.FromArgb(36, 255, 255, 255));
        }
        else
        {
            CardRoot.Background = new LinearGradientBrush(
                new GradientStopCollection
                {
                    new(System.Windows.Media.Color.FromArgb(235, 228, 248, 237), 0.0),
                    new(System.Windows.Media.Color.FromArgb(238, 246, 248, 252), 0.36),
                    new(System.Windows.Media.Color.FromArgb(236, 242, 245, 250), 1.0)
                },
                new System.Windows.Point(0, 0),
                new System.Windows.Point(1, 1));
            CardRoot.BorderBrush = new SolidColorBrush(System.Windows.Media.Color.FromArgb(42, 15, 23, 42));
            var ink = new SolidColorBrush(System.Windows.Media.Color.FromRgb(15, 23, 42));
            WhatsAppLabel.Foreground = ink;
            SenderText.Foreground = ink;
            PreviewText.Foreground = new SolidColorBrush(System.Windows.Media.Color.FromRgb(30, 41, 59));
            ChatNameText.Foreground = new SolidColorBrush(System.Windows.Media.Color.FromRgb(100, 116, 139));
            TimeText.Foreground = new SolidColorBrush(System.Windows.Media.Color.FromRgb(100, 116, 139));
            AvatarInitials.Foreground = new SolidColorBrush(System.Windows.Media.Color.FromRgb(6, 95, 70));
            VerticalDivider.Background = new SolidColorBrush(System.Windows.Media.Color.FromArgb(28, 15, 23, 42));
        }

        HoverHintText.Text = config.NotificationClickAction == NotificationClickAction.OpenGlassChatPopup
            ? "Click to view & reply →"
            : "Click to open chat →";

        if (IsLoaded)
        {
            Win32GlassHelper.ApplyBlur(
                new System.Windows.Interop.WindowInteropHelper(this).Handle,
                config.NativeGlassBlurEnabled,
                isDark);
        }
    }

    private void PopulateContent()
    {
        string displaySender = !string.IsNullOrWhiteSpace(Message.Sender)
            ? Message.Sender!
            : (!string.IsNullOrWhiteSpace(Message.ChatName) ? Message.ChatName! : "WhatsApp Message");

        SenderText.Text = displaySender;
        SenderText.Visibility = _config.ShowSender ? Visibility.Visible : Visibility.Collapsed;
        TestBadge.Visibility = Message.IsTest ? Visibility.Visible : Visibility.Collapsed;

        TimeText.Text = Message.Timestamp ?? "NOW";
        TimeText.Visibility = _config.ShowTimestamp ? Visibility.Visible : Visibility.Collapsed;

        AvatarBorder.Visibility = _config.ShowAvatar ? Visibility.Visible : Visibility.Collapsed;
        VerticalDivider.Visibility = _config.ShowAvatar ? Visibility.Visible : Visibility.Collapsed;
        AvatarInitials.Text = ComputeInitials(displaySender);

        bool showChat = _config.ShowChatName &&
                        !string.IsNullOrWhiteSpace(Message.ChatName) &&
                        !string.Equals(Message.ChatName, displaySender, StringComparison.OrdinalIgnoreCase);
        ChatNameText.Text = Message.ChatName ?? string.Empty;
        ChatNameText.Visibility = showChat ? Visibility.Visible : Visibility.Collapsed;

        string text = Message.Text ?? string.Empty;
        PreviewText.Text = text;
        PreviewText.Visibility = (_config.ShowPreview && text.Length > 0) ? Visibility.Visible : Visibility.Collapsed;
        CopyBtn.Visibility = (_config.ShowCopyButton && text.Length > 0) ? Visibility.Visible : Visibility.Collapsed;

        bool canExpand = text.Length > 140 || text.Split('\n').Length > 4;
        ExpandBtn.Visibility = canExpand ? Visibility.Visible : Visibility.Collapsed;
    }

    public System.Windows.Size MeasurePreferredSize()
    {
        Measure(new System.Windows.Size(320, 420));
        return new System.Windows.Size(320, Math.Clamp(DesiredSize.Height > 0 ? DesiredSize.Height : 112, 86, 260));
    }

    public void AnimateEntrance(double targetTop)
    {
        Opacity = 0;
        Top = targetTop + 20;
        var slide = new DoubleAnimation(targetTop + 20, targetTop, TimeSpan.FromMilliseconds(320))
        {
            EasingFunction = new CubicEase { EasingMode = EasingMode.EaseOut }
        };
        var fade = new DoubleAnimation(0, 1, TimeSpan.FromMilliseconds(260));
        BeginAnimation(TopProperty, slide);
        BeginAnimation(OpacityProperty, fade);
    }

    public void AnimateDismiss(Action onDone)
    {
        var slide = new DoubleAnimation(Top, Top - 14, TimeSpan.FromMilliseconds(200));
        var fade = new DoubleAnimation(Opacity, 0, TimeSpan.FromMilliseconds(200));
        fade.Completed += (_, _) => onDone();
        BeginAnimation(TopProperty, slide);
        BeginAnimation(OpacityProperty, fade);
    }

    private void OpenBtn_Click(object sender, RoutedEventArgs e)
    {
        e.Handled = true;
        _onOpenWhatsApp();
    }

    private void CopyBtn_Click(object sender, RoutedEventArgs e)
    {
        e.Handled = true;
        _onCopy();
        CopiedPill.Visibility = Visibility.Visible;
        TimeText.Visibility = Visibility.Collapsed;
        var timer = new System.Windows.Threading.DispatcherTimer { Interval = TimeSpan.FromSeconds(1.4) };
        timer.Tick += (_, _) =>
        {
            timer.Stop();
            CopiedPill.Visibility = Visibility.Collapsed;
            TimeText.Visibility = _config.ShowTimestamp ? Visibility.Visible : Visibility.Collapsed;
        };
        timer.Start();
    }

    private void CloseBtn_Click(object sender, RoutedEventArgs e)
    {
        e.Handled = true;
        _onDismiss();
    }

    private void ExpandBtn_Click(object sender, RoutedEventArgs e)
    {
        e.Handled = true;
        _isExpanded = !_isExpanded;
        PreviewText.MaxHeight = _isExpanded ? 210 : 76;
        ExpandBtn.Content = _isExpanded ? "Show less" : "Show more";
        UpdateLayout();
        _onLayoutChanged();
    }

    private static string ComputeInitials(string name)
    {
        var parts = name.Split(' ', StringSplitOptions.RemoveEmptyEntries);
        if (parts.Length == 0) return "WA";
        if (parts.Length == 1) return parts[0][..Math.Min(2, parts[0].Length)].ToUpperInvariant();
        return $"{char.ToUpperInvariant(parts[0][0])}{char.ToUpperInvariant(parts[^1][0])}";
    }
}
