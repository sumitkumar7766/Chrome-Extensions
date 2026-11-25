import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

public struct ReplyDispatchResult: Sendable, Equatable {
    public let succeeded: Bool
    public let errorMessage: String?

    public init(succeeded: Bool, errorMessage: String? = nil) {
        self.succeeded = succeeded
        self.errorMessage = errorMessage
    }
}

/// Lightweight snapshot of a single AXUIElement node to decouple live AX queries from extraction heuristics.
public struct AXNodeSnapshot: Sendable, Equatable {
    public let role: String
    public let subrole: String?
    public let identifier: String?
    public let title: String?
    public let value: String?
    public let descriptionText: String?
    public let frame: CGRect?
    public let children: [AXNodeSnapshot]

    public init(
        role: String,
        subrole: String? = nil,
        identifier: String? = nil,
        title: String? = nil,
        value: String? = nil,
        descriptionText: String? = nil,
        frame: CGRect? = nil,
        children: [AXNodeSnapshot] = []
    ) {
        self.role = role
        self.subrole = subrole
        self.identifier = identifier
        self.title = title
        self.value = value
        self.descriptionText = descriptionText
        self.frame = frame
        self.children = children
    }
}

/// Summary of an AX extraction pass over a WhatsApp Desktop window tree.
public struct ExtractionPassResult: Sendable {
    public let candidates: [ExtractedCandidate]
    public let accessibleWindowCount: Int
    public let visitedNodeCount: Int
    public let extractionMode: String
}

/// Multi-strategy macOS Accessibility extractor for WhatsApp Desktop.
///
/// Architectural note:
/// Official WhatsApp Desktop (`net.whatsapp.WhatsApp`, Mac Catalyst / WAAppKitBridge) does not expose
/// a single guaranteed cross-version AX hierarchy. This extractor avoids hardcoding one rigid path by:
///   1) Reading live AX attributes with strict depth and node-count limits (preventing CPU spikes),
///   2) Searching active conversation containers for message bubbles + horizontal alignment geometry,
///   3) Searching sidebar conversation rows for explicit unread badges + snippet previews.
/// Fields missing in Accessibility attributes remain `nil` and are never fabricated.
public final class AccessibilityExtractor: @unchecked Sendable {
    public struct Limits: Sendable {
        public let maxDepth: Int
        public let maxNodes: Int

        public init(maxDepth: Int = 22, maxNodes: Int = 1200) {
            self.maxDepth = maxDepth
            self.maxNodes = maxNodes
        }
    }

    private let limits: Limits

    public init(limits: Limits = Limits()) {
        self.limits = limits
    }

    /// Captures and extracts message candidates from a live WhatsApp `AXApplication` element.
    public func extract(fromAppElement appElement: AXUIElement) -> ExtractionPassResult {
        enableEnhancedAccessibilityIfSupported(on: appElement)
        let windows = collectAccessibleWindows(from: appElement, maxWindows: 4)
        guard !windows.isEmpty else {
            return ExtractionPassResult(
                candidates: [],
                accessibleWindowCount: 0,
                visitedNodeCount: 0,
                extractionMode: "No accessible windows"
            )
        }

        var totalVisited = 0
        var allCandidates: [ExtractedCandidate] = []
        var modes: Set<String> = []

        for window in windows {
            var remainingBudget = limits.maxNodes
            let snapshot = captureSnapshot(element: window, depth: 0, remainingBudget: &remainingBudget)
            totalVisited += (limits.maxNodes - remainingBudget)

            let windowCandidates = extractFromWindowSnapshot(snapshot)
            for candidate in windowCandidates {
                modes.insert(candidate.extractionPath)
            }
            allCandidates.append(contentsOf: windowCandidates)
        }

        let modeSummary = modes.isEmpty ? "AX Active (Watching)" : modes.sorted().joined(separator: " + ")
        return ExtractionPassResult(
            candidates: allCandidates,
            accessibleWindowCount: windows.count,
            visitedNodeCount: totalVisited,
            extractionMode: modeSummary
        )
    }

    /// Reads visible WhatsApp banners/alerts from macOS NotificationCenter (`com.apple.notificationcenterui`)
    /// using public Accessibility APIs when Accessibility trust is granted. Strictly ignores all non-WhatsApp notifications.
    public func extractNotificationCenterWhatsAppBanners(fromAppElement ncElement: AXUIElement) -> ExtractionPassResult {
        var roots = collectAccessibleWindows(from: ncElement, maxWindows: 4)
        if roots.isEmpty {
            var childrenRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(ncElement, kAXChildrenAttribute as CFString, &childrenRef) == .success,
               let children = childrenRef as? [AXUIElement] {
                roots = Array(children.prefix(4))
            }
        }

        guard !roots.isEmpty else {
            return ExtractionPassResult(
                candidates: [],
                accessibleWindowCount: 0,
                visitedNodeCount: 0,
                extractionMode: "NotificationCenter Idle"
            )
        }

        var totalVisited = 0
        var allCandidates: [ExtractedCandidate] = []
        for root in roots {
            var remainingBudget = 450
            let snapshot = captureSnapshot(element: root, depth: 0, remainingBudget: &remainingBudget, maxDepthOverride: 16)
            totalVisited += (450 - remainingBudget)
            allCandidates.append(contentsOf: extractWhatsAppBanners(fromNotificationWindowSnapshot: snapshot))
        }

        return ExtractionPassResult(
            candidates: allCandidates,
            accessibleWindowCount: roots.count,
            visitedNodeCount: totalVisited,
            extractionMode: allCandidates.isEmpty ? "AX Banner Watch" : "AXNotificationBanner"
        )
    }

    /// Pure-Swift NotificationCenter banner parser (also used directly in unit tests).
    public func extractWhatsAppBanners(fromNotificationWindowSnapshot window: AXNodeSnapshot) -> [ExtractedCandidate] {
        var bannerNodes: [AXNodeSnapshot] = []
        collectNodes(in: window, matching: { node in
            node.subrole == "AXNotificationCenterBanner" ||
            node.subrole == "AXNotificationCenterAlert" ||
            node.identifier == "AXNotificationCenterBanner" ||
            node.identifier == "AXNotificationCenterAlert"
        }, into: &bannerNodes)

        if bannerNodes.isEmpty {
            bannerNodes = [window]
        }

        let chromeLabels: Set<String> = [
            "close", "clear", "clear all", "options", "actions", "reply", "mark as read",
            "more", "view", "show details", "show more", "show less", "expand", "collapse",
            "open", "dismiss", "snooze", "mute", "whatsapp", "whatsapp desktop",
            "notification center", "notifications", "notification", "delivered quietly",
            "time sensitive",
        ]

        var results: [ExtractedCandidate] = []
        var occurrenceCounter: [String: Int] = [:]

        for (idx, banner) in bannerNodes.enumerated() {
            // 1. Check whether this banner explicitly belongs to WhatsApp.
            let rawMetaStrings = [banner.title, banner.descriptionText, banner.identifier, banner.value]
                .compactMap { $0 }
            let leafRecords = collectOrderedBannerLeafTexts(in: banner)
            let identifiesWhatsApp =
                rawMetaStrings.contains {
                    let l = $0.lowercased()
                    return l.contains("whatsapp") || l.contains("net.whatsapp")
                } ||
                leafRecords.contains {
                    let l = $0.text.lowercased()
                    return l == "whatsapp" || l.contains("whatsapp") || l.contains("net.whatsapp")
                }

            guard identifiesWhatsApp else { continue }

            // 2. Prefer structured child AXHeading/AXStaticText leaves sorted top-to-bottom
            //    so composite container AXDescription strings don't duplicate title/body.
            let candidateLines: [(role: String, text: String)]
            if !leafRecords.isEmpty {
                candidateLines = leafRecords
            } else {
                let fallbackRaw = banner.descriptionText ?? banner.title ?? banner.value ?? ""
                candidateLines = expandNotificationDescriptionIfNeeded(fallbackRaw)
                    .map { ("AXStaticText", $0) }
            }

            var timestamp: String?
            var filtered: [(role: String, text: String)] = []

            for item in candidateLines {
                let cleaned = stripDirectionalFormatting(item.text)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let lower = cleaned.lowercased()
                guard !cleaned.isEmpty,
                      !chromeLabels.contains(lower),
                      !isPureUnreadBadgeLabel(cleaned),
                      !lower.hasSuffix(" more notifications"),
                      lower != "1 more notification" else {
                    continue
                }
                if timestamp == nil && (looksLikeTimestamp(cleaned) || lower == "now") && candidateLines.count > 1 {
                    timestamp = cleaned
                    continue
                }
                if !filtered.contains(where: { $0.text == cleaned }) {
                    filtered.append((item.role, cleaned))
                }
            }

            guard !filtered.isEmpty else { continue }

            var chatTitle: String?
            var sender: String?
            var body: String

            if filtered.count >= 3,
               filtered[0].role == "AXHeading" || (filtered[1].text.count <= 48 && !filtered[1].text.contains("\n")) {
                chatTitle = filtered[0].text
                sender = filtered[1].text
                body = filtered.dropFirst(2).map(\.text).joined(separator: "\n")
            } else if filtered.count >= 2 {
                let header = filtered[0].text
                if let atRange = header.range(of: " @ ") {
                    sender = String(header[..<atRange.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
                    chatTitle = String(header[atRange.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
                } else {
                    sender = header
                    chatTitle = header
                }
                body = filtered.dropFirst().map(\.text).joined(separator: "\n")
            } else {
                let single = filtered[0].text
                if let colonIdx = single.firstIndex(of: ":"),
                   single.distance(from: single.startIndex, to: colonIdx) <= 40 {
                    let prefix = String(single[..<colonIdx]).trimmingCharacters(in: .whitespacesAndNewlines)
                    let rest = String(single[single.index(after: colonIdx)...]).trimmingCharacters(in: .whitespacesAndNewlines)
                    if !prefix.isEmpty && !rest.isEmpty {
                        sender = prefix
                        chatTitle = prefix
                        body = rest
                    } else {
                        sender = nil
                        chatTitle = "WhatsApp"
                        body = single
                    }
                } else {
                    sender = nil
                    chatTitle = "WhatsApp"
                    body = single
                }
            }

            guard !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }

            let key = "\(sender ?? chatTitle ?? "")|\(body)"
            let occurrence = occurrenceCounter[key, default: 0]
            occurrenceCounter[key] = occurrence + 1

            results.append(
                ExtractedCandidate(
                    sender: sender,
                    chatName: chatTitle,
                    text: body,
                    timestamp: timestamp,
                    direction: .incoming,
                    elementIdentity: banner.identifier ?? "nc-banner-\(idx)",
                    occurrenceIndex: occurrence,
                    baseConfidence: 0.90,
                    extractionPath: "AXNotificationBanner"
                )
            )
        }

        return results
    }

    private func collectAccessibleWindows(from appElement: AXUIElement, maxWindows: Int) -> [AXUIElement] {
        var collected: [AXUIElement] = []

        func appendUnique(_ el: AXUIElement) {
            if !collected.contains(where: { CFEqual($0, el) }) {
                collected.append(el)
            }
        }

        var windowsRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsRef) == .success,
           let windows = windowsRef as? [AXUIElement] {
            for win in windows {
                appendUnique(win)
            }
        }

        for fallbackAttr in [kAXMainWindowAttribute, kAXFocusedWindowAttribute] {
            var singleRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(appElement, fallbackAttr as CFString, &singleRef) == .success,
               let singleRef,
               CFGetTypeID(singleRef) == AXUIElementGetTypeID() {
                appendUnique(unsafeDowncast(singleRef, to: AXUIElement.self))
            }
        }

        if collected.isEmpty {
            var childrenRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(appElement, kAXChildrenAttribute as CFString, &childrenRef) == .success,
               let children = childrenRef as? [AXUIElement] {
                for child in children {
                    if copyStringAttribute(child, kAXRoleAttribute) == "AXWindow" {
                        appendUnique(child)
                    }
                }
            }
        }

        return Array(collected.prefix(maxWindows))
    }

    /// Attempts to open/select a specific conversation row in WhatsApp Desktop using public AX actions.
    /// Returns true only if a matching accessible element accepted `AXPress` or `AXSelected`.
    public func focusChat(named targetChatTitle: String, inPID pid: pid_t) -> Bool {
        let normalizedTarget = Self.normalizeChatLabel(targetChatTitle)
        guard !normalizedTarget.isEmpty, AXIsProcessTrusted() else { return false }

        let appElement = AXUIElementCreateApplication(pid)
        enableEnhancedAccessibilityIfSupported(on: appElement)
        let windows = collectAccessibleWindows(from: appElement, maxWindows: 4)
        guard !windows.isEmpty else {
            return false
        }

        var exactMatch: AXUIElement?
        var prefixMatch: AXUIElement?
        var remainingBudget = 900

        func scanLiveNode(_ element: AXUIElement, depth: Int) {
            guard depth <= 16, remainingBudget > 0, exactMatch == nil else { return }
            remainingBudget -= 1

            let role = copyStringAttribute(element, kAXRoleAttribute) ?? ""
            if role == "AXRow" || role == "AXCell" || role == "AXGroup" || role == "AXButton" {
                let candidateText = [
                    copyStringAttribute(element, kAXTitleAttribute),
                    copyStringAttribute(element, kAXDescriptionAttribute),
                    copyValueAsString(element),
                ]
                .compactMap { $0 }
                .joined(separator: " ")

                let rowTexts = collectLiveTextLeaves(element: element, maxSubnodes: 16) + [candidateText]
                for raw in rowTexts {
                    let norm = Self.normalizeChatLabel(raw)
                    guard !norm.isEmpty else { continue }
                    if norm == normalizedTarget {
                        exactMatch = element
                        return
                    }
                    if prefixMatch == nil && (norm.hasPrefix(normalizedTarget) || norm.contains(normalizedTarget)) {
                        prefixMatch = element
                    }
                }
            }

            var childrenRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenRef) == .success,
               let children = childrenRef as? [AXUIElement] {
                for child in children {
                    if remainingBudget <= 0 || exactMatch != nil { break }
                    scanLiveNode(child, depth: depth + 1)
                }
            }
        }

        for window in windows.prefix(4) {
            scanLiveNode(window, depth: 0)
            if exactMatch != nil { break }
        }

        guard let targetElement = exactMatch ?? prefixMatch else {
            return false
        }

        if AXUIElementPerformAction(targetElement, kAXPressAction as CFString) == .success {
            return true
        }
        if AXUIElementSetAttributeValue(targetElement, kAXSelectedAttribute as CFString, kCFBooleanTrue) == .success {
            return true
        }
        return false
    }

    /// Reads visible incoming/outgoing bubbles for `targetChatTitle` ONLY when the open WhatsApp chat
    /// window header matches `targetChatTitle` (preventing cross-chat leakage).
    public func extractVisibleConversation(forChatTitle targetChatTitle: String, fromPID pid: pid_t) -> [ChatBubbleEntry] {
        let normalizedTarget = Self.normalizeChatLabel(targetChatTitle)
        guard !normalizedTarget.isEmpty, AXIsProcessTrusted() else { return [] }

        let appElement = AXUIElementCreateApplication(pid)
        enableEnhancedAccessibilityIfSupported(on: appElement)
        let windows = collectAccessibleWindows(from: appElement, maxWindows: 4)
        guard !windows.isEmpty else {
            return []
        }

        for window in windows {
            var remainingBudget = limits.maxNodes
            let snapshot = captureSnapshot(element: window, depth: 0, remainingBudget: &remainingBudget)
            guard let activeTitle = inferWindowChatTitle(snapshot),
                  Self.normalizeChatLabel(activeTitle) == normalizedTarget else {
                continue
            }

            let bubbles = extractActiveChatBubbles(in: snapshot, activeChatTitle: activeTitle)
            if !bubbles.isEmpty {
                return bubbles.enumerated().compactMap { idx, item in
                    guard let text = item.text, !text.isEmpty else { return nil }
                    return ChatBubbleEntry(
                        id: "ax-\(idx)-\(item.elementIdentity ?? "")-\(text.hashValue)",
                        sender: item.sender,
                        text: text,
                        timestamp: item.timestamp,
                        isOutgoing: item.direction == .outgoing,
                        isTest: false
                    )
                }
            }
        }

        return []
    }

    /// Sends a reply through WhatsApp Desktop's accessible composer UI ONLY after verifying
    /// Accessibility permission, compose input element, and target chat selection.
    public func sendReply(_ replyText: String, expectedChatTitle: String?, inPID pid: pid_t) -> ReplyDispatchResult {
        let trimmedReply = replyText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedReply.isEmpty else {
            return ReplyDispatchResult(succeeded: false, errorMessage: "Reply message cannot be empty.")
        }
        guard AXIsProcessTrusted() else {
            return ReplyDispatchResult(succeeded: false, errorMessage: "Accessibility permission required.")
        }

        let appElement = AXUIElementCreateApplication(pid)
        enableEnhancedAccessibilityIfSupported(on: appElement)

        let windows = collectAccessibleWindows(from: appElement, maxWindows: 4)
        guard let mainWindow = windows.first else {
            return ReplyDispatchResult(
                succeeded: false,
                errorMessage: "Open WhatsApp's window once so PingGlass can access the message composer."
            )
        }

        // Un-minimize if minimized and raise window cleanly.
        var minimizedRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(mainWindow, kAXMinimizedAttribute as CFString, &minimizedRef) == .success,
           (minimizedRef as? Bool) == true {
            _ = AXUIElementSetAttributeValue(mainWindow, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
        }
        _ = AXUIElementPerformAction(mainWindow, kAXRaiseAction as CFString)

        // Focus requested chat row if specified and not already matching open header.
        if let expectedChatTitle, !expectedChatTitle.isEmpty {
            let normExpected = Self.normalizeChatLabel(expectedChatTitle)
            let initialTitle = activeChatTitle(in: mainWindow).map { Self.normalizeChatLabel($0) }
            if initialTitle != normExpected {
                let clicked = focusChat(named: expectedChatTitle, inPID: pid)
                if !clicked && (initialTitle != nil && initialTitle != normExpected) {
                    return ReplyDispatchResult(
                        succeeded: false,
                        errorMessage: "Could not switch WhatsApp to \"\(expectedChatTitle)\"."
                    )
                }
                Thread.sleep(forTimeInterval: 0.16)
            }

            if let verifiedTitle = activeChatTitle(in: mainWindow) {
                let normVerified = Self.normalizeChatLabel(verifiedTitle)
                if !normVerified.isEmpty &&
                    normVerified != "whatsapp" &&
                    normVerified != normExpected &&
                    !normVerified.contains(normExpected) &&
                    !normExpected.contains(normVerified) {
                    return ReplyDispatchResult(
                        succeeded: false,
                        errorMessage: "Active WhatsApp chat (\"\(verifiedTitle)\") does not match \"\(expectedChatTitle)\"."
                    )
                }
            }
        }

        guard let composeElement = findMessageComposer(in: mainWindow) else {
            return ReplyDispatchResult(
                succeeded: false,
                errorMessage: "WhatsApp message input box not accessible. Opened chat in WhatsApp."
            )
        }

        _ = AXUIElementSetAttributeValue(composeElement, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        _ = AXUIElementPerformAction(composeElement, kAXPressAction as CFString)

        let directErr = AXUIElementSetAttributeValue(composeElement, kAXValueAttribute as CFString, trimmedReply as CFTypeRef)
        Thread.sleep(forTimeInterval: 0.08)

        let readBack = copyValueAsString(composeElement)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if directErr != .success || !readBack.contains(trimmedReply) {
            // Catalyst UITextView fallback: paste once via NSPasteboard + Cmd+V into verified focused composer.
            let pb = NSPasteboard.general
            let prevString = pb.string(forType: .string)
            pb.clearContents()
            pb.setString(trimmedReply, forType: .string)
            postKeyCombo(virtualKey: 9, flags: .maskCommand, pid: pid) // Cmd+V
            Thread.sleep(forTimeInterval: 0.10)
            if let prevString {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    let restorePB = NSPasteboard.general
                    if restorePB.string(forType: .string) == trimmedReply {
                        restorePB.clearContents()
                        restorePB.setString(prevString, forType: .string)
                    }
                }
            }
        }

        if let sendButton = findSendButton(in: mainWindow) {
            if AXUIElementPerformAction(sendButton, kAXPressAction as CFString) == .success {
                return ReplyDispatchResult(succeeded: true)
            }
        }

        // Send Return key directly to verified active composer.
        postKeyCombo(virtualKey: 36, flags: [], pid: pid)
        return ReplyDispatchResult(succeeded: true)
    }

    private func activeChatTitle(in windowElement: AXUIElement) -> String? {
        var rem = 180
        let snap = captureSnapshot(element: windowElement, depth: 0, remainingBudget: &rem, maxDepthOverride: 6)
        return inferWindowChatTitle(snap)
    }

    private func findMessageComposer(in windowElement: AXUIElement) -> AXUIElement? {
        let winFrame = copyFrame(windowElement)
        var prioritized: AXUIElement?
        var bottomFallback: AXUIElement?
        var remaining = 900

        func scan(_ el: AXUIElement, depth: Int) {
            guard depth <= 18, remaining > 0, prioritized == nil else { return }
            remaining -= 1

            let role = copyStringAttribute(el, kAXRoleAttribute) ?? ""
            let id = (copyStringAttribute(el, kAXIdentifierAttribute) ?? "").lowercased()
            let desc = (copyStringAttribute(el, kAXDescriptionAttribute) ?? "").lowercased()
            let title = (copyStringAttribute(el, kAXTitleAttribute) ?? "").lowercased()

            let isSearch = id.contains("search") || desc.contains("search") || title.contains("search")
            if (role == "AXTextArea" || role == "AXTextField"), !isSearch {
                if id.contains("chatbar") || id.contains("composer") || desc.contains("type a message") || title.contains("type a message") {
                    prioritized = el
                    return
                }
                if let winFrame, let elFrame = copyFrame(el) {
                    let inBottomHalf = elFrame.midY >= winFrame.minY + winFrame.height * 0.65
                    let inRightPane = elFrame.midX >= winFrame.minX + winFrame.width * 0.30
                    if inBottomHalf && inRightPane {
                        bottomFallback = el
                    }
                } else if bottomFallback == nil && role == "AXTextArea" {
                    bottomFallback = el
                }
            }

            var childrenRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(el, kAXChildrenAttribute as CFString, &childrenRef) == .success,
               let children = childrenRef as? [AXUIElement] {
                for child in children {
                    if remaining <= 0 || prioritized != nil { break }
                    scan(child, depth: depth + 1)
                }
            }
        }
        scan(windowElement, depth: 0)
        return prioritized ?? bottomFallback
    }

    private func findSendButton(in windowElement: AXUIElement) -> AXUIElement? {
        let winFrame = copyFrame(windowElement)
        var found: AXUIElement?
        var remaining = 900

        func scan(_ el: AXUIElement, depth: Int) {
            guard depth <= 18, remaining > 0, found == nil else { return }
            remaining -= 1

            let role = copyStringAttribute(el, kAXRoleAttribute) ?? ""
            if role == "AXButton" {
                let id = (copyStringAttribute(el, kAXIdentifierAttribute) ?? "").lowercased()
                let desc = (copyStringAttribute(el, kAXDescriptionAttribute) ?? "").lowercased()
                let title = (copyStringAttribute(el, kAXTitleAttribute) ?? "").lowercased()
                let matchesSend = id.contains("send") || desc == "send" || desc.contains("send message") || title == "send"
                if matchesSend {
                    var enabledRef: CFTypeRef?
                    let enabled = (AXUIElementCopyAttributeValue(el, kAXEnabledAttribute as CFString, &enabledRef) == .success)
                        ? ((enabledRef as? Bool) ?? true)
                        : true
                    if enabled {
                        if let winFrame, let bf = copyFrame(el) {
                            if bf.midY >= winFrame.minY + winFrame.height * 0.60 {
                                found = el
                                return
                            }
                        } else {
                            found = el
                            return
                        }
                    }
                }
            }

            var childrenRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(el, kAXChildrenAttribute as CFString, &childrenRef) == .success,
               let children = childrenRef as? [AXUIElement] {
                for child in children {
                    if remaining <= 0 || found != nil { break }
                    scan(child, depth: depth + 1)
                }
            }
        }
        scan(windowElement, depth: 0)
        return found
    }

    private func postKeyCombo(virtualKey: CGKeyCode, flags: CGEventFlags, pid: pid_t) {
        let src = CGEventSource(stateID: .hidSystemState)
        if let down = CGEvent(keyboardEventSource: src, virtualKey: virtualKey, keyDown: true),
           let up = CGEvent(keyboardEventSource: src, virtualKey: virtualKey, keyDown: false) {
            down.flags = flags
            up.flags = flags
            down.postToPid(pid)
            up.postToPid(pid)
        }
    }

    private func enableEnhancedAccessibilityIfSupported(on appElement: AXUIElement) {
        _ = AXUIElementSetAttributeValue(appElement, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
    }

    /// Pure-Swift helper for unit testing chat row matching in sidebar snapshots.
    public func findMatchingSidebarRow(in window: AXNodeSnapshot, targetChatTitle: String) -> AXNodeSnapshot? {
        let normalizedTarget = Self.normalizeChatLabel(targetChatTitle)
        guard !normalizedTarget.isEmpty else { return nil }

        var rows: [AXNodeSnapshot] = []
        collectNodes(in: window, matching: { $0.role == "AXRow" || $0.role == "AXCell" }, into: &rows)

        var fallbackMatch: AXNodeSnapshot?
        for row in rows {
            let texts = collectTextLeaves(in: row) + [row.title, row.descriptionText, row.value].compactMap { $0 }
            for raw in texts {
                let norm = Self.normalizeChatLabel(raw)
                guard !norm.isEmpty else { continue }
                if norm == normalizedTarget {
                    return row
                }
                if fallbackMatch == nil && (norm.hasPrefix(normalizedTarget) || norm.contains(normalizedTarget)) {
                    fallbackMatch = row
                }
            }
        }
        return fallbackMatch
    }

    private static func normalizeChatLabel(_ value: String) -> String {
        stripDirectionalMarksStatic(value)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .lowercased()
    }

    private static func stripDirectionalMarksStatic(_ value: String) -> String {
        let marks: Set<UInt32> = [
            0x200B, 0x200C, 0x200D, 0x200E, 0x200F,
            0x202A, 0x202B, 0x202C, 0x202D, 0x202E,
            0x2066, 0x2067, 0x2068, 0x2069, 0xFEFF,
        ]
        return String(String.UnicodeScalarView(value.unicodeScalars.filter { !marks.contains($0.value) }))
    }

    private func stripDirectionalFormatting(_ value: String) -> String {
        Self.stripDirectionalMarksStatic(value)
    }

    private func collectLiveTextLeaves(element: AXUIElement, maxSubnodes: Int) -> [String] {
        var output: [String] = []
        var remaining = maxSubnodes

        func walk(_ node: AXUIElement, depth: Int) {
            guard depth <= 4, remaining > 0 else { return }
            remaining -= 1
            let role = copyStringAttribute(node, kAXRoleAttribute) ?? ""
            if role == "AXStaticText" || role == "AXHeading" {
                if let text = copyValueAsString(node) ?? copyStringAttribute(node, kAXTitleAttribute) {
                    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty {
                        output.append(trimmed)
                    }
                }
            }
            var childrenRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(node, kAXChildrenAttribute as CFString, &childrenRef) == .success,
               let children = childrenRef as? [AXUIElement] {
                for child in children {
                    if remaining <= 0 { break }
                    walk(child, depth: depth + 1)
                }
            }
        }
        walk(element, depth: 0)
        return output
    }

    /// Pure-Swift extraction entrypoint over a window `AXNodeSnapshot` (also used directly in unit tests).
    public func extractFromWindowSnapshot(_ window: AXNodeSnapshot) -> [ExtractedCandidate] {
        var candidates: [ExtractedCandidate] = []
        let activeChatTitle = inferWindowChatTitle(window)

        // Strategy 1: Sidebar / conversation list unread rows
        candidates.append(contentsOf: extractUnreadSidebarRows(in: window))

        // Strategy 2: Active chat pane message bubbles (tailored to visible tail of conversation)
        candidates.append(contentsOf: extractActiveChatBubbles(in: window, activeChatTitle: activeChatTitle))

        return candidates
    }

    // MARK: - Strategy 1: Sidebar Unread Rows

    private func extractUnreadSidebarRows(in root: AXNodeSnapshot) -> [ExtractedCandidate] {
        var results: [ExtractedCandidate] = []
        var candidateRows: [AXNodeSnapshot] = []
        collectNodes(in: root, matching: { node in
            if node.role == "AXRow" || node.role == "AXCell" {
                return true
            }
            if node.role == "AXButton" || node.role == "AXGroup" {
                if node.identifier?.localizedCaseInsensitiveContains("chat") == true ||
                    node.identifier?.localizedCaseInsensitiveContains("conversation") == true {
                    return true
                }
                // Match Catalyst AXButton/AXGroup cells that carry an explicit "unread" AX label directly
                // (without picking up an outer container that wraps multiple rows).
                let directMeta = [node.descriptionText, node.title, node.value]
                    .compactMap { $0 }
                    .joined(separator: " ")
                    .lowercased()
                let hasNestedRows = node.children.contains {
                    $0.role == "AXRow" || $0.role == "AXCell" || $0.role == "AXButton"
                }
                return !hasNestedRows && directMeta.contains("unread")
            }
            return false
        }, into: &candidateRows)

        var occurrenceCounter: [String: Int] = [:]

        for (idx, row) in candidateRows.enumerated() {
            let texts = collectTextLeaves(in: row)
            let rowDescription = [row.descriptionText, row.title, row.value]
                .compactMap { $0 }
                .joined(separator: " | ")

            let hasUnreadMarker = containsUnreadSignal(description: rowDescription, texts: texts)
            guard hasUnreadMarker else { continue }

            let parsed = parseSidebarRow(texts: texts, fallbackDescription: rowDescription)
            guard let bodyText = parsed.preview ?? parsed.sender else { continue }

            let direction: MessageDirection = parsed.isOutgoing ? .outgoing : .incoming
            let key = "\(parsed.sender ?? "")|\(bodyText)"
            let occurrence = occurrenceCounter[key, default: 0]
            occurrenceCounter[key] = occurrence + 1

            results.append(
                ExtractedCandidate(
                    sender: parsed.sender,
                    chatName: parsed.sender,
                    text: bodyText,
                    timestamp: parsed.timestamp,
                    direction: direction,
                    elementIdentity: row.identifier ?? "sidebar-row-\(idx)",
                    occurrenceIndex: occurrence,
                    baseConfidence: parsed.sender != nil && parsed.preview != nil ? 0.85 : 0.72,
                    extractionPath: "AXSidebarUnread"
                )
            )
        }

        return results
    }

    private func containsUnreadSignal(description: String, texts: [String]) -> Bool {
        let lowerDesc = description.lowercased()
        if lowerDesc.contains("unread") {
            return true
        }
        // Detect isolated small integer unread count badge in row children (e.g., "1", "3", "12").
        for text in texts {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if let num = Int(trimmed), num > 0, num < 1000 {
                // Ensure it's not part of a timestamp like "11:42"
                if !trimmed.contains(":") {
                    return true
                }
            }
        }
        return false
    }

    private func parseSidebarRow(texts: [String], fallbackDescription: String) -> (
        sender: String?,
        preview: String?,
        timestamp: String?,
        isOutgoing: Bool
    ) {
        var timestamp: String?
        var nonBadgeTexts: [String] = []

        for raw in texts {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            if let num = Int(trimmed), num > 0, num < 1000, !trimmed.contains(":") {
                continue // skip unread counter badge itself
            }
            if isPureUnreadBadgeLabel(trimmed) {
                continue // skip "1 unread message" / "unread messages" AX labels
            }
            if timestamp == nil, looksLikeTimestamp(trimmed) {
                timestamp = trimmed
                continue
            }
            nonBadgeTexts.append(trimmed)
        }

        if nonBadgeTexts.isEmpty && !fallbackDescription.isEmpty {
            let cleaned = fallbackDescription
                .replacingOccurrences(of: "unread message", with: "", options: .caseInsensitive)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return (nil, cleaned.isEmpty ? nil : cleaned, timestamp, cleaned.lowercased().hasPrefix("you:"))
        }

        // Strategy 1: If row holds a packed Catalyst accessibility description like "Rahul, 1:15 PM, Hey"
        // as a single string alongside no distinct child lines, split nicely.
        if nonBadgeTexts.count == 1, let single = nonBadgeTexts.first, single.contains(", ") {
            let parts = single.components(separatedBy: ", ").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter {
                !$0.isEmpty && !isPureUnreadBadgeLabel($0)
            }
            if parts.count >= 2 {
                var parsedParts: [String] = []
                for p in parts {
                    if timestamp == nil && looksLikeTimestamp(p) {
                        timestamp = p
                    } else {
                        parsedParts.append(p)
                    }
                }
                if parsedParts.count >= 2 {
                    let s = parsedParts.first
                    let p = parsedParts.dropFirst().joined(separator: "\n")
                    let out = (p.lowercased().hasPrefix("you:") || p.lowercased().hasPrefix("sent by you"))
                    return (s, p, timestamp, out)
                }
            }
        }

        let sender = nonBadgeTexts.first
        let preview = nonBadgeTexts.count > 1 ? nonBadgeTexts.dropFirst().joined(separator: "\n") : nil
        let isOutgoing = (preview?.lowercased().hasPrefix("you:") == true)
        return (sender, preview, timestamp, isOutgoing)
    }

    // MARK: - Strategy 2: Active Chat Message Bubbles

    private func extractActiveChatBubbles(
        in root: AXNodeSnapshot,
        activeChatTitle: String?
    ) -> [ExtractedCandidate] {
        var containers: [AXNodeSnapshot] = []
        collectNodes(in: root, matching: { node in
            (node.role == "AXScrollArea" || node.role == "AXList" || node.role == "AXTable") &&
            node.children.count >= 1 &&
            !isSidebarConversationContainer(node)
        }, into: &containers)

        // Heuristic: the active chat transcript container typically occupies the right/wider pane.
        let sortedContainers = containers.sorted { lhs, rhs in
            let lw = lhs.frame?.width ?? 0
            let rw = rhs.frame?.width ?? 0
            return lw > rw
        }

        var results: [ExtractedCandidate] = []
        var occurrenceCounter: [String: Int] = [:]

        for container in sortedContainers.prefix(2) {
            let bubbleNodes = flattenMessageLikeChildren(in: container)
            // Focus on the newest visible tail (up to last 8 items) to minimize noise & work.
            let tailNodes = bubbleNodes.suffix(8)

            for (idx, bubble) in tailNodes.enumerated() {
                let texts = collectTextLeaves(in: bubble)
                guard !texts.isEmpty else { continue }

                let combinedMeta = [bubble.descriptionText, bubble.title, bubble.identifier]
                    .compactMap { $0 }
                    .joined(separator: " ")

                let direction = inferBubbleDirection(
                    bubble: bubble,
                    containerFrame: container.frame,
                    metadata: combinedMeta,
                    texts: texts
                )

                var timestamp: String?
                var bodyLines: [String] = []
                for line in texts {
                    if timestamp == nil && looksLikeTimestamp(line) && texts.count > 1 {
                        timestamp = line
                    } else {
                        bodyLines.append(line)
                    }
                }

                // In group chats or Catalyst accessible labels, a leading short label before body can be sender.
                var sender: String?
                var bodyText = bodyLines.joined(separator: "\n")
                if bodyLines.count >= 2,
                   let first = bodyLines.first,
                   first.count <= 48,
                   !first.contains("\n") {
                    sender = first
                    bodyText = bodyLines.dropFirst().joined(separator: "\n")
                }

                guard !bodyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }

                let key = "\(sender ?? activeChatTitle ?? "")|\(bodyText)|\(timestamp ?? "")"
                let occurrence = occurrenceCounter[key, default: 0]
                occurrenceCounter[key] = occurrence + 1

                let confidence: Double = {
                    switch (direction, sender ?? activeChatTitle) {
                    case (.incoming, .some): return 0.90
                    case (.incoming, .none): return 0.78
                    case (.ambiguous, _): return 0.45
                    case (.outgoing, _): return 0.95
                    }
                }()

                results.append(
                    ExtractedCandidate(
                        sender: sender,
                        chatName: activeChatTitle,
                        text: bodyText,
                        timestamp: timestamp,
                        direction: direction,
                        elementIdentity: bubble.identifier ?? "chat-bubble-\(idx)",
                        occurrenceIndex: occurrence,
                        baseConfidence: confidence,
                        extractionPath: "AXActiveChatPane"
                    )
                )
            }

            if !results.isEmpty {
                break
            }
        }

        return results
    }

    private func inferBubbleDirection(
        bubble: AXNodeSnapshot,
        containerFrame: CGRect?,
        metadata: String,
        texts: [String]
    ) -> MessageDirection {
        let lowerMeta = metadata.lowercased()
        if lowerMeta.contains("outgoing") ||
           lowerMeta.contains("your message") ||
           lowerMeta.hasPrefix("you:") ||
           lowerMeta.contains("sent by you") {
            return .outgoing
        }
        if lowerMeta.contains("incoming") {
            return .incoming
        }
        if let first = texts.first?.lowercased(), first.hasPrefix("you:") {
            return .outgoing
        }

        // Geometric alignment fallback inside the chat container:
        // WhatsApp aligns outgoing bubbles on the right and incoming bubbles on the left.
        // Mac Catalyst often wraps each message inside a full-width AXCell/AXGroup, so resolve
        // the tightest inner bubble child frame whenever the wrapper spans >62% of the container.
        if let containerFrame,
           containerFrame.width > 120,
           let bubbleFrame = effectiveBubbleFrame(for: bubble, containerWidth: containerFrame.width),
           bubbleFrame.width > 0 {
            let relativeCenterX = (bubbleFrame.midX - containerFrame.minX) / containerFrame.width
            if relativeCenterX >= 0.54 {
                return .outgoing
            }
            if relativeCenterX <= 0.46 {
                return .incoming
            }
        }

        return .ambiguous
    }

    private func effectiveBubbleFrame(for node: AXNodeSnapshot, containerWidth: CGFloat) -> CGRect? {
        guard let outer = node.frame else { return nil }
        if outer.width <= containerWidth * 0.62 {
            return outer
        }

        var innerFrames: [CGRect] = []
        func findInner(_ current: AXNodeSnapshot, depth: Int) {
            guard depth <= 5 else { return }
            for child in current.children {
                if let cf = child.frame,
                   cf.width >= 28,
                   cf.width <= containerWidth * 0.68,
                   cf.height >= 16,
                   !collectTextLeaves(in: child).isEmpty {
                    innerFrames.append(cf)
                    continue
                }
                findInner(child, depth: depth + 1)
            }
        }
        findInner(node, depth: 0)

        guard let unionFrame = innerFrames.reduce(nil, { partial, next in
            partial.map { $0.union(next) } ?? next
        }), unionFrame.width <= containerWidth * 0.72 else {
            return outer
        }
        return unionFrame
    }

    private func isSidebarConversationContainer(_ container: AXNodeSnapshot) -> Bool {
        if let id = container.identifier?.lowercased(),
           id.contains("sidebar") || id.contains("chat-list") || id.contains("conversation-list") {
            return true
        }
        for child in container.children.prefix(12) {
            if child.role == "AXRow" || child.role == "AXCell" {
                let desc = [child.descriptionText, child.title, child.value]
                    .compactMap { $0 }
                    .joined(separator: " ")
                    .lowercased()
                if desc.contains("unread") {
                    return true
                }
            }
        }
        return false
    }

    private func flattenMessageLikeChildren(in container: AXNodeSnapshot) -> [AXNodeSnapshot] {
        var items: [AXNodeSnapshot] = []

        func collectBubbles(from node: AXNodeSnapshot, depth: Int) {
            guard depth <= 4 else { return }
            for child in node.children {
                if child.role == "AXRow" || child.role == "AXCell" {
                    if !collectTextLeaves(in: child).isEmpty {
                        items.append(child)
                    }
                    continue
                }
                if child.role == "AXGroup" {
                    // Check if this AXGroup is itself a collection wrapper holding 2+ text-bearing bubble children.
                    let textBearingChildren = child.children.filter { !collectTextLeaves(in: $0).isEmpty }
                    let childLooksLikeBubbleList = textBearingChildren.count >= 2 &&
                        child.children.contains { $0.role == "AXGroup" || $0.role == "AXCell" || $0.role == "AXRow" }
                    let onlyOneChildWrapper = child.children.count == 1 &&
                        (child.children[0].role == "AXGroup" || child.children[0].role == "AXList" || child.children[0].role == "AXTable")
                    if childLooksLikeBubbleList || onlyOneChildWrapper {
                        collectBubbles(from: child, depth: depth + 1)
                        continue
                    }
                    if !collectTextLeaves(in: child).isEmpty {
                        items.append(child)
                    }
                    continue
                }
                collectBubbles(from: child, depth: depth + 1)
            }
        }

        collectBubbles(from: container, depth: 0)
        return items
    }

    private func inferWindowChatTitle(_ window: AXNodeSnapshot) -> String? {
        if let title = window.title?.trimmingCharacters(in: .whitespacesAndNewlines),
           !title.isEmpty,
           title.caseInsensitiveCompare("WhatsApp") != .orderedSame {
            return title
        }

        // Look in toolbar/header groups near the top of the window for a chat header title.
        var topTitles: [String] = []
        func walk(_ node: AXNodeSnapshot, depth: Int) {
            guard depth <= 4 else { return }
            if (node.role == "AXStaticText" || node.role == "AXHeading"),
               let y = node.frame?.minY,
               let winY = window.frame?.minY,
               (y - winY) < 110,
               let text = node.value ?? node.title {
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty && trimmed.caseInsensitiveCompare("WhatsApp") != .orderedSame {
                    topTitles.append(trimmed)
                }
            }
            for child in node.children {
                walk(child, depth: depth + 1)
            }
        }
        walk(window, depth: 0)
        return topTitles.first
    }

    // MARK: - Live AXUIElement Traversal

    private func captureSnapshot(
        element: AXUIElement,
        depth: Int,
        remainingBudget: inout Int,
        maxDepthOverride: Int? = nil
    ) -> AXNodeSnapshot {
        remainingBudget -= 1
        let role = copyStringAttribute(element, kAXRoleAttribute) ?? "AXUnknown"
        let subrole = copyStringAttribute(element, kAXSubroleAttribute)
        let identifier = copyStringAttribute(element, kAXIdentifierAttribute)
        let title = copyStringAttribute(element, kAXTitleAttribute)
        let descriptionText = copyStringAttribute(element, kAXDescriptionAttribute)
        let value = copyValueAsString(element)
        let frame = copyFrame(element)

        var childSnapshots: [AXNodeSnapshot] = []
        let depthCap = maxDepthOverride ?? limits.maxDepth
        if depth < depthCap && remainingBudget > 0 {
            var childrenRef: CFTypeRef?
            var children: [AXUIElement]?
            if AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenRef) == .success,
               let direct = childrenRef as? [AXUIElement],
               !direct.isEmpty {
                children = direct
            } else if AXUIElementCopyAttributeValue(element, "AXChildrenInNavigationOrder" as CFString, &childrenRef) == .success,
                      let navChildren = childrenRef as? [AXUIElement],
                      !navChildren.isEmpty {
                children = navChildren
            }
            if let children {
                childSnapshots.reserveCapacity(min(children.count, remainingBudget))
                for child in children {
                    if remainingBudget <= 0 { break }
                    childSnapshots.append(
                        captureSnapshot(
                            element: child,
                            depth: depth + 1,
                            remainingBudget: &remainingBudget,
                            maxDepthOverride: maxDepthOverride
                        )
                    )
                }
            }
        }

        return AXNodeSnapshot(
            role: role,
            subrole: subrole,
            identifier: identifier,
            title: title,
            value: value,
            descriptionText: descriptionText,
            frame: frame,
            children: childSnapshots
        )
    }

    private func copyStringAttribute(_ element: AXUIElement, _ attribute: String) -> String? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &ref) == .success else {
            return nil
        }
        return ref as? String
    }

    private func copyValueAsString(_ element: AXUIElement) -> String? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &ref) == .success,
              let ref else {
            return nil
        }
        if let str = ref as? String {
            return str
        }
        if let num = ref as? NSNumber {
            return num.stringValue
        }
        return nil
    }

    private func copyFrame(_ element: AXUIElement) -> CGRect? {
        var posRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &posRef) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeRef) == .success,
              let posVal = posRef,
              let sizeVal = sizeRef,
              CFGetTypeID(posVal) == AXValueGetTypeID(),
              CFGetTypeID(sizeVal) == AXValueGetTypeID() else {
            return nil
        }

        var point = CGPoint.zero
        var size = CGSize.zero
        let posAX = unsafeDowncast(posVal, to: AXValue.self)
        let sizeAX = unsafeDowncast(sizeVal, to: AXValue.self)
        guard AXValueGetValue(posAX, .cgPoint, &point),
              AXValueGetValue(sizeAX, .cgSize, &size) else {
            return nil
        }
        return CGRect(origin: point, size: size)
    }

    // MARK: - Snapshot Helpers

    private func collectNodes(
        in node: AXNodeSnapshot,
        matching predicate: (AXNodeSnapshot) -> Bool,
        into output: inout [AXNodeSnapshot]
    ) {
        if predicate(node) {
            output.append(node)
        }
        for child in node.children {
            collectNodes(in: child, matching: predicate, into: &output)
        }
    }

    private func collectTextLeaves(in node: AXNodeSnapshot) -> [String] {
        var output: [String] = []

        func appendUnique(_ raw: String?) {
            guard let raw else { return }
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, !output.contains(trimmed) else { return }
            output.append(trimmed)
        }

        func walk(_ current: AXNodeSnapshot) {
            if current.role == "AXStaticText" ||
               current.role == "AXTextField" ||
               current.role == "AXTextArea" ||
               current.role == "AXHeading" {
                appendUnique(current.value ?? current.title ?? current.descriptionText)
            }
            for child in current.children {
                walk(child)
            }
            if current.role == "AXRow" ||
               current.role == "AXCell" ||
               current.role == "AXGroup" ||
               current.role == "AXButton" {
                appendUnique(current.descriptionText)
                appendUnique(current.title)
                appendUnique(current.value)
            }
        }
        walk(node)

        if output.isEmpty {
            appendUnique(node.descriptionText)
            appendUnique(node.title)
            appendUnique(node.value)
        }

        return output
    }

    private func collectOrderedBannerLeafTexts(in node: AXNodeSnapshot) -> [(role: String, text: String)] {
        var collected: [(y: CGFloat, role: String, text: String)] = []

        func walk(_ current: AXNodeSnapshot, insideButton: Bool) {
            let nowInButton = insideButton || current.role == "AXButton"
            if !nowInButton &&
               (current.role == "AXHeading" || current.role == "AXStaticText" || current.role == "AXTextField") {
                let candidate = current.value ?? current.title ?? current.descriptionText ?? ""
                let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    let y = current.frame?.minY ?? CGFloat(collected.count)
                    if !collected.contains(where: { $0.text == trimmed }) {
                        collected.append((y: y, role: current.role, text: trimmed))
                    }
                }
            }
            for child in current.children {
                walk(child, insideButton: nowInButton)
            }
        }
        walk(node, insideButton: false)

        return collected
            .sorted { $0.y < $1.y }
            .map { ($0.role, $0.text) }
    }

    private func expandNotificationDescriptionIfNeeded(_ raw: String) -> [String] {
        let cleaned = stripDirectionalFormatting(raw)
        if cleaned.lowercased().hasPrefix("whatsapp, ") {
            return cleaned.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        }
        return cleaned.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    private func isPureUnreadBadgeLabel(_ text: String) -> Bool {
        let lower = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let pattern = #"^(\d+\s+)?unread(\s+messages?)?$"#
        return lower.range(of: pattern, options: .regularExpression) != nil
    }

    private func looksLikeTimestamp(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count > 15 { return false }
        let pattern = #"^(\d{1,2}:\d{2}(\s?[APap][Mm])?|Yesterday|Today)$"#
        return trimmed.range(of: pattern, options: .regularExpression) != nil
    }

    /// Captures a strict non-PII structural AX report for WhatsApp, Dock badge, and NotificationCenter.
    public func structuralDiagnostics(whatsappPID: pid_t?, dockPID: pid_t?, notificationCenterPID: pid_t?) -> String {
        var lines: [String] = []
        lines.append("AXIsProcessTrusted=\(AXIsProcessTrusted())")

        if let whatsappPID {
            let waApp = AXUIElementCreateApplication(whatsappPID)
            enableEnhancedAccessibilityIfSupported(on: waApp)
            var attrNames: CFArray?
            AXUIElementCopyAttributeNames(waApp, &attrNames)
            lines.append("WA.pid=\(whatsappPID) attrs=\((attrNames as? [String]) ?? [])")

            for (label, attr) in [
                ("AXWindows", kAXWindowsAttribute),
                ("AXChildren", kAXChildrenAttribute),
                ("AXMainWindow", kAXMainWindowAttribute),
                ("AXFocusedWindow", kAXFocusedWindowAttribute),
            ] {
                var ref: CFTypeRef?
                let err = AXUIElementCopyAttributeValue(waApp, attr as CFString, &ref)
                let count = (ref as? [AXUIElement])?.count ?? (ref != nil ? 1 : 0)
                lines.append("WA.\(label) err=\(err.rawValue) count=\(count)")
            }

            let resolvedWins = collectAccessibleWindows(from: waApp, maxWindows: 2)
            lines.append("WA.resolvedWindows=\(resolvedWins.count)")
            for (i, w) in resolvedWins.enumerated() {
                var minRef: CFTypeRef?
                _ = AXUIElementCopyAttributeValue(w, kAXMinimizedAttribute as CFString, &minRef)
                lines.append("  WA.ResolvedWin[\(i)] minimized=\(String(describing: minRef)):\n\(describeStructure(element: w, maxNodes: 100, maxDepth: 12))")
            }
        } else {
            lines.append("WA.pid=nil")
        }

        if let dockPID {
            let dockEl = AXUIElementCreateApplication(dockPID)
            var listsRef: CFTypeRef?
            let err = AXUIElementCopyAttributeValue(dockEl, kAXChildrenAttribute as CFString, &listsRef)
            var badgeInfo = "not_found"
            if let lists = listsRef as? [AXUIElement] {
                for list in lists {
                    var itemsRef: CFTypeRef?
                    if AXUIElementCopyAttributeValue(list, kAXChildrenAttribute as CFString, &itemsRef) == .success,
                       let items = itemsRef as? [AXUIElement] {
                        for item in items {
                            if let title = copyStringAttribute(item, kAXTitleAttribute),
                               title.localizedCaseInsensitiveContains("WhatsApp") {
                                var statusRef: CFTypeRef?
                                let sErr = AXUIElementCopyAttributeValue(item, "AXStatusLabel" as CFString, &statusRef)
                                badgeInfo = "err=\(sErr.rawValue) val=\(String(describing: statusRef))"
                            }
                        }
                    }
                }
            }
            lines.append("Dock.err=\(err.rawValue) waBadge=\(badgeInfo)")
        }

        if let notificationCenterPID {
            let ncEl = AXUIElementCreateApplication(notificationCenterPID)
            var winRef: CFTypeRef?
            let winErr = AXUIElementCopyAttributeValue(ncEl, kAXWindowsAttribute as CFString, &winRef)
            let wins = (winRef as? [AXUIElement]) ?? []
            var chRef: CFTypeRef?
            let chErr = AXUIElementCopyAttributeValue(ncEl, kAXChildrenAttribute as CFString, &chRef)
            let chs = (chRef as? [AXUIElement]) ?? []
            lines.append("NC.pid=\(notificationCenterPID) winErr=\(winErr.rawValue) winCount=\(wins.count) chErr=\(chErr.rawValue) chCount=\(chs.count)")
            for (i, w) in wins.prefix(2).enumerated() {
                lines.append("  NC.Win[\(i)]: \(describeStructure(element: w, maxNodes: 60, maxDepth: 6))")
            }
        }
        return lines.joined(separator: "\n")
    }

    private func describeStructure(element: AXUIElement, maxNodes: Int, maxDepth: Int) -> String {
        var out: [String] = []
        var rem = maxNodes
        func walk(_ el: AXUIElement, depth: Int) {
            guard depth <= maxDepth, rem > 0 else { return }
            rem -= 1
            let role = copyStringAttribute(el, kAXRoleAttribute) ?? "?"
            let subrole = copyStringAttribute(el, kAXSubroleAttribute)
            let id = copyStringAttribute(el, kAXIdentifierAttribute)
            let hasTitle = (copyStringAttribute(el, kAXTitleAttribute)?.isEmpty == false)
            let desc = copyStringAttribute(el, kAXDescriptionAttribute)
            let hasDesc = (desc?.isEmpty == false)
            let val = copyValueAsString(el)
            let hasVal = (val?.isEmpty == false)
            let unreadFlag = (desc?.lowercased().contains("unread") == true) || (val?.lowercased().contains("unread") == true)
            let frame = copyFrame(el).map { "(\(Int($0.origin.x)),\(Int($0.origin.y)),\(Int($0.width))x\(Int($0.height)))" } ?? ""
            var tag = String(repeating: " ", count: depth) + "\(role)"
            if let subrole { tag += "/\(subrole)" }
            if let id, !id.isEmpty { tag += " id=\(id)" }
            if !frame.isEmpty { tag += " \(frame)" }
            tag += " T=\(hasTitle ? 1 : 0) D=\(hasDesc ? 1 : 0) V=\(hasVal ? 1 : 0)"
            if unreadFlag { tag += " [UNREAD]" }
            out.append(tag)
            var chRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(el, kAXChildrenAttribute as CFString, &chRef) == .success,
               let children = chRef as? [AXUIElement] {
                for c in children {
                    if rem <= 0 { break }
                    walk(c, depth: depth + 1)
                }
            }
        }
        walk(element, depth: 0)
        return out.joined(separator: "\n")
    }
}
