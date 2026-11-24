import CryptoKit
import Foundation

/// Thread-safe, memory-only, bounded TTL deduplication cache.
/// Prevents repeated notifications from Accessibility UI re-renders while allowing genuinely new messages with identical text.
public final class MessageFingerprintStore: @unchecked Sendable {
    private let lock = NSLock()
    private let maxEntries: Int
    private let ttlSeconds: TimeInterval

    /// Maps fingerprint hash -> expiration timestamp.
    private var entries: [String: Date] = [:]
    /// Insertion order queue for deterministic bounded eviction.
    private var insertionOrder: [String] = []

    public init(maxEntries: Int = 500, ttlSeconds: TimeInterval = 300) {
        self.maxEntries = max(50, maxEntries)
        self.ttlSeconds = max(15, ttlSeconds)
    }

    /// Computes a deterministic SHA-256 fingerprint from available message metadata.
    /// Never persists raw message text.
    public static func computeFingerprint(
        sender: String?,
        chatName: String?,
        text: String?,
        timestamp: String?,
        elementIdentity: String?,
        occurrenceIndex: Int = 0
    ) -> String {
        let components = [
            normalize(sender),
            normalize(chatName),
            normalize(text),
            normalize(timestamp),
            normalize(elementIdentity),
            String(occurrenceIndex),
        ]
        let joined = components.joined(separator: "\u{001F}")
        let digest = SHA256.hash(data: Data(joined.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// Seeds a fingerprint into the cache (e.g., initial window baseline) without triggering a notification.
    public func seed(_ fingerprint: String, now: Date = Date()) {
        lock.lock()
        defer { lock.unlock() }
        pruneExpiredLocked(now: now)
        insertOrRefreshLocked(fingerprint, now: now)
    }

    /// Returns true if the fingerprint is new (not seen within TTL) and records it; false if duplicate.
    public func shouldAccept(_ fingerprint: String, now: Date = Date()) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        pruneExpiredLocked(now: now)

        if let expiry = entries[fingerprint], expiry > now {
            return false
        }

        insertOrRefreshLocked(fingerprint, now: now)
        return true
    }

    /// Clears all in-memory fingerprints immediately.
    public func reset() {
        lock.lock()
        defer { lock.unlock() }
        entries.removeAll(keepingCapacity: false)
        insertionOrder.removeAll(keepingCapacity: false)
    }

    public var count: Int {
        lock.lock()
        defer { lock.unlock() }
        pruneExpiredLocked(now: Date())
        return entries.count
    }

    private static func normalize(_ value: String?) -> String {
        guard let value else { return "" }
        return value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
    }

    private func insertOrRefreshLocked(_ fingerprint: String, now: Date) {
        let expiry = now.addingTimeInterval(ttlSeconds)
        if entries[fingerprint] == nil {
            insertionOrder.append(fingerprint)
        }
        entries[fingerprint] = expiry

        while entries.count > maxEntries, !insertionOrder.isEmpty {
            let oldest = insertionOrder.removeFirst()
            entries.removeValue(forKey: oldest)
        }
    }

    private func pruneExpiredLocked(now: Date) {
        guard !entries.isEmpty else { return }
        var kept: [String] = []
        kept.reserveCapacity(insertionOrder.count)

        for key in insertionOrder {
            if let expiry = entries[key], expiry > now {
                kept.append(key)
            } else {
                entries.removeValue(forKey: key)
            }
        }
        insertionOrder = kept
    }
}
