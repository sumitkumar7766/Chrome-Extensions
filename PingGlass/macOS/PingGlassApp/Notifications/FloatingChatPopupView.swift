import AppKit
import SwiftUI

/// Floating native glass popup displaying the clicked contact's recent chat messages
/// at the notification screen corner, without stealing focus or requiring app switching.
final class GlassChatPopupView: NSView {
    static let popupSize = CGSize(width: 372, height: 430)
    static let cornerRadius: CGFloat = 24.0

    private let backdropView = LiquidGlassBackdropView(cornerRadius: GlassChatPopupView.cornerRadius)
    private let hostingView: NSHostingView<FloatingChatPopupContent>

    init(
        chatTitle: String,
        subtitle: String?,
        messages: [ChatBubbleEntry],
        isLiveAXSynced: Bool,
        isTestChat: Bool,
        config: HelperConfiguration,
        onRefresh: @escaping () -> Void,
        onOpenWhatsApp: @escaping () -> Void,
        onCopyText: @escaping (String) -> Void,
        onClose: @escaping () -> Void
    ) {
        self.hostingView = NSHostingView(
            rootView: FloatingChatPopupContent(
                chatTitle: chatTitle,
                subtitle: subtitle,
                messages: messages,
                isLiveAXSynced: isLiveAXSynced,
                isTestChat: isTestChat,
                config: config,
                onRefresh: onRefresh,
                onOpenWhatsApp: onOpenWhatsApp,
                onCopyText: onCopyText,
                onClose: onClose
            )
        )
        super.init(frame: NSRect(origin: .zero, size: Self.popupSize))

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

        update(
            chatTitle: chatTitle,
            subtitle: subtitle,
            messages: messages,
            isLiveAXSynced: isLiveAXSynced,
            isTestChat: isTestChat,
            config: config,
            onRefresh: onRefresh,
            onOpenWhatsApp: onOpenWhatsApp,
            onCopyText: onCopyText,
            onClose: onClose
        )
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(
        chatTitle: String,
        subtitle: String?,
        messages: [ChatBubbleEntry],
        isLiveAXSynced: Bool,
        isTestChat: Bool,
        config: HelperConfiguration,
        onRefresh: @escaping () -> Void,
        onOpenWhatsApp: @escaping () -> Void,
        onCopyText: @escaping (String) -> Void,
        onClose: @escaping () -> Void
    ) {
        hostingView.rootView = FloatingChatPopupContent(
            chatTitle: chatTitle,
            subtitle: subtitle,
            messages: messages,
            isLiveAXSynced: isLiveAXSynced,
            isTestChat: isTestChat,
            config: config,
            onRefresh: onRefresh,
            onOpenWhatsApp: onOpenWhatsApp,
            onCopyText: onCopyText,
            onClose: onClose
        )

        appearance = NSAppearance(named: config.appearanceMode == .dark ? .darkAqua : .aqua)
        backdropView.apply(config: config, hovered: false)
    }
}

private struct FloatingChatPopupContent: View {
    let chatTitle: String
    let subtitle: String?
    let messages: [ChatBubbleEntry]
    let isLiveAXSynced: Bool
    let isTestChat: Bool
    let config: HelperConfiguration
    let onRefresh: () -> Void
    let onOpenWhatsApp: () -> Void
    let onCopyText: (String) -> Void
    let onClose: () -> Void

    @State private var copiedId: String?

    private var isDark: Bool { config.appearanceMode == .dark }
    private var primaryText: Color { isDark ? .white : Color(red: 0.06, green: 0.09, blue: 0.16) }
    private var secondaryText: Color { isDark ? Color.white.opacity(0.76) : Color(red: 0.25, green: 0.30, blue: 0.39) }
    private var mutedText: Color { isDark ? Color.white.opacity(0.55) : Color(red: 0.42, green: 0.47, blue: 0.56) }
    private var whatsappGreen: Color { Color(red: 0.145, green: 0.827, blue: 0.400) }

    var body: some View {
        VStack(spacing: 0) {
            headerBar

            Divider().opacity(0.25)

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 8) {
                        if messages.isEmpty {
                            Text("No accessible messages captured for this chat yet.")
                                .font(.caption)
                                .foregroundStyle(mutedText)
                                .padding(.top, 40)
                        } else {
                            ForEach(messages) { entry in
                                bubbleRow(entry)
                                    .id(entry.id)
                            }
                        }
                    }
                    .padding(12)
                }
                .onAppear {
                    if let last = messages.last {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
                .onChange(of: messages.count) { _ in
                    if let last = messages.last {
                        withAnimation(.easeOut(duration: 0.2)) {
                            proxy.scrollTo(last.id, anchor: .bottom)
                        }
                    }
                }
            }

            Divider().opacity(0.25)

            footerBar
        }
        .frame(width: GlassChatPopupView.popupSize.width, height: GlassChatPopupView.popupSize.height)
    }

    private var headerBar: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle()
                    .fill(whatsappGreen.opacity(isDark ? 0.22 : 0.16))
                Text(initials(from: chatTitle))
                    .font(.system(size: 12.5, weight: .bold))
                    .foregroundStyle(isDark ? .white : Color(red: 0.02, green: 0.45, blue: 0.25))
            }
            .frame(width: 34, height: 34)
            .overlay(Circle().stroke(whatsappGreen.opacity(0.38), lineWidth: 1))

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(chatTitle)
                        .font(.system(size: 13.5, weight: .semibold))
                        .foregroundStyle(primaryText)
                        .lineLimit(1)
                    if isTestChat {
                        Text("TEST")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(whatsappGreen)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(whatsappGreen.opacity(0.16), in: Capsule())
                    }
                }

                Text(subtitle ?? (isLiveAXSynced ? "Live WhatsApp Accessibility View" : "Session Messages"))
                    .font(.system(size: 10.5))
                    .foregroundStyle(mutedText)
                    .lineLimit(1)
            }

            Spacer()

            HStack(spacing: 4) {
                GlassIconActionButton(
                    systemName: "arrow.clockwise",
                    tooltip: "Refresh visible messages from WhatsApp Accessibility",
                    isDark: isDark,
                    action: onRefresh
                )

                GlassIconActionButton(
                    systemName: "xmark",
                    tooltip: "Close chat popup",
                    isDark: isDark,
                    action: onClose
                )
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }

    private func bubbleRow(_ entry: ChatBubbleEntry) -> some View {
        HStack {
            if entry.isOutgoing { Spacer(minLength: 42) }

            VStack(alignment: .leading, spacing: 3) {
                if !entry.isOutgoing, let sender = entry.sender, !sender.isEmpty, sender != chatTitle {
                    Text(sender)
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(whatsappGreen)
                }

                Text(entry.text)
                    .font(.system(size: 12.5))
                    .foregroundStyle(primaryText)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 6) {
                    if let time = entry.timestamp, !time.isEmpty {
                        Text(time)
                            .font(.system(size: 9.5))
                            .foregroundStyle(mutedText)
                    }

                    Spacer(minLength: 8)

                    Button {
                        onCopyText(entry.text)
                        copiedId = entry.id
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                            if copiedId == entry.id { copiedId = nil }
                        }
                    } label: {
                        Text(copiedId == entry.id ? "Copied ✓" : "Copy")
                            .font(.system(size: 9.5, weight: .semibold))
                            .foregroundStyle(copiedId == entry.id ? whatsappGreen : mutedText)
                    }
                    .buttonStyle(.borderless)
                }
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 8)
            .background(bubbleBackground(isOutgoing: entry.isOutgoing))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(
                        entry.isOutgoing
                            ? whatsappGreen.opacity(0.32)
                            : (isDark ? Color.white.opacity(0.10) : Color.black.opacity(0.07)),
                        lineWidth: 1
                    )
            )

            if !entry.isOutgoing { Spacer(minLength: 42) }
        }
    }

    private func bubbleBackground(isOutgoing: Bool) -> Color {
        if isOutgoing {
            return whatsappGreen.opacity(isDark ? 0.22 : 0.16)
        }
        return isDark ? Color.white.opacity(0.08) : Color.black.opacity(0.05)
    }

    private var footerBar: some View {
        HStack(spacing: 8) {
            if !isLiveAXSynced && !isTestChat {
                Text("Session view · open WhatsApp for full history")
                    .font(.system(size: 10.5))
                    .foregroundStyle(mutedText)
                    .lineLimit(1)
            } else {
                Text("Local-only · No message history saved")
                    .font(.system(size: 10.5))
                    .foregroundStyle(mutedText)
                    .lineLimit(1)
            }

            Spacer()

            Button(action: onOpenWhatsApp) {
                Label("Open in WhatsApp", systemImage: "arrow.up.forward.app")
                    .font(.system(size: 11.5, weight: .semibold))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(whatsappGreen.opacity(0.20), in: Capsule())
                    .foregroundStyle(isDark ? Color.white : Color(red: 0.02, green: 0.45, blue: 0.25))
            }
            .buttonStyle(.borderless)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private func initials(from name: String) -> String {
        let parts = name.split(whereSeparator: { $0.isWhitespace })
        if parts.isEmpty { return "WA" }
        if parts.count == 1 { return String(parts[0].prefix(2)).uppercased() }
        let first = parts.first?.first.map(String.init) ?? ""
        let last = parts.last?.first.map(String.init) ?? ""
        return (first + last).uppercased()
    }
}
