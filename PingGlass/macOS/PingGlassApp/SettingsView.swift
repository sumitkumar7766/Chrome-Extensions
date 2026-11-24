import SwiftUI

/// Settings, global notification customization, privacy notice, and troubleshooting inside PingGlass.
struct SettingsView: View {
    @ObservedObject var appState: AppState
    @ObservedObject var launchAtLogin: LaunchAtLoginManager
    @ObservedObject var permissionManager: PermissionManager
    @Binding var activeTab: PopoverTab

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Button {
                    activeTab = .status
                } label: {
                    Label("Back", systemImage: "chevron.left")
                        .font(.caption.weight(.semibold))
                }
                .buttonStyle(.borderless)

                Spacer()

                Text("Settings & Privacy")
                    .font(.subheadline.bold())

                Spacer()
                Color.clear.frame(width: 44, height: 1)
            }

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    globalNotificationsSection
                    cardContentSection
                    monitoringSection
                    directionPolicySection
                    launchAtLoginSection
                    privacySection
                    troubleshootingSection
                }
                .padding(.trailing, 2)
            }
            .frame(maxHeight: 330)
        }
        .padding(11)
        .frame(width: 316)
    }

    private var globalNotificationsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Global Desktop Notifications")
                .font(.caption.bold())
                .foregroundStyle(.secondary)

            Toggle("Enable Global Desktop Notifications", isOn: $appState.config.globalNotificationsEnabled)
                .toggleStyle(.switch)
                .font(.caption)

            Toggle("Native macOS Glass Blur", isOn: $appState.config.nativeGlassBlurEnabled)
                .toggleStyle(.switch)
                .font(.caption)

            Toggle("Slide & Fade Animations", isOn: $appState.config.animationEnabled)
                .toggleStyle(.switch)
                .font(.caption)

            Toggle("Subtle Notification Sound", isOn: $appState.config.soundEnabled)
                .toggleStyle(.switch)
                .font(.caption)

            Picker("Appearance", selection: $appState.config.appearanceMode) {
                ForEach(GlassAppearanceMode.allCases, id: \.self) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            .font(.caption)

            Picker("Position", selection: $appState.config.notificationPosition) {
                ForEach(NotificationPosition.allCases, id: \.self) { pos in
                    Text(pos.displayName).tag(pos)
                }
            }
            .font(.caption)

            Picker("Display", selection: $appState.config.preferredDisplayMode) {
                ForEach(PreferredDisplayMode.allCases, id: \.self) { display in
                    Text(display.displayName).tag(display)
                }
            }
            .font(.caption)

            Picker("Auto-Dismiss", selection: $appState.config.notificationDurationSeconds) {
                ForEach(NotificationDurationOption.allCases, id: \.self) { opt in
                    Text(opt.displayName).tag(opt.rawValue)
                }
            }
            .font(.caption)

            Picker("On Card Click", selection: $appState.config.notificationClickAction) {
                ForEach(NotificationClickAction.allCases, id: \.self) { action in
                    Text(action.displayName).tag(action)
                }
            }
            .font(.caption)

            Stepper(
                "Max Visible Cards: \(appState.config.maxVisibleNotifications)",
                value: $appState.config.maxVisibleNotifications,
                in: 1...6
            )
            .font(.caption)

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Edge Margin")
                        .font(.caption)
                    Spacer()
                    Text("\(Int(appState.config.edgeMargin)) px")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Slider(value: $appState.config.edgeMargin, in: 12...48, step: 2)
            }
        }
        .padding(10)
        .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var cardContentSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Notification Card Elements")
                .font(.caption.bold())
                .foregroundStyle(.secondary)

            Toggle("Show Avatar / Initials", isOn: $appState.config.showAvatar).font(.caption)
            Toggle("Show Sender Name", isOn: $appState.config.showSender).font(.caption)
            Toggle("Show Chat Name", isOn: $appState.config.showChatName).font(.caption)
            Toggle("Show Timestamp", isOn: $appState.config.showTimestamp).font(.caption)
            Toggle("Show Message Preview", isOn: $appState.config.showPreview).font(.caption)
            Toggle("Show Copy Button", isOn: $appState.config.showCopyButton).font(.caption)
        }
        .padding(10)
        .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var monitoringSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Monitoring & Optional Chrome Bridge")
                .font(.caption.bold())
                .foregroundStyle(.secondary)

            Toggle("Enable WhatsApp Accessibility Monitoring", isOn: $appState.config.monitoringEnabled)
                .toggleStyle(.switch)
                .font(.caption)

            Toggle("Also Forward to Chrome Extension (Optional)", isOn: $appState.config.chromeForwardingEnabled)
                .toggleStyle(.switch)
                .font(.caption)

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Fallback Polling Interval")
                        .font(.caption)
                    Spacer()
                    Text(String(format: "%.1fs", appState.config.fallbackPollingIntervalSeconds))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Slider(
                    value: $appState.config.fallbackPollingIntervalSeconds,
                    in: 1.5...10.0,
                    step: 0.5
                )
            }

            Stepper(
                "Max Preview Length: \(appState.config.maxPreviewLength) chars",
                value: $appState.config.maxPreviewLength,
                in: 80...600,
                step: 40
            )
            .font(.caption)
        }
        .padding(10)
        .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var directionPolicySection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Uncertain Message Direction")
                .font(.caption.bold())
                .foregroundStyle(.secondary)

            Picker("Ambiguous Direction Policy", selection: $appState.config.ambiguousDirectionPolicy) {
                ForEach(AmbiguousDirectionPolicy.allCases, id: \.self) { policy in
                    Text(policy.title).tag(policy)
                }
            }
            .labelsHidden()
            .pickerStyle(.radioGroup)
            .font(.caption)

            Text(appState.config.ambiguousDirectionPolicy.description)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var launchAtLoginSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Startup")
                .font(.caption.bold())
                .foregroundStyle(.secondary)

            Toggle(
                "Launch PingGlass at Login",
                isOn: Binding(
                    get: { launchAtLogin.isEnabled },
                    set: { launchAtLogin.setEnabled($0) }
                )
            )
            .disabled(!launchAtLogin.isSupported)
            .font(.caption)

            if !launchAtLogin.statusNote.isEmpty {
                Text(launchAtLogin.statusNote)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(10)
        .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var privacySection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("Local-Only Privacy", systemImage: "lock.shield")
                .font(.caption.bold())
            Text("Notifications render natively on your Mac without Chrome or internet access. Messages stay strictly in memory, are never logged or saved to disk, and PingGlass never touches WhatsApp databases.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .background(Color.green.opacity(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var troubleshootingSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("macOS Behavior & Troubleshooting")
                .font(.caption.bold())
                .foregroundStyle(.secondary)

            Text("• Global floating cards appear above Chrome, VS Code, Finder, Terminal, and standard macOS apps without stealing focus.\n• Fullscreen Spaces: macOS permits auxiliary panels over standard fullscreen apps, though exclusive Metal/DRM fullscreen apps may hide overlays.\n• After rebuilding PingGlass.app, re-toggle Accessibility permission in System Settings if trust resets.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Button("Open Accessibility Settings") {
                permissionManager.openAccessibilitySettings()
            }
            .controlSize(.small)
        }
        .padding(10)
        .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}
