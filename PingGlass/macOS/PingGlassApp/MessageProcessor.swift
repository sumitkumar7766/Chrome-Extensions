import Foundation

/// Direction inferred from Accessibility context and bubble layout geometry.
public enum MessageDirection: String, Sendable, Equatable {
    case incoming
    case outgoing
    case ambiguous
}

/// Raw extraction candidate produced by `AccessibilityExtractor` prior to sanitization and deduplication.
public struct ExtractedCandidate: Sendable, Equatable {
    public let sender: String?
    public let chatName: String?
    public let text: String?
    public let timestamp: String?
    public let avatar: String?
    public let direction: MessageDirection
    public let elementIdentity: String?
    public let occurrenceIndex: Int
    public let baseConfidence: Double
    public let extractionPath: String

    public init(
        sender: String?,
        chatName: String?,
        text: String?,
        timestamp: String?,
        avatar: String? = nil,
        direction: MessageDirection,
        elementIdentity: String?,
        occurrenceIndex: Int = 0,
        baseConfidence: Double,
        extractionPath: String
    ) {
        self.sender = sender
        self.chatName = chatName
        self.text = text
        self.timestamp = timestamp
        self.avatar = avatar
        self.direction = direction
        self.elementIdentity = elementIdentity
        self.occurrenceIndex = occurrenceIndex
        self.baseConfidence = baseConfidence
        self.extractionPath = extractionPath
    }
}

/// Sanitizes Accessibility extraction candidates, filters outgoing/duplicate items, and builds standardized messages.
public final class MessageProcessor: @unchecked Sendable {
    private let fingerprintStore: MessageFingerprintStore

    public init(fingerprintStore: MessageFingerprintStore = MessageFingerprintStore()) {
        self.fingerprintStore = fingerprintStore
    }

    /// Processes a batch of extracted candidates.
    /// When `seedOnly` is true (initial baseline scan), records fingerprints without emitting notifications.
    public func process(
        candidates: [ExtractedCandidate],
        config: HelperConfiguration,
        seedOnly: Bool = false,
        now: Date = Date()
    ) -> [WhatsAppMessage] {
        var accepted: [WhatsAppMessage] = []

        for candidate in candidates {
            var sanitizedSender = sanitizeSingleLine(candidate.sender, maxLength: 120)
            let sanitizedChatName = sanitizeSingleLine(candidate.chatName, maxLength: 120)
            if sanitizedSender?.caseInsensitiveCompare("WhatsApp") == .orderedSame,
               let sanitizedChatName,
               sanitizedChatName.caseInsensitiveCompare("WhatsApp") != .orderedSame {
                sanitizedSender = sanitizedChatName
            }
            let sanitizedText = sanitizeMultilineText(candidate.text, maxLength: config.maxPreviewLength)
            let sanitizedTimestamp = sanitizeSingleLine(candidate.timestamp, maxLength: 40)
            let sanitizedAvatar = sanitizeAvatarDataURI(candidate.avatar)

            // Require at least sender/chat context or message text; never fabricate empty payloads.
            if sanitizedText == nil && sanitizedSender == nil && sanitizedChatName == nil {
                continue
            }

            let effectiveDirection = refineDirection(
                initial: candidate.direction,
                rawText: sanitizedText,
                sender: sanitizedSender
            )

            // Never notify for outgoing messages.
            if effectiveDirection == .outgoing {
                continue
            }

            if effectiveDirection == .ambiguous && config.ambiguousDirectionPolicy == .ignore {
                continue
            }

            let fingerprint = MessageFingerprintStore.computeFingerprint(
                sender: sanitizedSender,
                chatName: sanitizedChatName,
                text: sanitizedText,
                timestamp: sanitizedTimestamp,
                elementIdentity: candidate.elementIdentity,
                occurrenceIndex: candidate.occurrenceIndex
            )
            let contentHash = MessageFingerprintStore.computeContentHash(
                sender: sanitizedSender,
                chatName: sanitizedChatName,
                text: sanitizedText
            )

            if seedOnly {
                fingerprintStore.seed(fingerprint, now: now)
                fingerprintStore.seedCrossSource(contentHash: contentHash, sourcePath: candidate.extractionPath, now: now)
                continue
            }

            guard fingerprintStore.shouldAccept(
                fingerprint,
                contentHash: contentHash,
                sourcePath: candidate.extractionPath,
                now: now
            ) else {
                continue
            }

            let confidence: Double
            if effectiveDirection == .ambiguous {
                confidence = min(candidate.baseConfidence, 0.45)
            } else {
                confidence = candidate.baseConfidence
            }

            let message = WhatsAppMessage(
                id: UUID().uuidString,
                sender: sanitizedSender,
                chatName: sanitizedChatName,
                text: sanitizedText,
                timestamp: sanitizedTimestamp,
                avatar: sanitizedAvatar,
                receivedAt: ISO8601DateFormatter().string(from: now),
                source: "whatsapp-desktop",
                confidence: confidence,
                isTest: false
            )
            accepted.append(message)
        }

        return accepted
    }

    public func resetCache() {
        fingerprintStore.reset()
    }

    /// Refines direction using explicit outgoing prefixes (e.g., sidebar "You: ...").
    func refineDirection(
        initial: MessageDirection,
        rawText: String?,
        sender: String?
    ) -> MessageDirection {
        if initial == .outgoing {
            return .outgoing
        }

        if let sender = sender?.lowercased(), sender == "you" || sender == "me" {
            return .outgoing
        }

        if let text = rawText?.trimmingCharacters(in: .whitespacesAndNewlines) {
            let lower = text.lowercased()
            if lower.hasPrefix("you:") || lower.hasPrefix("you sent ") {
                return .outgoing
            }
        }

        return initial
    }

    func sanitizeSingleLine(_ value: String?, maxLength: Int) -> String? {
        guard let value else { return nil }
        let stripped = stripControlCharacters(value, allowNewlines: false)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !stripped.isEmpty else { return nil }
        if stripped.count <= maxLength {
            return stripped
        }
        return String(stripped.prefix(maxLength))
    }

    func sanitizeMultilineText(_ value: String?, maxLength: Int) -> String? {
        guard let value else { return nil }
        let stripped = stripControlCharacters(value, allowNewlines: true)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !stripped.isEmpty else { return nil }
        if stripped.count <= maxLength {
            return stripped
        }
        let clipped = String(stripped.prefix(max(1, maxLength - 1)))
        return "\(clipped)…"
    }

    /// Only allow small inline `data:image/` payloads; never permit arbitrary external URLs or file paths.
    func sanitizeAvatarDataURI(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        guard value.hasPrefix("data:image/png;base64,") || value.hasPrefix("data:image/jpeg;base64,") else {
            return nil
        }
        guard value.count <= 131_072 else {
            return nil
        }
        return value
    }

    private func stripControlCharacters(_ input: String, allowNewlines: Bool) -> String {
        let directionalFormatting: Set<UInt32> = [
            0x200B, 0x200C, 0x200D, 0x200E, 0x200F,
            0x202A, 0x202B, 0x202C, 0x202D, 0x202E,
            0x2066, 0x2067, 0x2068, 0x2069, 0xFEFF,
        ]
        var result = ""
        result.reserveCapacity(input.count)
        for scalar in input.unicodeScalars {
            if directionalFormatting.contains(scalar.value) {
                continue
            }
            if CharacterSet.controlCharacters.contains(scalar) {
                if allowNewlines && (scalar == "\n" || scalar == "\t") {
                    result.unicodeScalars.append(scalar)
                } else if scalar == "\r" {
                    continue
                } else {
                    result.append(" ")
                }
            } else {
                result.unicodeScalars.append(scalar)
            }
        }
        return result
    }
}
