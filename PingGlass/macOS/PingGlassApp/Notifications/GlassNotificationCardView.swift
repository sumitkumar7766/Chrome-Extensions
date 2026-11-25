import AppKit
import SwiftUI

/// Shared native macOS Liquid Glass backdrop:
/// combines `NSVisualEffectView` (`.behindWindow`) with a balanced neutral charcoal tint,
/// crisp semi-transparent white border, and a subtle left-edge green accent glow.
final class LiquidGlassBackdropView: NSView {
    private let visualEffectView = NSVisualEffectView()
    private let tintLayer = CALayer()
    private let leftEdgeAccentLayer = CAGradientLayer()
    private let specularTopLayer = CAGradientLayer()
    private let borderLayer = CALayer()

    private let cornerRadiusValue: CGFloat
    private let showLeftAccent: Bool
    private var isHovered = false

    init(cornerRadius: CGFloat, showLeftAccent: Bool = true) {
        self.cornerRadiusValue = cornerRadius
        self.showLeftAccent = showLeftAccent
        super.init(frame: .zero)

        wantsLayer = true
        layer?.cornerRadius = cornerRadius
        layer?.masksToBounds = true
        layer?.backgroundColor = NSColor.clear.cgColor

        visualEffectView.translatesAutoresizingMaskIntoConstraints = false
        visualEffectView.blendingMode = .behindWindow
        visualEffectView.state = .active
        visualEffectView.wantsLayer = true
        visualEffectView.layer?.cornerRadius = cornerRadius
        visualEffectView.layer?.masksToBounds = true

        addSubview(visualEffectView)
        NSLayoutConstraint.activate([
            visualEffectView.leadingAnchor.constraint(equalTo: leadingAnchor),
            visualEffectView.trailingAnchor.constraint(equalTo: trailingAnchor),
            visualEffectView.topAnchor.constraint(equalTo: topAnchor),
            visualEffectView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        tintLayer.cornerRadius = cornerRadius
        layer?.addSublayer(tintLayer)

        if showLeftAccent {
            leftEdgeAccentLayer.cornerRadius = cornerRadius
            leftEdgeAccentLayer.type = .radial
            leftEdgeAccentLayer.startPoint = CGPoint(x: 0.0, y: 0.58)
            leftEdgeAccentLayer.endPoint = CGPoint(x: 0.22, y: 0.58)
            layer?.addSublayer(leftEdgeAccentLayer)
        }

        specularTopLayer.cornerRadius = cornerRadius
        specularTopLayer.startPoint = CGPoint(x: 0.5, y: 1.0)
        specularTopLayer.endPoint = CGPoint(x: 0.5, y: 0.80)
        layer?.addSublayer(specularTopLayer)

        borderLayer.cornerRadius = cornerRadius
        borderLayer.borderWidth = 1.0
        layer?.addSublayer(borderLayer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        tintLayer.frame = bounds
        if showLeftAccent {
            leftEdgeAccentLayer.frame = bounds
        }
        specularTopLayer.frame = bounds
        borderLayer.frame = bounds
    }

    func apply(config: HelperConfiguration, hovered: Bool = false) {
        isHovered = hovered

        let isDark = config.appearanceMode == .dark
        let blurEnabled = config.nativeGlassBlurEnabled
        visualEffectView.isHidden = !blurEnabled

        CATransaction.begin()
        CATransaction.setDisableActions(false)
        CATransaction.setAnimationDuration(0.14)

        if isDark {
            appearance = NSAppearance(named: .darkAqua)
            visualEffectView.material = .hudWindow
            let tintAlpha: CGFloat = blurEnabled ? (hovered ? 0.54 : 0.46) : 0.92
            tintLayer.backgroundColor = NSColor(red: 0.08, green: 0.09, blue: 0.11, alpha: tintAlpha).cgColor
            if showLeftAccent {
                leftEdgeAccentLayer.colors = [
                    NSColor(red: 0.145, green: 0.827, blue: 0.400, alpha: hovered ? 0.30 : 0.22).cgColor,
                    NSColor.clear.cgColor,
                ]
            }
            specularTopLayer.colors = [
                NSColor.white.withAlphaComponent(hovered ? 0.14 : 0.09).cgColor,
                NSColor.clear.cgColor,
            ]
            borderLayer.borderColor = NSColor.white.withAlphaComponent(hovered ? 0.36 : 0.24).cgColor
        } else {
            appearance = NSAppearance(named: .aqua)
            visualEffectView.material = .popover
            let tintAlpha: CGFloat = blurEnabled ? (hovered ? 0.78 : 0.70) : 0.95
            tintLayer.backgroundColor = NSColor(red: 0.96, green: 0.97, blue: 0.985, alpha: tintAlpha).cgColor
            if showLeftAccent {
                leftEdgeAccentLayer.colors = [
                    NSColor(red: 0.145, green: 0.827, blue: 0.400, alpha: hovered ? 0.18 : 0.12).cgColor,
                    NSColor.clear.cgColor,
                ]
            }
            specularTopLayer.colors = [
                NSColor.white.withAlphaComponent(0.55).cgColor,
                NSColor.clear.cgColor,
            ]
            borderLayer.borderColor = NSColor.black.withAlphaComponent(hovered ? 0.20 : 0.12).cgColor
        }

        CATransaction.commit()
    }
}

/// Crisp WhatsApp badge matching the rounded green phone-bubble icon style.
struct WhatsAppBadgeIcon: View {
    var size: CGFloat = 18

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                .fill(Color(red: 0.145, green: 0.827, blue: 0.400))
                .frame(width: size, height: size)
            Image(systemName: "phone.bubble.fill")
                .font(.system(size: size * 0.56, weight: .bold))
                .foregroundStyle(.white)
        }
    }
}

/// Compact bordered square SF Symbol button matching the glass header controls.
struct GlassIconActionButton: View {
    let systemName: String
    let tooltip: String
    let isDark: Bool
    var tintColor: Color? = nil
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(foreground)
                .frame(width: 22, height: 22)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(backgroundColor)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .stroke(borderColor, lineWidth: 0.75)
                )
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.14)) {
                isHovering = hovering
            }
        }
        .help(tooltip)
    }

    private var foreground: Color {
        if let tintColor { return tintColor }
        if isDark {
            return Color.white.opacity(isHovering ? 1.0 : 0.82)
        }
        return Color(red: 0.08, green: 0.11, blue: 0.17).opacity(isHovering ? 0.96 : 0.75)
    }

    private var backgroundColor: Color {
        if isDark {
            return Color.white.opacity(isHovering ? 0.20 : 0.10)
        }
        return Color.black.opacity(isHovering ? 0.12 : 0.05)
    }

    private var borderColor: Color {
        if isDark {
            return Color.white.opacity(isHovering ? 0.34 : 0.18)
        }
        return Color.black.opacity(isHovering ? 0.20 : 0.10)
    }
}

/// Compact AppKit wrapper hosting native Liquid Glass notification cards (`318px` wide).
final class GlassNotificationCardView: NSView {
    static let cardWidth: CGFloat = 318.0
    static let minCardHeight: CGFloat = 78.0
    static let maxCardHeight: CGFloat = 230.0
    static let cornerRadius: CGFloat = 18.0

    private let backdropView = LiquidGlassBackdropView(cornerRadius: GlassNotificationCardView.cornerRadius, showLeftAccent: true)
    private let hostingView: NSHostingView<NotificationCardContentView>
    private var trackingArea: NSTrackingArea?
    private var latestConfig: HelperConfiguration

    private let onHoverChanged: (Bool) -> Void

    init(
        message: WhatsAppMessage,
        config: HelperConfiguration,
        onCardClick: @escaping () -> Void,
        onCopy: @escaping () -> Void,
        onOpenWhatsApp: @escaping () -> Void,
        onDismiss: @escaping () -> Void,
        onToggleExpand: @escaping () -> Void,
        onHoverChanged: @escaping (Bool) -> Void
    ) {
        self.latestConfig = config
        self.onHoverChanged = onHoverChanged
        let content = NotificationCardContentView(
            message: message,
            config: config,
            onCardClick: onCardClick,
            onCopy: onCopy,
            onOpenWhatsApp: onOpenWhatsApp,
            onDismiss: onDismiss,
            onToggleExpand: onToggleExpand
        )
        self.hostingView = NSHostingView(rootView: content)
        super.init(frame: NSRect(x: 0, y: 0, width: Self.cardWidth, height: 96))

        wantsLayer = true
        layer?.cornerRadius = Self.cornerRadius
        layer?.masksToBounds = true
        layer?.backgroundColor = NSColor.clear.cgColor

        backdropView.translatesAutoresizingMaskIntoConstraints = false
        hostingView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(backdropView)
        addSubview(hostingView)

        NSLayoutConstraint.activate([
            backdropView.leadingAnchor.constraint(equalTo: leadingAnchor),
            backdropView.trailingAnchor.constraint(equalTo: trailingAnchor),
            backdropView.topAnchor.constraint(equalTo: topAnchor),
            backdropView.bottomAnchor.constraint(equalTo: bottomAnchor),

            hostingView.leadingAnchor.constraint(equalTo: leadingAnchor),
            hostingView.trailingAnchor.constraint(equalTo: trailingAnchor),
            hostingView.topAnchor.constraint(equalTo: topAnchor),
            hostingView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        applyAppearance(config: config)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        backdropView.apply(config: latestConfig, hovered: true)
        onHoverChanged(true)
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        backdropView.apply(config: latestConfig, hovered: false)
        onHoverChanged(false)
    }

    func applyAppearance(config: HelperConfiguration) {
        latestConfig = config
        appearance = NSAppearance(named: config.appearanceMode == .dark ? .darkAqua : .aqua)
        backdropView.apply(config: config, hovered: false)
    }

    func preferredSize() -> CGSize {
        hostingView.layoutSubtreeIfNeeded()
        let fitting = hostingView.fittingSize
        let height = min(Self.maxCardHeight, max(Self.minCardHeight, ceil(fitting.height)))
        return CGSize(width: Self.cardWidth, height: height)
    }
}

/// Compact Liquid Glass card layout matching the reference screenshot.
private struct NotificationCardContentView: View {
    let message: WhatsAppMessage
    let config: HelperConfiguration
    let onCardClick: () -> Void
    let onCopy: () -> Void
    let onOpenWhatsApp: () -> Void
    let onDismiss: () -> Void
    let onToggleExpand: () -> Void

    @State private var showCopiedState = false
    @State private var isExpanded = false

    private var isDark: Bool { config.appearanceMode == .dark }
    private var primaryText: Color {
        isDark ? .white : Color(red: 0.06, green: 0.08, blue: 0.13)
    }
    private var messageTextColor: Color {
        isDark ? Color.white.opacity(0.90) : Color(red: 0.14, green: 0.17, blue: 0.24)
    }
    private var secondaryText: Color {
        isDark ? Color.white.opacity(0.62) : Color(red: 0.36, green: 0.40, blue: 0.49)
    }
    private var mutedText: Color {
        isDark ? Color.white.opacity(0.55) : Color(red: 0.45, green: 0.49, blue: 0.58)
    }
    private var whatsappGreen: Color {
        Color(red: 0.145, green: 0.827, blue: 0.400)
    }

    private var displaySender: String {
        if let sender = message.sender, !sender.isEmpty {
            return sender
        }
        if let chatName = message.chatName, !chatName.isEmpty {
            return chatName
        }
        return "WhatsApp Message"
    }

    private var contextSubtitle: String? {
        guard config.showChatName,
              let chatName = message.chatName,
              !chatName.isEmpty,
              chatName.caseInsensitiveCompare(displaySender) != .orderedSame else {
            return nil
        }
        return chatName
    }

    private var canExpandPreview: Bool {
        guard let text = message.text else { return false }
        return text.count > 140 || text.components(separatedBy: "\n").count > 4
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            headerRow

            HStack(alignment: .top, spacing: 10) {
                if config.showAvatar {
                    avatarView
                        .padding(.top, 2)

                    Rectangle()
                        .fill(isDark ? Color.white.opacity(0.14) : Color.black.opacity(0.10))
                        .frame(width: 1)
                        .padding(.vertical, 2)
                }

                VStack(alignment: .leading, spacing: 2) {
                    if config.showSender {
                        Text(displaySender)
                            .font(.system(size: 14.5, weight: .semibold))
                            .foregroundStyle(primaryText)
                            .lineLimit(1)
                    }

                    if let contextSubtitle {
                        Text(contextSubtitle)
                            .font(.system(size: 11.5, weight: .regular))
                            .foregroundStyle(secondaryText)
                            .lineLimit(1)
                    }

                    if config.showPreview, let text = message.text, !text.isEmpty {
                        Text(text)
                            .font(.system(size: 12.5, weight: .regular))
                            .lineSpacing(2.0)
                            .foregroundStyle(messageTextColor)
                            .lineLimit(isExpanded ? 8 : 4)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.top, 2)

                        if canExpandPreview {
                            Button(isExpanded ? "Show less" : "Show more") {
                                isExpanded.toggle()
                                DispatchQueue.main.async {
                                    onToggleExpand()
                                }
                            }
                            .buttonStyle(.plain)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(whatsappGreen)
                            .padding(.top, 1)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .contentShape(Rectangle())
            .onTapGesture {
                onCardClick()
            }
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 10)
        .frame(width: GlassNotificationCardView.cardWidth, alignment: .leading)
    }

    private var headerRow: some View {
        HStack(spacing: 6) {
            HStack(spacing: 6) {
                WhatsAppBadgeIcon(size: 17)

                Text("WhatsApp")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(primaryText.opacity(0.92))

                if message.isTest {
                    Text("TEST")
                        .font(.system(size: 8.5, weight: .bold))
                        .tracking(0.3)
                        .foregroundStyle(whatsappGreen)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1.5)
                        .background(whatsappGreen.opacity(0.20), in: Capsule())
                }
            }
            .contentShape(Rectangle())
            .onTapGesture {
                onCardClick()
            }

            Spacer(minLength: 4)

            if showCopiedState {
                Text("Copied ✓")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(whatsappGreen)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1.5)
                    .background(whatsappGreen.opacity(0.16), in: Capsule())
                    .transition(.opacity)
            } else if config.showTimestamp {
                Text(message.timestamp ?? "NOW")
                    .font(.system(size: 11, weight: .regular))
                    .foregroundStyle(mutedText)
            }

            HStack(spacing: 4) {
                GlassIconActionButton(
                    systemName: "arrow.up.forward.square",
                    tooltip: "Open in WhatsApp",
                    isDark: isDark,
                    action: onOpenWhatsApp
                )

                if config.showCopyButton, let text = message.text, !text.isEmpty {
                    GlassIconActionButton(
                        systemName: showCopiedState ? "checkmark" : "doc.on.doc",
                        tooltip: "Copy message",
                        isDark: isDark,
                        tintColor: showCopiedState ? whatsappGreen : nil
                    ) {
                        onCopy()
                        withAnimation(.easeOut(duration: 0.16)) {
                            showCopiedState = true
                        }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) {
                            withAnimation(.easeIn(duration: 0.18)) {
                                showCopiedState = false
                            }
                        }
                    }
                }

                GlassIconActionButton(
                    systemName: "xmark",
                    tooltip: "Dismiss notification",
                    isDark: isDark,
                    action: onDismiss
                )
            }
        }
    }

    @ViewBuilder
    private var avatarView: some View {
        if let nsImage = decodeAvatarImage(message.avatar) {
            Image(nsImage: nsImage)
                .resizable()
                .scaledToFill()
                .frame(width: 34, height: 34)
                .clipShape(Circle())
                .overlay(Circle().stroke(whatsappGreen, lineWidth: 1.25))
        } else {
            ZStack {
                Circle()
                    .fill(isDark ? Color.black.opacity(0.26) : whatsappGreen.opacity(0.14))
                Text(initials(from: displaySender))
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(isDark ? .white : Color(red: 0.04, green: 0.42, blue: 0.22))
            }
            .frame(width: 34, height: 34)
            .overlay(Circle().stroke(whatsappGreen, lineWidth: 1.25))
        }
    }

    private func initials(from name: String) -> String {
        let parts = name.split(whereSeparator: { $0.isWhitespace })
        if parts.isEmpty { return "WA" }
        if parts.count == 1 { return String(parts[0].prefix(2)).uppercased() }
        let first = parts.first?.first.map(String.init) ?? ""
        let last = parts.last?.first.map(String.init) ?? ""
        return (first + last).uppercased()
    }

    private func decodeAvatarImage(_ dataURI: String?) -> NSImage? {
        guard let dataURI,
              let commaIdx = dataURI.firstIndex(of: ",") else {
            return nil
        }
        let base64 = String(dataURI[dataURI.index(after: commaIdx)...])
        guard let data = Data(base64Encoded: base64) else { return nil }
        return NSImage(data: data)
    }
}

/// Compact neutral dark glass "Clear All" pill aligned above/below the notification stack.
final class ClearAllGlassPillView: NSView {
    private let backdropView = LiquidGlassBackdropView(cornerRadius: 13, showLeftAccent: false)
    private let hostingView: NSHostingView<ClearAllPillContent>
    private var trackingArea: NSTrackingArea?
    private var latestConfig: HelperConfiguration

    init(totalCount: Int, config: HelperConfiguration, onClearAll: @escaping () -> Void) {
        self.latestConfig = config
        self.hostingView = NSHostingView(
            rootView: ClearAllPillContent(totalCount: totalCount, config: config, isHovered: false, onClearAll: onClearAll)
        )
        super.init(frame: NSRect(x: 0, y: 0, width: 96, height: 26))

        wantsLayer = true
        layer?.cornerRadius = 13
        layer?.masksToBounds = true
        layer?.backgroundColor = NSColor.clear.cgColor

        backdropView.translatesAutoresizingMaskIntoConstraints = false
        hostingView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(backdropView)
        addSubview(hostingView)

        NSLayoutConstraint.activate([
            backdropView.leadingAnchor.constraint(equalTo: leadingAnchor),
            backdropView.trailingAnchor.constraint(equalTo: trailingAnchor),
            backdropView.topAnchor.constraint(equalTo: topAnchor),
            backdropView.bottomAnchor.constraint(equalTo: bottomAnchor),

            hostingView.leadingAnchor.constraint(equalTo: leadingAnchor),
            hostingView.trailingAnchor.constraint(equalTo: trailingAnchor),
            hostingView.topAnchor.constraint(equalTo: topAnchor),
            hostingView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        update(totalCount: totalCount, config: config, onClearAll: onClearAll)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        backdropView.apply(config: latestConfig, hovered: true)
        let current = hostingView.rootView
        hostingView.rootView = ClearAllPillContent(
            totalCount: current.totalCount,
            config: latestConfig,
            isHovered: true,
            onClearAll: current.onClearAll
        )
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        backdropView.apply(config: latestConfig, hovered: false)
        let current = hostingView.rootView
        hostingView.rootView = ClearAllPillContent(
            totalCount: current.totalCount,
            config: latestConfig,
            isHovered: false,
            onClearAll: current.onClearAll
        )
    }

    func update(totalCount: Int, config: HelperConfiguration, onClearAll: @escaping () -> Void) {
        latestConfig = config
        appearance = NSAppearance(named: config.appearanceMode == .dark ? .darkAqua : .aqua)
        backdropView.apply(config: config, hovered: false)
        hostingView.rootView = ClearAllPillContent(
            totalCount: totalCount,
            config: config,
            isHovered: false,
            onClearAll: onClearAll
        )
    }

    func preferredSize() -> CGSize {
        hostingView.layoutSubtreeIfNeeded()
        let fitting = hostingView.fittingSize
        return CGSize(width: max(86, ceil(fitting.width)), height: 26)
    }
}

private struct ClearAllPillContent: View {
    let totalCount: Int
    let config: HelperConfiguration
    let isHovered: Bool
    let onClearAll: () -> Void

    private var isDark: Bool { config.appearanceMode == .dark }
    private var whatsappGreen: Color { Color(red: 0.145, green: 0.827, blue: 0.400) }

    var body: some View {
        Button(action: onClearAll) {
            HStack(spacing: 5) {
                Image(systemName: "square.3.layers.3d")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(isHovered ? whatsappGreen : textColor)
                Text(totalCount > 1 ? "Clear All (\(totalCount))" : "Clear All")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(textColor)
            }
            .padding(.horizontal, 11)
            .frame(height: 26)
            .background(
                Capsule()
                    .fill(isHovered ? whatsappGreen.opacity(0.14) : Color.clear)
            )
            .overlay(
                Capsule()
                    .stroke(isHovered ? whatsappGreen.opacity(0.38) : Color.clear, lineWidth: 1)
            )
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help("Dismiss all notifications")
    }

    private var textColor: Color {
        if isDark {
            return Color.white.opacity(isHovered ? 1.0 : 0.90)
        }
        return Color(red: 0.08, green: 0.11, blue: 0.17).opacity(isHovered ? 0.96 : 0.85)
    }
}
