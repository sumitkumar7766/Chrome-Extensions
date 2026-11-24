import AppKit
import Foundation

/// Immutable snapshot describing the running official WhatsApp Desktop process.
public struct WhatsAppProcessInfo: Sendable, Equatable {
    public let pid: pid_t
    public let bundleIdentifier: String
    public let appName: String
    public let appVersion: String?
    public let isActive: Bool
    public let bundlePath: String?
}

/// Discovers and tracks the lifecycle of the native macOS WhatsApp Desktop app (Mac App Store / native bundle).
/// Verified local bundle identifier on macOS WhatsApp Desktop 26.43.77: `net.whatsapp.WhatsApp`.
@MainActor
final class WhatsAppDetector: ObservableObject {
    /// Known official WhatsApp Desktop bundle identifiers (primary verified first).
    static let supportedBundleIdentifiers = [
        "net.whatsapp.WhatsApp",
        "desktop.WhatsApp",
    ]

    @Published private(set) var currentProcess: WhatsAppProcessInfo?

    var onProcessChanged: ((WhatsAppProcessInfo?) -> Void)?

    private var workspaceObservers: [NSObjectProtocol] = []

    init() {
        installWorkspaceObservers()
        refreshNow()
    }

    deinit {
        let nc = NSWorkspace.shared.notificationCenter
        for observer in workspaceObservers {
            nc.removeObserver(observer)
        }
    }

    /// Queries NSWorkspace for a running official WhatsApp Desktop process.
    @discardableResult
    func refreshNow() -> WhatsAppProcessInfo? {
        let found = findRunningWhatsApp()
        if found != currentProcess {
            currentProcess = found
            onProcessChanged?(found)
        }
        return found
    }

    private func findRunningWhatsApp() -> WhatsAppProcessInfo? {
        for bundleId in Self.supportedBundleIdentifiers {
            let matches = NSRunningApplication.runningApplications(withBundleIdentifier: bundleId)
            if let app = matches.first(where: { !$0.isTerminated }) {
                return buildInfo(for: app)
            }
        }

        // Fallback: verify official WhatsApp.app by exact localized/executable name inside standard app locations
        // rather than blindly matching browser tabs or helper agents.
        for app in NSWorkspace.shared.runningApplications where !app.isTerminated {
            guard app.activationPolicy == .regular else { continue }
            guard let bundleURL = app.bundleURL else { continue }
            let path = bundleURL.path
            let isStandardInstall =
                path.hasPrefix("/Applications/WhatsApp.app") ||
                path.hasSuffix("/Applications/WhatsApp.app")
            if isStandardInstall {
                return buildInfo(for: app)
            }
        }

        return nil
    }

    private func buildInfo(for app: NSRunningApplication) -> WhatsAppProcessInfo {
        let bundleId = app.bundleIdentifier ?? "net.whatsapp.WhatsApp"
        var version: String?
        if let bundleURL = app.bundleURL, let bundle = Bundle(url: bundleURL) {
            version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        }

        return WhatsAppProcessInfo(
            pid: app.processIdentifier,
            bundleIdentifier: bundleId,
            appName: app.localizedName ?? "WhatsApp",
            appVersion: version,
            isActive: app.isActive,
            bundlePath: app.bundleURL?.path
        )
    }

    private func installWorkspaceObservers() {
        let nc = NSWorkspace.shared.notificationCenter
        let watchedNames: [Notification.Name] = [
            NSWorkspace.didLaunchApplicationNotification,
            NSWorkspace.didTerminateApplicationNotification,
            NSWorkspace.didActivateApplicationNotification,
            NSWorkspace.didDeactivateApplicationNotification,
        ]

        for name in watchedNames {
            let token = nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.refreshNow()
                }
            }
            workspaceObservers.append(token)
        }
    }
}
