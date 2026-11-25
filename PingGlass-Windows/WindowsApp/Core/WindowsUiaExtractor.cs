using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text.RegularExpressions;
using System.Windows;
using System.Windows.Automation;
using PingGlassWindows.Models;

namespace PingGlassWindows.Core;

public sealed class UIANodeSnapshot
{
    public string ControlTypeName { get; init; } = string.Empty;
    public string? AutomationId { get; init; }
    public string? ClassName { get; init; }
    public string? Name { get; init; }
    public string? HelpText { get; init; }
    public string? Value { get; init; }
    public Rect BoundingRect { get; init; } = Rect.Empty;
    public List<UIANodeSnapshot> Children { get; } = new();
}

public sealed record ExtractionPassResult(
    List<ExtractedCandidate> Candidates,
    int AccessibleWindowCount,
    int VisitedNodeCount,
    string ExtractionMode);

/// <summary>
/// Public Windows UI Automation (System.Windows.Automation) extractor, chat opener,
/// live bubble reader, and direct accessible reply sender for WhatsApp Desktop on Windows.
/// Never touches WhatsApp SQLite files or private APIs.
/// </summary>
public sealed class WindowsUiaExtractor
{
    private const int MaxDepth = 16;
    private const int MaxNodes = 1800;

    [DllImport("user32.dll")]
    private static extern bool SetForegroundWindow(IntPtr hWnd);

    [DllImport("user32.dll")]
    private static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);

    [DllImport("user32.dll")]
    private static extern bool IsIconic(IntPtr hWnd);

    [DllImport("user32.dll", SetLastError = true)]
    private static extern uint SendInput(uint nInputs, INPUT[] pInputs, int cbSize);

    private const int SW_RESTORE = 9;
    private const uint INPUT_KEYBOARD = 1;
    private const uint KEYEVENTF_KEYUP = 0x0002;
    private const uint KEYEVENTF_UNICODE = 0x0004;
    private const ushort VK_RETURN = 0x0D;
    private const ushort VK_CONTROL = 0x11;
    private const ushort VK_A = 0x41;
    private const ushort VK_BACK = 0x08;

    [StructLayout(LayoutKind.Sequential)]
    private struct INPUT
    {
        public uint type;
        public InputUnion U;
    }

    [StructLayout(LayoutKind.Explicit)]
    private struct InputUnion
    {
        [FieldOffset(0)] public KEYBDINPUT ki;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct KEYBDINPUT
    {
        public ushort wVk;
        public ushort wScan;
        public uint dwFlags;
        public uint time;
        public UIntPtr dwExtraInfo;
    }

    public ExtractionPassResult Extract(IntPtr windowHandle)
    {
        if (windowHandle == IntPtr.Zero)
        {
            return new ExtractionPassResult(new List<ExtractedCandidate>(), 0, 0, "No WhatsApp window");
        }

        try
        {
            var rootEl = AutomationElement.FromHandle(windowHandle);
            if (rootEl == null)
            {
                return new ExtractionPassResult(new List<ExtractedCandidate>(), 0, 0, "Window handle inaccessible");
            }

            int remaining = MaxNodes;
            var snapshot = CaptureSnapshot(rootEl, 0, ref remaining);
            int visited = MaxNodes - remaining;
            var candidates = ExtractFromWindowSnapshot(snapshot);

            string mode = candidates.Count > 0
                ? $"UIA tree ({candidates.Count} candidate(s))"
                : "UIA tree scanned (no new unread markers)";

            return new ExtractionPassResult(candidates, 1, visited, mode);
        }
        catch
        {
            return new ExtractionPassResult(new List<ExtractedCandidate>(), 0, 0, "WhatsApp UIA busy");
        }
    }

    public List<ExtractedCandidate> ExtractFromWindowSnapshot(UIANodeSnapshot window)
    {
        var results = new List<ExtractedCandidate>();
        var activeChatTitle = InferWindowChatTitle(window);
        results.AddRange(ExtractUnreadSidebarRows(window));
        results.AddRange(ExtractActiveChatBubbles(window, activeChatTitle));
        return results;
    }

    public List<ChatBubbleEntry> ExtractVisibleConversation(string targetChatTitle, IntPtr windowHandle)
    {
        var normalizedTarget = NormalizeChatLabel(targetChatTitle);
        if (string.IsNullOrEmpty(normalizedTarget) || windowHandle == IntPtr.Zero)
        {
            return new List<ChatBubbleEntry>();
        }

        try
        {
            var rootEl = AutomationElement.FromHandle(windowHandle);
            if (rootEl == null) return new List<ChatBubbleEntry>();
            int remaining = MaxNodes;
            var snapshot = CaptureSnapshot(rootEl, 0, ref remaining);
            var activeTitle = InferWindowChatTitle(snapshot);
            if (string.IsNullOrEmpty(activeTitle) || NormalizeChatLabel(activeTitle) != normalizedTarget)
            {
                return new List<ChatBubbleEntry>();
            }

            var bubbles = ExtractActiveChatBubbles(snapshot, activeTitle);
            var entries = new List<ChatBubbleEntry>(bubbles.Count);
            for (int i = 0; i < bubbles.Count; i++)
            {
                var b = bubbles[i];
                if (string.IsNullOrWhiteSpace(b.Text)) continue;
                entries.Add(new ChatBubbleEntry
                {
                    Id = $"uia-{i}-{(b.ElementIdentity ?? "").GetHashCode()}-{b.Text.GetHashCode()}",
                    Sender = b.Sender,
                    Text = b.Text,
                    Timestamp = b.Timestamp,
                    IsOutgoing = b.Direction == MessageDirection.Outgoing,
                    IsTest = false
                });
            }
            return entries;
        }
        catch
        {
            return new List<ChatBubbleEntry>();
        }
    }

    public bool SelectChat(string targetChatTitle, IntPtr windowHandle)
    {
        var normalizedTarget = NormalizeChatLabel(targetChatTitle);
        if (string.IsNullOrEmpty(normalizedTarget) || windowHandle == IntPtr.Zero) return false;

        try
        {
            if (IsIconic(windowHandle)) ShowWindow(windowHandle, SW_RESTORE);
            SetForegroundWindow(windowHandle);

            var root = AutomationElement.FromHandle(windowHandle);
            if (root == null) return false;

            var walker = TreeWalker.RawViewWalker;
            AutomationElement? exactMatch = null;
            AutomationElement? prefixMatch = null;
            int remaining = MaxNodes;

            void Walk(AutomationElement node, int depth)
            {
                if (depth > MaxDepth || remaining-- <= 0 || exactMatch != null) return;
                string ct = node.Current.ControlType.ProgrammaticName;
                if (ct is "ControlType.ListItem" or "ControlType.Button" or "ControlType.Custom")
                {
                    var name = node.Current.Name ?? string.Empty;
                    var norm = NormalizeChatLabel(name);
                    if (!string.IsNullOrEmpty(norm) && !IsChipFilterControl(node))
                    {
                        if (norm == normalizedTarget || norm.StartsWith(normalizedTarget + ",", StringComparison.Ordinal))
                        {
                            exactMatch = node;
                            return;
                        }
                        if (prefixMatch == null && norm.Contains(normalizedTarget, StringComparison.Ordinal))
                        {
                            prefixMatch = node;
                        }
                    }
                }

                var child = walker.GetFirstChild(node);
                while (child != null && remaining > 0 && exactMatch == null)
                {
                    Walk(child, depth + 1);
                    child = walker.GetNextSibling(child);
                }
            }

            Walk(root, 0);
            var target = exactMatch ?? prefixMatch;
            if (target == null) return false;

            if (target.TryGetCurrentPattern(InvokePattern.Pattern, out var invokeObj) && invokeObj is InvokePattern invoke)
            {
                invoke.Invoke();
                return true;
            }
            if (target.TryGetCurrentPattern(SelectionItemPattern.Pattern, out var selObj) && selObj is SelectionItemPattern sel)
            {
                sel.Select();
                return true;
            }
            return false;
        }
        catch
        {
            return false;
        }
    }

    public ReplyDispatchResult SendReply(string replyText, string? expectedChatTitle, IntPtr windowHandle)
    {
        var trimmed = replyText.Trim();
        if (string.IsNullOrEmpty(trimmed))
        {
            return new ReplyDispatchResult { Succeeded = false, ErrorMessage = "Reply message cannot be empty." };
        }
        if (windowHandle == IntPtr.Zero)
        {
            return new ReplyDispatchResult { Succeeded = false, ErrorMessage = "WhatsApp Desktop window is closed." };
        }

        try
        {
            if (IsIconic(windowHandle)) ShowWindow(windowHandle, SW_RESTORE);
            SetForegroundWindow(windowHandle);

            if (!string.IsNullOrWhiteSpace(expectedChatTitle))
            {
                int seed = MaxNodes;
                var rootEl = AutomationElement.FromHandle(windowHandle);
                var snap = CaptureSnapshot(rootEl, 0, ref seed);
                var currentTitle = InferWindowChatTitle(snap);
                if (currentTitle == null || NormalizeChatLabel(currentTitle) != NormalizeChatLabel(expectedChatTitle))
                {
                    SelectChat(expectedChatTitle, windowHandle);
                    System.Threading.Thread.Sleep(240);
                }
            }

            var root = AutomationElement.FromHandle(windowHandle);
            var winRect = root.Current.BoundingRectangle;
            var composer = FindComposer(root, winRect);
            if (composer == null)
            {
                return new ReplyDispatchResult
                {
                    Succeeded = false,
                    ErrorMessage = "Open the target chat in WhatsApp Desktop so the reply box is visible."
                };
            }

            try { composer.SetFocus(); } catch { }
            System.Threading.Thread.Sleep(60);

            bool wroteViaPattern = false;
            if (composer.TryGetCurrentPattern(ValuePattern.Pattern, out var valObj) && valObj is ValuePattern vp && !vp.Current.IsReadOnly)
            {
                vp.SetValue(trimmed);
                wroteViaPattern = true;
            }
            else
            {
                SendCtrlAAndBackspace();
                SendUnicodeText(trimmed);
            }

            System.Threading.Thread.Sleep(90);

            var sendBtn = FindSendButton(root, winRect);
            if (sendBtn != null && sendBtn.TryGetCurrentPattern(InvokePattern.Pattern, out var invokeObj) && invokeObj is InvokePattern sendInvoke)
            {
                sendInvoke.Invoke();
                return new ReplyDispatchResult { Succeeded = true };
            }

            if (wroteViaPattern || true)
            {
                SendKey(VK_RETURN);
                return new ReplyDispatchResult { Succeeded = true };
            }
        }
        catch (Exception ex)
        {
            return new ReplyDispatchResult { Succeeded = false, ErrorMessage = $"Reply failed: {ex.Message}" };
        }
    }

    private static UIANodeSnapshot CaptureSnapshot(AutomationElement element, int depth, ref int remaining)
    {
        var cur = element.Current;
        string? val = null;
        if (element.TryGetCurrentPattern(ValuePattern.Pattern, out var valObj) && valObj is ValuePattern vp)
        {
            val = vp.Current.Value;
        }

        var node = new UIANodeSnapshot
        {
            ControlTypeName = cur.ControlType.ProgrammaticName,
            AutomationId = string.IsNullOrWhiteSpace(cur.AutomationId) ? null : cur.AutomationId,
            ClassName = string.IsNullOrWhiteSpace(cur.ClassName) ? null : cur.ClassName,
            Name = string.IsNullOrWhiteSpace(cur.Name) ? null : cur.Name,
            HelpText = string.IsNullOrWhiteSpace(cur.HelpText) ? null : cur.HelpText,
            Value = string.IsNullOrWhiteSpace(val) ? null : val,
            BoundingRect = cur.BoundingRectangle
        };

        if (depth >= MaxDepth || remaining <= 0) return node;

        var walker = TreeWalker.RawViewWalker;
        var child = walker.GetFirstChild(element);
        while (child != null && remaining > 0)
        {
            remaining--;
            node.Children.Add(CaptureSnapshot(child, depth + 1, ref remaining));
            child = walker.GetNextSibling(child);
        }
        return node;
    }

    private static List<ExtractedCandidate> ExtractUnreadSidebarRows(UIANodeSnapshot root)
    {
        var results = new List<ExtractedCandidate>();
        var rows = new List<UIANodeSnapshot>();

        void WalkSidebar(UIANodeSnapshot node)
        {
            if (IsExcludedSidebarNode(node)) return;

            bool isRowLike = node.ControlTypeName is "ControlType.ListItem" or "ControlType.DataItem" ||
                             ((node.ControlTypeName is "ControlType.Button" or "ControlType.Custom") &&
                              (node.Name?.Contains("unread", StringComparison.OrdinalIgnoreCase) == true ||
                               node.AutomationId?.Contains("ChatList", StringComparison.OrdinalIgnoreCase) == true) &&
                              !node.Children.Exists(c => c.ControlTypeName is "ControlType.ListItem" or "ControlType.Button"));

            if (isRowLike)
            {
                rows.Add(node);
                return;
            }

            foreach (var child in node.Children)
            {
                WalkSidebar(child);
            }
        }

        WalkSidebar(root);
        var occurrences = new Dictionary<string, int>();

        foreach (var row in rows)
        {
            var texts = CollectTextLeaves(row);
            var combined = string.Join(" | ", new[] { row.Name, row.HelpText, row.Value }.FindAll(s => !string.IsNullOrWhiteSpace(s)));

            if (!ContainsUnreadSignal(combined, texts)) continue;

            var parsed = ParseSidebarRow(texts, combined);
            var bodyText = parsed.Preview ?? parsed.Sender;
            if (string.IsNullOrWhiteSpace(bodyText)) continue;

            var dir = parsed.IsOutgoing ? MessageDirection.Outgoing : MessageDirection.Incoming;
            var key = $"{parsed.Sender ?? ""}|{bodyText}";
            int occ = occurrences.TryGetValue(key, out int prev) ? prev : 0;
            occurrences[key] = occ + 1;

            var stableId = (!string.IsNullOrWhiteSpace(row.AutomationId) && row.AutomationId != "ChatList")
                ? row.AutomationId!
                : "sidebar-" + NormalizeChatLabel(parsed.Sender ?? bodyText);

            results.Add(new ExtractedCandidate
            {
                Sender = parsed.Sender,
                ChatName = parsed.Sender,
                Text = bodyText,
                Timestamp = parsed.Timestamp,
                Direction = dir,
                ElementIdentity = stableId,
                OccurrenceIndex = occ,
                BaseConfidence = parsed.Sender != null && parsed.Preview != null ? 0.85 : 0.72,
                ExtractionPath = "UIASidebarUnread"
            });
        }

        return results;
    }

    private static List<ExtractedCandidate> ExtractActiveChatBubbles(UIANodeSnapshot root, string? activeChatTitle)
    {
        var containers = new List<UIANodeSnapshot>();
        void FindContainers(UIANodeSnapshot node)
        {
            if ((node.ControlTypeName is "ControlType.List" or "ControlType.Pane" or "ControlType.Document") &&
                node.Children.Count >= 1 &&
                !IsSidebarListContainer(node) &&
                (node.AutomationId?.Contains("Message", StringComparison.OrdinalIgnoreCase) == true ||
                 (node.BoundingRect.Width > 300 && root.BoundingRect.Width > 500 &&
                  node.BoundingRect.Left >= root.BoundingRect.Left + root.BoundingRect.Width * 0.28)))
            {
                containers.Add(node);
            }
            foreach (var child in node.Children) FindContainers(child);
        }
        FindContainers(root);

        containers.Sort((a, b) =>
        {
            bool aMsg = a.AutomationId?.Contains("Message", StringComparison.OrdinalIgnoreCase) == true;
            bool bMsg = b.AutomationId?.Contains("Message", StringComparison.OrdinalIgnoreCase) == true;
            if (aMsg != bMsg) return aMsg ? -1 : 1;
            return b.BoundingRect.Width.CompareTo(a.BoundingRect.Width);
        });

        var results = new List<ExtractedCandidate>();
        var occurrences = new Dictionary<string, int>();

        foreach (var container in containers)
        {
            var items = container.Children.FindAll(c => CollectTextLeaves(c).Count > 0);
            int start = Math.Max(0, items.Count - 8);
            for (int i = start; i < items.Count; i++)
            {
                var bubble = items[i];
                var texts = CollectTextLeaves(bubble);
                if (texts.Count == 0) continue;

                var meta = string.Join(" ", new[] { bubble.Name, bubble.HelpText, bubble.AutomationId }.FindAll(s => !string.IsNullOrWhiteSpace(s)));
                var direction = InferBubbleDirection(bubble, container.BoundingRect, meta, texts);

                string? timestamp = null;
                var bodyLines = new List<string>();
                foreach (var line in texts)
                {
                    if (timestamp == null && LooksLikeTimestamp(line) && texts.Count > 1)
                    {
                        timestamp = line;
                    }
                    else
                    {
                        bodyLines.Add(line);
                    }
                }

                string? sender = null;
                string bodyText = string.Join("\n", bodyLines);
                if (bodyLines.Count >= 2 && bodyLines[0].Length <= 48 && !bodyLines[0].Contains('\n'))
                {
                    sender = bodyLines[0];
                    bodyText = string.Join("\n", bodyLines.GetRange(1, bodyLines.Count - 1));
                }

                if (string.IsNullOrWhiteSpace(bodyText)) continue;

                var key = $"{sender ?? activeChatTitle ?? ""}|{bodyText}|{timestamp ?? ""}";
                int occ = occurrences.TryGetValue(key, out int prev) ? prev : 0;
                occurrences[key] = occ + 1;

                var stableId = (!string.IsNullOrWhiteSpace(bubble.AutomationId) && bubble.AutomationId != "BubbleItem")
                    ? bubble.AutomationId!
                    : "chat-bubble-" + NormalizeChatLabel(activeChatTitle ?? sender ?? "active");

                double confidence = (direction, sender ?? activeChatTitle) switch
                {
                    (MessageDirection.Incoming, not null) => 0.90,
                    (MessageDirection.Incoming, null) => 0.78,
                    (MessageDirection.Ambiguous, _) => 0.45,
                    _ => 0.95
                };

                results.Add(new ExtractedCandidate
                {
                    Sender = sender,
                    ChatName = activeChatTitle,
                    Text = bodyText,
                    Timestamp = timestamp,
                    Direction = direction,
                    ElementIdentity = stableId,
                    OccurrenceIndex = occ,
                    BaseConfidence = confidence,
                    ExtractionPath = "UIAActiveChatPane"
                });
            }

            if (results.Count > 0) break;
        }

        return results;
    }

    private static bool IsExcludedSidebarNode(UIANodeSnapshot node)
    {
        var id = (node.AutomationId ?? string.Empty).ToLowerInvariant();
        if (id.Contains("messages") || id.Contains("filter") || id.Contains("chip") || id.Contains("navbar"))
        {
            return true;
        }
        if (node.ControlTypeName == "ControlType.Button")
        {
            var label = (node.Name ?? string.Empty).Trim().ToLowerInvariant();
            if (label is "all" or "unread" or "favorites" or "groups" || label.StartsWith("unread "))
            {
                return true;
            }
        }
        return false;
    }

    private static bool IsChipFilterControl(AutomationElement el)
    {
        var name = (el.Current.Name ?? string.Empty).Trim().ToLowerInvariant();
        var id = (el.Current.AutomationId ?? string.Empty).ToLowerInvariant();
        return id.Contains("filter") || name is "all" or "unread" or "favorites" or "groups";
    }

    private static bool IsSidebarListContainer(UIANodeSnapshot container)
    {
        var id = (container.AutomationId ?? string.Empty).ToLowerInvariant();
        if (id.Contains("messages")) return false;
        if (id.Contains("chatlist") || id.Contains("sidebar") || id.Contains("conversations")) return true;
        return container.Children.Exists(c =>
            (c.Name ?? string.Empty).Contains("unread", StringComparison.OrdinalIgnoreCase));
    }

    private static MessageDirection InferBubbleDirection(UIANodeSnapshot bubble, Rect containerRect, string metadata, List<string> texts)
    {
        var lower = metadata.ToLowerInvariant();
        if (lower.Contains("outgoing") || lower.Contains("your message") || lower.StartsWith("you:") || lower.Contains("sent by you"))
            return MessageDirection.Outgoing;
        if (lower.Contains("incoming"))
            return MessageDirection.Incoming;
        if (texts.Count > 0 && texts[0].Trim().StartsWith("you:", StringComparison.OrdinalIgnoreCase))
            return MessageDirection.Outgoing;

        if (!containerRect.IsEmpty && containerRect.Width > 120 && !bubble.BoundingRect.IsEmpty && bubble.BoundingRect.Width > 0)
        {
            double midX = bubble.BoundingRect.Left + bubble.BoundingRect.Width / 2.0;
            double relX = (midX - containerRect.Left) / containerRect.Width;
            if (relX >= 0.54) return MessageDirection.Outgoing;
            if (relX <= 0.46) return MessageDirection.Incoming;
        }
        return MessageDirection.Ambiguous;
    }

    private static bool ContainsUnreadSignal(string combined, List<string> texts)
    {
        if (combined.Contains("unread", StringComparison.OrdinalIgnoreCase)) return true;
        foreach (var text in texts)
        {
            var trimmed = text.Trim();
            if (int.TryParse(trimmed, out int count) && count > 0 && count < 1000 && !trimmed.Contains(':'))
                return true;
        }
        return false;
    }

    private static (string? Sender, string? Preview, string? Timestamp, bool IsOutgoing) ParseSidebarRow(
        List<string> texts,
        string fallbackDescription)
    {
        string? timestamp = null;
        var clean = new List<string>();
        foreach (var raw in texts)
        {
            var trimmed = raw.Trim();
            if (string.IsNullOrEmpty(trimmed)) continue;
            if (int.TryParse(trimmed, out int num) && num > 0 && num < 1000 && !trimmed.Contains(':')) continue;
            if (IsPureUnreadBadgeLabel(trimmed)) continue;
            if (timestamp == null && LooksLikeTimestamp(trimmed))
            {
                timestamp = trimmed;
                continue;
            }
            clean.Add(trimmed);
        }

        if (clean.Count == 1 && clean[0].Contains(", "))
        {
            var parts = clean[0].Split(", ", StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries);
            var filtered = new List<string>();
            foreach (var p in parts)
            {
                if (IsPureUnreadBadgeLabel(p)) continue;
                if (timestamp == null && LooksLikeTimestamp(p)) timestamp = p;
                else filtered.Add(p);
            }
            if (filtered.Count >= 2)
            {
                var sender = filtered[0];
                var preview = string.Join("\n", filtered.GetRange(1, filtered.Count - 1));
                return (sender, preview, timestamp, preview.StartsWith("You:", StringComparison.OrdinalIgnoreCase));
            }
        }

        if (clean.Count == 0 && !string.IsNullOrWhiteSpace(fallbackDescription))
        {
            var stripped = Regex.Replace(fallbackDescription, "unread message(s)?", "", RegexOptions.IgnoreCase).Trim();
            return (null, string.IsNullOrEmpty(stripped) ? null : stripped, timestamp,
                stripped.StartsWith("You:", StringComparison.OrdinalIgnoreCase));
        }

        string? s = clean.Count > 0 ? clean[0] : null;
        string? prevText = clean.Count > 1 ? string.Join("\n", clean.GetRange(1, clean.Count - 1)) : null;
        return (s, prevText, timestamp, prevText?.StartsWith("You:", StringComparison.OrdinalIgnoreCase) == true);
    }

    private static string? InferWindowChatTitle(UIANodeSnapshot window)
    {
        var rightPaneCandidates = new List<string>();
        void Walk(UIANodeSnapshot node, int depth)
        {
            if (depth > 5) return;
            if (node.ControlTypeName is "ControlType.Text" or "ControlType.Button" &&
                !node.BoundingRect.IsEmpty && !window.BoundingRect.IsEmpty &&
                (node.BoundingRect.Top - window.BoundingRect.Top) < 110 &&
                node.BoundingRect.Left >= window.BoundingRect.Left + window.BoundingRect.Width * 0.35)
            {
                var raw = (node.Name ?? node.Value ?? string.Empty).Trim();
                if (!string.IsNullOrEmpty(raw) &&
                    !raw.Equals("WhatsApp", StringComparison.OrdinalIgnoreCase) &&
                    !raw.Equals("Chats", StringComparison.OrdinalIgnoreCase) &&
                    !raw.Contains("Search", StringComparison.OrdinalIgnoreCase))
                {
                    rightPaneCandidates.Add(raw);
                }
            }
            foreach (var c in node.Children) Walk(c, depth + 1);
        }
        Walk(window, 0);
        return rightPaneCandidates.Count > 0 ? rightPaneCandidates[0] : null;
    }

    private static List<string> CollectTextLeaves(UIANodeSnapshot node)
    {
        var list = new List<string>();
        void AddUnique(string? raw)
        {
            if (string.IsNullOrWhiteSpace(raw)) return;
            var t = raw.Trim();
            if (!list.Contains(t)) list.Add(t);
        }

        void Walk(UIANodeSnapshot cur)
        {
            if (cur.ControlTypeName is "ControlType.Text" or "ControlType.Edit" or "ControlType.Document")
            {
                AddUnique(cur.Value ?? cur.Name);
            }
            foreach (var child in cur.Children) Walk(child);
        }
        Walk(node);
        if (list.Count == 0)
        {
            AddUnique(node.Name);
            AddUnique(node.Value);
            AddUnique(node.HelpText);
        }
        return list;
    }

    private static bool IsPureUnreadBadgeLabel(string text)
    {
        var lower = text.Trim().ToLowerInvariant();
        return lower == "unread" ||
               Regex.IsMatch(lower, @"^\d+\s+unread(\s+messages?)?$");
    }

    private static bool LooksLikeTimestamp(string text) =>
        Regex.IsMatch(text.Trim(), @"^(\d{1,2}:\d{2}(\s?[AP]M)?|Yesterday|Today|Just now)$", RegexOptions.IgnoreCase);

    public static string NormalizeChatLabel(string value)
    {
        if (string.IsNullOrWhiteSpace(value)) return string.Empty;
        return Regex.Replace(MessageProcessor.StripControlAndDirectional(value, false).Trim(), "\\s+", " ").ToLowerInvariant();
    }

    private static AutomationElement? FindComposer(AutomationElement root, Rect winRect)
    {
        var walker = TreeWalker.RawViewWalker;
        AutomationElement? found = null;
        int remaining = 900;

        void Walk(AutomationElement el, int depth)
        {
            if (depth > 16 || remaining-- <= 0 || found != null) return;
            if (el.Current.ControlType == ControlType.Edit)
            {
                var id = (el.Current.AutomationId ?? "").ToLowerInvariant();
                var name = (el.Current.Name ?? "").ToLowerInvariant();
                if (!id.Contains("search") && !name.Contains("search"))
                {
                    var rect = el.Current.BoundingRectangle;
                    if (!winRect.IsEmpty && !rect.IsEmpty)
                    {
                        if (rect.Top >= winRect.Top + winRect.Height * 0.60 &&
                            rect.Left >= winRect.Left + winRect.Width * 0.25)
                        {
                            found = el;
                            return;
                        }
                    }
                    else
                    {
                        found = el;
                        return;
                    }
                }
            }
            var child = walker.GetFirstChild(el);
            while (child != null && remaining > 0 && found == null)
            {
                Walk(child, depth + 1);
                child = walker.GetNextSibling(child);
            }
        }
        Walk(root, 0);
        return found;
    }

    private static AutomationElement? FindSendButton(AutomationElement root, Rect winRect)
    {
        var walker = TreeWalker.RawViewWalker;
        AutomationElement? found = null;
        int remaining = 900;

        void Walk(AutomationElement el, int depth)
        {
            if (depth > 16 || remaining-- <= 0 || found != null) return;
            if (el.Current.ControlType == ControlType.Button)
            {
                var id = (el.Current.AutomationId ?? "").ToLowerInvariant();
                var name = (el.Current.Name ?? "").ToLowerInvariant();
                if (id.Contains("send") || name == "send" || name.Contains("send message"))
                {
                    var rect = el.Current.BoundingRectangle;
                    if (winRect.IsEmpty || rect.IsEmpty || rect.Top >= winRect.Top + winRect.Height * 0.60)
                    {
                        found = el;
                        return;
                    }
                }
            }
            var child = walker.GetFirstChild(el);
            while (child != null && remaining > 0 && found == null)
            {
                Walk(child, depth + 1);
                child = walker.GetNextSibling(child);
            }
        }
        Walk(root, 0);
        return found;
    }

    private static void SendCtrlAAndBackspace()
    {
        var inputs = new[]
        {
            KeyDown(VK_CONTROL), KeyDown(VK_A), KeyUp(VK_A), KeyUp(VK_CONTROL),
            KeyDown(VK_BACK), KeyUp(VK_BACK)
        };
        SendInput((uint)inputs.Length, inputs, Marshal.SizeOf<INPUT>());
    }

    private static void SendUnicodeText(string text)
    {
        var list = new List<INPUT>(text.Length * 2);
        foreach (char c in text)
        {
            list.Add(new INPUT
            {
                type = INPUT_KEYBOARD,
                U = new InputUnion { ki = new KEYBDINPUT { wVk = 0, wScan = c, dwFlags = KEYEVENTF_UNICODE } }
            });
            list.Add(new INPUT
            {
                type = INPUT_KEYBOARD,
                U = new InputUnion { ki = new KEYBDINPUT { wVk = 0, wScan = c, dwFlags = KEYEVENTF_UNICODE | KEYEVENTF_KEYUP } }
            });
        }
        SendInput((uint)list.Count, list.ToArray(), Marshal.SizeOf<INPUT>());
    }

    private static void SendKey(ushort vk)
    {
        var inputs = new[] { KeyDown(vk), KeyUp(vk) };
        SendInput((uint)inputs.Length, inputs, Marshal.SizeOf<INPUT>());
    }

    private static INPUT KeyDown(ushort vk) => new()
    {
        type = INPUT_KEYBOARD,
        U = new InputUnion { ki = new KEYBDINPUT { wVk = vk, dwFlags = 0 } }
    };

    private static INPUT KeyUp(ushort vk) => new()
    {
        type = INPUT_KEYBOARD,
        U = new InputUnion { ki = new KEYBDINPUT { wVk = vk, dwFlags = KEYEVENTF_KEYUP } }
    };
}
