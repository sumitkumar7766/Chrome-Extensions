using System;
using System.Collections.Generic;
using System.Security.Cryptography;
using System.Text;
using System.Text.RegularExpressions;

namespace PingGlassWindows.Core;

/// <summary>
/// Thread-safe bounded SHA-256 fingerprint store preventing duplicate notifications across scans
/// and across UIA sources (sidebar vs active chat pane) even after Clear All. Never writes to disk.
/// </summary>
public sealed class MessageFingerprintStore
{
    private readonly object _lock = new();
    private readonly int _maxEntries;
    private readonly double _ttlSeconds;
    private readonly Dictionary<string, DateTimeOffset> _entries = new();
    private readonly Queue<string> _insertionOrder = new();
    private readonly Dictionary<string, (string SourcePath, DateTimeOffset Expiry)> _crossSourceEntries = new();

    public MessageFingerprintStore(int maxEntries = 2000, double ttlSeconds = 86_400)
    {
        _maxEntries = Math.Max(20, maxEntries);
        _ttlSeconds = Math.Max(15.0, ttlSeconds);
    }

    public static string ComputeContentHash(string? sender, string? chatName, string? text)
    {
        var contact = Normalize(chatName ?? sender).ToLowerInvariant();
        var body = Normalize(text);
        return Sha256Hex($"{contact}\u001F{body}");
    }

    public static string ComputeFingerprint(
        string? sender,
        string? chatName,
        string? text,
        string? timestamp,
        string? elementIdentity,
        int occurrenceIndex = 0)
    {
        var joined = string.Join("\u001F", new[]
        {
            Normalize(sender),
            Normalize(chatName),
            Normalize(text),
            Normalize(timestamp),
            Normalize(elementIdentity),
            occurrenceIndex.ToString()
        });
        return Sha256Hex(joined);
    }

    public void Seed(string fingerprint, DateTimeOffset? now = null)
    {
        var current = now ?? DateTimeOffset.UtcNow;
        lock (_lock)
        {
            PruneExpiredLocked(current);
            InsertOrRefreshLocked(fingerprint, current);
        }
    }

    public void SeedCrossSource(string contentHash, string sourcePath, DateTimeOffset? now = null)
    {
        var current = now ?? DateTimeOffset.UtcNow;
        lock (_lock)
        {
            PruneExpiredLocked(current);
            _crossSourceEntries[contentHash] = (sourcePath, current.AddSeconds(_ttlSeconds));
        }
    }

    public bool ShouldAccept(
        string fingerprint,
        string? contentHash = null,
        string? sourcePath = null,
        DateTimeOffset? now = null)
    {
        var current = now ?? DateTimeOffset.UtcNow;
        lock (_lock)
        {
            PruneExpiredLocked(current);

            if (_entries.TryGetValue(fingerprint, out var expiry) && expiry > current)
            {
                return false;
            }

            if (contentHash != null && sourcePath != null &&
                _crossSourceEntries.TryGetValue(contentHash, out var existing) &&
                existing.Expiry > current &&
                existing.SourcePath != sourcePath)
            {
                InsertOrRefreshLocked(fingerprint, current);
                return false;
            }

            InsertOrRefreshLocked(fingerprint, current);
            if (contentHash != null && sourcePath != null)
            {
                _crossSourceEntries[contentHash] = (sourcePath, current.AddSeconds(_ttlSeconds));
            }
            return true;
        }
    }

    public void Reset()
    {
        lock (_lock)
        {
            _entries.Clear();
            _insertionOrder.Clear();
            _crossSourceEntries.Clear();
        }
    }

    private void InsertOrRefreshLocked(string fingerprint, DateTimeOffset now)
    {
        if (!_entries.ContainsKey(fingerprint))
        {
            _insertionOrder.Enqueue(fingerprint);
        }
        _entries[fingerprint] = now.AddSeconds(_ttlSeconds);

        while (_entries.Count > _maxEntries && _insertionOrder.Count > 0)
        {
            var oldest = _insertionOrder.Dequeue();
            _entries.Remove(oldest);
        }
    }

    private void PruneExpiredLocked(DateTimeOffset now)
    {
        if (_entries.Count > 0)
        {
            var expiredKeys = new List<string>();
            foreach (var kv in _entries)
            {
                if (kv.Value <= now) expiredKeys.Add(kv.Key);
            }
            foreach (var key in expiredKeys)
            {
                _entries.Remove(key);
            }
        }

        if (_crossSourceEntries.Count > 0)
        {
            var expiredCross = new List<string>();
            foreach (var kv in _crossSourceEntries)
            {
                if (kv.Value.Expiry <= now) expiredCross.Add(kv.Key);
            }
            foreach (var key in expiredCross)
            {
                _crossSourceEntries.Remove(key);
            }
        }
    }

    private static string Normalize(string? value)
    {
        if (string.IsNullOrEmpty(value)) return string.Empty;
        return Regex.Replace(value.Trim(), "\\s+", " ");
    }

    private static string Sha256Hex(string input)
    {
        var bytes = SHA256.HashData(Encoding.UTF8.GetBytes(input));
        var sb = new StringBuilder(bytes.Length * 2);
        foreach (var b in bytes)
        {
            sb.Append(b.ToString("x2"));
        }
        return sb.ToString();
    }
}
