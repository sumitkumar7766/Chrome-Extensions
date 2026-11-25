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
    /// Short-TTL cross-source content map (`contentHash -> (sourcePath, expiry)`) so simultaneous banner + window observations deduplicate cleanly.
    private var crossSourceEntries: [String: (sourcePath: String, expiry: Date)] = [:]

    public init(maxEntries: Int = 2000, ttlSeconds: TimeInterval = 86_400) {
        self.maxEntries = max(50, maxEntries)
        self.ttlSeconds = max(15, ttlSeconds)
    }

    public static func computeContentHash(sender: String?, chatName: String?, text: String?) -> String {
        let contact = normalize(chatName ?? sender).lowercased()
        let body = normalize(text)
        let joined = "\(contact)\u{001F}\(body)"
        let digest = SHA256.hash(data: Data(joined.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
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
    public func shouldAccept(
        _ fingerprint: String,
        contentHash: String? = nil,
        sourcePath: String? = nil,
        now: Date = Date()
    ) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        pruneExpiredLocked(now: now)

        if let expiry = entries[fingerprint], expiry > now {
            return false
        }

        if let contentHash, let sourcePath,
           let existing = crossSourceEntries[contentHash],
           existing.expiry > now,
           existing.sourcePath != sourcePath {
            insertOrRefreshLocked(fingerprint, now: now)
            return false
        }

        insertOrRefreshLocked(fingerprint, now: now)
        if let contentHash, let sourcePath {
            crossSourceEntries[contentHash] = (sourcePath, now.addingTimeInterval(20))
        }
        return true
    }

    public func seedCrossSource(contentHash: String, sourcePath: String, now: Date = Date()) {
        lock.lock()
        defer { lock.unlock() }
        pruneExpiredLocked(now: now)
        crossSourceEntries[contentHash] = (sourcePath, now.addingTimeInterval(20))
    }

    /// Clears all in-memory fingerprints immediately.
    public func reset() {
        lock.lock()
        defer { lock.unlock() }
        entries.removeAll(keepingCapacity: false)
        insertionOrder.removeAll(keepingCapacity: false)
        crossSourceEntries.removeAll(keepingCapacity: false)
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
        if !crossSourceEntries.isEmpty {
            crossSourceEntries = crossSourceEntries.filter { $0.value.expiry > now }
        }
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
