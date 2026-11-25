using System;
using System.Collections.Generic;
using System.Media;
using System.Windows;
using System.Windows.Threading;
using PingGlassWindows.Core;
using PingGlassWindows.Models;

namespace PingGlassWindows.Notifications;

public sealed class GlobalNotificationWindowManager
{
    private sealed class ActiveCardEntry
    {
        public WhatsAppMessage Message { get; }
        public NotificationCardWindow Window { get; }
        public DispatcherTimer? DismissTimer { get; set; }
        public double? RemainingSeconds { get; set; }
        public DateTimeOffset? TimerStartedAt { get; set; }
        public bool IsExiting { get; set; }

        public ActiveCardEntry(WhatsAppMessage msg, NotificationCardWindow window, double? durationSeconds)
        {
            Message = msg;
            Window = window;
            RemainingSeconds = durationSeconds;
        }
    }

    private readonly Dictionary<string, ActiveCardEntry> _activeEntries = new();
    private readonly NotificationStackQueue _queue;
    private readonly SessionChatStore _chatStore = new();
    private ClearAllPillWindow? _clearAllWindow;
    private FloatingChatPopupWindow? _chatPopupWindow;
    private WhatsAppMessage? _activeChatPopupMessage;
    private HelperConfiguration _config;

    public event Action<WhatsAppMessage>? OnOpenWhatsAppRequested;
    public Func<WhatsAppMessage, List<ChatBubbleEntry>>? OnFetchLiveConversation;
    public Action<WhatsAppMessage, string, Action<ReplyDispatchResult>>? OnSendReplyRequested;
    public event Action<int, int>? OnCountsChanged;
    public event Action? OnClearAllRequested;

    public int ActiveWindowCount => _activeEntries.Count;
    public int QueuedCount => _queue.PendingMessages.Count;

    public GlobalNotificationWindowManager(HelperConfiguration? config = null)
    {
        _config = config?.Clone() ?? new HelperConfiguration();
        _queue = new NotificationStackQueue(_config.MaxVisibleNotifications);
    }

    public void UpdateConfiguration(HelperConfiguration newConfig)
    {
        var oldConfig = _config;
        _config = newConfig.Clone();
        _queue.MaxVisible = _config.MaxVisibleNotifications;

        if (!_config.GlobalNotificationsEnabled || _config.IsNotificationsPaused())
        {
            DismissAll(_config.AnimationEnabled);
            return;
        }

        foreach (var entry in _activeEntries.Values)
        {
            if (entry.IsExiting) continue;
            entry.Window.ApplyAppearance(_config);
            if (oldConfig.NotificationDurationSeconds != _config.NotificationDurationSeconds)
            {
                entry.RemainingSeconds = _config.NotificationDurationSeconds > 0
                    ? _config.NotificationDurationSeconds
                    : null;
                StartDismissTimer(entry);
            }
        }

        foreach (var next in _queue.PromoteAvailableSlots())
        {
            PresentCard(next);
        }

        RepositionVisiblePanels();
    }

    public void Enqueue(WhatsAppMessage message, HelperConfiguration config)
    {
        _config = config.Clone();
        _queue.MaxVisible = _config.MaxVisibleNotifications;

        if (!message.IsTest)
        {
            if (!_config.GlobalNotificationsEnabled || _config.IsNotificationsPaused()) return;
        }
        else if (!_config.GlobalNotificationsEnabled)
        {
            return;
        }

        _chatStore.Record(message);
        if (_activeChatPopupMessage != null &&
            SessionChatStore.ChatKey(_activeChatPopupMessage) == SessionChatStore.ChatKey(message))
        {
            RefreshOpenChatPopup(_activeChatPopupMessage);
        }

        switch (_queue.Enqueue(message))
        {
            case QueueEnqueueOutcome.DisplayNow:
                PresentCard(message);
                if (_config.SoundEnabled) SystemSounds.Asterisk.Play();
                NotifyCountsChanged();
                break;

            case QueueEnqueueOutcome.Queued:
                RepositionVisiblePanels();
                NotifyCountsChanged();
                break;
        }
    }

    public void Dismiss(string id, bool? animated = null)
    {
        bool shouldAnimate = animated ?? _config.AnimationEnabled;
        if (!_activeEntries.TryGetValue(id, out var entry))
        {
            _queue.Remove(id);
            NotifyCountsChanged();
            return;
        }
        if (entry.IsExiting) return;
        entry.IsExiting = true;
        entry.DismissTimer?.Stop();

        void FinishRemoval()
        {
            try { entry.Window.Close(); } catch { }
            _activeEntries.Remove(id);
            if (_queue.Remove(id) is { } promoted)
            {
                PresentCard(promoted);
            }
            RepositionVisiblePanels();
            NotifyCountsChanged();
        }

        if (shouldAnimate)
        {
            entry.Window.AnimateDismiss(FinishRemoval);
        }
        else
        {
            FinishRemoval();
        }
    }

    public void DismissAll(bool animated = false)
    {
        HideClearAllBar();
        CloseChatPopup();
        _chatStore.ClearAll();

        var ids = new List<string>(_activeEntries.Keys);
        _queue.ClearAll();
        foreach (var id in ids)
        {
            Dismiss(id, animated);
        }
        NotifyCountsChanged();
    }

    private void PresentCard(WhatsAppMessage message)
    {
        double? duration = _config.NotificationDurationSeconds > 0
            ? _config.NotificationDurationSeconds
            : null;

        var card = new NotificationCardWindow(
            message,
            _config,
            onCardClick: () => HandleNotificationCardClick(message),
            onOpenWhatsApp: () => OnOpenWhatsAppRequested?.Invoke(message),
            onCopy: () => CopyText(message.Text ?? message.Sender ?? string.Empty),
            onDismiss: () => Dismiss(message.Id),
            onLayoutChanged: RepositionVisiblePanels,
            onHoverChanged: hovering => HandleHoverChange(message.Id, hovering));

        var entry = new ActiveCardEntry(message, card, duration);
        _activeEntries[message.Id] = entry;

        var frames = ComputeCurrentFrames(out var ordered, out var workArea);
        int idx = ordered.FindIndex(m => m.Id == message.Id);
        if (idx >= 0 && idx < frames.Count)
        {
            var target = frames[idx];
            card.Left = target.Left;
            card.Top = target.Top;
            card.Show();
            if (_config.AnimationEnabled)
            {
                card.AnimateEntrance(target.Top);
            }
        }

        for (int i = 0; i < ordered.Count && i < frames.Count; i++)
        {
            var m = ordered[i];
            if (m.Id == message.Id) continue;
            if (_activeEntries.TryGetValue(m.Id, out var existing) && !existing.IsExiting)
            {
                existing.Window.Left = frames[i].Left;
                existing.Window.Top = frames[i].Top;
            }
        }

        StartDismissTimer(entry);
        UpdateClearAllBar(frames, workArea);
    }

    private List<Rect> ComputeCurrentFrames(out List<WhatsAppMessage> ordered, out Rect workArea)
    {
        ordered = new List<WhatsAppMessage>();
        var sizes = new List<System.Windows.Size>();
        foreach (var msg in _queue.VisibleMessages)
        {
            if (_activeEntries.TryGetValue(msg.Id, out var e) && !e.IsExiting)
            {
                ordered.Add(msg);
                sizes.Add(e.Window.MeasurePreferredSize());
            }
        }

        workArea = DisplayScreenLocator.GetTargetWorkingAreaDip(_config.PreferredDisplayMode);
        return DisplayScreenLocator.ComputeStackedFrames(
            sizes,
            workArea,
            _config.NotificationPosition,
            _config.EdgeMargin);
    }

    public void RepositionVisiblePanels()
    {
        var frames = ComputeCurrentFrames(out var ordered, out var workArea);
        if (ordered.Count == 0)
        {
            HideClearAllBar();
            return;
        }

        for (int i = 0; i < ordered.Count && i < frames.Count; i++)
        {
            if (_activeEntries.TryGetValue(ordered[i].Id, out var entry) && !entry.IsExiting)
            {
                entry.Window.Left = frames[i].Left;
                entry.Window.Top = frames[i].Top;
            }
        }

        UpdateClearAllBar(frames, workArea);
        if (_chatPopupWindow != null)
        {
            var chatFrame = DisplayScreenLocator.ComputeChatPopupFrame(
                FloatingChatPopupWindow.PopupSize,
                workArea,
                _config.NotificationPosition,
                _config.EdgeMargin,
                frames);
            _chatPopupWindow.Left = chatFrame.Left;
            _chatPopupWindow.Top = chatFrame.Top;
        }
    }

    private void HandleNotificationCardClick(WhatsAppMessage message)
    {
        Dismiss(message.Id, _config.AnimationEnabled);
        if (_config.NotificationClickAction == NotificationClickAction.OpenWhatsAppDirectly)
        {
            OnOpenWhatsAppRequested?.Invoke(message);
        }
        else
        {
            OpenChatPopup(message);
        }
    }

    public void OpenChatPopup(WhatsAppMessage message)
    {
        _chatStore.Record(message);
        _activeChatPopupMessage = message;

        string chatTitle = !string.IsNullOrWhiteSpace(message.ChatName)
            ? message.ChatName!
            : (!string.IsNullOrWhiteSpace(message.Sender) ? message.Sender! : "WhatsApp Chat");
        string? subtitle = (!string.IsNullOrWhiteSpace(message.ChatName) &&
                            !string.IsNullOrWhiteSpace(message.Sender) &&
                            message.ChatName != message.Sender)
            ? message.Sender
            : null;

        var (entries, isLive) = MergedConversation(message);
        var frames = ComputeCurrentFrames(out _, out var workArea);
        var popupFrame = DisplayScreenLocator.ComputeChatPopupFrame(
            FloatingChatPopupWindow.PopupSize,
            workArea,
            _config.NotificationPosition,
            _config.EdgeMargin,
            frames);

        if (_chatPopupWindow == null)
        {
            _chatPopupWindow = new FloatingChatPopupWindow();
        }

        _chatPopupWindow.Left = popupFrame.Left;
        _chatPopupWindow.Top = popupFrame.Top;
        _chatPopupWindow.UpdateState(
            chatTitle,
            subtitle,
            entries,
            isLive,
            message.IsTest,
            _config,
            onRefresh: () => RefreshOpenChatPopup(message),
            onOpenWhatsApp: () => OnOpenWhatsAppRequested?.Invoke(message),
            onCopyText: CopyText,
            onSendReply: (replyText, completion) =>
            {
                if (OnSendReplyRequested != null)
                {
                    OnSendReplyRequested(message, replyText, result =>
                    {
                        if (result.Succeeded)
                        {
                            _chatStore.RecordOutgoing(replyText, message);
                            RefreshOpenChatPopup(message);
                        }
                        completion(result);
                    });
                }
                else
                {
                    _chatStore.RecordOutgoing(replyText, message);
                    RefreshOpenChatPopup(message);
                    completion(new ReplyDispatchResult { Succeeded = true });
                }
            },
            onClose: CloseChatPopup);

        if (!_chatPopupWindow.IsVisible)
        {
            _chatPopupWindow.Show();
        }
        _chatPopupWindow.Activate();
    }

    public void RefreshOpenChatPopup(WhatsAppMessage message)
    {
        if (_activeChatPopupMessage == null) return;
        System.Windows.Application.Current?.Dispatcher.Invoke(() => OpenChatPopup(message));
    }

    public void RecordExternalOutgoingReply(string text, WhatsAppMessage message)
    {
        _chatStore.RecordOutgoing(text, message);
        if (_activeChatPopupMessage != null &&
            SessionChatStore.ChatKey(_activeChatPopupMessage) == SessionChatStore.ChatKey(message))
        {
            RefreshOpenChatPopup(_activeChatPopupMessage);
        }
    }

    public void CloseChatPopup()
    {
        if (_chatPopupWindow != null)
        {
            try { _chatPopupWindow.Close(); } catch { }
            _chatPopupWindow = null;
        }
        _activeChatPopupMessage = null;
    }

    private (List<ChatBubbleEntry> Entries, bool IsLive) MergedConversation(WhatsAppMessage message)
    {
        var live = (!message.IsTest && OnFetchLiveConversation != null)
            ? OnFetchLiveConversation(message)
            : new List<ChatBubbleEntry>();
        var session = _chatStore.Messages(message);
        if (live.Count > 0)
        {
            var combined = new List<ChatBubbleEntry>(live);
            foreach (var item in session)
            {
                if (!combined.Exists(c => c.Text.Trim() == item.Text.Trim()))
                {
                    combined.Add(item);
                }
            }
            return (combined, true);
        }
        return (session, false);
    }

    private void UpdateClearAllBar(List<Rect> frames, Rect workArea)
    {
        int total = _queue.PendingMessages.Count;
        foreach (var e in _activeEntries.Values)
        {
            if (!e.IsExiting) total++;
        }

        if (total < 1 || frames.Count == 0)
        {
            HideClearAllBar();
            return;
        }

        Action clearAction = () =>
        {
            if (OnClearAllRequested != null) OnClearAllRequested();
            else DismissAll(_config.AnimationEnabled);
        };

        if (_clearAllWindow == null)
        {
            _clearAllWindow = new ClearAllPillWindow(total, _config, clearAction);
        }
        else
        {
            _clearAllWindow.UpdateState(total, _config, clearAction);
        }

        var barFrame = DisplayScreenLocator.ComputeClearAllBarFrame(
            frames,
            _clearAllWindow.MeasurePreferredSize(),
            workArea,
            _config.NotificationPosition,
            _config.EdgeMargin);

        _clearAllWindow.Left = barFrame.Left;
        _clearAllWindow.Top = barFrame.Top;
        if (!_clearAllWindow.IsVisible)
        {
            _clearAllWindow.Show();
        }
    }

    private void HideClearAllBar()
    {
        if (_clearAllWindow != null)
        {
            try { _clearAllWindow.Close(); } catch { }
            _clearAllWindow = null;
        }
    }

    private void StartDismissTimer(ActiveCardEntry entry)
    {
        entry.DismissTimer?.Stop();
        entry.DismissTimer = null;
        if (!entry.RemainingSeconds.HasValue || entry.RemainingSeconds.Value <= 0) return;

        var msgId = entry.Message.Id;
        entry.TimerStartedAt = DateTimeOffset.UtcNow;
        var timer = new DispatcherTimer { Interval = TimeSpan.FromSeconds(entry.RemainingSeconds.Value) };
        timer.Tick += (_, _) =>
        {
            timer.Stop();
            Dismiss(msgId);
        };
        entry.DismissTimer = timer;
        timer.Start();
    }

    private void HandleHoverChange(string id, bool hovering)
    {
        if (!_activeEntries.TryGetValue(id, out var entry) || entry.IsExiting) return;
        if (hovering)
        {
            if (entry.TimerStartedAt.HasValue && entry.RemainingSeconds.HasValue)
            {
                double elapsed = (DateTimeOffset.UtcNow - entry.TimerStartedAt.Value).TotalSeconds;
                entry.RemainingSeconds = Math.Max(0.8, entry.RemainingSeconds.Value - elapsed);
            }
            entry.DismissTimer?.Stop();
        }
        else
        {
            StartDismissTimer(entry);
        }
    }

    private void NotifyCountsChanged()
    {
        int active = 0;
        foreach (var e in _activeEntries.Values)
        {
            if (!e.IsExiting) active++;
        }
        OnCountsChanged?.Invoke(active, _queue.PendingMessages.Count);
    }

    private static void CopyText(string text)
    {
        if (string.IsNullOrEmpty(text)) return;
        try
        {
            System.Windows.Clipboard.SetText(text);
        }
        catch
        {
            // Retry once if clipboard was transiently locked by another app.
            try
            {
                System.Threading.Thread.Sleep(25);
                System.Windows.Clipboard.SetText(text);
            }
            catch { }
        }
    }
}
