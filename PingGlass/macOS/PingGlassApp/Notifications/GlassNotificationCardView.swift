import AppKit
import SwiftUI

/// Shared native macOS Liquid Glass backdrop:
/// combines `NSVisualEffectView` (`.behindWindow`) with a neutral graphite/charcoal tint overlay
/// so colorful or warm wallpapers never create a muddy brown/yellow cast.
final class LiquidGlassBackdropView: NSView {
    private let visualEffectView = NSVisualEffectView()
    private let tintLayer = CALayer()
    private let ambientAccentLayer = CAGradientLayer()
    private let specularTopLayer = CAGradientLayer()
    private let borderLayer = CALayer()

    private let cornerRadiusValue: CGFloat
    private var lastConfig: HelperConfiguration?
    private var isHovered = false

    init(cornerRadius: CGFloat) {
        self.cornerRadiusValue = cornerRadius
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

        ambientAccentLayer.cornerRadius = cornerRadius
        ambientAccentLayer.type = .radial
        ambientAccentLayer.startPoint = CGPoint(x: 0.08, y: 0.92)
        ambientAccentLayer.endPoint = CGPoint(x: 0.65, y: 0.25)
        layer?.addSublayer(ambientAccentLayer)

        specularTopLayer.cornerRadius = cornerRadius
        specularTopLayer.startPoint = CGPoint(x: 0.5, y: 1.0)
        specularTopLayer.endPoint = CGPoint(x: 0.5, y: 0.72)
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
        ambientAccentLayer.frame = bounds
        specularTopLayer.frame = bounds
        borderLayer.frame = bounds
    }

    func apply(config: HelperConfiguration, hovered: Bool = false) {
        lastConfig = config
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
            // Neutral smoked charcoal graphite tint prevents warm/yellow wallpaper bleed.
            let tintAlpha: CGFloat = blurEnabled ? (hovered ? 0.66 : 0.58) : 0.93
            tintLayer.backgroundColor = NSColor(red: 0.082, green: 0.090, blue: 0.106, alpha: tintAlpha).cgColor
            ambientAccentLayer.colors = [
                NSColor(red: 0.145, green: 0.827, blue: 0.400, alpha: hovered ? 0.08 : 0.05).cgColor,
                NSColor.clear.cgColor,
            ]
            specularTopLayer.colors = [
                NSColor.white.withAlphaComponent(hovered ? 0.09 : 0.06).cgColor,
                NSColor.clear.cgColor,
            ]
            borderLayer.borderColor = NSColor.white.withAlphaComponent(hovered ? 0.24 : 0.14).cgColor
        } else {
            appearance = NSAppearance(named: .aqua)
            visualEffectView.material = .popover
            let tintAlpha: CGFloat = blurEnabled ? (hovered ? 0.78 : 0.70) : 0.95
            tintLayer.backgroundColor = NSColor(red: 0.96, green: 0.97, blue: 0.985, alpha: tintAlpha).cgColor
            ambientAccentLayer.colors = [
                NSColor(red: 0.145, green: 0.827, blue: 0.400, alpha: hovered ? 0.07 : 0.04).cgColor,
                NSColor.clear.cgColor,
            ]
            specularTopLayer.colors = [
                NSColor.white.withAlphaComponent(0.55).cgColor,
                NSColor.clear.cgColor,
            ]
            borderLayer.borderColor = NSColor.black.withAlphaComponent(hovered ? 0.16 : 0.09).cgColor
        }

        CATransaction.commit()
    }
}

/// Shared SF Symbol button with subtle hover highlight and tooltip.
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
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(foreground)
                .frame(width: 24, height: 24)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(hoverBackground)
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
            return Color.white.opacity(isHovering ? 0.96 : 0.56)
        }
        return Color(red: 0.08, green: 0.11, blue: 0.17).opacity(isHovering ? 0.95 : 0.55)
    }

    private var hoverBackground: Color {
        guard isHovering else { return .clear }
        return isDark ? Color.white.opacity(0.12) : Color.black.opacity(0.08)
    }
}

/// AppKit wrapper providing reliable hover tracking across inactive background windows,
/// native Liquid Glass blur, rounded 24px corners, and SwiftUI card content.
final class GlassNotificationCardView: NSView {
    static let cardWidth: CGFloat = 356.0
    static let minCardHeight: CGFloat = 96.0
    static let maxCardHeight: CGFloat = 310.0
    static let cornerRadius: CGFloat = 24.0

    private let backdropView = LiquidGlassBackdropView(cornerRadius: GlassNotificationCardView.cornerRadius)
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
        super.init(frame: NSRect(x: 0, y: 0, width: Self.cardWidth, height: 120))

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
        // `.activeAlways` ensures hover clarity & timer pause work over any active macOS app.
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

/// Refined macOS Liquid Glass SwiftUI layout rendered inside `GlassNotificationCardView`.
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
        isDark ? Color(white: 0.96) : Color(red: 0.06, green: 0.08, blue: 0.13)
    }
    private var messageTextColor: Color {
        isDark ? Color.white.opacity(0.88) : Color(red: 0.14, green: 0.17, blue: 0.24)
    }
    private var secondaryText: Color {
        isDark ? Color.white.opacity(0.58) : Color(red: 0.36, green: 0.40, blue: 0.49)
    }
    private var mutedText: Color {
        isDark ? Color.white.opacity(0.48) : Color(red: 0.45, green: 0.49, blue: 0.58)
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
              chatName != displaySender else {
            return nil
        }
        return chatName
    }

    private var canExpandPreview: Bool {
        guard let text = message.text else { return false }
        return text.count > 160 || text.components(separatedBy: "\n").count > 4
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            headerRow

            VStack(alignment: .leading, spacing: 10) {
                senderSection
                messageBodySection
            }
            .contentShape(Rectangle())
            .onTapGesture {
                onCardClick()
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(width: GlassNotificationCardView.cardWidth, alignment: .leading)
    }

    private var headerRow: some View {
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                ZStack {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(whatsappGreen.opacity(isDark ? 0.16 : 0.14))
                        .frame(width: 20, height: 20)
                    Image(systemName: "message.fill")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(whatsappGreen)
                }

                Text("WhatsApp")
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(secondaryText)

                if message.isTest {
                    Text("TEST")
                        .font(.system(size: 9, weight: .bold))
                        .tracking(0.4)
                        .foregroundStyle(whatsappGreen.opacity(0.95))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(whatsappGreen.opacity(0.14), in: Capsule())
                        .overlay(Capsule().stroke(whatsappGreen.opacity(0.28), lineWidth: 0.5))
                }
            }
            .contentShape(Rectangle())
            .onTapGesture {
                onCardClick()
            }

            Spacer(minLength: 6)

            if showCopiedState {
                Text("Copied")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(whatsappGreen)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(whatsappGreen.opacity(0.14), in: Capsule())
                    .transition(.opacity)
            } else if config.showTimestamp {
                Text(message.timestamp ?? "NOW")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(mutedText)
            }

            HStack(spacing: 3) {
                GlassIconActionButton(
                    systemName: "arrow.up.forward.app",
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

    private var senderSection: some View {
        HStack(alignment: .center, spacing: 11) {
            if config.showAvatar {
                avatarView
            }

            VStack(alignment: .leading, spacing: 2) {
                if config.showSender {
                    Text(displaySender)
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(primaryText)
                        .lineLimit(1)
                }

                if let contextSubtitle {
                    Text(contextSubtitle)
                        .font(.system(size: 13, weight: .regular))
                        .foregroundStyle(secondaryText)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private var messageBodySection: some View {
        if config.showPreview, let text = message.text, !text.isEmpty {
            VStack(alignment: .leading, spacing: 5) {
                Text(text)
                    .font(.system(size: 15.5, weight: .regular))
                    .lineSpacing(3.0)
                    .foregroundStyle(messageTextColor)
                    .lineLimit(isExpanded ? 10 : 5)
                    .fixedSize(horizontal: false, vertical: true)

                if canExpandPreview {
                    Button(isExpanded ? "Show less" : "Show more") {
                        isExpanded.toggle()
                        DispatchQueue.main.async {
                            onToggleExpand()
                        }
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(whatsappGreen.opacity(0.92))
                }
            }
        }
    }

    @ViewBuilder
    private var avatarView: some View {
        if let nsImage = decodeAvatarImage(message.avatar) {
            Image(nsImage: nsImage)
                .resizable()
                .scaledToFill()
                .frame(width: 40, height: 40)
                .clipShape(Circle())
                .overlay(Circle().stroke(whatsappGreen.opacity(0.32), lineWidth: 1))
        } else {
            ZStack {
                Circle()
                    .fill(whatsappGreen.opacity(isDark ? 0.16 : 0.14))
                Text(initials(from: displaySender))
                    .font(.system(size: 14.5, weight: .semibold))
                    .foregroundStyle(isDark ? Color.white.opacity(0.94) : Color(red: 0.04, green: 0.42, blue: 0.22))
            }
            .frame(width: 40, height: 40)
            .overlay(Circle().stroke(whatsappGreen.opacity(0.30), lineWidth: 1))
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

/// Neutral dark glass "Clear All" pill aligned cleanly with the notification stack.
final class ClearAllGlassPillView: NSView {
    private let backdropView = LiquidGlassBackdropView(cornerRadius: 15)
    private let hostingView: NSHostingView<ClearAllPillContent>
    private var trackingArea: NSTrackingArea?
    private var latestConfig: HelperConfiguration

    init(totalCount: Int, config: HelperConfiguration, onClearAll: @escaping () -> Void) {
        self.latestConfig = config
        self.hostingView = NSHostingView(
            rootView: ClearAllPillContent(totalCount: totalCount, config: config, isHovered: false, onClearAll: onClearAll)
        )
        super.init(frame: NSRect(x: 0, y: 0, width: 120, height: 30))

        wantsLayer = true
        layer?.cornerRadius = 15
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
        return CGSize(width: max(98, ceil(fitting.width)), height: 30)
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
                Image(systemName: "xmark.circle")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(isHovered ? whatsappGreen : textColor)
                Text(totalCount > 1 ? "Clear All (\(totalCount))" : "Clear All")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(textColor)
            }
            .padding(.horizontal, 12)
            .frame(height: 30)
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
            return Color.white.opacity(isHovered ? 0.96 : 0.82)
        }
        return Color(red: 0.08, green: 0.11, blue: 0.17).opacity(isHovered ? 0.96 : 0.80)
    }
}
