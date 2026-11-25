import AppKit
import SwiftUI

/// Floating native glass chat & quick-reply popup displaying session + live AX bubbles
/// and allowing replies directly through WhatsApp Desktop's accessible composer.
final class GlassChatPopupView: NSView {
    static let popupSize = CGSize(width: 342, height: 414)
    static let cornerRadius: CGFloat = 20.0

    private let backdropView = LiquidGlassBackdropView(cornerRadius: GlassChatPopupView.cornerRadius, showLeftAccent: true)
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
        onSendReply: @escaping (String, @escaping (ReplyDispatchResult) -> Void) -> Void,
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
                onSendReply: onSendReply,
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
            onSendReply: onSendReply,
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
        onSendReply: @escaping (String, @escaping (ReplyDispatchResult) -> Void) -> Void,
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
            onSendReply: onSendReply,
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
    let onSendReply: (String, @escaping (ReplyDispatchResult) -> Void) -> Void
    let onClose: () -> Void

    @State private var copiedId: String?
    @State private var copiedAll = false
    @State private var hoveredBubbleId: String?
    @State private var draftReply: String = ""
    @State private var isSending = false
    @State private var replyStatusText: String?
    @State private var replyIsError = false
    @FocusState private var isComposerFocused: Bool

    private let quickReplies = ["👍", "Ok", "On my way", "Call soon"]

    private var isDark: Bool { config.appearanceMode == .dark }
    private var primaryText: Color { isDark ? .white : Color(red: 0.06, green: 0.09, blue: 0.16) }
    private var secondaryText: Color { isDark ? Color.white.opacity(0.76) : Color(red: 0.25, green: 0.30, blue: 0.39) }
    private var mutedText: Color { isDark ? Color.white.opacity(0.55) : Color(red: 0.42, green: 0.47, blue: 0.56) }
    private var whatsappGreen: Color { Color(red: 0.145, green: 0.827, blue: 0.400) }

    var body: some View {
        VStack(spacing: 0) {
            headerBar

            Divider().opacity(0.24)

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 8) {
                        if messages.isEmpty {
                            VStack(spacing: 8) {
                                Text("No accessible messages captured for this chat yet.")
                                    .font(.caption)
                                    .foregroundStyle(mutedText)
                                    .multilineTextAlignment(.center)
                                openHistoryButton
                            }
                            .padding(.top, 44)
                            .padding(.horizontal, 18)
                        } else {
                            ForEach(messages) { entry in
                                bubbleRow(entry)
                                    .id(entry.id)
                            }

                            if !isLiveAXSynced && !isTestChat && messages.count <= 1 {
                                openHistoryButton
                                    .padding(.top, 4)
                            }
                        }
                    }
                    .padding(12)
                }
                .onAppear {
                    scrollToBottom(proxy: proxy, animated: false)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
                        isComposerFocused = true
                    }
                }
                .onChange(of: messages.count) { _ in
                    scrollToBottom(proxy: proxy, animated: true)
                }
                .onChange(of: messages.last?.id) { _ in
                    scrollToBottom(proxy: proxy, animated: true)
                }
            }

            Divider().opacity(0.24)

            composerFooterBar
        }
        .frame(width: GlassChatPopupView.popupSize.width, height: GlassChatPopupView.popupSize.height)
    }

    private func scrollToBottom(proxy: ScrollViewProxy, animated: Bool) {
        guard let last = messages.last else { return }
        if animated {
            withAnimation(.easeOut(duration: 0.2)) {
                proxy.scrollTo(last.id, anchor: .bottom)
            }
        } else {
            proxy.scrollTo(last.id, anchor: .bottom)
        }
    }

    private var openHistoryButton: some View {
        Button(action: onOpenWhatsApp) {
            HStack(spacing: 5) {
                Image(systemName: "arrow.up.forward.square")
                    .font(.system(size: 10, weight: .semibold))
                Text("Open in WhatsApp to sync full chat")
                    .font(.system(size: 10.5, weight: .medium))
            }
            .foregroundStyle(whatsappGreen)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(whatsappGreen.opacity(isDark ? 0.13 : 0.10), in: Capsule())
            .overlay(Capsule().stroke(whatsappGreen.opacity(0.28), lineWidth: 0.75))
        }
        .buttonStyle(.plain)
    }

    private var headerBar: some View {
        HStack(spacing: 8) {
            ZStack(alignment: .bottomTrailing) {
                ZStack {
                    Circle()
                        .fill(isDark ? Color.black.opacity(0.28) : whatsappGreen.opacity(0.14))
                    Text(initials(from: chatTitle))
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(isDark ? .white : Color(red: 0.02, green: 0.45, blue: 0.25))
                }
                .frame(width: 32, height: 32)
                .overlay(Circle().stroke(whatsappGreen.opacity(0.85), lineWidth: 1.2))

                Circle()
                    .fill(whatsappGreen)
                    .frame(width: 9, height: 9)
                    .overlay(Circle().stroke(isDark ? Color(white: 0.12) : Color.white, lineWidth: 1.3))
                    .offset(x: 1, y: 1)
            }

            VStack(alignment: .leading, spacing: 1.5) {
                HStack(spacing: 5) {
                    Text(chatTitle)
                        .font(.system(size: 13.5, weight: .semibold))
                        .foregroundStyle(primaryText)
                        .lineLimit(1)
                    if isTestChat {
                        Text("TEST")
                            .font(.system(size: 8.5, weight: .bold))
                            .foregroundStyle(whatsappGreen)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(whatsappGreen.opacity(0.20), in: Capsule())
                    }
                }

                HStack(spacing: 4) {
                    Circle()
                        .fill(isLiveAXSynced ? whatsappGreen : mutedText.opacity(0.65))
                        .frame(width: 5.5, height: 5.5)
                    Text(headerSubtitleText)
                        .font(.system(size: 10.5))
                        .foregroundStyle(mutedText)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 4)

            HStack(spacing: 4) {
                if !messages.isEmpty {
                    GlassIconActionButton(
                        systemName: copiedAll ? "checkmark" : "doc.on.clipboard",
                        tooltip: copiedAll ? "Copied chat" : "Copy full conversation",
                        isDark: isDark,
                        action: copyFullConversation
                    )
                }

                GlassIconActionButton(
                    systemName: "arrow.up.forward.square",
                    tooltip: "Open in WhatsApp Desktop",
                    isDark: isDark,
                    action: onOpenWhatsApp
                )

                GlassIconActionButton(
                    systemName: "arrow.clockwise",
                    tooltip: "Refresh visible messages",
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
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private var headerSubtitleText: String {
        let countSuffix = messages.isEmpty ? "" : " · \(messages.count) msg\(messages.count == 1 ? "" : "s")"
        if let subtitle, !subtitle.isEmpty {
            return "\(subtitle)\(countSuffix)"
        }
        return (isLiveAXSynced ? "Live WhatsApp Sync" : "Session Chat") + countSuffix
    }

    private func copyFullConversation() {
        let transcript = messages.map { entry -> String in
            let author = entry.isOutgoing ? "You" : (entry.sender ?? chatTitle)
            let timePart = entry.timestamp.map { " [\($0)]" } ?? ""
            return "\(author)\(timePart): \(entry.text)"
        }.joined(separator: "\n")
        guard !transcript.isEmpty else { return }
        onCopyText(transcript)
        copiedAll = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) {
            copiedAll = false
        }
    }

    private func bubbleRow(_ entry: ChatBubbleEntry) -> some View {
        let isHovered = hoveredBubbleId == entry.id

        return HStack {
            if entry.isOutgoing { Spacer(minLength: 42) }

            VStack(alignment: .leading, spacing: 3.5) {
                if !entry.isOutgoing, let sender = entry.sender, !sender.isEmpty, sender != chatTitle {
                    Text(sender)
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(whatsappGreen)
                }

                Text(entry.text)
                    .font(.system(size: 12.8))
                    .lineSpacing(1.8)
                    .foregroundStyle(primaryText)
                    .textSelection(.enabled)
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
                        HStack(spacing: 2.5) {
                            Image(systemName: copiedId == entry.id ? "checkmark" : "doc.on.doc")
                                .font(.system(size: 8.5, weight: .semibold))
                            Text(copiedId == entry.id ? "Copied" : "Copy")
                                .font(.system(size: 9.5, weight: .semibold))
                        }
                        .foregroundStyle(copiedId == entry.id ? whatsappGreen : mutedText)
                        .opacity((isHovered || copiedId == entry.id) ? 1.0 : 0.72)
                    }
                    .buttonStyle(.borderless)
                }
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 8)
            .background(bubbleBackground(isOutgoing: entry.isOutgoing, isHovered: isHovered))
            .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .stroke(
                        entry.isOutgoing
                            ? whatsappGreen.opacity(isHovered ? 0.50 : 0.34)
                            : (isDark ? Color.white.opacity(isHovered ? 0.20 : 0.11) : Color.black.opacity(isHovered ? 0.14 : 0.08)),
                        lineWidth: 1
                    )
            )
            .onHover { hovering in
                hoveredBubbleId = hovering ? entry.id : (hoveredBubbleId == entry.id ? nil : hoveredBubbleId)
            }

            if !entry.isOutgoing { Spacer(minLength: 42) }
        }
    }

    private func bubbleBackground(isOutgoing: Bool, isHovered: Bool) -> Color {
        if isOutgoing {
            return whatsappGreen.opacity(isDark ? (isHovered ? 0.28 : 0.22) : (isHovered ? 0.22 : 0.17))
        }
        return isDark ? Color.white.opacity(isHovered ? 0.12 : 0.085) : Color.black.opacity(isHovered ? 0.08 : 0.05)
    }

    private var composerFooterBar: some View {
        VStack(alignment: .leading, spacing: 6) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 5) {
                    ForEach(quickReplies, id: \.self) { chip in
                        Button {
                            sendText(chip)
                        } label: {
                            Text(chip)
                                .font(.system(size: 10.5, weight: .medium))
                                .foregroundStyle(secondaryText)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3.5)
                                .background(
                                    Capsule()
                                        .fill(isDark ? Color.white.opacity(0.08) : Color.black.opacity(0.05))
                                )
                                .overlay(
                                    Capsule()
                                        .stroke(isDark ? Color.white.opacity(0.14) : Color.black.opacity(0.10), lineWidth: 0.75)
                                )
                        }
                        .buttonStyle(.plain)
                        .disabled(isSending)
                    }
                }
            }

            HStack(spacing: 7) {
                TextField("Reply to \(chatTitle)…", text: $draftReply, axis: .vertical)
                    .lineLimit(1...3)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12.2))
                    .foregroundStyle(primaryText)
                    .focused($isComposerFocused)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6.5)
                    .background(
                        RoundedRectangle(cornerRadius: 11, style: .continuous)
                            .fill(isDark ? Color.white.opacity(0.09) : Color.black.opacity(0.05))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 11, style: .continuous)
                            .stroke(
                                isComposerFocused
                                    ? whatsappGreen.opacity(0.55)
                                    : (isDark ? Color.white.opacity(0.18) : Color.black.opacity(0.12)),
                                lineWidth: 0.9
                            )
                    )
                    .disabled(isSending)
                    .onSubmit {
                        submitReply()
                    }

                Button(action: submitReply) {
                    ZStack {
                        Circle()
                            .fill(canSend ? whatsappGreen : Color.gray.opacity(0.35))
                            .frame(width: 29, height: 29)
                        if isSending {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Image(systemName: "paperplane.fill")
                                .font(.system(size: 11.5, weight: .semibold))
                                .foregroundStyle(.white)
                        }
                    }
                }
                .buttonStyle(.plain)
                .disabled(!canSend || isSending)
                .help("Send reply through WhatsApp Desktop")
            }

            HStack(spacing: 6) {
                if let replyStatusText {
                    Text(replyStatusText)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(replyIsError ? Color.orange : whatsappGreen)
                        .lineLimit(1)
                } else {
                    Text("Local-only · Press Return to send via WhatsApp")
                        .font(.system(size: 10))
                        .foregroundStyle(mutedText)
                        .lineLimit(1)
                }
                Spacer()
            }
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 9)
    }

    private var canSend: Bool {
        !draftReply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func submitReply() {
        let text = draftReply.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        sendText(text, clearDraftOnSuccess: true)
    }

    private func sendText(_ text: String, clearDraftOnSuccess: Bool = false) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isSending else { return }
        isSending = true
        replyStatusText = "Sending via WhatsApp…"
        replyIsError = false

        onSendReply(trimmed) { result in
            isSending = false
            if result.succeeded {
                if clearDraftOnSuccess {
                    draftReply = ""
                }
                replyStatusText = "Sent ✓"
                replyIsError = false
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                    if replyStatusText == "Sent ✓" {
                        replyStatusText = nil
                    }
                }
            } else {
                replyIsError = true
                replyStatusText = result.errorMessage ?? "Could not send reply."
            }
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
}
