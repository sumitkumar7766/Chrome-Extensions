using System;
using System.Collections.Generic;
using System.Linq;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using PingGlassWindows.Models;

namespace PingGlassWindows.Notifications;

public partial class FloatingChatPopupWindow : Window
{
    public static readonly System.Windows.Size PopupSize = new(342, 414);

    private static readonly string[] QuickReplies = { "👍", "Ok", "On my way", "Call soon" };

    private string _chatTitle = "WhatsApp Chat";
    private List<ChatBubbleEntry> _messages = new();
    private bool _isSending;
    private Action _onRefresh = () => { };
    private Action _onOpenWhatsApp = () => { };
    private Action<string> _onCopyText = _ => { };
    private Action<string, Action<ReplyDispatchResult>> _onSendReply = (_, cb) => cb(new ReplyDispatchResult { Succeeded = false });
    private Action _onClose = () => { };

    public FloatingChatPopupWindow()
    {
        InitializeComponent();
        SourceInitialized += (_, _) =>
        {
            Win32GlassHelper.ApplyFloatingGlassWindowStyle(this, allowKeyFocus: true, enableBlur: true, isDark: true);
        };
        Loaded += (_, _) => ReplyTextBox.Focus();
        BuildQuickChips();
    }

    public void UpdateState(
        string chatTitle,
        string? subtitle,
        List<ChatBubbleEntry> messages,
        bool isLiveUiaSynced,
        bool isTestChat,
        HelperConfiguration config,
        Action onRefresh,
        Action onOpenWhatsApp,
        Action<string> onCopyText,
        Action<string, Action<ReplyDispatchResult>> onSendReply,
        Action onClose)
    {
        _chatTitle = chatTitle;
        _messages = messages;
        _onRefresh = onRefresh;
        _onOpenWhatsApp = onOpenWhatsApp;
        _onCopyText = onCopyText;
        _onSendReply = onSendReply;
        _onClose = onClose;

        ChatTitleText.Text = chatTitle;
        AvatarInitials.Text = ComputeInitials(chatTitle);
        TestPill.Visibility = isTestChat ? Visibility.Visible : Visibility.Collapsed;
        CopyAllBtn.Visibility = messages.Count > 0 ? Visibility.Visible : Visibility.Collapsed;

        string countSuffix = messages.Count > 0 ? $" · {messages.Count} msg{(messages.Count == 1 ? "" : "s")}" : string.Empty;
        string baseSub = !string.IsNullOrWhiteSpace(subtitle)
            ? subtitle!
            : (isLiveUiaSynced ? "Live WhatsApp Sync" : "Session Chat");
        SubtitleText.Text = baseSub + countSuffix;
        SyncDot.Fill = new SolidColorBrush(isLiveUiaSynced
            ? System.Windows.Media.Color.FromRgb(37, 211, 102)
            : System.Windows.Media.Color.FromArgb(165, 255, 255, 255));

        ApplyTheme(config);
        RenderBubbles(isLiveUiaSynced, isTestChat, config);
    }

    private void ApplyTheme(HelperConfiguration config)
    {
        bool isDark = config.AppearanceMode == GlassAppearanceMode.Dark;
        if (isDark)
        {
            PopupRoot.Background = new LinearGradientBrush(
                new GradientStopCollection
                {
                    new(System.Windows.Media.Color.FromArgb(210, 24, 42, 33), 0.0),
                    new(System.Windows.Media.Color.FromArgb(220, 19, 22, 28), 0.35),
                    new(System.Windows.Media.Color.FromArgb(224, 15, 17, 22), 1.0)
                },
                new System.Windows.Point(0, 0),
                new System.Windows.Point(1, 1));
            PopupRoot.BorderBrush = new SolidColorBrush(System.Windows.Media.Color.FromArgb(64, 255, 255, 255));
            ChatTitleText.Foreground = System.Windows.Media.Brushes.White;
            ReplyTextBox.Foreground = System.Windows.Media.Brushes.White;
        }
        else
        {
            PopupRoot.Background = new LinearGradientBrush(
                new GradientStopCollection
                {
                    new(System.Windows.Media.Color.FromArgb(236, 228, 248, 237), 0.0),
                    new(System.Windows.Media.Color.FromArgb(242, 246, 248, 252), 0.35),
                    new(System.Windows.Media.Color.FromArgb(242, 242, 245, 250), 1.0)
                },
                new System.Windows.Point(0, 0),
                new System.Windows.Point(1, 1));
            PopupRoot.BorderBrush = new SolidColorBrush(System.Windows.Media.Color.FromArgb(40, 15, 23, 42));
            var ink = new SolidColorBrush(System.Windows.Media.Color.FromRgb(15, 23, 42));
            ChatTitleText.Foreground = ink;
            ReplyTextBox.Foreground = ink;
        }
    }

    private void RenderBubbles(bool isLiveUiaSynced, bool isTestChat, HelperConfiguration config)
    {
        MessagesPanel.Children.Clear();
        bool isDark = config.AppearanceMode == GlassAppearanceMode.Dark;

        if (_messages.Count == 0)
        {
            MessagesPanel.Children.Add(new TextBlock
            {
                Text = "No accessible messages captured for this chat yet.",
                FontSize = 11.5,
                Foreground = new SolidColorBrush(System.Windows.Media.Color.FromArgb(145, 255, 255, 255)),
                TextAlignment = TextAlignment.Center,
                TextWrapping = TextWrapping.Wrap,
                Margin = new Thickness(12, 36, 12, 8)
            });
        }
        else
        {
            foreach (var entry in _messages)
            {
                var border = new Border
                {
                    CornerRadius = new CornerRadius(13),
                    Padding = new Thickness(10, 7, 10, 7),
                    Margin = entry.IsOutgoing ? new Thickness(42, 0, 0, 7) : new Thickness(0, 0, 42, 7),
                    HorizontalAlignment = entry.IsOutgoing ? System.Windows.HorizontalAlignment.Right : System.Windows.HorizontalAlignment.Left,
                    Background = new SolidColorBrush(entry.IsOutgoing
                        ? System.Windows.Media.Color.FromArgb(62, 37, 211, 102)
                        : (isDark ? System.Windows.Media.Color.FromArgb(24, 255, 255, 255) : System.Windows.Media.Color.FromArgb(18, 15, 23, 42))),
                    BorderThickness = new Thickness(1),
                    BorderBrush = new SolidColorBrush(entry.IsOutgoing
                        ? System.Windows.Media.Color.FromArgb(95, 37, 211, 102)
                        : (isDark ? System.Windows.Media.Color.FromArgb(30, 255, 255, 255) : System.Windows.Media.Color.FromArgb(22, 15, 23, 42)))
                };

                var stack = new StackPanel();
                if (!entry.IsOutgoing && !string.IsNullOrWhiteSpace(entry.Sender) && entry.Sender != _chatTitle)
                {
                    stack.Children.Add(new TextBlock
                    {
                        Text = entry.Sender,
                        FontSize = 10.5,
                        FontWeight = FontWeights.SemiBold,
                        Foreground = new SolidColorBrush(System.Windows.Media.Color.FromRgb(37, 211, 102)),
                        Margin = new Thickness(0, 0, 0, 2)
                    });
                }

                // Read-only TextBox enables native text selection inside message bubbles
                stack.Children.Add(new System.Windows.Controls.TextBox
                {
                    Text = entry.Text,
                    IsReadOnly = true,
                    BorderThickness = new Thickness(0),
                    Background = System.Windows.Media.Brushes.Transparent,
                    Foreground = isDark
                        ? System.Windows.Media.Brushes.White
                        : new SolidColorBrush(System.Windows.Media.Color.FromRgb(15, 23, 42)),
                    FontSize = 12.6,
                    TextWrapping = TextWrapping.Wrap,
                    Padding = new Thickness(0)
                });

                var metaGrid = new Grid { Margin = new Thickness(0, 3, 0, 0) };
                metaGrid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
                metaGrid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });

                var timeTb = new TextBlock
                {
                    Text = entry.Timestamp ?? string.Empty,
                    FontSize = 9.5,
                    Foreground = new SolidColorBrush(isDark
                        ? System.Windows.Media.Color.FromArgb(140, 255, 255, 255)
                        : System.Windows.Media.Color.FromRgb(100, 116, 139)),
                    Margin = new Thickness(0, 0, 10, 0)
                };
                Grid.SetColumn(timeTb, 0);
                metaGrid.Children.Add(timeTb);

                var copyBubbleBtn = new System.Windows.Controls.Button
                {
                    Content = "Copy",
                    FontSize = 9.5,
                    FontWeight = FontWeights.SemiBold,
                    BorderThickness = new Thickness(0),
                    Background = System.Windows.Media.Brushes.Transparent,
                    Foreground = new SolidColorBrush(isDark
                        ? System.Windows.Media.Color.FromArgb(165, 255, 255, 255)
                        : System.Windows.Media.Color.FromRgb(100, 116, 139)),
                    Padding = new Thickness(0),
                    Cursor = System.Windows.Input.Cursors.Hand
                };
                copyBubbleBtn.Click += (_, _) =>
                {
                    _onCopyText(entry.Text);
                    copyBubbleBtn.Content = "Copied ✓";
                    copyBubbleBtn.Foreground = new SolidColorBrush(System.Windows.Media.Color.FromRgb(37, 211, 102));
                };
                Grid.SetColumn(copyBubbleBtn, 1);
                metaGrid.Children.Add(copyBubbleBtn);

                stack.Children.Add(metaGrid);
                border.Child = stack;
                MessagesPanel.Children.Add(border);
            }
        }

        if (!isLiveUiaSynced && !isTestChat && _messages.Count <= 1)
        {
            var syncBtn = new System.Windows.Controls.Button
            {
                Content = "↗ Open in WhatsApp to sync full chat",
                FontSize = 10.5,
                FontWeight = FontWeights.Medium,
                Foreground = new SolidColorBrush(System.Windows.Media.Color.FromRgb(37, 211, 102)),
                Background = new SolidColorBrush(System.Windows.Media.Color.FromArgb(30, 37, 211, 102)),
                BorderBrush = new SolidColorBrush(System.Windows.Media.Color.FromArgb(72, 37, 211, 102)),
                BorderThickness = new Thickness(1),
                Padding = new Thickness(10, 4, 10, 4),
                Margin = new Thickness(0, 4, 0, 0),
                HorizontalAlignment = System.Windows.HorizontalAlignment.Center,
                Cursor = System.Windows.Input.Cursors.Hand
            };
            syncBtn.Click += (_, _) => _onOpenWhatsApp();
            MessagesPanel.Children.Add(syncBtn);
        }

        MessagesScroll.ScrollToEnd();
    }

    private void BuildQuickChips()
    {
        QuickChipsPanel.Children.Clear();
        foreach (var label in QuickReplies)
        {
            var chip = new System.Windows.Controls.Button
            {
                Content = label,
                FontSize = 10.5,
                FontWeight = FontWeights.Medium,
                Foreground = new SolidColorBrush(System.Windows.Media.Color.FromArgb(220, 255, 255, 255)),
                Background = new SolidColorBrush(System.Windows.Media.Color.FromArgb(24, 255, 255, 255)),
                BorderBrush = new SolidColorBrush(System.Windows.Media.Color.FromArgb(40, 255, 255, 255)),
                BorderThickness = new Thickness(1),
                Padding = new Thickness(8, 2.5, 8, 2.5),
                Margin = new Thickness(0, 0, 5, 0),
                Cursor = System.Windows.Input.Cursors.Hand
            };
            chip.Click += (_, _) => DispatchReply(label, clearInput: false);
            QuickChipsPanel.Children.Add(chip);
        }
    }

    private void DispatchReply(string rawText, bool clearInput)
    {
        var text = rawText.Trim();
        if (string.IsNullOrEmpty(text) || _isSending) return;

        _isSending = true;
        ReplyTextBox.IsEnabled = false;
        SendBtn.IsEnabled = false;
        ReplyStatusText.Text = "Sending via WhatsApp Desktop…";
        ReplyStatusText.Foreground = new SolidColorBrush(System.Windows.Media.Color.FromArgb(190, 255, 255, 255));

        _onSendReply(text, result =>
        {
            Dispatcher.Invoke(() =>
            {
                _isSending = false;
                ReplyTextBox.IsEnabled = true;
                if (result.Succeeded)
                {
                    if (clearInput) ReplyTextBox.Text = string.Empty;
                    ReplyStatusText.Text = "Sent ✓";
                    ReplyStatusText.Foreground = new SolidColorBrush(System.Windows.Media.Color.FromRgb(37, 211, 102));
                }
                else
                {
                    ReplyStatusText.Text = result.ErrorMessage ?? "Could not send reply.";
                    ReplyStatusText.Foreground = new SolidColorBrush(System.Windows.Media.Color.FromRgb(251, 191, 36));
                }
                SendBtn.IsEnabled = !string.IsNullOrWhiteSpace(ReplyTextBox.Text);
                ReplyTextBox.Focus();
            });
        });
    }

    private void ReplyTextBox_TextChanged(object sender, TextChangedEventArgs e)
    {
        SendBtn.IsEnabled = !_isSending && !string.IsNullOrWhiteSpace(ReplyTextBox.Text);
    }

    private void ReplyTextBox_PreviewKeyDown(object sender, System.Windows.Input.KeyEventArgs e)
    {
        if (e.Key == Key.Enter && (Keyboard.Modifiers & ModifierKeys.Shift) == 0)
        {
            e.Handled = true;
            DispatchReply(ReplyTextBox.Text, clearInput: true);
        }
    }

    private void SendBtn_Click(object sender, RoutedEventArgs e) => DispatchReply(ReplyTextBox.Text, clearInput: true);
    private void OpenWhatsAppBtn_Click(object sender, RoutedEventArgs e) => _onOpenWhatsApp();
    private void RefreshBtn_Click(object sender, RoutedEventArgs e) => _onRefresh();
    private void CloseBtn_Click(object sender, RoutedEventArgs e) => _onClose();

    private void CopyAllBtn_Click(object sender, RoutedEventArgs e)
    {
        if (_messages.Count == 0) return;
        var transcript = string.Join("\n", _messages.Select(m =>
        {
            var author = m.IsOutgoing ? "You" : (m.Sender ?? _chatTitle);
            var t = string.IsNullOrWhiteSpace(m.Timestamp) ? "" : $" [{m.Timestamp}]";
            return $"{author}{t}: {m.Text}";
        }));
        _onCopyText(transcript);
        CopyAllBtn.Content = "✓";
    }

    private static string ComputeInitials(string name)
    {
        var parts = name.Split(' ', StringSplitOptions.RemoveEmptyEntries);
        if (parts.Length == 0) return "WA";
        if (parts.Length == 1) return parts[0][..Math.Min(2, parts[0].Length)].ToUpperInvariant();
        return $"{char.ToUpperInvariant(parts[0][0])}{char.ToUpperInvariant(parts[^1][0])}";
    }
}
