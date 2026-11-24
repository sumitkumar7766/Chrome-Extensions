import AppKit
import SwiftUI

/// Compact macOS-native menu bar popover for PingGlass global desktop notifications.
struct StatusView: View {
    @ObservedObject var appState: AppState
    @ObservedObject var whatsappDetector: WhatsAppDetector
    @ObservedObject var permissionManager: PermissionManager
    @Binding var activeTab: PopoverTab

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            headerSection

            Divider()

            statusRowsSection

            if appState.lifecycleState == .accessibilityRequired {
                accessibilityRecoveryCard
            } else if appState.lifecycleState == .whatsappNotRunning {
                whatsappRecoveryBanner
            }

            Divider()

            controlsSection
        }
        .padding(14)
        .frame(width: 348)
    }

    private var headerSection: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color(red: 0.145, green: 0.827, blue: 0.400).opacity(0.16))
                    .frame(width: 32, height: 32)
                Image(systemName: "bubble.left.and.exclamationmark.bubble.right.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color(red: 0.08, green: 0.62, blue: 0.28))
            }

            VStack(alignment: .leading, spacing: 1) {
                Text("PingGlass")
                    .font(.headline)
                Text(appState.lifecycleState.displayTitle)
                    .font(.caption)
                    .foregroundStyle(stateColor)
            }

            Spacer()

            Button {
                activeTab = .settings
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 13, weight: .medium))
            }
            .buttonStyle(.borderless)
            .help("Open Settings")
        }
    }

    private var statusRowsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            StatusRow(
                label: "WhatsApp Desktop",
                value: whatsappValueText,
                dotColor: whatsappDetector.currentProcess != nil ? .green : .secondary
            )
            StatusRow(
                label: "Accessibility",
                value: permissionManager.isAccessibilityGranted ? "Granted" : "Permission Required",
                dotColor: permissionManager.isAccessibilityGranted ? .green : .orange
            )
            StatusRow(
                label: "Global Notifications",
                value: appState.pauseStatusSummary,
                dotColor: (!appState.config.globalNotificationsEnabled || appState.isNotificationsPaused) ? .orange : .green
            )
            StatusRow(
                label: "Chrome Bridge (Optional)",
                value: appState.connectedBridgeClients > 0
                    ? "Connected (\(appState.connectedBridgeClients))"
                    : "Not Required",
                dotColor: appState.connectedBridgeClients > 0 ? .green : .secondary
            )
            StatusRow(
                label: "Detection Mode",
                value: appState.extractionMode,
                dotColor: appState.observerAttached ? .green : (appState.fallbackPollingActive ? .yellow : .secondary)
            )
            StatusRow(
                label: "Session Messages",
                value: "\(appState.sessionMessagesForwarded) message\(appState.sessionMessagesForwarded == 1 ? "" : "s")",
                dotColor: .blue
            )

            Text(appState.statusDetail)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 2)
        }
    }

    private var accessibilityRecoveryCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Accessibility Access Needed")
                .font(.caption.bold())
                .foregroundStyle(.orange)
            Text("Enable PingGlass in System Settings → Privacy & Security → Accessibility to observe WhatsApp UI changes.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                Button("Request Prompt") {
                    permissionManager.requestAccessibilityPrompt()
                }
                .controlSize(.small)

                Button("Open Settings") {
                    permissionManager.openAccessibilitySettings()
                }
                .controlSize(.small)
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(10)
        .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var whatsappRecoveryBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "info.circle")
                .foregroundStyle(.secondary)
            Text("Open WhatsApp Desktop to monitor messages. You can still test global notifications right now.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var controlsSection: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Button {
                    appState.toggleMonitoring()
                } label: {
                    Label(
                        appState.config.monitoringEnabled ? "Stop Monitoring" : "Start Monitoring",
                        systemImage: appState.config.monitoringEnabled ? "pause.fill" : "play.fill"
                    )
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(appState.config.monitoringEnabled ? .orange : .accentColor)

                Button {
                    appState.sendTestNotification()
                } label: {
                    Label("Test", systemImage: "sparkles")
                }
                .buttonStyle(.bordered)
                .help("Show a global floating test glass notification")
            }

            HStack(spacing: 8) {
                if appState.isNotificationsPaused {
                    Button {
                        appState.resumeNotifications()
                    } label: {
                        Label("Resume Notifications", systemImage: "bell.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                } else {
                    Menu {
                        Button("Pause for 15 minutes") {
                            appState.pauseNotifications(forMinutes: 15)
                        }
                        Button("Pause for 1 hour") {
                            appState.pauseNotifications(forMinutes: 60)
                        }
                        Button("Pause until manually resumed") {
                            appState.pauseNotificationsIndefinitely()
                        }
                    } label: {
                        Label("Pause Notifications", systemImage: "bell.slash")
                            .frame(maxWidth: .infinity)
                    }
                    .controlSize(.small)
                }

                Button("Settings") {
                    activeTab = .settings
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            HStack {
                Button("Refresh Status") {
                    appState.refreshAll()
                }
                .buttonStyle(.link)
                .font(.caption)

                Spacer()

                Button("Quit PingGlass") {
                    NSApp.terminate(nil)
                }
                .buttonStyle(.link)
                .font(.caption)
                .foregroundStyle(.red)
            }
        }
    }

    private var whatsappValueText: String {
        guard let proc = whatsappDetector.currentProcess else {
            return "Not Running"
        }
        if let ver = proc.appVersion {
            return "Running (v\(ver))"
        }
        return "Running (PID \(proc.pid))"
    }

    private var stateColor: Color {
        switch appState.lifecycleState {
        case .monitoringActive:
            return .green
        case .monitoringLimited:
            return .orange
        case .accessibilityRequired:
            return .orange
        case .error:
            return .red
        case .whatsappDetected:
            return .blue
        case .whatsappNotRunning:
            return .secondary
        }
    }
}

private struct StatusRow: View {
    let label: String
    let value: String
    let dotColor: Color

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(dotColor)
                .frame(width: 7, height: 7)
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.caption.weight(.medium))
                .lineLimit(1)
                .truncationMode(.tail)
        }
    }
}
