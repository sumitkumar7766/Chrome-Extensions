import AppKit
import SwiftUI

/// AppKit wrapper providing reliable hover tracking across inactive background windows,
/// native `NSVisualEffectView` glass blur, rounded corners, and SwiftUI card content.
final class GlassNotificationCardView: NSView {
    static let cardWidth: CGFloat = 350.0
    static let minCardHeight: CGFloat = 82.0
    static let maxCardHeight: CGFloat = 290.0

    private let visualEffectView = NSVisualEffectView()
    private let solidFallbackView = NSView()
    private let borderOverlayLayer = CALayer()
    private let hostingView: NSHostingView<NotificationCardContentView>
    private var trackingArea: NSTrackingArea?

    private let onHoverChanged: (Bool) -> Void

    init(
        message: WhatsAppMessage,
        config: HelperConfiguration,
        onCopy: @escaping () -> Void,
        onOpenWhatsApp: @escaping () -> Void,
        onDismiss: @escaping () -> Void,
        onToggleExpand: @escaping () -> Void,
        onHoverChanged: @escaping (Bool) -> Void
    ) {
        self.onHoverChanged = onHoverChanged
        let content = NotificationCardContentView(
            message: message,
            config: config,
            onCopy: onCopy,
            onOpenWhatsApp: onOpenWhatsApp,
            onDismiss: onDismiss,
            onToggleExpand: onToggleExpand
        )
        self.hostingView = NSHostingView(rootView: content)
        super.init(frame: NSRect(x: 0, y: 0, width: Self.cardWidth, height: 110))

        wantsLayer = true
        layer?.cornerRadius = 16
        layer?.masksToBounds = true
        layer?.backgroundColor = NSColor.clear.cgColor

        setupGlassLayers(config: config)
        setupHostingView()
        applyAppearance(config: config)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupGlassLayers(config: HelperConfiguration) {
        visualEffectView.translatesAutoresizingMaskIntoConstraints = false
        visualEffectView.blendingMode = .behindWindow
        visualEffectView.state = .active
        visualEffectView.wantsLayer = true
        visualEffectView.layer?.cornerRadius = 16
        visualEffectView.layer?.masksToBounds = true

        solidFallbackView.translatesAutoresizingMaskIntoConstraints = false
        solidFallbackView.wantsLayer = true
        solidFallbackView.layer?.cornerRadius = 16
        solidFallbackView.layer?.masksToBounds = true

        addSubview(solidFallbackView)
        addSubview(visualEffectView)

        NSLayoutConstraint.activate([
            solidFallbackView.leadingAnchor.constraint(equalTo: leadingAnchor),
            solidFallbackView.trailingAnchor.constraint(equalTo: trailingAnchor),
            solidFallbackView.topAnchor.constraint(equalTo: topAnchor),
            solidFallbackView.bottomAnchor.constraint(equalTo: bottomAnchor),

            visualEffectView.leadingAnchor.constraint(equalTo: leadingAnchor),
            visualEffectView.trailingAnchor.constraint(equalTo: trailingAnchor),
            visualEffectView.topAnchor.constraint(equalTo: topAnchor),
            visualEffectView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        borderOverlayLayer.cornerRadius = 16
        borderOverlayLayer.borderWidth = 1.0
        layer?.addSublayer(borderOverlayLayer)
    }

    private func setupHostingView() {
        hostingView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(hostingView)
        NSLayoutConstraint.activate([
            hostingView.leadingAnchor.constraint(equalTo: leadingAnchor),
            hostingView.trailingAnchor.constraint(equalTo: trailingAnchor),
            hostingView.topAnchor.constraint(equalTo: topAnchor),
            hostingView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    override func layout() {
        super.layout()
        borderOverlayLayer.frame = bounds
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        // `.activeAlways` guarantees hover detection works while other apps hold focus.
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
        onHoverChanged(true)
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        onHoverChanged(false)
    }

    func applyAppearance(config: HelperConfiguration) {
        let isDark = config.appearanceMode == .dark
        visualEffectView.isHidden = !config.nativeGlassBlurEnabled
        solidFallbackView.isHidden = config.nativeGlassBlurEnabled

        if isDark {
            appearance = NSAppearance(named: .darkAqua)
            visualEffectView.material = .hudWindow
            solidFallbackView.layer?.backgroundColor = NSColor(red: 0.08, green: 0.10, blue: 0.14, alpha: 0.92).cgColor
            borderOverlayLayer.borderColor = NSColor.white.withAlphaComponent(0.16).cgColor
        } else {
            appearance = NSAppearance(named: .aqua)
            visualEffectView.material = .popover
            solidFallbackView.layer?.backgroundColor = NSColor(white: 0.97, alpha: 0.94).cgColor
            borderOverlayLayer.borderColor = NSColor.black.withAlphaComponent(0.10).cgColor
        }
    }

    func preferredSize() -> CGSize {
        hostingView.layoutSubtreeIfNeeded()
        let fitting = hostingView.fittingSize
        let height = min(Self.maxCardHeight, max(Self.minCardHeight, ceil(fitting.height)))
        return CGSize(width: Self.cardWidth, height: height)
    }
}

/// SwiftUI layout rendered inside `GlassNotificationCardView`.
private struct NotificationCardContentView: View {
    let message: WhatsAppMessage
    let config: HelperConfiguration
    let onCopy: () -> Void
    let onOpenWhatsApp: () -> Void
    let onDismiss: () -> Void
    let onToggleExpand: () -> Void

    @State private var showCopiedBadge = false
    @State private var isExpanded = false

    private var isDark: Bool { config.appearanceMode == .dark }
    private var primaryText: Color { isDark ? .white : Color(red: 0.06, green: 0.09, blue: 0.16) }
    private var secondaryText: Color { isDark ? Color.white.opacity(0.74) : Color(red: 0.25, green: 0.30, blue: 0.39) }
    private var mutedText: Color { isDark ? Color.white.opacity(0.54) : Color(red: 0.42, green: 0.47, blue: 0.56) }
    private var whatsappGreen: Color { Color(red: 0.145, green: 0.827, blue: 0.400) }

    private var displaySender: String {
        if let sender = message.sender, !sender.isEmpty {
            return sender
        }
        if let chatName = message.chatName, !chatName.isEmpty {
            return chatName
        }
        return "WhatsApp Message"
    }

    private var shouldShowChatSubtitle: Bool {
        guard config.showChatName,
              let chatName = message.chatName,
              !chatName.isEmpty else {
            return false
        }
        return chatName != displaySender
    }

    private var canExpandPreview: Bool {
        guard let text = message.text else { return false }
        return text.count > 140 || text.components(separatedBy: "\n").count > 4
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Top bar: WhatsApp app badge + Timestamp + Action buttons
            HStack(spacing: 6) {
                HStack(spacing: 5) {
                    Image(systemName: "message.fill")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(whatsappGreen)
                    Text("WhatsApp")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(secondaryText)
                    if message.isTest {
                        Text("TEST")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(whatsappGreen)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1.5)
                            .background(whatsappGreen.opacity(0.16), in: Capsule())
                    }
                }

                Spacer(minLength: 6)

                if config.showTimestamp {
                    Text(message.timestamp ?? "NOW")
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(mutedText)
                }

                if showCopiedBadge {
                    Text("Copied ✓")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(whatsappGreen)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(whatsappGreen.opacity(0.16), in: Capsule())
                        .transition(.opacity)
                }

                HStack(spacing: 4) {
                    Button {
                        onOpenWhatsApp()
                    } label: {
                        Image(systemName: "arrow.up.forward.app")
                            .font(.system(size: 11, weight: .medium))
                            .frame(width: 20, height: 20)
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(mutedText)
                    .help("Open WhatsApp")

                    if config.showCopyButton, let text = message.text, !text.isEmpty {
                        Button {
                            onCopy()
                            withAnimation(.easeOut(duration: 0.16)) {
                                showCopiedBadge = true
                            }
                            DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) {
                                withAnimation(.easeIn(duration: 0.16)) {
                                    showCopiedBadge = false
                                }
                            }
                        } label: {
                            Image(systemName: "doc.on.doc")
                                .font(.system(size: 10.5, weight: .medium))
                                .frame(width: 20, height: 20)
                        }
                        .buttonStyle(.borderless)
                        .foregroundStyle(mutedText)
                        .help("Copy message")
                    }

                    Button {
                        onDismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 10.5, weight: .semibold))
                            .frame(width: 20, height: 20)
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(mutedText)
                    .help("Dismiss")
                }
            }

            // Main content row: Avatar + Sender/Chat + Preview
            HStack(alignment: .top, spacing: 10) {
                if config.showAvatar {
                    avatarView
                }

                VStack(alignment: .leading, spacing: 3) {
                    if config.showSender {
                        Text(displaySender)
                            .font(.system(size: 13.5, weight: .semibold))
                            .foregroundStyle(primaryText)
                            .lineLimit(1)
                    }

                    if shouldShowChatSubtitle, let chatName = message.chatName {
                        Text(chatName)
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundStyle(mutedText)
                            .lineLimit(1)
                    }

                    if config.showPreview, let text = message.text, !text.isEmpty {
                        Text(text)
                            .font(.system(size: 12.5))
                            .foregroundStyle(secondaryText)
                            .lineLimit(isExpanded ? 9 : 4)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.top, 1)

                        if canExpandPreview {
                            Button(isExpanded ? "Show less" : "Show more") {
                                isExpanded.toggle()
                                DispatchQueue.main.async {
                                    onToggleExpand()
                                }
                            }
                            .buttonStyle(.borderless)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(whatsappGreen)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(width: GlassNotificationCardView.cardWidth, alignment: .leading)
    }

    @ViewBuilder
    private var avatarView: some View {
        if let nsImage = decodeAvatarImage(message.avatar) {
            Image(nsImage: nsImage)
                .resizable()
                .scaledToFill()
                .frame(width: 36, height: 36)
                .clipShape(Circle())
                .overlay(Circle().stroke(whatsappGreen.opacity(0.45), lineWidth: 1))
        } else {
            ZStack {
                Circle()
                    .fill(whatsappGreen.opacity(isDark ? 0.22 : 0.16))
                Text(initials(from: displaySender))
                    .font(.system(size: 12.5, weight: .bold))
                    .foregroundStyle(isDark ? Color.white : Color(red: 0.02, green: 0.45, blue: 0.25))
            }
            .frame(width: 36, height: 36)
            .overlay(Circle().stroke(whatsappGreen.opacity(0.35), lineWidth: 1))
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
