import AppKit
import ApplicationServices
import Foundation

/// Checks macOS Accessibility trust state and provides explicit user-guided recovery actions.
/// Never attempts to bypass or silently alter TCC permissions.
@MainActor
final class PermissionManager: ObservableObject {
    @Published private(set) var isAccessibilityGranted: Bool = AXIsProcessTrusted()

    private var pollTimer: Timer?

    deinit {
        pollTimer?.invalidate()
    }

    /// Re-evaluates `AXIsProcessTrusted()` synchronously.
    @discardableResult
    func refreshStatus() -> Bool {
        let trusted = AXIsProcessTrusted()
        if trusted != isAccessibilityGranted {
            isAccessibilityGranted = trusted
        }
        return trusted
    }

    /// Prompts macOS to show the Accessibility permission sheet (only on explicit user action).
    func requestAccessibilityPrompt() {
        let promptKey = "AXTrustedCheckOptionPrompt"
        let options = [promptKey: true] as CFDictionary
        let trusted = AXIsProcessTrustedWithOptions(options)
        isAccessibilityGranted = trusted
        if !trusted {
            startTransientRefresh()
        }
    }

    /// Opens System Settings -> Privacy & Security -> Accessibility.
    func openAccessibilitySettings() {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        ) else {
            return
        }
        NSWorkspace.shared.open(url)
        startTransientRefresh()
    }

    /// Polls permission state briefly while waiting for the user to toggle System Settings.
    func startTransientRefresh(duration: TimeInterval = 45.0) {
        pollTimer?.invalidate()
        let deadline = Date().addingTimeInterval(duration)
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] timer in
            Task { @MainActor [weak self] in
                guard let self else {
                    timer.invalidate()
                    return
                }
                let granted = self.refreshStatus()
                if granted || Date() >= deadline {
                    timer.invalidate()
                    self.pollTimer = nil
                }
            }
        }
    }

    func stopTransientRefresh() {
        pollTimer?.invalidate()
        pollTimer = nil
    }
}
