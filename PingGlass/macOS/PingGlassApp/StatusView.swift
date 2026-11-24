import AppKit
import SwiftUI

/// Compact macOS-native menu bar popover for PingGlass global desktop notifications.
struct StatusView: View {
    @ObservedObject var appState: AppState
    @ObservedObject var whatsappDetector: WhatsAppDetector
    @ObservedObject var permissionManager: PermissionManager
    @Binding var activeTab: PopoverTab
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            headerSection

            statusRowsSection

            if appState.lifecycleState == .accessibilityRequired {
                accessibilityRecoveryCard
            } else if appState.lifecycleState == .whatsappNotRunning {
                whatsappRecoveryBanner
            }

            controlsSection
        }
        .padding(14)
        .frame(width: 356)
        .background(popoverBacking)
    }

    private var popoverBacking: some View {
        colorScheme == .dark
            ? Color.black.opacity(0.32)
            : Color.white.opacity(0.38)
    }

    private var secondarySurfaceColor: Color {
        colorScheme == .dark
            ? Color.white.opacity(0.10)
            : Color.black.opacity(0.06)
    }

    private var controlSurfaceColor: Color {
        colorScheme == .dark
            ? Color.white.opacity(0.16)
            : Color.black.opacity(0.10)
    }

    private var controlBorderColor: Color {
        colorScheme == .dark
            ? Color.white.opacity(0.24)
            : Color.black.opacity(0.16)
    }

    private var headerSection: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color(red: 0.11, green: 0.68, blue: 0.33))
                    .frame(width: 32, height: 32)
                Image(systemName: "bubble.left.and.exclamationmark.bubble.right.fill")
                    .font(.system(size: 14.5, weight: .semibold))
                    .foregroundStyle(.white)
            }

            VStack(alignment: .leading, spacing: 1) {
                Text("PingGlass")
                    .font(.headline)
                    .foregroundStyle(.primary)
                Text(appState.lifecycleState.displayTitle)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(stateColor)
            }

            Spacer()

            Button {
                activeTab = .settings
            } label: {
                Image(systemName: "gearshape.fill")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.primary)
                    .frame(width: 28, height: 28)
                    .background(controlSurfaceColor, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .stroke(controlBorderColor, lineWidth: 1)
                    )
            }
            .buttonStyle(.plain)
            .help("Open Settings")
        }
    }

    private var statusRowsSection: some View {
        VStack(alignment: .leading, spacing: 7) {
            StatusRow(
                label: "WhatsApp Desktop",
                value: whatsappValueText,
                dotColor: whatsappDetector.currentProcess != nil ? .green : .gray
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
                dotColor: appState.connectedBridgeClients > 0 ? .green : .gray
            )
            StatusRow(
                label: "Detection Mode",
                value: appState.extractionMode,
                dotColor: appState.observerAttached ? .green : (appState.fallbackPollingActive ? .yellow : .gray)
            )
            StatusRow(
                label: "Session Messages",
                value: "\(appState.sessionMessagesForwarded) message\(appState.sessionMessagesForwarded == 1 ? "" : "s")",
                dotColor: .blue
            )

            Text(appState.statusDetail)
                .font(.caption2)
                .foregroundStyle(.primary.opacity(0.75))
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 2)
        }
        .padding(10)
        .background(secondarySurfaceColor, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(controlBorderColor.opacity(0.65), lineWidth: 1)
        )
    }

    private var accessibilityRecoveryCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Accessibility Access Needed")
                .font(.caption.bold())
                .foregroundStyle(.orange)
            Text("Enable PingGlass in System Settings → Privacy & Security → Accessibility to observe WhatsApp UI changes.")
                .font(.caption2)
                .foregroundStyle(.primary.opacity(0.85))
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                Button {
                    permissionManager.requestAccessibilityPrompt()
                } label: {
                    Text("Request Prompt")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.primary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(controlSurfaceColor, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
                .buttonStyle(.plain)

                Button {
                    permissionManager.openAccessibilitySettings()
                } label: {
                    Text("Open Settings")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(10)
        .background(Color.orange.opacity(0.16), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.orange.opacity(0.45), lineWidth: 1)
        )
    }

    private var whatsappRecoveryBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "info.circle.fill")
                .foregroundStyle(.primary.opacity(0.8))
            Text("Open WhatsApp Desktop to monitor messages. You can still test global notifications right now.")
                .font(.caption2)
                .foregroundStyle(.primary.opacity(0.85))
        }
        .padding(9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(secondarySurfaceColor, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    }

    private var controlsSection: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                // High-contrast solid fill avoids washed-out orange/yellow system tints over wallpaper.
                Button {
                    appState.toggleMonitoring()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: appState.config.monitoringEnabled ? "pause.fill" : "play.fill")
                            .font(.system(size: 11.5, weight: .bold))
                        Text(appState.config.monitoringEnabled ? "Stop Monitoring" : "Start Monitoring")
                            .font(.system(size: 12.5, weight: .semibold))
                    }
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 32)
                    .background(
                        appState.config.monitoringEnabled
                            ? Color(red: 0.84, green: 0.34, blue: 0.06)
                            : Color(red: 0.09, green: 0.58, blue: 0.29),
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(Color.white.opacity(0.22), lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)

                Button {
                    appState.sendTestNotification()
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "sparkles")
                            .font(.system(size: 11.5, weight: .semibold))
                        Text("Test")
                            .font(.system(size: 12.5, weight: .semibold))
                    }
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 14)
                    .frame(height: 32)
                    .background(controlSurfaceColor, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(controlBorderColor, lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)
                .help("Show a global floating test glass notification")
            }

            HStack(spacing: 8) {
                Button {
                    appState.clearAllNotifications()
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 11, weight: .semibold))
                        Text(
                            appState.totalActiveAndQueuedNotifications > 0
                                ? "Clear All (\(appState.totalActiveAndQueuedNotifications))"
                                : "Clear All"
                        )
                        .font(.system(size: 12, weight: .semibold))
                    }
                    .foregroundStyle(appState.totalActiveAndQueuedNotifications > 0 ? .white : .primary.opacity(0.55))
                    .frame(maxWidth: .infinity)
                    .frame(height: 29)
                    .background(
                        appState.totalActiveAndQueuedNotifications > 0
                            ? Color(red: 0.80, green: 0.20, blue: 0.20)
                            : secondarySurfaceColor,
                        in: RoundedRectangle(cornerRadius: 7, style: .continuous)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .stroke(
                                appState.totalActiveAndQueuedNotifications > 0
                                    ? Color.white.opacity(0.20)
                                    : controlBorderColor.opacity(0.6),
                                lineWidth: 1
                            )
                    )
                }
                .buttonStyle(.plain)
                .disabled(appState.totalActiveAndQueuedNotifications == 0)

                if appState.isNotificationsPaused {
                    Button {
                        appState.resumeNotifications()
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "bell.fill")
                                .font(.system(size: 11, weight: .semibold))
                            Text("Resume")
                                .font(.system(size: 12, weight: .semibold))
                        }
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 29)
                        .background(Color(red: 0.14, green: 0.46, blue: 0.88), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                    }
                    .buttonStyle(.plain)
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
                        HStack(spacing: 5) {
                            Image(systemName: "bell.slash")
                                .font(.system(size: 11, weight: .semibold))
                            Text("Pause")
                                .font(.system(size: 12, weight: .semibold))
                        }
                        .foregroundStyle(.primary)
                        .frame(maxWidth: .infinity)
                        .frame(height: 29)
                        .background(controlSurfaceColor, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .stroke(controlBorderColor, lineWidth: 1)
                        )
                    }
                    .menuStyle(.borderlessButton)
                }

                Button {
                    activeTab = .settings
                } label: {
                    Text("Settings")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.primary)
                        .padding(.horizontal, 12)
                        .frame(height: 29)
                        .background(controlSurfaceColor, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .stroke(controlBorderColor, lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)
            }

            HStack {
                Button {
                    appState.refreshAll()
                } label: {
                    Label("Refresh Status", systemImage: "arrow.clockwise")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.primary.opacity(0.85))
                }
                .buttonStyle(.plain)

                Spacer()

                Button {
                    NSApp.terminate(nil)
                } label: {
                    Text("Quit PingGlass")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(
                            colorScheme == .dark
                                ? Color(red: 1.0, green: 0.45, blue: 0.45)
                                : Color(red: 0.78, green: 0.14, blue: 0.14)
                        )
                }
                .buttonStyle(.plain)
            }
            .padding(.top, 2)
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
            return Color(red: 0.28, green: 0.90, blue: 0.48)
        case .monitoringLimited:
            return Color(red: 1.0, green: 0.74, blue: 0.25)
        case .accessibilityRequired:
            return Color(red: 1.0, green: 0.65, blue: 0.25)
        case .error:
            return Color(red: 1.0, green: 0.45, blue: 0.45)
        case .whatsappDetected:
            return Color(red: 0.42, green: 0.72, blue: 1.0)
        case .whatsappNotRunning:
            return .primary.opacity(0.70)
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
                .foregroundStyle(.primary.opacity(0.72))
            Spacer()
            Text(value)
                .font(.caption.weight(.medium))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
    }
}
