import AppKit
import SwiftUI

enum PopoverTab {
    case status
    case settings
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var appState: AppState?
    var openMainWindowAction: (() -> Void)?

    func applicationWillTerminate(_ notification: Notification) {
        Task { @MainActor in
            appState?.shutdown()
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            openMainWindowAction?()
        }
        return true
    }
}

@main
struct PingGlassApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var appState = AppState()
    @State private var activeTab: PopoverTab = .status
    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        MenuBarExtra {
            popoverContent
                .onAppear {
                    appDelegate.appState = appState
                    appDelegate.openMainWindowAction = {
                        openWindow(id: "pingglass-window")
                        NSApp.activate(ignoringOtherApps: true)
                    }
                    appState.refreshAll()
                }
        } label: {
            Label("PingGlass", systemImage: menuBarIconName)
        }
        .menuBarExtraStyle(.window)

        // Optional window opened if the user invokes `open -a PingGlass` from Chrome.
        Window("PingGlass", id: "pingglass-window") {
            popoverContent
                .onAppear {
                    appDelegate.appState = appState
                    appState.refreshAll()
                }
        }
        .windowResizability(.contentSize)
    }

    @ViewBuilder
    private var popoverContent: some View {
        switch activeTab {
        case .status:
            StatusView(
                appState: appState,
                whatsappDetector: appState.whatsappDetector,
                permissionManager: appState.permissionManager,
                activeTab: $activeTab
            )
        case .settings:
            SettingsView(
                appState: appState,
                launchAtLogin: appState.launchAtLoginManager,
                permissionManager: appState.permissionManager,
                activeTab: $activeTab
            )
        }
    }

    private var menuBarIconName: String {
        if appState.isNotificationsPaused || !appState.config.globalNotificationsEnabled {
            return "bell.slash"
        }
        switch appState.lifecycleState {
        case .monitoringActive:
            return "bubble.left.and.text.bubble.right.fill"
        case .accessibilityRequired, .error:
            return "exclamationmark.bubble.fill"
        case .monitoringLimited:
            return "bubble.left.and.text.bubble.right"
        case .whatsappDetected, .whatsappNotRunning:
            return "bubble.left"
        }
    }
}
