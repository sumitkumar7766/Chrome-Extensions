import AppKit
import QuartzCore

/// Coordinates native macOS global floating notification panels (`NSPanel`) across displays and Spaces.
///
/// Key behavioral guarantees:
/// - Never activates PingGlass or steals keyboard focus (`nonactivatingPanel` + `orderFrontRegardless`).
/// - Does not switch Spaces or bring WhatsApp/Chrome to the foreground unless explicitly requested by user click.
/// - Respects macOS Reduce Motion accessibility preferences and user animation settings.
/// - Destroys dismissed panels immediately and bounds active/queued notifications in memory.
@MainActor
final class GlobalNotificationWindowManager {
    private final class ActiveCardEntry {
        let message: WhatsAppMessage
        let panel: FloatingNotificationPanel
        let cardView: GlassNotificationCardView
        var dismissTimer: Timer?
        var timerStartedAt: Date?
        var remainingDuration: TimeInterval?
        var isHovering = false
        var isExiting = false

        init(
            message: WhatsAppMessage,
            panel: FloatingNotificationPanel,
            cardView: GlassNotificationCardView,
            remainingDuration: TimeInterval?
        ) {
            self.message = message
            self.panel = panel
            self.cardView = cardView
            self.remainingDuration = remainingDuration
        }
    }

    private var queue: NotificationStackQueue
    private var activeEntries: [String: ActiveCardEntry] = [:]
    private var clearAllPanel: FloatingNotificationPanel?
    private var clearAllView: ClearAllGlassPillView?
    private let chatStore = SessionChatStore()
    private var chatPopupPanel: FloatingNotificationPanel?
    private var chatPopupView: GlassChatPopupView?
    private var activeChatPopupMessage: WhatsAppMessage?
    private var currentConfig: HelperConfiguration
    private var screenObserver: NSObjectProtocol?

    var onOpenWhatsAppRequested: ((WhatsAppMessage) -> Void)?
    var onFetchLiveConversation: ((WhatsAppMessage) -> [ChatBubbleEntry])?
    var onSendReplyRequested: ((WhatsAppMessage, String, @escaping (ReplyDispatchResult) -> Void) -> Void)?
    var onCountsChanged: ((Int, Int) -> Void)?

    init(config: HelperConfiguration = HelperConfiguration()) {
        self.currentConfig = config
        self.queue = NotificationStackQueue(maxVisible: config.maxVisibleNotifications)
        installScreenObserver()
    }

    deinit {
        if let screenObserver {
            NotificationCenter.default.removeObserver(screenObserver)
        }
    }

    var activeWindowCount: Int {
        activeEntries.count
    }

    var queuedCount: Int {
        queue.pendingMessages.count
    }

    var isClearAllBarVisible: Bool {
        clearAllPanel != nil
    }

    var isChatPopupVisible: Bool {
        chatPopupPanel != nil
    }

    /// Updates notification configuration and handles disable/pause/duration/layout changes.
    func updateConfiguration(_ newConfig: HelperConfiguration) {
        let oldConfig = currentConfig
        currentConfig = newConfig
        queue.maxVisible = newConfig.maxVisibleNotifications

        if !newConfig.globalNotificationsEnabled || newConfig.isNotificationsPaused() {
            dismissAll(animated: newConfig.animationEnabled)
            return
        }

        // Apply updated theme/blur/duration to active cards.
        for entry in activeEntries.values where !entry.isExiting {
            entry.cardView.applyAppearance(config: newConfig)
            if oldConfig.notificationDurationSeconds != newConfig.notificationDurationSeconds {
                let updatedDuration = newConfig.notificationDurationSeconds > 0
                    ? TimeInterval(newConfig.notificationDurationSeconds)
                    : nil
                entry.remainingDuration = updatedDuration
                if !entry.isHovering {
                    restartDismissTimer(for: entry)
                }
            }
        }

        if let openMsg = activeChatPopupMessage {
            refreshOpenChatPopup(for: openMsg)
        }

        // Promote queued cards if maxVisible increased.
        let promoted = queue.promoteAvailableSlots()
        for msg in promoted {
            presentCard(for: msg)
        }

        repositionVisiblePanels(animated: newConfig.animationEnabled)
    }

    /// Enqueues a WhatsApp (or test) message for global floating desktop display.
    func enqueue(_ message: WhatsAppMessage, config: HelperConfiguration) {
        currentConfig = config
        queue.maxVisible = config.maxVisibleNotifications

        // Test notifications can still be previewed when monitoring is paused,
        // unless global notifications themselves are paused or turned off (handled by caller for real msgs).
        if !message.isTest {
            guard config.globalNotificationsEnabled, !config.isNotificationsPaused() else {
                return
            }
        } else if !config.globalNotificationsEnabled {
            return
        }

        chatStore.record(message)
        if let openMsg = activeChatPopupMessage,
           SessionChatStore.chatKey(for: openMsg) == SessionChatStore.chatKey(for: message) {
            refreshOpenChatPopup(for: openMsg)
        }

        let outcome = queue.enqueue(message)
        switch outcome {
        case .displayNow:
            presentCard(for: message)
            playSubtleSoundIfEnabled()
            notifyCountsChanged()
        case .queued:
            updateClearAllBarCountIfVisible()
            notifyCountsChanged()
        case .ignoredDuplicate:
            break
        }
    }

    func dismiss(id: String, animated: Bool? = nil) {
        let shouldAnimate = (animated ?? currentConfig.animationEnabled) && !shouldReduceMotion
        guard let entry = activeEntries[id] else {
            _ = queue.remove(id: id)
            notifyCountsChanged()
            return
        }
        guard !entry.isExiting else { return }
        entry.isExiting = true
        invalidateTimer(for: entry)

        if !activeEntries.values.contains(where: { !$0.isExiting }) {
            hideClearAllBar()
        }

        let finishRemoval = { [weak self] in
            guard let self, self.activeEntries[id] === entry else { return }
            entry.panel.orderOut(nil)
            entry.panel.close()
            self.activeEntries.removeValue(forKey: id)
            if let nextMessage = self.queue.remove(id: id) {
                self.presentCard(for: nextMessage)
                self.playSubtleSoundIfEnabled()
            }
            self.repositionVisiblePanels(animated: self.currentConfig.animationEnabled)
            self.notifyCountsChanged()
        }

        if !shouldAnimate {
            finishRemoval()
            return
        }

        let startFrame = entry.panel.frame
        let exitFrame = NSRect(
            x: startFrame.origin.x,
            y: startFrame.origin.y + 18.0,
            width: startFrame.width,
            height: startFrame.height
        )

        if let layer = entry.cardView.layer {
            applyScaleAnimation(on: layer, from: 1.0, to: 0.97, duration: 0.24)
        }

        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.24
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            entry.panel.animator().alphaValue = 0.0
            entry.panel.animator().setFrame(exitFrame, display: true)
        }, completionHandler: {
            Task { @MainActor in
                finishRemoval()
            }
        })
    }

    func dismissAll(animated: Bool = false) {
        hideClearAllBar()
        closeChatPopup()
        let ids = Array(activeEntries.keys)
        queue.clearAll()
        for id in ids {
            dismiss(id: id, animated: animated)
        }
        notifyCountsChanged()
    }

    // MARK: - Presentation & Stacking

    private var shouldReduceMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    private func presentCard(for message: WhatsAppMessage) {
        let duration: TimeInterval? = currentConfig.notificationDurationSeconds > 0
            ? TimeInterval(currentConfig.notificationDurationSeconds)
            : nil

        let cardView = GlassNotificationCardView(
            message: message,
            config: currentConfig,
            onCardClick: { [weak self] in
                self?.handleNotificationCardClick(message)
            },
            onCopy: { [weak self] in
                self?.copyMessageToPasteboard(message)
            },
            onOpenWhatsApp: { [weak self] in
                self?.onOpenWhatsAppRequested?(message)
            },
            onDismiss: { [weak self] in
                self?.dismiss(id: message.id)
            },
            onToggleExpand: { [weak self] in
                self?.repositionVisiblePanels(animated: true)
            },
            onHoverChanged: { [weak self] hovering in
                self?.handleHoverChange(id: message.id, hovering: hovering)
            }
        )

        let preferredSize = cardView.preferredSize()
        let initialRect = NSRect(origin: .zero, size: preferredSize)
        let panel = FloatingNotificationPanel(contentRect: initialRect)
        panel.contentView = cardView

        let entry = ActiveCardEntry(
            message: message,
            panel: panel,
            cardView: cardView,
            remainingDuration: duration
        )
        activeEntries[message.id] = entry

        // Compute stacked target frames across all visible cards.
        let orderedMessages = queue.visibleMessages
        let sizes = orderedMessages.compactMap { msg -> CGSize? in
            activeEntries[msg.id]?.cardView.preferredSize()
        }
        let bounds = DisplayScreenLocator.targetBounds(for: currentConfig.preferredDisplayMode)
        let targetFrames = DisplayScreenLocator.computeStackedFrames(
            cardSizes: sizes,
            in: bounds.visibleFrame,
            position: currentConfig.notificationPosition,
            edgeMargin: currentConfig.edgeMargin,
            stackSpacing: 8.0
        )

        guard let newIdx = orderedMessages.firstIndex(where: { $0.id == message.id }),
              newIdx < targetFrames.count else {
            return
        }

        let targetFrame = targetFrames[newIdx]
        let animateEntry = currentConfig.animationEnabled && !shouldReduceMotion

        if animateEntry {
            let startFrame = NSRect(
                x: targetFrame.origin.x,
                y: targetFrame.origin.y - 22.0,
                width: targetFrame.width,
                height: targetFrame.height
            )
            panel.setFrame(startFrame, display: false)
            panel.alphaValue = 0.0
            panel.orderFrontRegardless()
            panel.invalidateShadow()

            if let layer = cardView.layer {
                applyScaleAnimation(on: layer, from: 0.97, to: 1.0, duration: 0.46)
            }

            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.46
                ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.19, 1.0, 0.22, 1.0)
                panel.animator().alphaValue = 1.0
                panel.animator().setFrame(targetFrame, display: true)
            }
        } else if currentConfig.animationEnabled {
            // Reduce Motion enabled: simple fade without slide/scale.
            panel.setFrame(targetFrame, display: false)
            panel.alphaValue = 0.0
            panel.orderFrontRegardless()
            panel.invalidateShadow()
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.20
                panel.animator().alphaValue = 1.0
            }
        } else {
            panel.setFrame(targetFrame, display: false)
            panel.alphaValue = 1.0
            panel.orderFrontRegardless()
            panel.invalidateShadow()
        }

        // Smoothly reposition older visible cards in the stack.
        for (idx, msg) in orderedMessages.enumerated() where msg.id != message.id && idx < targetFrames.count {
            guard let existing = activeEntries[msg.id], !existing.isExiting else { continue }
            let frame = targetFrames[idx]
            if animateEntry {
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = 0.28
                    ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.22, 1.0, 0.36, 1.0)
                    existing.panel.animator().setFrame(frame, display: true)
                }
            } else {
                existing.panel.setFrame(frame, display: true)
            }
        }

        startDismissTimer(for: entry)
        updateClearAllBar(for: targetFrames, in: bounds, animated: animateEntry)
    }

    func repositionVisiblePanels(animated: Bool) {
        let orderedMessages = queue.visibleMessages.filter {
            activeEntries[$0.id]?.isExiting == false
        }
        guard !orderedMessages.isEmpty else {
            hideClearAllBar()
            return
        }

        let sizes = orderedMessages.compactMap { msg -> CGSize? in
            activeEntries[msg.id]?.cardView.preferredSize()
        }
        let bounds = DisplayScreenLocator.targetBounds(for: currentConfig.preferredDisplayMode)
        let targetFrames = DisplayScreenLocator.computeStackedFrames(
            cardSizes: sizes,
            in: bounds.visibleFrame,
            position: currentConfig.notificationPosition,
            edgeMargin: currentConfig.edgeMargin,
            stackSpacing: 8.0
        )

        let shouldAnimate = animated && currentConfig.animationEnabled && !shouldReduceMotion
        for (idx, msg) in orderedMessages.enumerated() where idx < targetFrames.count {
            guard let entry = activeEntries[msg.id], !entry.isExiting else { continue }
            let frame = targetFrames[idx]
            if shouldAnimate {
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = 0.24
                    ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.19, 1.0, 0.22, 1.0)
                    entry.panel.animator().setFrame(frame, display: true)
                }
                entry.panel.invalidateShadow()
            } else {
                entry.panel.setFrame(frame, display: true)
                entry.panel.invalidateShadow()
            }
        }

        updateClearAllBar(for: targetFrames, in: bounds, animated: shouldAnimate)
        repositionChatPopupIfVisible(cardFrames: targetFrames, bounds: bounds, animated: shouldAnimate)
    }

    // MARK: - Notification Click & Floating Glass Chat Popup

    func handleNotificationCardClick(_ message: WhatsAppMessage) {
        dismiss(id: message.id, animated: currentConfig.animationEnabled)
        switch currentConfig.notificationClickAction {
        case .openGlassChatPopup:
            openChatPopup(for: message)
        case .openWhatsAppDirectly:
            onOpenWhatsAppRequested?(message)
        }
    }

    func openChatPopup(for message: WhatsAppMessage) {
        chatStore.record(message)
        activeChatPopupMessage = message

        let chatTitle = message.chatName ?? message.sender ?? "WhatsApp Chat"
        let subtitle: String? = (message.chatName != nil && message.sender != nil && message.chatName != message.sender)
            ? message.sender
            : nil

        let merged = mergedConversation(for: message)
        let bounds = DisplayScreenLocator.targetBounds(for: currentConfig.preferredDisplayMode)
        let targetFrame = computeNonOverlappingChatPopupFrame(bounds: bounds)

        let sendReplyHandler: (String, @escaping (ReplyDispatchResult) -> Void) -> Void = { [weak self] replyText, completion in
            guard let self else {
                completion(ReplyDispatchResult(succeeded: false, errorMessage: "Window closed."))
                return
            }
            if let handler = self.onSendReplyRequested {
                handler(message, replyText) { [weak self] result in
                    if result.succeeded {
                        _ = self?.chatStore.recordOutgoing(text: replyText, for: message)
                        self?.refreshOpenChatPopup(for: message)
                    }
                    completion(result)
                }
            } else {
                _ = self.chatStore.recordOutgoing(text: replyText, for: message)
                self.refreshOpenChatPopup(for: message)
                completion(ReplyDispatchResult(succeeded: true))
            }
        }

        if let existingView = chatPopupView, let existingPanel = chatPopupPanel {
            existingView.update(
                chatTitle: chatTitle,
                subtitle: subtitle,
                messages: merged.entries,
                isLiveAXSynced: merged.isLiveAXSynced,
                isTestChat: message.isTest,
                config: currentConfig,
                onRefresh: { [weak self] in
                    self?.refreshOpenChatPopup(for: message)
                },
                onOpenWhatsApp: { [weak self] in
                    self?.onOpenWhatsAppRequested?(message)
                },
                onCopyText: { [weak self] text in
                    self?.copyRawTextToPasteboard(text)
                },
                onSendReply: sendReplyHandler,
                onClose: { [weak self] in
                    self?.closeChatPopup()
                }
            )
            existingPanel.setFrame(targetFrame, display: true)
            existingPanel.orderFrontRegardless()
            return
        }

        let popupView = GlassChatPopupView(
            chatTitle: chatTitle,
            subtitle: subtitle,
            messages: merged.entries,
            isLiveAXSynced: merged.isLiveAXSynced,
            isTestChat: message.isTest,
            config: currentConfig,
            onRefresh: { [weak self] in
                self?.refreshOpenChatPopup(for: message)
            },
            onOpenWhatsApp: { [weak self] in
                self?.onOpenWhatsAppRequested?(message)
            },
            onCopyText: { [weak self] text in
                self?.copyRawTextToPasteboard(text)
            },
            onSendReply: sendReplyHandler,
            onClose: { [weak self] in
                self?.closeChatPopup()
            }
        )

        let panel = FloatingNotificationPanel(contentRect: targetFrame, allowsKeyFocus: true)
        panel.contentView = popupView
        chatPopupView = popupView
        chatPopupPanel = panel

        let animate = currentConfig.animationEnabled && !shouldReduceMotion
        if animate {
            let startFrame = NSRect(
                x: targetFrame.origin.x,
                y: targetFrame.origin.y - 22.0,
                width: targetFrame.width,
                height: targetFrame.height
            )
            panel.setFrame(startFrame, display: false)
            panel.alphaValue = 0.0
            panel.orderFrontRegardless()

            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.36
                ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.22, 1.0, 0.36, 1.0)
                panel.animator().alphaValue = 1.0
                panel.animator().setFrame(targetFrame, display: true)
            }
        } else {
            panel.setFrame(targetFrame, display: false)
            panel.alphaValue = 1.0
            panel.orderFrontRegardless()
        }
    }

    func refreshOpenChatPopup(for message: WhatsAppMessage) {
        guard activeChatPopupMessage != nil else { return }
        openChatPopup(for: message)
    }

    func recordExternalOutgoingReply(_ text: String, for message: WhatsAppMessage) {
        _ = chatStore.recordOutgoing(text: text, for: message)
        if let openMsg = activeChatPopupMessage,
           SessionChatStore.chatKey(for: openMsg) == SessionChatStore.chatKey(for: message) {
            refreshOpenChatPopup(for: openMsg)
        }
    }

    func closeChatPopup() {
        if let panel = chatPopupPanel {
            panel.orderOut(nil)
            panel.close()
        }
        chatPopupPanel = nil
        chatPopupView = nil
        activeChatPopupMessage = nil
    }

    private func mergedConversation(for message: WhatsAppMessage) -> (entries: [ChatBubbleEntry], isLiveAXSynced: Bool) {
        let liveEntries = message.isTest ? [] : (onFetchLiveConversation?(message) ?? [])
        let sessionEntries = chatStore.messages(for: message)

        if !liveEntries.isEmpty {
            var combined = liveEntries
            for item in sessionEntries {
                let alreadyInLive = combined.contains {
                    $0.text.trimmingCharacters(in: .whitespacesAndNewlines) ==
                        item.text.trimmingCharacters(in: .whitespacesAndNewlines)
                }
                if !alreadyInLive {
                    combined.append(item)
                }
            }
            return (combined, true)
        }
        return (sessionEntries, false)
    }

    private func computeNonOverlappingChatPopupFrame(bounds: ScreenBounds, cardFrames: [CGRect]? = nil) -> CGRect {
        var frame = DisplayScreenLocator.computeChatPopupFrame(
            size: GlassChatPopupView.popupSize,
            in: bounds.visibleFrame,
            position: currentConfig.notificationPosition,
            edgeMargin: currentConfig.edgeMargin
        )

        let activeFrames = cardFrames ?? activeEntries.values
            .filter { !$0.isExiting }
            .map { $0.panel.frame }

        if !activeFrames.isEmpty {
            let offsetShift = GlassNotificationCardView.cardWidth + 14.0
            if currentConfig.notificationPosition.isRightAligned {
                let shiftedX = frame.origin.x - offsetShift
                if shiftedX >= bounds.visibleFrame.minX + 8.0 {
                    frame.origin.x = shiftedX
                }
            } else {
                let shiftedX = frame.origin.x + offsetShift
                if shiftedX + frame.width <= bounds.visibleFrame.maxX - 8.0 {
                    frame.origin.x = shiftedX
                }
            }
        }

        return frame
    }

    private func repositionChatPopupIfVisible(cardFrames: [CGRect], bounds: ScreenBounds, animated: Bool) {
        guard let panel = chatPopupPanel else { return }
        let target = computeNonOverlappingChatPopupFrame(bounds: bounds, cardFrames: cardFrames)
        if animated && !shouldReduceMotion {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.24
                ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.22, 1.0, 0.36, 1.0)
                panel.animator().setFrame(target, display: true)
            }
        } else {
            panel.setFrame(target, display: true)
        }
    }

    // MARK: - Clear All Floating Pill

    private func updateClearAllBarCountIfVisible() {
        guard clearAllPanel != nil else { return }
        repositionVisiblePanels(animated: false)
    }

    private func updateClearAllBar(for cardFrames: [CGRect], in bounds: ScreenBounds, animated: Bool) {
        let total = activeEntries.values.filter { !$0.isExiting }.count + queue.pendingMessages.count
        guard total >= 1, !cardFrames.isEmpty else {
            hideClearAllBar()
            return
        }

        let pillView: ClearAllGlassPillView
        let pillPanel: FloatingNotificationPanel
        let isNew: Bool

        if let existingView = clearAllView, let existingPanel = clearAllPanel {
            existingView.update(totalCount: total, config: currentConfig) { [weak self] in
                guard let self else { return }
                self.dismissAll(animated: self.currentConfig.animationEnabled)
            }
            pillView = existingView
            pillPanel = existingPanel
            isNew = false
        } else {
            let newView = ClearAllGlassPillView(
                totalCount: total,
                config: currentConfig
            ) { [weak self] in
                guard let self else { return }
                self.dismissAll(animated: self.currentConfig.animationEnabled)
            }
            let newPanel = FloatingNotificationPanel(contentRect: NSRect(x: 0, y: 0, width: 96, height: 26))
            newPanel.contentView = newView
            clearAllView = newView
            clearAllPanel = newPanel
            pillView = newView
            pillPanel = newPanel
            isNew = true
        }

        let barSize = pillView.preferredSize()
        let targetFrame = DisplayScreenLocator.computeClearAllBarFrame(
            for: cardFrames,
            barSize: barSize,
            in: bounds.visibleFrame,
            position: currentConfig.notificationPosition,
            edgeMargin: currentConfig.edgeMargin
        )

        if isNew {
            pillPanel.setFrame(targetFrame, display: false)
            if animated && !shouldReduceMotion {
                pillPanel.alphaValue = 0.0
                pillPanel.orderFrontRegardless()
                pillPanel.invalidateShadow()
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = 0.25
                    pillPanel.animator().alphaValue = 1.0
                }
            } else {
                pillPanel.alphaValue = 1.0
                pillPanel.orderFrontRegardless()
                pillPanel.invalidateShadow()
            }
        } else if animated && !shouldReduceMotion {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.24
                ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.19, 1.0, 0.22, 1.0)
                pillPanel.animator().setFrame(targetFrame, display: true)
            }
            pillPanel.invalidateShadow()
        } else {
            pillPanel.setFrame(targetFrame, display: true)
            pillPanel.invalidateShadow()
        }
    }

    private func hideClearAllBar() {
        if let panel = clearAllPanel {
            panel.orderOut(nil)
            panel.close()
        }
        clearAllPanel = nil
        clearAllView = nil
    }

    private func notifyCountsChanged() {
        let activeCount = activeEntries.values.filter { !$0.isExiting }.count
        let pendingCount = queue.pendingMessages.count
        onCountsChanged?(activeCount, pendingCount)
    }

    // MARK: - Timers, Sound, Clipboard & Screen Changes

    private func startDismissTimer(for entry: ActiveCardEntry) {
        invalidateTimer(for: entry)
        guard let remaining = entry.remainingDuration, remaining > 0 else { return }

        let messageId = entry.message.id
        entry.timerStartedAt = Date()
        entry.dismissTimer = Timer.scheduledTimer(withTimeInterval: remaining, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.dismiss(id: messageId)
            }
        }
    }

    private func restartDismissTimer(for entry: ActiveCardEntry) {
        startDismissTimer(for: entry)
    }

    private func invalidateTimer(for entry: ActiveCardEntry) {
        entry.dismissTimer?.invalidate()
        entry.dismissTimer = nil
    }

    private func handleHoverChange(id: String, hovering: Bool) {
        guard let entry = activeEntries[id], !entry.isExiting else { return }
        entry.isHovering = hovering

        if hovering {
            if let startedAt = entry.timerStartedAt, let remaining = entry.remainingDuration {
                let elapsed = Date().timeIntervalSince(startedAt)
                entry.remainingDuration = max(0.8, remaining - elapsed)
            }
            invalidateTimer(for: entry)
        } else {
            startDismissTimer(for: entry)
        }
    }

    private func copyMessageToPasteboard(_ message: WhatsAppMessage) {
        let payload: String
        if let text = message.text, !text.isEmpty {
            payload = text
        } else if let sender = message.sender, !sender.isEmpty {
            payload = sender
        } else {
            return
        }

        copyRawTextToPasteboard(payload)
    }

    private func copyRawTextToPasteboard(_ text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }

    private func playSubtleSoundIfEnabled() {
        guard currentConfig.soundEnabled else { return }
        NSSound(named: NSSound.Name("Pop"))?.play()
    }

    private func installScreenObserver() {
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.repositionVisiblePanels(animated: false)
            }
        }
    }

    private func applyScaleAnimation(on layer: CALayer, from: CGFloat, to: CGFloat, duration: CFTimeInterval) {
        let bounds = layer.bounds
        let cx = bounds.midX
        let cy = bounds.midY

        func centeredScaleTransform(_ scale: CGFloat) -> CATransform3D {
            var t = CATransform3DIdentity
            t = CATransform3DTranslate(t, cx, cy, 0)
            t = CATransform3DScale(t, scale, scale, 1.0)
            t = CATransform3DTranslate(t, -cx, -cy, 0)
            return t
        }

        let anim = CABasicAnimation(keyPath: "transform")
        anim.fromValue = NSValue(caTransform3D: centeredScaleTransform(from))
        anim.toValue = NSValue(caTransform3D: centeredScaleTransform(to))
        anim.duration = duration
        anim.timingFunction = CAMediaTimingFunction(controlPoints: 0.22, 1.0, 0.36, 1.0)
        anim.isRemovedOnCompletion = true
        layer.add(anim, forKey: "pingglass.scale")
    }
}
