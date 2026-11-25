using System;
using System.Collections.Generic;
using System.Text;
using PingGlassWindows.Models;

namespace PingGlassWindows.Core;

public enum MessageDirection
{
    Incoming,
    Outgoing,
    Ambiguous
}

public sealed class ExtractedCandidate
{
    public string? Sender { get; init; }
    public string? ChatName { get; init; }
    public string? Text { get; init; }
    public string? Timestamp { get; init; }
    public string? Avatar { get; init; }
    public MessageDirection Direction { get; init; }
    public string? ElementIdentity { get; init; }
    public int OccurrenceIndex { get; init; }
    public double BaseConfidence { get; init; }
    public string ExtractionPath { get; init; } = "UIASidebarUnread";
}

/// <summary>
/// Sanitizes UI Automation candidates, drops outgoing or ambiguous items per policy,
/// strips hidden directional control characters, and emits deduplicated WhatsAppMessages.
/// </summary>
public sealed class MessageProcessor
{
    private readonly MessageFingerprintStore _fingerprintStore;

    public MessageProcessor(MessageFingerprintStore? fingerprintStore = null)
    {
        _fingerprintStore = fingerprintStore ?? new MessageFingerprintStore();
    }

    public List<WhatsAppMessage> Process(
        IEnumerable<ExtractedCandidate> candidates,
        HelperConfiguration config,
        bool seedOnly = false,
        DateTimeOffset? now = null)
    {
        var current = now ?? DateTimeOffset.UtcNow;
        var accepted = new List<WhatsAppMessage>();

        foreach (var candidate in candidates)
        {
            var sanitizedSender = SanitizeSingleLine(candidate.Sender, 120);
            var sanitizedChatName = SanitizeSingleLine(candidate.ChatName, 120);
            if (string.Equals(sanitizedSender, "WhatsApp", StringComparison.OrdinalIgnoreCase) &&
                !string.IsNullOrEmpty(sanitizedChatName) &&
                !string.Equals(sanitizedChatName, "WhatsApp", StringComparison.OrdinalIgnoreCase))
            {
                sanitizedSender = sanitizedChatName;
            }

            var sanitizedText = SanitizeMultiline(candidate.Text, config.MaxPreviewLength);
            var sanitizedTimestamp = SanitizeSingleLine(candidate.Timestamp, 40);

            if (sanitizedText == null && sanitizedSender == null && sanitizedChatName == null)
            {
                continue;
            }

            var effectiveDirection = RefineDirection(candidate.Direction, sanitizedText, sanitizedSender);
            if (effectiveDirection == MessageDirection.Outgoing)
            {
                continue;
            }

            if (effectiveDirection == MessageDirection.Ambiguous &&
                config.AmbiguousDirectionPolicy == AmbiguousDirectionPolicy.Ignore)
            {
                continue;
            }

            var fingerprint = MessageFingerprintStore.ComputeFingerprint(
                sanitizedSender,
                sanitizedChatName,
                sanitizedText,
                sanitizedTimestamp,
                candidate.ElementIdentity,
                candidate.OccurrenceIndex);

            var contentHash = MessageFingerprintStore.ComputeContentHash(
                sanitizedSender,
                sanitizedChatName,
                sanitizedText);

            if (seedOnly)
            {
                _fingerprintStore.Seed(fingerprint, current);
                _fingerprintStore.SeedCrossSource(contentHash, candidate.ExtractionPath, current);
                continue;
            }

            if (!_fingerprintStore.ShouldAccept(fingerprint, contentHash, candidate.ExtractionPath, current))
            {
                continue;
            }

            var confidence = effectiveDirection == MessageDirection.Ambiguous
                ? Math.Min(candidate.BaseConfidence, 0.45)
                : candidate.BaseConfidence;

            accepted.Add(new WhatsAppMessage
            {
                Id = Guid.NewGuid().ToString(),
                Sender = sanitizedSender,
                ChatName = sanitizedChatName,
                Text = sanitizedText,
                Timestamp = sanitizedTimestamp,
                Avatar = null,
                ReceivedAt = current.ToString("o"),
                Source = "whatsapp-desktop",
                Confidence = confidence,
                IsTest = false,
                IsOutgoing = false
            });
        }

        return accepted;
    }

    public void ResetCache() => _fingerprintStore.Reset();

    public static MessageDirection RefineDirection(MessageDirection initial, string? rawText, string? sender)
    {
        if (initial == MessageDirection.Outgoing) return MessageDirection.Outgoing;
        if (!string.IsNullOrEmpty(sender))
        {
            var s = sender.Trim().ToLowerInvariant();
            if (s == "you" || s == "me") return MessageDirection.Outgoing;
        }
        if (!string.IsNullOrEmpty(rawText))
        {
            var t = rawText.Trim().ToLowerInvariant();
            if (t.StartsWith("you:", StringComparison.Ordinal) ||
                t.StartsWith("you sent ", StringComparison.Ordinal))
            {
                return MessageDirection.Outgoing;
            }
        }
        return initial;
    }

    public static string? SanitizeSingleLine(string? value, int maxLength)
    {
        if (string.IsNullOrEmpty(value)) return null;
        var cleaned = StripControlAndDirectional(value, allowNewlines: false).Trim();
        if (cleaned.Length == 0) return null;
        return cleaned.Length <= maxLength ? cleaned : cleaned[..maxLength];
    }

    public static string? SanitizeMultiline(string? value, int maxLength)
    {
        if (string.IsNullOrEmpty(value)) return null;
        var cleaned = StripControlAndDirectional(value, allowNewlines: true).Trim();
        if (cleaned.Length == 0) return null;
        if (cleaned.Length <= maxLength) return cleaned;
        return cleaned[..Math.Max(1, maxLength - 1)] + "…";
    }

    public static string StripControlAndDirectional(string value, bool allowNewlines)
    {
        var sb = new StringBuilder(value.Length);
        foreach (var ch in value)
        {
            if (IsHiddenDirectional(ch)) continue;
            if (ch == '\n' || ch == '\r')
            {
                if (allowNewlines)
                {
                    if (ch == '\n') sb.Append('\n');
                }
                else
                {
                    sb.Append(' ');
                }
                continue;
            }
            if (char.IsControl(ch)) continue;
            sb.Append(ch);
        }
        return sb.ToString();
    }

    private static bool IsHiddenDirectional(char ch) => ch is
        '\u200B' or '\u200C' or '\u200D' or '\u200E' or '\u200F' or
        '\u202A' or '\u202B' or '\u202C' or '\u202D' or '\u202E' or
        '\u2066' or '\u2067' or '\u2068' or '\u2069' or '\uFEFF';
}
