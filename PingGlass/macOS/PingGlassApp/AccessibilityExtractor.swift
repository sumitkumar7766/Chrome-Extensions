import ApplicationServices
import CoreGraphics
import Foundation

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

        public init(maxDepth: Int = 10, maxNodes: Int = 360) {
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
        var windowsRef: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsRef)
        guard err == .success, let windows = windowsRef as? [AXUIElement], !windows.isEmpty else {
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

        // Inspect at most the top 2 windows (main window + optional detached chat window).
        for window in windows.prefix(2) {
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

    /// Attempts to open/select a specific conversation row in WhatsApp Desktop using public AX actions.
    /// Returns true only if a matching accessible element accepted `AXPress` or `AXSelected`.
    public func focusChat(named targetChatTitle: String, inPID pid: pid_t) -> Bool {
        let normalizedTarget = Self.normalizeChatLabel(targetChatTitle)
        guard !normalizedTarget.isEmpty, AXIsProcessTrusted() else { return false }

        let appElement = AXUIElementCreateApplication(pid)
        var windowsRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsRef) == .success,
              let windows = windowsRef as? [AXUIElement],
              !windows.isEmpty else {
            return false
        }

        var exactMatch: AXUIElement?
        var prefixMatch: AXUIElement?
        var remainingBudget = 450

        func scanLiveNode(_ element: AXUIElement, depth: Int) {
            guard depth <= 8, remainingBudget > 0, exactMatch == nil else { return }
            remainingBudget -= 1

            let role = copyStringAttribute(element, kAXRoleAttribute) ?? ""
            if role == "AXRow" || role == "AXCell" || role == "AXGroup" {
                let candidateText = [
                    copyStringAttribute(element, kAXTitleAttribute),
                    copyStringAttribute(element, kAXDescriptionAttribute),
                    copyValueAsString(element),
                ]
                .compactMap { $0 }
                .joined(separator: " ")

                let rowTexts = collectLiveTextLeaves(element: element, maxSubnodes: 12) + [candidateText]
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

        for window in windows.prefix(2) {
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
        var windowsRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsRef) == .success,
              let windows = windowsRef as? [AXUIElement],
              !windows.isEmpty else {
            return []
        }

        for window in windows.prefix(2) {
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
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .lowercased()
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
            node.role == "AXRow" || node.role == "AXCell" ||
            (node.role == "AXGroup" && (node.identifier?.localizedCaseInsensitiveContains("chat") == true ||
                                        node.identifier?.localizedCaseInsensitiveContains("conversation") == true))
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

        let sender = nonBadgeTexts.first
        let preview = nonBadgeTexts.count > 1 ? nonBadgeTexts.dropFirst().joined(separator: " ") : nil
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
        if let containerFrame,
           containerFrame.width > 120,
           let bubbleFrame = bubble.frame,
           bubbleFrame.width > 0 {
            let relativeCenterX = (bubbleFrame.midX - containerFrame.minX) / containerFrame.width
            if relativeCenterX >= 0.56 {
                return .outgoing
            }
            if relativeCenterX <= 0.44 {
                return .incoming
            }
        }

        return .ambiguous
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
        for child in container.children {
            if child.role == "AXGroup" || child.role == "AXRow" || child.role == "AXCell" {
                let texts = collectTextLeaves(in: child)
                if !texts.isEmpty {
                    items.append(child)
                    continue
                }
            }
            for grandChild in child.children {
                if !collectTextLeaves(in: grandChild).isEmpty {
                    items.append(grandChild)
                }
            }
        }
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
        remainingBudget: inout Int
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
        if depth < limits.maxDepth && remainingBudget > 0 {
            var childrenRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenRef) == .success,
               let children = childrenRef as? [AXUIElement] {
                childSnapshots.reserveCapacity(min(children.count, remainingBudget))
                for child in children {
                    if remainingBudget <= 0 { break }
                    childSnapshots.append(
                        captureSnapshot(element: child, depth: depth + 1, remainingBudget: &remainingBudget)
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

        func walk(_ current: AXNodeSnapshot) {
            if current.role == "AXStaticText" || current.role == "AXTextField" || current.role == "AXTextArea" {
                if let candidate = current.value ?? current.title ?? current.descriptionText {
                    let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty {
                        output.append(trimmed)
                    }
                }
            }
            for child in current.children {
                walk(child)
            }
        }
        walk(node)

        if output.isEmpty, let fallback = node.descriptionText ?? node.title ?? node.value {
            let trimmed = fallback.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                output.append(trimmed)
            }
        }

        return output
    }

    private func looksLikeTimestamp(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count > 15 { return false }
        let pattern = #"^(\d{1,2}:\d{2}(\s?[APap][Mm])?|Yesterday|Today)$"#
        return trimmed.range(of: pattern, options: .regularExpression) != nil
    }
}
