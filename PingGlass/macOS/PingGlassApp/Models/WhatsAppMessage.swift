import Foundation

/// Standardized message payload used by both the native macOS floating notification engine
/// and the optional Chrome Native Messaging bridge.
/// All content fields remain optional so missing Accessibility attributes are never fabricated.
public struct WhatsAppMessage: Codable, Sendable, Equatable {
    public let id: String
    public let sender: String?
    public let chatName: String?
    public let text: String?
    public let timestamp: String?
    public let avatar: String?
    public let receivedAt: String
    public let source: String
    public let confidence: Double
    public let isTest: Bool
    public let isOutgoing: Bool

    public init(
        id: String = UUID().uuidString,
        sender: String? = nil,
        chatName: String? = nil,
        text: String? = nil,
        timestamp: String? = nil,
        avatar: String? = nil,
        receivedAt: String = ISO8601DateFormatter().string(from: Date()),
        source: String = "whatsapp-desktop",
        confidence: Double = 0.0,
        isTest: Bool = false,
        isOutgoing: Bool = false
    ) {
        self.id = id
        self.sender = sender
        self.chatName = chatName
        self.text = text
        self.timestamp = timestamp
        self.avatar = avatar
        self.receivedAt = receivedAt
        self.source = source
        self.confidence = min(1.0, max(0.0, confidence))
        self.isTest = isTest
        self.isOutgoing = isOutgoing
    }

    private enum CodingKeys: String, CodingKey {
        case id, sender, chatName, text, timestamp, avatar, receivedAt, source, confidence, isTest, isOutgoing
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try c.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString,
            sender: try c.decodeIfPresent(String.self, forKey: .sender),
            chatName: try c.decodeIfPresent(String.self, forKey: .chatName),
            text: try c.decodeIfPresent(String.self, forKey: .text),
            timestamp: try c.decodeIfPresent(String.self, forKey: .timestamp),
            avatar: try c.decodeIfPresent(String.self, forKey: .avatar),
            receivedAt: try c.decodeIfPresent(String.self, forKey: .receivedAt) ?? ISO8601DateFormatter().string(from: Date()),
            source: try c.decodeIfPresent(String.self, forKey: .source) ?? "whatsapp-desktop",
            confidence: try c.decodeIfPresent(Double.self, forKey: .confidence) ?? 0.0,
            isTest: try c.decodeIfPresent(Bool.self, forKey: .isTest) ?? false,
            isOutgoing: try c.decodeIfPresent(Bool.self, forKey: .isOutgoing) ?? false
        )
    }
}

/// High-level monitoring lifecycle states surfaced to both the SwiftUI menu bar and Chrome popup.
public enum MonitoringLifecycleState: String, Codable, Sendable {
    case whatsappNotRunning = "whatsapp_not_running"
    case whatsappDetected = "whatsapp_detected"
    case accessibilityRequired = "accessibility_required"
    case monitoringActive = "monitoring_active"
    case monitoringLimited = "monitoring_limited"
    case error = "error"

    public var displayTitle: String {
        switch self {
        case .whatsappNotRunning:
            return "WhatsApp Not Running"
        case .whatsappDetected:
            return "WhatsApp Detected"
        case .accessibilityRequired:
            return "Accessibility Permission Required"
        case .monitoringActive:
            return "Monitoring Active"
        case .monitoringLimited:
            return "Monitoring Limited"
        case .error:
            return "Error"
        }
    }
}

/// Safe fallback behavior when incoming vs. outgoing message direction cannot be verified via AX.
public enum AmbiguousDirectionPolicy: String, Codable, CaseIterable, Sendable {
    case ignore = "ignore"
    case forwardLowConfidence = "forward_low_confidence"

    public var title: String {
        switch self {
        case .ignore:
            return "Ignore uncertain messages (Recommended)"
        case .forwardLowConfidence:
            return "Forward with low confidence"
        }
    }

    public var description: String {
        switch self {
        case .ignore:
            return "Only notifies when layout or Accessibility labels indicate an incoming message. Prevents false notifications for your own replies."
        case .forwardLowConfidence:
            return "Forwards messages when direction cannot be confirmed via Accessibility attributes. May occasionally show an outgoing reply if WhatsApp hides alignment."
        }
    }
}

/// Screen placement options for global floating desktop notifications.
public enum NotificationPosition: String, Codable, CaseIterable, Sendable {
    case bottomRight = "bottom_right"
    case centerRight = "center_right"
    case topRight = "top_right"
    case bottomLeft = "bottom_left"
    case topLeft = "top_left"

    public var displayName: String {
        switch self {
        case .bottomRight: return "Bottom Right"
        case .centerRight: return "Center Right"
        case .topRight: return "Top Right"
        case .bottomLeft: return "Bottom Left"
        case .topLeft: return "Top Left"
        }
    }

    public var isRightAligned: Bool {
        switch self {
        case .bottomRight, .centerRight, .topRight:
            return true
        case .bottomLeft, .topLeft:
            return false
        }
    }

    public var growsUpward: Bool {
        switch self {
        case .bottomRight, .bottomLeft:
            return true
        case .centerRight, .topRight, .topLeft:
            return false
        }
    }
}

/// Display selection policy on single or multi-monitor Macs.
public enum PreferredDisplayMode: String, Codable, CaseIterable, Sendable {
    case activeDisplay = "active_display"
    case primaryDisplay = "primary_display"
    case secondaryDisplay = "secondary_display"

    public var displayName: String {
        switch self {
        case .activeDisplay: return "Active Display (Follows Cursor)"
        case .primaryDisplay: return "Primary Display"
        case .secondaryDisplay: return "Secondary Display"
        }
    }
}

/// Glass card appearance style.
public enum GlassAppearanceMode: String, Codable, CaseIterable, Sendable {
    case dark = "dark"
    case light = "light"

    public var displayName: String {
        switch self {
        case .dark: return "Dark Glass"
        case .light: return "Light Glass"
        }
    }
}

/// Behavior when clicking the body of a floating glass notification card.
public enum NotificationClickAction: String, Codable, CaseIterable, Sendable {
    case openGlassChatPopup = "open_glass_chat_popup"
    case openWhatsAppDirectly = "open_whatsapp_directly"

    public var displayName: String {
        switch self {
        case .openGlassChatPopup:
            return "Open Floating Glass Chat Popup"
        case .openWhatsAppDirectly:
            return "Open Chat in WhatsApp Desktop"
        }
    }
}

/// Supported auto-dismiss durations in seconds (`0` = Never auto-dismiss).
public enum NotificationDurationOption: Int, Codable, CaseIterable, Sendable {
    case threeSeconds = 3
    case fiveSeconds = 5
    case sixSeconds = 6
    case eightSeconds = 8
    case tenSeconds = 10
    case never = 0

    public var displayName: String {
        switch self {
        case .never: return "Until closed (Never)"
        default: return "\(rawValue) seconds"
        }
    }
}

/// Helper and global notification configuration persisted locally in UserDefaults.
/// Custom decoding preserves existing settings when upgrading from earlier versions.
public struct HelperConfiguration: Codable, Sendable, Equatable {
    // Monitoring & Extraction
    public var monitoringEnabled: Bool
    public var fallbackPollingIntervalSeconds: Double
    public var ambiguousDirectionPolicy: AmbiguousDirectionPolicy
    public var maxPreviewLength: Int

    // Global Desktop Floating Notifications
    public var globalNotificationsEnabled: Bool
    public var chromeForwardingEnabled: Bool
    public var animationEnabled: Bool
    public var nativeGlassBlurEnabled: Bool
    public var notificationDurationSeconds: Int
    public var maxVisibleNotifications: Int
    public var notificationPosition: NotificationPosition
    public var edgeMargin: Double
    public var preferredDisplayMode: PreferredDisplayMode
    public var appearanceMode: GlassAppearanceMode
    public var notificationClickAction: NotificationClickAction

    // Card Content & Audio
    public var showAvatar: Bool
    public var showSender: Bool
    public var showChatName: Bool
    public var showTimestamp: Bool
    public var showPreview: Bool
    public var showCopyButton: Bool
    public var soundEnabled: Bool

    // Pause Mode
    public var pausedUntil: Date?
    public var pausedIndefinitely: Bool

    public init(
        monitoringEnabled: Bool = false,
        fallbackPollingIntervalSeconds: Double = 3.0,
        ambiguousDirectionPolicy: AmbiguousDirectionPolicy = .ignore,
        maxPreviewLength: Int = 280,
        globalNotificationsEnabled: Bool = true,
        chromeForwardingEnabled: Bool = true,
        animationEnabled: Bool = true,
        nativeGlassBlurEnabled: Bool = true,
        notificationDurationSeconds: Int = 0,
        maxVisibleNotifications: Int = 3,
        notificationPosition: NotificationPosition = .bottomRight,
        edgeMargin: Double = 28.0,
        preferredDisplayMode: PreferredDisplayMode = .activeDisplay,
        appearanceMode: GlassAppearanceMode = .dark,
        notificationClickAction: NotificationClickAction = .openGlassChatPopup,
        showAvatar: Bool = true,
        showSender: Bool = true,
        showChatName: Bool = true,
        showTimestamp: Bool = true,
        showPreview: Bool = true,
        showCopyButton: Bool = true,
        soundEnabled: Bool = false,
        pausedUntil: Date? = nil,
        pausedIndefinitely: Bool = false
    ) {
        self.monitoringEnabled = monitoringEnabled
        self.fallbackPollingIntervalSeconds = max(1.5, min(15.0, fallbackPollingIntervalSeconds))
        self.ambiguousDirectionPolicy = ambiguousDirectionPolicy
        self.maxPreviewLength = max(80, min(1000, maxPreviewLength))
        self.globalNotificationsEnabled = globalNotificationsEnabled
        self.chromeForwardingEnabled = chromeForwardingEnabled
        self.animationEnabled = animationEnabled
        self.nativeGlassBlurEnabled = nativeGlassBlurEnabled
        self.notificationDurationSeconds = max(0, min(60, notificationDurationSeconds))
        self.maxVisibleNotifications = max(1, min(6, maxVisibleNotifications))
        self.notificationPosition = notificationPosition
        self.edgeMargin = max(12.0, min(64.0, edgeMargin))
        self.preferredDisplayMode = preferredDisplayMode
        self.appearanceMode = appearanceMode
        self.notificationClickAction = notificationClickAction
        self.showAvatar = showAvatar
        self.showSender = showSender
        self.showChatName = showChatName
        self.showTimestamp = showTimestamp
        self.showPreview = showPreview
        self.showCopyButton = showCopyButton
        self.soundEnabled = soundEnabled
        self.pausedUntil = pausedUntil
        self.pausedIndefinitely = pausedIndefinitely
    }

    public func isNotificationsPaused(at now: Date = Date()) -> Bool {
        if pausedIndefinitely {
            return true
        }
        if let pausedUntil {
            return pausedUntil > now
        }
        return false
    }

    private enum CodingKeys: String, CodingKey {
        case monitoringEnabled
        case fallbackPollingIntervalSeconds
        case ambiguousDirectionPolicy
        case maxPreviewLength
        case globalNotificationsEnabled
        case chromeForwardingEnabled
        case animationEnabled
        case nativeGlassBlurEnabled
        case notificationDurationSeconds
        case maxVisibleNotifications
        case notificationPosition
        case edgeMargin
        case preferredDisplayMode
        case appearanceMode
        case notificationClickAction
        case showAvatar
        case showSender
        case showChatName
        case showTimestamp
        case showPreview
        case showCopyButton
        case soundEnabled
        case pausedUntil
        case pausedIndefinitely
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            monitoringEnabled: try c.decodeIfPresent(Bool.self, forKey: .monitoringEnabled) ?? false,
            fallbackPollingIntervalSeconds: try c.decodeIfPresent(Double.self, forKey: .fallbackPollingIntervalSeconds) ?? 3.0,
            ambiguousDirectionPolicy: try c.decodeIfPresent(AmbiguousDirectionPolicy.self, forKey: .ambiguousDirectionPolicy) ?? .ignore,
            maxPreviewLength: try c.decodeIfPresent(Int.self, forKey: .maxPreviewLength) ?? 280,
            globalNotificationsEnabled: try c.decodeIfPresent(Bool.self, forKey: .globalNotificationsEnabled) ?? true,
            chromeForwardingEnabled: try c.decodeIfPresent(Bool.self, forKey: .chromeForwardingEnabled) ?? true,
            animationEnabled: try c.decodeIfPresent(Bool.self, forKey: .animationEnabled) ?? true,
            nativeGlassBlurEnabled: try c.decodeIfPresent(Bool.self, forKey: .nativeGlassBlurEnabled) ?? true,
            notificationDurationSeconds: try c.decodeIfPresent(Int.self, forKey: .notificationDurationSeconds) ?? 0,
            maxVisibleNotifications: try c.decodeIfPresent(Int.self, forKey: .maxVisibleNotifications) ?? 3,
            notificationPosition: try c.decodeIfPresent(NotificationPosition.self, forKey: .notificationPosition) ?? .bottomRight,
            edgeMargin: try c.decodeIfPresent(Double.self, forKey: .edgeMargin) ?? 28.0,
            preferredDisplayMode: try c.decodeIfPresent(PreferredDisplayMode.self, forKey: .preferredDisplayMode) ?? .activeDisplay,
            appearanceMode: try c.decodeIfPresent(GlassAppearanceMode.self, forKey: .appearanceMode) ?? .dark,
            notificationClickAction: try c.decodeIfPresent(NotificationClickAction.self, forKey: .notificationClickAction) ?? .openGlassChatPopup,
            showAvatar: try c.decodeIfPresent(Bool.self, forKey: .showAvatar) ?? true,
            showSender: try c.decodeIfPresent(Bool.self, forKey: .showSender) ?? true,
            showChatName: try c.decodeIfPresent(Bool.self, forKey: .showChatName) ?? true,
            showTimestamp: try c.decodeIfPresent(Bool.self, forKey: .showTimestamp) ?? true,
            showPreview: try c.decodeIfPresent(Bool.self, forKey: .showPreview) ?? true,
            showCopyButton: try c.decodeIfPresent(Bool.self, forKey: .showCopyButton) ?? true,
            soundEnabled: try c.decodeIfPresent(Bool.self, forKey: .soundEnabled) ?? false,
            pausedUntil: try c.decodeIfPresent(Date.self, forKey: .pausedUntil),
            pausedIndefinitely: try c.decodeIfPresent(Bool.self, forKey: .pausedIndefinitely) ?? false
        )
    }
}

/// Snapshot of macOS helper health sent in `monitoring_status` and `connection_status` envelopes.
public struct HelperStatusSnapshot: Codable, Sendable, Equatable {
    public let monitoringState: MonitoringLifecycleState
    public let monitoringEnabled: Bool
    public let whatsappRunning: Bool
    public let whatsappActive: Bool
    public let whatsappBundleId: String?
    public let whatsappVersion: String?
    public let accessibilityGranted: Bool
    public let observerAttached: Bool
    public let fallbackPollingActive: Bool
    public let extractionMode: String
    public let statusDetail: String
    public let sessionMessagesForwarded: Int
    public let globalNotificationsEnabled: Bool
    public let notificationsPaused: Bool
    public let activeNotificationCount: Int
    public let pauseSummary: String?
    public let config: BridgeSettingsPayload?
    public let updatedAt: String

    public init(
        monitoringState: MonitoringLifecycleState,
        monitoringEnabled: Bool,
        whatsappRunning: Bool,
        whatsappActive: Bool,
        whatsappBundleId: String?,
        whatsappVersion: String?,
        accessibilityGranted: Bool,
        observerAttached: Bool,
        fallbackPollingActive: Bool,
        extractionMode: String,
        statusDetail: String,
        sessionMessagesForwarded: Int,
        globalNotificationsEnabled: Bool = true,
        notificationsPaused: Bool = false,
        activeNotificationCount: Int = 0,
        pauseSummary: String? = nil,
        config: BridgeSettingsPayload? = nil,
        updatedAt: String = ISO8601DateFormatter().string(from: Date())
    ) {
        self.monitoringState = monitoringState
        self.monitoringEnabled = monitoringEnabled
        self.whatsappRunning = whatsappRunning
        self.whatsappActive = whatsappActive
        self.whatsappBundleId = whatsappBundleId
        self.whatsappVersion = whatsappVersion
        self.accessibilityGranted = accessibilityGranted
        self.observerAttached = observerAttached
        self.fallbackPollingActive = fallbackPollingActive
        self.extractionMode = extractionMode
        self.statusDetail = statusDetail
        self.sessionMessagesForwarded = sessionMessagesForwarded
        self.globalNotificationsEnabled = globalNotificationsEnabled
        self.notificationsPaused = notificationsPaused
        self.activeNotificationCount = activeNotificationCount
        self.pauseSummary = pauseSummary
        self.config = config
        self.updatedAt = updatedAt
    }

    private enum CodingKeys: String, CodingKey {
        case monitoringState, monitoringEnabled, whatsappRunning, whatsappActive
        case whatsappBundleId, whatsappVersion, accessibilityGranted, observerAttached
        case fallbackPollingActive, extractionMode, statusDetail, sessionMessagesForwarded
        case globalNotificationsEnabled, notificationsPaused, activeNotificationCount
        case pauseSummary, config, updatedAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            monitoringState: try c.decode(MonitoringLifecycleState.self, forKey: .monitoringState),
            monitoringEnabled: try c.decode(Bool.self, forKey: .monitoringEnabled),
            whatsappRunning: try c.decode(Bool.self, forKey: .whatsappRunning),
            whatsappActive: try c.decode(Bool.self, forKey: .whatsappActive),
            whatsappBundleId: try c.decodeIfPresent(String.self, forKey: .whatsappBundleId),
            whatsappVersion: try c.decodeIfPresent(String.self, forKey: .whatsappVersion),
            accessibilityGranted: try c.decode(Bool.self, forKey: .accessibilityGranted),
            observerAttached: try c.decode(Bool.self, forKey: .observerAttached),
            fallbackPollingActive: try c.decode(Bool.self, forKey: .fallbackPollingActive),
            extractionMode: try c.decode(String.self, forKey: .extractionMode),
            statusDetail: try c.decode(String.self, forKey: .statusDetail),
            sessionMessagesForwarded: try c.decode(Int.self, forKey: .sessionMessagesForwarded),
            globalNotificationsEnabled: try c.decodeIfPresent(Bool.self, forKey: .globalNotificationsEnabled) ?? true,
            notificationsPaused: try c.decodeIfPresent(Bool.self, forKey: .notificationsPaused) ?? false,
            activeNotificationCount: try c.decodeIfPresent(Int.self, forKey: .activeNotificationCount) ?? 0,
            pauseSummary: try c.decodeIfPresent(String.self, forKey: .pauseSummary),
            config: try c.decodeIfPresent(BridgeSettingsPayload.self, forKey: .config),
            updatedAt: try c.decodeIfPresent(String.self, forKey: .updatedAt) ?? ISO8601DateFormatter().string(from: Date())
        )
    }
}

/// Wire envelope shared between Swift helper, Python Native Messaging host, and Chrome Extension.
public struct BridgeEnvelope: Codable, Sendable {
    public let type: String
    public let message: WhatsAppMessage?
    public let status: HelperStatusSnapshot?
    public let settings: BridgeSettingsPayload?
    public let helperConnected: Bool?
    public let error: String?
    public let diagnostics: String?
    public let timestamp: String

    public init(
        type: String,
        message: WhatsAppMessage? = nil,
        status: HelperStatusSnapshot? = nil,
        settings: BridgeSettingsPayload? = nil,
        helperConnected: Bool? = nil,
        error: String? = nil,
        diagnostics: String? = nil,
        timestamp: String = ISO8601DateFormatter().string(from: Date())
    ) {
        self.type = type
        self.message = message
        self.status = status
        self.settings = settings
        self.helperConnected = helperConnected
        self.error = error
        self.diagnostics = diagnostics
        self.timestamp = timestamp
    }

    private enum CodingKeys: String, CodingKey {
        case type, message, status, settings, helperConnected, error, diagnostics, timestamp
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            type: try c.decode(String.self, forKey: .type),
            message: try c.decodeIfPresent(WhatsAppMessage.self, forKey: .message),
            status: try c.decodeIfPresent(HelperStatusSnapshot.self, forKey: .status),
            settings: try c.decodeIfPresent(BridgeSettingsPayload.self, forKey: .settings),
            helperConnected: try c.decodeIfPresent(Bool.self, forKey: .helperConnected),
            error: try c.decodeIfPresent(String.self, forKey: .error),
            diagnostics: try c.decodeIfPresent(String.self, forKey: .diagnostics),
            timestamp: try c.decodeIfPresent(String.self, forKey: .timestamp) ?? ISO8601DateFormatter().string(from: Date())
        )
    }
}

/// Partial settings payload shared between Chrome extension and Swift helper (backward-compatible).
public struct BridgeSettingsPayload: Codable, Sendable, Equatable {
    public let monitoringEnabled: Bool?
    public let ambiguousDirectionPolicy: AmbiguousDirectionPolicy?
    public let maxPreviewLength: Int?
    public let fallbackPollingIntervalSeconds: Double?
    public let globalNotificationsEnabled: Bool?
    public let chromeForwardingEnabled: Bool?
    public let notificationsPaused: Bool?
    public let pauseMinutes: Int?
    public let pausedIndefinitely: Bool?
    public let animationEnabled: Bool?
    public let soundEnabled: Bool?
    public let autoDismissSeconds: Int?
    public let maxVisibleNotifications: Int?
    public let notificationPosition: NotificationPosition?
    public let edgeMargin: Double?
    public let appearanceMode: GlassAppearanceMode?
    public let notificationClickAction: NotificationClickAction?
    public let showAvatar: Bool?
    public let showSender: Bool?
    public let showChatName: Bool?
    public let showTimestamp: Bool?
    public let showPreview: Bool?
    public let showCopyButton: Bool?

    public init(
        monitoringEnabled: Bool? = nil,
        ambiguousDirectionPolicy: AmbiguousDirectionPolicy? = nil,
        maxPreviewLength: Int? = nil,
        fallbackPollingIntervalSeconds: Double? = nil,
        globalNotificationsEnabled: Bool? = nil,
        chromeForwardingEnabled: Bool? = nil,
        notificationsPaused: Bool? = nil,
        pauseMinutes: Int? = nil,
        pausedIndefinitely: Bool? = nil,
        animationEnabled: Bool? = nil,
        soundEnabled: Bool? = nil,
        autoDismissSeconds: Int? = nil,
        maxVisibleNotifications: Int? = nil,
        notificationPosition: NotificationPosition? = nil,
        edgeMargin: Double? = nil,
        appearanceMode: GlassAppearanceMode? = nil,
        notificationClickAction: NotificationClickAction? = nil,
        showAvatar: Bool? = nil,
        showSender: Bool? = nil,
        showChatName: Bool? = nil,
        showTimestamp: Bool? = nil,
        showPreview: Bool? = nil,
        showCopyButton: Bool? = nil
    ) {
        self.monitoringEnabled = monitoringEnabled
        self.ambiguousDirectionPolicy = ambiguousDirectionPolicy
        self.maxPreviewLength = maxPreviewLength
        self.fallbackPollingIntervalSeconds = fallbackPollingIntervalSeconds
        self.globalNotificationsEnabled = globalNotificationsEnabled
        self.chromeForwardingEnabled = chromeForwardingEnabled
        self.notificationsPaused = notificationsPaused
        self.pauseMinutes = pauseMinutes
        self.pausedIndefinitely = pausedIndefinitely
        self.animationEnabled = animationEnabled
        self.soundEnabled = soundEnabled
        self.autoDismissSeconds = autoDismissSeconds
        self.maxVisibleNotifications = maxVisibleNotifications
        self.notificationPosition = notificationPosition
        self.edgeMargin = edgeMargin
        self.appearanceMode = appearanceMode
        self.notificationClickAction = notificationClickAction
        self.showAvatar = showAvatar
        self.showSender = showSender
        self.showChatName = showChatName
        self.showTimestamp = showTimestamp
        self.showPreview = showPreview
        self.showCopyButton = showCopyButton
    }
}
