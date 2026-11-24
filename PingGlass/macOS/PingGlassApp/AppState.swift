import AppKit
import Combine
import Foundation
import os

/// Central coordinator connecting WhatsApp detection, Accessibility observation,
/// native macOS global floating notifications, optional Chrome Native Messaging IPC,
/// and SwiftUI status/settings interfaces.
@MainActor
final class AppState: ObservableObject {
    private static let logger = Logger(subsystem: "com.pingglass.app", category: "coordinator")
    private static let defaultsKey = "pingglass.helper.config.v1"

    @Published private(set) var lifecycleState: MonitoringLifecycleState = .whatsappNotRunning
    @Published private(set) var statusDetail: String = "Launch official WhatsApp Desktop to begin."
    @Published private(set) var extractionMode: String = "Idle"
    @Published private(set) var observerAttached: Bool = false
    @Published private(set) var fallbackPollingActive: Bool = false
    @Published private(set) var connectedBridgeClients: Int = 0
    @Published private(set) var sessionMessagesForwarded: Int = 0
    @Published private(set) var ipcServerError: String?
    @Published var config: HelperConfiguration {
        didSet {
            saveConfiguration()
            accessibilityMonitor.updateConfiguration(config)
            notificationManager.updateConfiguration(config)
            schedulePauseExpirationTimerIfNeeded()
            evaluateLifecycle()
            broadcastStatus()
        }
    }

    let whatsappDetector: WhatsAppDetector
    let permissionManager: PermissionManager
    let launchAtLoginManager: LaunchAtLoginManager
    let notificationManager: GlobalNotificationWindowManager

    private let accessibilityMonitor: AccessibilityMonitor
    private let ipcServer: NativeMessagingServer
    private var cancellables: Set<AnyCancellable> = []
    private var pauseExpirationTimer: Timer?

    init(
        whatsappDetector: WhatsAppDetector? = nil,
        permissionManager: PermissionManager? = nil,
        launchAtLoginManager: LaunchAtLoginManager? = nil,
        accessibilityMonitor: AccessibilityMonitor? = nil,
        ipcServer: NativeMessagingServer? = nil,
        notificationManager: GlobalNotificationWindowManager? = nil
    ) {
        let initialConfig = Self.loadConfiguration()
        self.whatsappDetector = whatsappDetector ?? WhatsAppDetector()
        self.permissionManager = permissionManager ?? PermissionManager()
        self.launchAtLoginManager = launchAtLoginManager ?? LaunchAtLoginManager()
        self.accessibilityMonitor = accessibilityMonitor ?? AccessibilityMonitor()
        self.ipcServer = ipcServer ?? NativeMessagingServer()
        self.notificationManager = notificationManager ?? GlobalNotificationWindowManager(config: initialConfig)
        self.config = initialConfig

        wireCallbacks()
        startIPCServer()
        schedulePauseExpirationTimerIfNeeded()
        evaluateLifecycle()
    }

    func shutdown() {
        pauseExpirationTimer?.invalidate()
        pauseExpirationTimer = nil
        notificationManager.dismissAll(animated: false)
        accessibilityMonitor.stop(resetCache: true)
        permissionManager.stopTransientRefresh()
        ipcServer.stop()
    }

    // MARK: - Monitoring & Pause Controls

    func startMonitoring() {
        permissionManager.refreshStatus()
        whatsappDetector.refreshNow()
        config.monitoringEnabled = true
        evaluateLifecycle()
    }

    func stopMonitoring() {
        config.monitoringEnabled = false
        accessibilityMonitor.stop(resetCache: true)
        observerAttached = false
        fallbackPollingActive = false
        extractionMode = "Paused by user"
        evaluateLifecycle()
    }

    func toggleMonitoring() {
        if config.monitoringEnabled {
            stopMonitoring()
        } else {
            startMonitoring()
        }
    }

    func pauseNotifications(forMinutes minutes: Int) {
        var updated = config
        updated.pausedIndefinitely = false
        updated.pausedUntil = Date().addingTimeInterval(TimeInterval(minutes * 60))
        config = updated
    }

    func pauseNotificationsIndefinitely() {
        var updated = config
        updated.pausedIndefinitely = true
        updated.pausedUntil = nil
        config = updated
    }

    func resumeNotifications() {
        var updated = config
        updated.pausedIndefinitely = false
        updated.pausedUntil = nil
        config = updated
    }

    var isNotificationsPaused: Bool {
        config.isNotificationsPaused()
    }

    var pauseStatusSummary: String {
        if !config.globalNotificationsEnabled {
            return "Disabled"
        }
        if config.pausedIndefinitely {
            return "Paused until resumed"
        }
        if let until = config.pausedUntil, until > Date() {
            let minutes = max(1, Int(ceil(until.timeIntervalSinceNow / 60.0)))
            return "Paused (\(minutes)m left)"
        }
        return "Active"
    }

    func refreshAll() {
        permissionManager.refreshStatus()
        whatsappDetector.refreshNow()
        evaluateLifecycle()
        broadcastStatus()
    }

    /// Sends a test notification through the primary native global floating renderer
    /// (and optionally forwards to any connected Chrome bridge client).
    func sendTestNotification() {
        let nowString = ISO8601DateFormatter().string(from: Date())
        let timeLabel = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .short)

        let testMessage = WhatsAppMessage(
            id: "test-\(UUID().uuidString)",
            sender: "PingGlass Test",
            chatName: "Global Notification",
            text: "Your global glass notification is working beautifully! ✨",
            timestamp: timeLabel,
            avatar: nil,
            receivedAt: nowString,
            source: "pingglass-test",
            confidence: 1.0,
            isTest: true
        )

        notificationManager.enqueue(testMessage, config: config)

        if config.chromeForwardingEnabled && connectedBridgeClients > 0 {
            ipcServer.broadcast(BridgeEnvelope(type: "incoming_message", message: testMessage))
        }
        Self.logger.info("Displayed test global glass notification.")
    }

    /// Explicitly opens/activates official WhatsApp Desktop when requested by user click.
    func openWhatsAppDesktop(for _: WhatsAppMessage? = nil) {
        for bundleId in WhatsAppDetector.supportedBundleIdentifiers {
            if let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleId).first(where: { !$0.isTerminated }) {
                running.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
                return
            }
        }

        let candidates = [
            URL(fileURLWithPath: "/Applications/WhatsApp.app"),
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications/WhatsApp.app"),
        ]
        if let appURL = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }) {
            let openConfig = NSWorkspace.OpenConfiguration()
            openConfig.activates = true
            NSWorkspace.shared.openApplication(at: appURL, configuration: openConfig, completionHandler: nil)
        }
    }

    func currentSnapshot() -> HelperStatusSnapshot {
        let proc = whatsappDetector.currentProcess
        return HelperStatusSnapshot(
            monitoringState: lifecycleState,
            monitoringEnabled: config.monitoringEnabled,
            whatsappRunning: proc != nil,
            whatsappActive: proc?.isActive ?? false,
            whatsappBundleId: proc?.bundleIdentifier,
            whatsappVersion: proc?.appVersion,
            accessibilityGranted: permissionManager.isAccessibilityGranted,
            observerAttached: observerAttached,
            fallbackPollingActive: fallbackPollingActive,
            extractionMode: extractionMode,
            statusDetail: statusDetail,
            sessionMessagesForwarded: sessionMessagesForwarded,
            globalNotificationsEnabled: config.globalNotificationsEnabled,
            notificationsPaused: isNotificationsPaused
        )
    }

    // MARK: - Wiring & Lifecycle State Machine

    private func wireCallbacks() {
        notificationManager.onOpenWhatsAppRequested = { [weak self] message in
            self?.openWhatsAppDesktop(for: message)
        }

        whatsappDetector.onProcessChanged = { [weak self] _ in
            self?.evaluateLifecycle()
        }

        permissionManager.$isAccessibilityGranted
            .dropFirst()
            .sink { [weak self] _ in
                self?.evaluateLifecycle()
            }
            .store(in: &cancellables)

        accessibilityMonitor.onObservationUpdated = { [weak self] report in
            guard let self else { return }
            self.observerAttached = report.observerAttached
            self.fallbackPollingActive = report.fallbackPollingActive
            self.extractionMode = report.extractionMode

            if report.permissionRevoked {
                self.permissionManager.refreshStatus()
                self.lifecycleState = .accessibilityRequired
                self.statusDetail = report.errorDescription ?? "Accessibility permission was revoked."
                self.broadcastStatus()
                return
            }

            guard self.config.monitoringEnabled, self.whatsappDetector.currentProcess != nil else {
                return
            }

            if !report.observerAttached && !report.fallbackPollingActive {
                self.lifecycleState = .error
                self.statusDetail = report.errorDescription ?? "Unable to observe WhatsApp UI."
            } else if !report.observerAttached || report.accessibleWindowCount == 0 {
                self.lifecycleState = .monitoringLimited
                self.statusDetail = report.errorDescription ??
                    "Fallback polling active; open WhatsApp window for best Accessibility coverage."
            } else {
                self.lifecycleState = .monitoringActive
                self.statusDetail = "Observing WhatsApp Desktop via Accessibility APIs."
            }
            self.broadcastStatus()
        }

        accessibilityMonitor.onMessagesDetected = { [weak self] messages in
            guard let self, self.config.monitoringEnabled else { return }

            for message in messages {
                self.sessionMessagesForwarded += 1

                // Primary renderer: global macOS floating glass notifications (independent of Chrome).
                self.notificationManager.enqueue(message, config: self.config)

                // Optional secondary bridge: Chrome extension when enabled and connected.
                if self.config.chromeForwardingEnabled && self.connectedBridgeClients > 0 {
                    self.ipcServer.broadcast(BridgeEnvelope(type: "incoming_message", message: message))
                }
            }
            // Log count only; never log private message text or sender names.
            Self.logger.info("Processed \(messages.count) sanitized event(s).")
            self.broadcastStatus()
        }

        ipcServer.onClientCountChanged = { [weak self] count in
            guard let self else { return }
            self.connectedBridgeClients = count
            if count > 0 {
                self.ipcServer.broadcast(
                    BridgeEnvelope(
                        type: "connection_status",
                        status: self.currentSnapshot(),
                        helperConnected: true
                    )
                )
                self.broadcastStatus()
            }
        }

        ipcServer.onEnvelopeReceived = { [weak self] envelope in
            Task { @MainActor [weak self] in
                self?.handleIncomingBridgeEnvelope(envelope)
            }
        }
    }

    private func startIPCServer() {
        do {
            try ipcServer.start()
            ipcServerError = nil
        } catch {
            ipcServerError = "Local IPC socket error: \(error.localizedDescription)"
            Self.logger.error("Failed to start IPC server: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func schedulePauseExpirationTimerIfNeeded() {
        pauseExpirationTimer?.invalidate()
        pauseExpirationTimer = nil

        guard !config.pausedIndefinitely, let until = config.pausedUntil else { return }
        let remaining = until.timeIntervalSinceNow
        if remaining <= 0 {
            config.pausedUntil = nil
            return
        }

        pauseExpirationTimer = Timer.scheduledTimer(withTimeInterval: remaining + 0.1, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let expiry = self.config.pausedUntil, expiry <= Date() {
                    self.config.pausedUntil = nil
                }
            }
        }
    }

    private func evaluateLifecycle() {
        if let ipcServerError {
            lifecycleState = .error
            statusDetail = ipcServerError
            accessibilityMonitor.stop(resetCache: false)
            broadcastStatus()
            return
        }

        let trusted = permissionManager.refreshStatus()
        guard let process = whatsappDetector.currentProcess else {
            accessibilityMonitor.stop(resetCache: true)
            observerAttached = false
            fallbackPollingActive = false
            extractionMode = "Idle"
            lifecycleState = .whatsappNotRunning
            statusDetail = "WhatsApp Desktop is not running."
            broadcastStatus()
            return
        }

        guard trusted else {
            accessibilityMonitor.stop(resetCache: false)
            observerAttached = false
            fallbackPollingActive = false
            extractionMode = "Permission required"
            lifecycleState = .accessibilityRequired
            statusDetail = "Grant Accessibility access in System Settings to observe WhatsApp."
            broadcastStatus()
            return
        }

        guard config.monitoringEnabled else {
            accessibilityMonitor.stop(resetCache: false)
            observerAttached = false
            fallbackPollingActive = false
            extractionMode = "Paused"
            lifecycleState = .whatsappDetected
            statusDetail = "WhatsApp detected (PID \(process.pid)). Monitoring is paused."
            broadcastStatus()
            return
        }

        accessibilityMonitor.start(pid: process.pid, config: config)
        if lifecycleState == .whatsappNotRunning ||
            lifecycleState == .whatsappDetected ||
            lifecycleState == .accessibilityRequired {
            lifecycleState = .monitoringLimited
            statusDetail = "Attaching Accessibility observer to WhatsApp..."
            broadcastStatus()
        }
    }

    private func handleIncomingBridgeEnvelope(_ envelope: BridgeEnvelope) {
        switch envelope.type {
        case "ping":
            ipcServer.broadcast(
                BridgeEnvelope(
                    type: "pong",
                    status: currentSnapshot(),
                    helperConnected: true
                )
            )
        case "request_status":
            broadcastStatus()
        case "start_monitoring":
            startMonitoring()
        case "pause_monitoring":
            stopMonitoring()
        case "test_notification":
            sendTestNotification()
        case "settings_update":
            guard let payload = envelope.settings else { return }
            var updated = config
            if let enabled = payload.monitoringEnabled {
                updated.monitoringEnabled = enabled
            }
            if let policy = payload.ambiguousDirectionPolicy {
                updated.ambiguousDirectionPolicy = policy
            }
            if let maxLen = payload.maxPreviewLength {
                updated.maxPreviewLength = max(80, min(1000, maxLen))
            }
            if let poll = payload.fallbackPollingIntervalSeconds {
                updated.fallbackPollingIntervalSeconds = max(1.5, min(15.0, poll))
            }
            if let globalEnabled = payload.globalNotificationsEnabled {
                updated.globalNotificationsEnabled = globalEnabled
            }
            if let chromeForward = payload.chromeForwardingEnabled {
                updated.chromeForwardingEnabled = chromeForward
            }
            if let paused = payload.notificationsPaused {
                updated.pausedIndefinitely = paused
                if !paused {
                    updated.pausedUntil = nil
                }
            }
            if updated != config {
                config = updated
            }
        default:
            Self.logger.debug("Ignored unknown bridge message type: \(envelope.type, privacy: .public)")
        }
    }

    private func broadcastStatus() {
        ipcServer.broadcast(
            BridgeEnvelope(
                type: "monitoring_status",
                status: currentSnapshot(),
                helperConnected: true
            )
        )
    }

    // MARK: - Non-sensitive Config Persistence (never stores WhatsApp messages)

    private static func loadConfiguration() -> HelperConfiguration {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let decoded = try? JSONDecoder().decode(HelperConfiguration.self, from: data) else {
            return HelperConfiguration()
        }
        return decoded
    }

    private func saveConfiguration() {
        if let encoded = try? JSONEncoder().encode(config) {
            UserDefaults.standard.set(encoded, forKey: Self.defaultsKey)
        }
    }
}
