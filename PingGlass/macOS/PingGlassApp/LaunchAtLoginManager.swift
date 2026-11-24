import Foundation
import ServiceManagement

/// Manages optional Launch at Login via macOS 13+ SMAppService when running from an app bundle.
@MainActor
final class LaunchAtLoginManager: ObservableObject {
    @Published private(set) var isEnabled: Bool = false
    @Published private(set) var isSupported: Bool = false
    @Published private(set) var statusNote: String = ""

    init() {
        refresh()
    }

    func refresh() {
        // SMAppService.mainApp requires a bundled .app executable.
        let isAppBundle = Bundle.main.bundleURL.pathExtension.lowercased() == "app"
        isSupported = isAppBundle

        guard isAppBundle else {
            isEnabled = false
            statusNote = "Build and run PingGlass.app bundle to enable Launch at Login."
            return
        }

        let status = SMAppService.mainApp.status
        switch status {
        case .enabled:
            isEnabled = true
            statusNote = "PingGlass starts automatically when you log in."
        case .requiresApproval:
            isEnabled = false
            statusNote = "Approval required in System Settings → General → Login Items."
        case .notRegistered, .notFound:
            isEnabled = false
            statusNote = "Launch at Login is off."
        @unknown default:
            isEnabled = false
            statusNote = "Launch at Login status unavailable."
        }
    }

    func setEnabled(_ enabled: Bool) {
        guard isSupported else {
            refresh()
            return
        }

        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            statusNote = "Unable to update Launch at Login: \(error.localizedDescription)"
        }
        refresh()
    }
}
