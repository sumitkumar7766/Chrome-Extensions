import AppKit
import ApplicationServices
import Foundation

/// Observation status emitted by `AccessibilityMonitor`.
public struct AccessibilityObservationReport: Sendable {
    public let observerAttached: Bool
    public let bannerObserverAttached: Bool
    public let fallbackPollingActive: Bool
    public let accessibleWindowCount: Int
    public let extractionMode: String
    public let permissionRevoked: Bool
    public let errorDescription: String?
}

/// Manages `AXObserver` registration (for WhatsApp Desktop AND public macOS NotificationCenter WhatsApp banners)
/// and low-frequency adaptive fallback polling.
@MainActor
final class AccessibilityMonitor {
    private let extractor: AccessibilityExtractor
    private let processor: MessageProcessor
    private let extractionQueue = DispatchQueue(label: "com.pingglass.ax.extractor", qos: .utility)

    private var observer: AXObserver?
    private var ncObserver: AXObserver?
    private var observedPid: pid_t?
    private var observedNcPid: pid_t?
    private var appElement: AXUIElement?
    private var pollingTimer: Timer?
    private var debounceWorkItem: DispatchWorkItem?
    private var needsBaselineSeed = true
    private var isActive = false
    private var attachedNotificationsCount = 0
    private var attachedNcNotificationsCount = 0
    private var attachedWindowObserversCount = 0
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
        debounceWorkItem?.cancel()
        pollingTimer?.invalidate()
        if let observer {
            CFRunLoopRemoveSource(
                CFRunLoopGetMain(),
                AXObserverGetRunLoopSource(observer),
                .defaultMode
            )
        }
        if let ncObserver {
            CFRunLoopRemoveSource(
                CFRunLoopGetMain(),
                AXObserverGetRunLoopSource(ncObserver),
                .defaultMode
            )
        }
    }

    /// Starts observing the specified WhatsApp process ID alongside public NotificationCenter WhatsApp banners.
    func start(pid: pid_t, config: HelperConfiguration) {
        lastConfig = config

        let ncPid = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.notificationcenterui").first?.processIdentifier

        // Avoid recreating duplicate observers for the same PID.
        if isActive && observedPid == pid && observer != nil {
            if ncPid != observedNcPid {
                attachNotificationCenterObserver(pid: ncPid)
            }
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
                    bannerObserverAttached: false,
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

        let selfPointer = Unmanaged.passUnretained(self).toOpaque()
        var createdObserver: AXObserver?
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
                kAXLayoutChangedNotification as String,
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

            // Also attach observers to any open WhatsApp windows directly so inner Catalyst updates trigger events.
            attachWindowObservers(to: targetApp, observer: createdObserver, selfPointer: selfPointer)

            attachedNotificationsCount = count
        } else {
            attachedNotificationsCount = 0
        }

        attachNotificationCenterObserver(pid: ncPid)
        restartPollingTimerIfNeeded(interval: config.fallbackPollingIntervalSeconds)
        scheduleScan(immediate: true)
    }

    private func attachNotificationCenterObserver(pid: pid_t?) {
        if let existing = ncObserver {
            CFRunLoopRemoveSource(
                CFRunLoopGetMain(),
                AXObserverGetRunLoopSource(existing),
                .defaultMode
            )
            ncObserver = nil
        }
        observedNcPid = pid
        attachedNcNotificationsCount = 0

        guard let pid, AXIsProcessTrusted() else { return }

        let ncElement = AXUIElementCreateApplication(pid)
        var createdNC: AXObserver?
        let selfPointer = Unmanaged.passUnretained(self).toOpaque()
        if AXObserverCreate(pid, Self.axObserverCallback, &createdNC) == .success, let createdNC {
            ncObserver = createdNC
            CFRunLoopAddSource(
                CFRunLoopGetMain(),
                AXObserverGetRunLoopSource(createdNC),
                .defaultMode
            )
            var count = 0
            for name in [
                kAXWindowCreatedNotification as String,
                kAXCreatedNotification as String,
                kAXLayoutChangedNotification as String,
                kAXFocusedWindowChangedNotification as String,
                kAXValueChangedNotification as String,
            ] {
                let err = AXObserverAddNotification(createdNC, ncElement, name as CFString, selfPointer)
                if err == .success || err == .notificationAlreadyRegistered {
                    count += 1
                }
            }
            attachedNcNotificationsCount = count
        }
    }

    /// Updates polling cadence or direction policy without recreating an active observer.
    func updateConfiguration(_ config: HelperConfiguration) {
        lastConfig = config
        if isActive {
            restartPollingTimerIfNeeded(interval: config.fallbackPollingIntervalSeconds)
        }
    }

    /// Tears down AXObservers, fallback polling timer, and optionally clears deduplication state.
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
        if let ncObserver {
            CFRunLoopRemoveSource(
                CFRunLoopGetMain(),
                AXObserverGetRunLoopSource(ncObserver),
                .defaultMode
            )
        }
        observer = nil
        ncObserver = nil
        appElement = nil
        observedPid = nil
        observedNcPid = nil
        attachedNotificationsCount = 0
        attachedNcNotificationsCount = 0
        attachedWindowObserversCount = 0
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
                bannerObserverAttached: false,
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
            let waObserverAttached = self.attachedNotificationsCount > 0
            let ncObserverAttached = self.attachedNcNotificationsCount > 0
            let pollingActive = self.pollingTimer != nil
            let currentNcPid = self.observedNcPid
            let extractor = self.extractor
            let processor = self.processor

            self.extractionQueue.async { [weak self] in
                let targetApp = AXUIElementCreateApplication(observedPid)
                let waResult = extractor.extract(fromAppElement: targetApp)

                var combinedCandidates = waResult.candidates
                var ncResult: ExtractionPassResult?
                if let currentNcPid {
                    let ncApp = AXUIElementCreateApplication(currentNcPid)
                    let banners = extractor.extractNotificationCenterWhatsAppBanners(fromAppElement: ncApp)
                    ncResult = banners
                    combinedCandidates.append(contentsOf: banners.candidates)
                }

                let messages = processor.process(
                    candidates: combinedCandidates,
                    config: configSnapshot,
                    seedOnly: seedOnly
                )

                let hasUsableWhatsAppUI = waResult.accessibleWindowCount > 0 && waResult.visitedNodeCount > 4

                let modeSummary: String
                if let ncResult, !ncResult.candidates.isEmpty, waResult.candidates.isEmpty {
                    modeSummary = ncResult.extractionMode
                } else if !hasUsableWhatsAppUI {
                    modeSummary = waResult.accessibleWindowCount > 0
                        ? "WhatsApp Minimized/Closed (\(waResult.visitedNodeCount) nodes)"
                        : "AX Banners (Window Closed)"
                } else {
                    modeSummary = "\(waResult.extractionMode) (\(waResult.visitedNodeCount) nodes)"
                }

                Task { @MainActor [weak self] in
                    guard let self, self.isActive else { return }
                    if seedOnly {
                        self.needsBaselineSeed = false
                    }

                    if hasUsableWhatsAppUI && self.attachedWindowObserversCount == 0,
                       let appEl = self.appElement,
                       let activeObs = self.observer {
                        let ptr = Unmanaged.passUnretained(self).toOpaque()
                        self.attachWindowObservers(to: appEl, observer: activeObs, selfPointer: ptr)
                    } else if !hasUsableWhatsAppUI {
                        self.attachedWindowObserversCount = 0
                    }

                    let errorDetail: String?
                    if !hasUsableWhatsAppUI {
                        errorDetail = "Keep WhatsApp window open behind apps (not minimized/closed) so PingGlass reads chats while system notifications are OFF."
                    } else {
                        errorDetail = nil
                    }

                    let report = AccessibilityObservationReport(
                        observerAttached: waObserverAttached || ncObserverAttached,
                        bannerObserverAttached: ncObserverAttached,
                        fallbackPollingActive: pollingActive,
                        accessibleWindowCount: hasUsableWhatsAppUI ? waResult.accessibleWindowCount : 0,
                        extractionMode: modeSummary,
                        permissionRevoked: false,
                        errorDescription: errorDetail
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
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.14, execute: work)
        }
    }

    private func attachWindowObservers(to appElement: AXUIElement, observer: AXObserver, selfPointer: UnsafeMutableRawPointer) {
        var winRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &winRef) == .success,
              let windows = winRef as? [AXUIElement] else {
            return
        }
        var attached = 0
        for window in windows.prefix(2) {
            for name in [
                kAXValueChangedNotification as String,
                kAXCreatedNotification as String,
                kAXRowCountChangedNotification as String,
                kAXLayoutChangedNotification as String,
            ] {
                let err = AXObserverAddNotification(observer, window, name as CFString, selfPointer)
                if err == .success || err == .notificationAlreadyRegistered {
                    attached += 1
                }
            }
        }
        attachedWindowObserversCount = attached
    }
}
