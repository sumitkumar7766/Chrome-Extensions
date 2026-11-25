using System;
using System.Collections.Generic;
using PingGlassWindows.Models;

namespace PingGlassWindows.Notifications;

public enum QueueEnqueueOutcome
{
    DisplayNow,
    Queued,
    IgnoredDuplicate
}

public sealed class NotificationStackQueue
{
    private readonly List<WhatsAppMessage> _visible = new();
    private readonly List<WhatsAppMessage> _pending = new();
    private int _maxVisible;
    private readonly int _maxPendingCapacity;

    public IReadOnlyList<WhatsAppMessage> VisibleMessages => _visible;
    public IReadOnlyList<WhatsAppMessage> PendingMessages => _pending;

    public int MaxVisible
    {
        get => _maxVisible;
        set => _maxVisible = Math.Clamp(value, 1, 6);
    }

    public NotificationStackQueue(int maxVisible = 3, int maxPendingCapacity = 50)
    {
        _maxVisible = Math.Clamp(maxVisible, 1, 6);
        _maxPendingCapacity = Math.Max(5, maxPendingCapacity);
    }

    public QueueEnqueueOutcome Enqueue(WhatsAppMessage message)
    {
        if (_visible.Exists(m => m.Id == message.Id) || _pending.Exists(m => m.Id == message.Id))
        {
            return QueueEnqueueOutcome.IgnoredDuplicate;
        }

        if (_visible.Count < _maxVisible)
        {
            _visible.Insert(0, message);
            return QueueEnqueueOutcome.DisplayNow;
        }

        if (_pending.Count >= _maxPendingCapacity)
        {
            _pending.RemoveAt(0);
        }
        _pending.Add(message);
        return QueueEnqueueOutcome.Queued;
    }

    public WhatsAppMessage? Remove(string id)
    {
        var visibleIdx = _visible.FindIndex(m => m.Id == id);
        if (visibleIdx >= 0)
        {
            _visible.RemoveAt(visibleIdx);
            return PromoteNextIfAvailable();
        }

        var pendingIdx = _pending.FindIndex(m => m.Id == id);
        if (pendingIdx >= 0)
        {
            _pending.RemoveAt(pendingIdx);
        }
        return null;
    }

    public List<WhatsAppMessage> PromoteAvailableSlots()
    {
        var promoted = new List<WhatsAppMessage>();
        while (PromoteNextIfAvailable() is { } next)
        {
            promoted.Add(next);
        }
        return promoted;
    }

    public void ClearAll()
    {
        _visible.Clear();
        _pending.Clear();
    }

    private WhatsAppMessage? PromoteNextIfAvailable()
    {
        if (_visible.Count >= _maxVisible || _pending.Count == 0)
        {
            return null;
        }
        var next = _pending[0];
        _pending.RemoveAt(0);
        _visible.Insert(0, next);
        return next;
    }
}
