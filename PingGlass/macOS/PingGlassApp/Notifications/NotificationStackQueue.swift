import Foundation

/// Outcome of enqueueing a notification into the bounded stack queue.
public enum QueueEnqueueOutcome: Equatable, Sendable {
    case displayNow
    case queued
    case ignoredDuplicate
}

/// Bounded FIFO queue and visible-slot tracker for global floating notification cards.
/// Never retains message history after dismissal.
public final class NotificationStackQueue {
    public private(set) var visibleMessages: [WhatsAppMessage] = []
    public private(set) var pendingMessages: [WhatsAppMessage] = []

    public var maxVisible: Int {
        didSet {
            maxVisible = max(1, min(6, maxVisible))
        }
    }

    public let maxPendingCapacity: Int

    public init(maxVisible: Int = 3, maxPendingCapacity: Int = 50) {
        self.maxVisible = max(1, min(6, maxVisible))
        self.maxPendingCapacity = max(5, maxPendingCapacity)
    }

    /// Enqueues a notification. New visible cards are inserted at index `0` (newest at anchor edge).
    public func enqueue(_ message: WhatsAppMessage) -> QueueEnqueueOutcome {
        if visibleMessages.contains(where: { $0.id == message.id }) ||
            pendingMessages.contains(where: { $0.id == message.id }) {
            return .ignoredDuplicate
        }

        if visibleMessages.count < maxVisible {
            visibleMessages.insert(message, at: 0)
            return .displayNow
        }

        if pendingMessages.count >= maxPendingCapacity {
            pendingMessages.removeFirst()
        }
        pendingMessages.append(message)
        return .queued
    }

    /// Removes a notification by ID and promotes the oldest pending message if a visible slot opened.
    @discardableResult
    public func remove(id: String) -> WhatsAppMessage? {
        if let visibleIdx = visibleMessages.firstIndex(where: { $0.id == id }) {
            visibleMessages.remove(at: visibleIdx)
            return promoteNextIfAvailable()
        }

        if let pendingIdx = pendingMessages.firstIndex(where: { $0.id == id }) {
            pendingMessages.remove(at: pendingIdx)
        }
        return nil
    }

    /// Promotes waiting items if `maxVisible` increased or slots became free.
    public func promoteAvailableSlots() -> [WhatsAppMessage] {
        var promoted: [WhatsAppMessage] = []
        while let next = promoteNextIfAvailable() {
            promoted.append(next)
        }
        return promoted
    }

    public func clearAll() {
        visibleMessages.removeAll(keepingCapacity: false)
        pendingMessages.removeAll(keepingCapacity: false)
    }

    private func promoteNextIfAvailable() -> WhatsAppMessage? {
        guard visibleMessages.count < maxVisible, !pendingMessages.isEmpty else {
            return nil
        }
        let next = pendingMessages.removeFirst()
        visibleMessages.insert(next, at: 0)
        return next
    }
}
