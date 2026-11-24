import ApplicationServices
import Foundation

/// Observation status emitted by `AccessibilityMonitor`.
public struct AccessibilityObservationReport: Sendable {
    public let observerAttached: Bool
    public let fallbackPollingActive: Bool
    public let accessibleWindowCount: Int
    public let extractionMode: String
    public let permissionRevoked: Bool
    public let errorDescription: String?
}

/// Manages `AXObserver` registration and low-frequency adaptive fallback polling for WhatsApp Desktop.
@MainActor
final class AccessibilityMonitor {
    private let extractor: AccessibilityExtractor
    private let processor: MessageProcessor
    private let extractionQueue = DispatchQueue(label: "com.pingglass.ax.extractor", qos: .utility)

    private var observer: AXObserver?
    private var observedPid: pid_t?
    private var appElement: AXUIElement?
    private var pollingTimer: Timer?
    private var debounceWorkItem: DispatchWorkItem?
    private var needsBaselineSeed = true
    private var isActive = false
    private var attachedNotificationsCount = 0
    private var lastConfig = HelperConfiguration()

    var onMessagesDetected: (([WhatsAppMessage]) -> Void)?
    var onObservationUpdated: ((AccessibilityObservationReport) -> Void)?

    init(
        extractor: AccessibilityExtractor = AccessibilityExtractor(),
        processor: MessageProcessor = MessageProcessor()
    ) {
        self.extractor = extractor
        self.processor = processor
    }

    deinit {
        // Ensure C-level AXObserver and timers are cleaned up.
        debounceWorkItem?.cancel()
        pollingTimer?.invalidate()
        if let observer {
            CFRunLoopRemoveSource(
                CFRunLoopGetMain(),
                AXObserverGetRunLoopSource(observer),
                .defaultMode
            )
        }
    }

    /// Starts observing the specified WhatsApp process ID.
    func start(pid: pid_t, config: HelperConfiguration) {
        lastConfig = config

        // Avoid creating duplicate observers for the same PID.
        if isActive && observedPid == pid && observer != nil {
            restartPollingTimerIfNeeded(interval: config.fallbackPollingIntervalSeconds)
            return
        }

        stop(resetCache: true)
        observedPid = pid
        needsBaselineSeed = true
        isActive = true

        guard AXIsProcessTrusted() else {
            onObservationUpdated?(
                AccessibilityObservationReport(
                    observerAttached: false,
                    fallbackPollingActive: false,
                    accessibleWindowCount: 0,
                    extractionMode: "Accessibility trust missing",
                    permissionRevoked: true,
                    errorDescription: "Grant Accessibility permission in System Settings."
                )
            )
            stop(resetCache: false)
            return
        }

        let targetApp = AXUIElementCreateApplication(pid)
        appElement = targetApp

        var createdObserver: AXObserver?
        let selfPointer = Unmanaged.passUnretained(self).toOpaque()
        let createErr = AXObserverCreate(pid, Self.axObserverCallback, &createdObserver)

        if createErr == .success, let createdObserver {
            observer = createdObserver
            CFRunLoopAddSource(
                CFRunLoopGetMain(),
                AXObserverGetRunLoopSource(createdObserver),
                .defaultMode
            )

            let watchedNotifications: [String] = [
                kAXValueChangedNotification as String,
                kAXCreatedNotification as String,
                kAXFocusedWindowChangedNotification as String,
                kAXWindowCreatedNotification as String,
                kAXRowCountChangedNotification as String,
                kAXTitleChangedNotification as String,
            ]

            var count = 0
            for name in watchedNotifications {
                let addErr = AXObserverAddNotification(
                    createdObserver,
                    targetApp,
                    name as CFString,
                    selfPointer
                )
                if addErr == .success || addErr == .notificationAlreadyRegistered {
                    count += 1
                }
            }
            attachedNotificationsCount = count
        } else {
            attachedNotificationsCount = 0
        }

        restartPollingTimerIfNeeded(interval: config.fallbackPollingIntervalSeconds)
        scheduleScan(immediate: true)
    }

    /// Updates polling cadence or direction policy without recreating an active observer.
    func updateConfiguration(_ config: HelperConfiguration) {
        lastConfig = config
        if isActive {
            restartPollingTimerIfNeeded(interval: config.fallbackPollingIntervalSeconds)
        }
    }

    /// Tears down AXObserver, fallback polling timer, and optionally clears deduplication state.
    func stop(resetCache: Bool = true) {
        isActive = false
        debounceWorkItem?.cancel()
        debounceWorkItem = nil

        pollingTimer?.invalidate()
        pollingTimer = nil

        if let observer {
            CFRunLoopRemoveSource(
                CFRunLoopGetMain(),
                AXObserverGetRunLoopSource(observer),
                .defaultMode
            )
        }
        observer = nil
        appElement = nil
        observedPid = nil
        attachedNotificationsCount = 0
        needsBaselineSeed = true

        if resetCache {
            processor.resetCache()
        }
    }

    // MARK: - AX Callback & Throttled Scanning

    private static let axObserverCallback: AXObserverCallback = { _, _, _, refcon in
        guard let refcon else { return }
        let monitor = Unmanaged<AccessibilityMonitor>.fromOpaque(refcon).takeUnretainedValue()
        Task { @MainActor in
            monitor.handleAXEvent()
        }
    }

    private func handleAXEvent() {
        guard isActive else { return }
        scheduleScan(immediate: false)
    }

    private func restartPollingTimerIfNeeded(interval: TimeInterval) {
        pollingTimer?.invalidate()
        let safeInterval = max(1.5, min(15.0, interval))
        pollingTimer = Timer.scheduledTimer(withTimeInterval: safeInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.isActive else { return }
                self.scheduleScan(immediate: false)
            }
        }
    }

    private func scheduleScan(immediate: Bool) {
        debounceWorkItem?.cancel()

        guard isActive, let observedPid else { return }

        if !AXIsProcessTrusted() {
            let report = AccessibilityObservationReport(
                observerAttached: false,
                fallbackPollingActive: false,
                accessibleWindowCount: 0,
                extractionMode: "Accessibility permission revoked",
                permissionRevoked: true,
                errorDescription: "Accessibility permission was revoked."
            )
            stop(resetCache: false)
            onObservationUpdated?(report)
            return
        }

        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let seedOnly = self.needsBaselineSeed
            let configSnapshot = self.lastConfig
            let observerAttached = self.attachedNotificationsCount > 0
            let pollingActive = self.pollingTimer != nil
            let extractor = self.extractor
            let processor = self.processor

            self.extractionQueue.async { [weak self] in
                let targetApp = AXUIElementCreateApplication(observedPid)
                let passResult = extractor.extract(fromAppElement: targetApp)
                let messages = processor.process(
                    candidates: passResult.candidates,
                    config: configSnapshot,
                    seedOnly: seedOnly
                )

                Task { @MainActor [weak self] in
                    guard let self, self.isActive else { return }
                    if seedOnly {
                        self.needsBaselineSeed = false
                    }

                    let report = AccessibilityObservationReport(
                        observerAttached: observerAttached,
                        fallbackPollingActive: pollingActive,
                        accessibleWindowCount: passResult.accessibleWindowCount,
                        extractionMode: passResult.extractionMode,
                        permissionRevoked: false,
                        errorDescription: passResult.accessibleWindowCount == 0
                            ? "WhatsApp has no open accessible window (minimized or closed)."
                            : nil
                    )
                    self.onObservationUpdated?(report)

                    if !messages.isEmpty {
                        self.onMessagesDetected?(messages)
                    }
                }
            }
        }

        debounceWorkItem = work
        if immediate {
            DispatchQueue.main.async(execute: work)
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.22, execute: work)
        }
    }
}
