using System;
using System.Collections.Generic;
using System.Text.RegularExpressions;
using PingGlassWindows.Models;

namespace PingGlassWindows.Core;

/// <summary>
/// Ephemeral in-memory session chat history per contact/group (never persisted to disk).
/// Caps each thread at 25 messages and clears immediately on Clear All.
/// </summary>
public sealed class SessionChatStore
{
    private readonly int _maxPerChat;
    private readonly object _lock = new();
    private readonly Dictionary<string, List<ChatBubbleEntry>> _chats = new();

    public SessionChatStore(int maxPerChat = 25)
    {
        _maxPerChat = Math.Max(5, maxPerChat);
    }

    public static string ChatKey(WhatsAppMessage message)
    {
        var raw = !string.IsNullOrWhiteSpace(message.ChatName)
            ? message.ChatName
            : (!string.IsNullOrWhiteSpace(message.Sender) ? message.Sender : "unknown");
        return Regex.Replace(raw.Trim(), "\\s+", " ").ToLowerInvariant();
    }

    public void Record(WhatsAppMessage message)
    {
        var text = (message.Text ?? string.Empty).Trim();
        if (text.Length == 0) return;

        var key = ChatKey(message);
        lock (_lock)
        {
            if (!_chats.TryGetValue(key, out var list))
            {
                list = new List<ChatBubbleEntry>();
                _chats[key] = list;
            }

            if (list.Exists(e => e.Id == message.Id)) return;

            list.Add(new ChatBubbleEntry
            {
                Id = message.Id,
                Sender = message.IsOutgoing ? "You" : message.Sender,
                Text = text,
                Timestamp = message.Timestamp,
                IsOutgoing = message.IsOutgoing,
                IsTest = message.IsTest
            });

            if (list.Count > _maxPerChat)
            {
                list.RemoveRange(0, list.Count - _maxPerChat);
            }
        }
    }

    public ChatBubbleEntry? RecordOutgoing(string replyText, WhatsAppMessage targetMessage)
    {
        var trimmed = replyText.Trim();
        if (trimmed.Length == 0) return null;

        var key = ChatKey(targetMessage);
        var entry = new ChatBubbleEntry
        {
            Id = "out-" + Guid.NewGuid().ToString(),
            Sender = "You",
            Text = trimmed,
            Timestamp = DateTime.Now.ToString("t"),
            IsOutgoing = true,
            IsTest = targetMessage.IsTest
        };

        lock (_lock)
        {
            if (!_chats.TryGetValue(key, out var list))
            {
                list = new List<ChatBubbleEntry>();
                _chats[key] = list;
            }
            list.Add(entry);
            if (list.Count > _maxPerChat)
            {
                list.RemoveRange(0, list.Count - _maxPerChat);
            }
        }
        return entry;
    }

    public List<ChatBubbleEntry> Messages(WhatsAppMessage targetMessage)
    {
        var key = ChatKey(targetMessage);
        lock (_lock)
        {
            return _chats.TryGetValue(key, out var list)
                ? new List<ChatBubbleEntry>(list)
                : new List<ChatBubbleEntry>();
        }
    }

    public void ClearAll()
    {
        lock (_lock)
        {
            _chats.Clear();
        }
    }
}
