import Foundation

/// Single entry shown in the floating glass chat popup (in-memory only, never persisted to disk).
public struct ChatBubbleEntry: Identifiable, Equatable, Sendable {
    public let id: String
    public let sender: String?
    public let text: String
    public let timestamp: String?
    public let isOutgoing: Bool
    public let isTest: Bool

    public init(
        id: String,
        sender: String?,
        text: String,
        timestamp: String?,
        isOutgoing: Bool,
        isTest: Bool = false
    ) {
        self.id = id
        self.sender = sender
        self.text = text
        self.timestamp = timestamp
        self.isOutgoing = isOutgoing
        self.isTest = isTest
    }
}

/// Bounded in-memory per-chat buffer for the active PingGlass session.
/// Enables opening a person's recent session messages inside the floating glass chat popup
/// without storing any message history to disk or accessing WhatsApp databases.
public final class SessionChatStore {
    public private(set) var maxChats: Int
    public private(set) var maxMessagesPerChat: Int

    private var chats: [String: [ChatBubbleEntry]] = [:]
    private var chatOrder: [String] = []

    public init(maxChats: Int = 30, maxMessagesPerChat: Int = 40) {
        self.maxChats = max(5, maxChats)
        self.maxMessagesPerChat = max(10, maxMessagesPerChat)
    }

    public static func chatKey(for message: WhatsAppMessage) -> String {
        let raw = message.chatName ?? message.sender ?? message.id
        return raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    public func record(_ message: WhatsAppMessage) {
        guard let text = message.text, !text.isEmpty else { return }
        let key = Self.chatKey(for: message)
        let entry = ChatBubbleEntry(
            id: message.id,
            sender: message.sender,
            text: text,
            timestamp: message.timestamp,
            isOutgoing: false,
            isTest: message.isTest
        )

        var list = chats[key] ?? []
        if !list.contains(where: { $0.id == entry.id }) {
            list.append(entry)
            if list.count > maxMessagesPerChat {
                list.removeFirst(list.count - maxMessagesPerChat)
            }
            chats[key] = list
        }

        if let existingIdx = chatOrder.firstIndex(of: key) {
            chatOrder.remove(at: existingIdx)
        }
        chatOrder.append(key)

        while chatOrder.count > maxChats {
            let evicted = chatOrder.removeFirst()
            chats.removeValue(forKey: evicted)
        }
    }

    public func messages(for message: WhatsAppMessage) -> [ChatBubbleEntry] {
        let key = Self.chatKey(for: message)
        return chats[key] ?? []
    }

    public func clearAll() {
        chats.removeAll(keepingCapacity: false)
        chatOrder.removeAll(keepingCapacity: false)
    }
}
