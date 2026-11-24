import AppKit
import CoreGraphics
import Foundation
import XCTest
@testable import PingGlassApp

final class PingGlassTests: XCTestCase {
    func testFingerprintDeduplicatesIdenticalWithinTTLAndAllowsDistinctElements() {
        let store = MessageFingerprintStore(maxEntries: 100, ttlSeconds: 300)
        let fp1 = MessageFingerprintStore.computeFingerprint(
            sender: "Rahul",
            chatName: "Rahul",
            text: "Bhai kal milte hain",
            timestamp: "11:42 PM",
            elementIdentity: "bubble-1",
            occurrenceIndex: 0
        )
        let fp2 = MessageFingerprintStore.computeFingerprint(
            sender: "Rahul",
            chatName: "Rahul",
            text: "Bhai kal milte hain",
            timestamp: "11:42 PM",
            elementIdentity: "bubble-2",
            occurrenceIndex: 1
        )

        XCTAssertTrue(store.shouldAccept(fp1))
        XCTAssertFalse(store.shouldAccept(fp1), "Repeated AX callback for same element should be filtered")
        XCTAssertTrue(store.shouldAccept(fp2), "Genuinely separate message with identical text should be allowed")
    }

    func testFingerprintExpirationAndBoundedCapacity() {
        let store = MessageFingerprintStore(maxEntries: 50, ttlSeconds: 15)
        let t0 = Date(timeIntervalSince1970: 1000)
        let fp = MessageFingerprintStore.computeFingerprint(
            sender: "Asha",
            chatName: "Asha",
            text: "Ping",
            timestamp: "10:00",
            elementIdentity: "e1"
        )

        XCTAssertTrue(store.shouldAccept(fp, now: t0))
        XCTAssertFalse(store.shouldAccept(fp, now: t0.addingTimeInterval(5)))
        XCTAssertTrue(store.shouldAccept(fp, now: t0.addingTimeInterval(20)), "Expired entry should be pruned")

        for i in 0..<80 {
            let entry = MessageFingerprintStore.computeFingerprint(
                sender: "User",
                chatName: "Chat",
                text: "Msg \(i)",
                timestamp: nil,
                elementIdentity: "id-\(i)"
            )
            _ = store.shouldAccept(entry, now: t0.addingTimeInterval(30))
        }
        XCTAssertLessThanOrEqual(store.count, 50)
    }

    func testMessageProcessorIgnoresOutgoingAndRespectsAmbiguousPolicy() {
        let processor = MessageProcessor()
        let outgoing = ExtractedCandidate(
            sender: "You",
            chatName: "Rahul",
            text: "On my way",
            timestamp: "11:40 PM",
            direction: .outgoing,
            elementIdentity: "b1",
            baseConfidence: 0.95,
            extractionPath: "AXActiveChatPane"
        )
        let ambiguous = ExtractedCandidate(
            sender: nil,
            chatName: "Design Team",
            text: "Check Figma",
            timestamp: "11:41 PM",
            direction: .ambiguous,
            elementIdentity: "b2",
            baseConfidence: 0.80,
            extractionPath: "AXActiveChatPane"
        )
        let incoming = ExtractedCandidate(
            sender: "Rahul",
            chatName: "Rahul",
            text: "Bhai kal milte hain\u{0007}",
            timestamp: "11:42 PM",
            avatar: "https://evil.example.com/avatar.png",
            direction: .incoming,
            elementIdentity: "b3",
            baseConfidence: 0.92,
            extractionPath: "AXActiveChatPane"
        )

        let strictConfig = HelperConfiguration(
            monitoringEnabled: true,
            ambiguousDirectionPolicy: .ignore,
            maxPreviewLength: 100
        )
        let strictResult = processor.process(
            candidates: [outgoing, ambiguous, incoming],
            config: strictConfig
        )
        XCTAssertEqual(strictResult.count, 1)
        XCTAssertEqual(strictResult[0].sender, "Rahul")
        XCTAssertEqual(strictResult[0].text, "Bhai kal milte hain")
        XCTAssertNil(strictResult[0].avatar, "External URLs must be stripped for safety")

        let permissiveConfig = HelperConfiguration(
            monitoringEnabled: true,
            ambiguousDirectionPolicy: .forwardLowConfidence,
            maxPreviewLength: 100
        )
        let permissiveResult = processor.process(
            candidates: [ambiguous],
            config: permissiveConfig
        )
        XCTAssertEqual(permissiveResult.count, 1)
        XCTAssertLessThanOrEqual(permissiveResult[0].confidence, 0.45)
        XCTAssertNil(permissiveResult[0].sender, "Missing sender must remain nil, never fabricated")
    }

    func testExtractorDetectsIncomingLeftBubbleAndIgnoresRightOutgoingBubble() {
        let extractor = AccessibilityExtractor()
        let leftBubble = AXNodeSnapshot(
            role: "AXGroup",
            identifier: "msg-in-1",
            frame: CGRect(x: 320, y: 400, width: 220, height: 48),
            children: [
                AXNodeSnapshot(role: "AXStaticText", value: "Rahul"),
                AXNodeSnapshot(role: "AXStaticText", value: "See you at 5"),
                AXNodeSnapshot(role: "AXStaticText", value: "4:55 PM"),
            ]
        )
        let rightBubble = AXNodeSnapshot(
            role: "AXGroup",
            identifier: "msg-out-1",
            frame: CGRect(x: 680, y: 460, width: 200, height: 42),
            children: [
                AXNodeSnapshot(role: "AXStaticText", value: "Sounds good!"),
                AXNodeSnapshot(role: "AXStaticText", value: "4:56 PM"),
            ]
        )
        let chatScroll = AXNodeSnapshot(
            role: "AXScrollArea",
            frame: CGRect(x: 300, y: 80, width: 620, height: 500),
            children: [leftBubble, rightBubble]
        )
        let window = AXNodeSnapshot(
            role: "AXWindow",
            title: "Rahul",
            frame: CGRect(x: 0, y: 0, width: 940, height: 600),
            children: [chatScroll]
        )

        let candidates = extractor.extractFromWindowSnapshot(window)
        XCTAssertEqual(candidates.count, 2)
        XCTAssertEqual(candidates[0].direction, .incoming)
        XCTAssertEqual(candidates[0].sender, "Rahul")
        XCTAssertEqual(candidates[0].text, "See you at 5")
        XCTAssertEqual(candidates[1].direction, .outgoing)
    }

    func testExtractorDetectsSidebarUnreadRowAndIgnoresSelfReplyPreview() {
        let extractor = AccessibilityExtractor()
        let unreadIncomingRow = AXNodeSnapshot(
            role: "AXRow",
            identifier: "chat-row-1",
            descriptionText: "1 unread message",
            children: [
                AXNodeSnapshot(role: "AXStaticText", value: "Neha"),
                AXNodeSnapshot(role: "AXStaticText", value: "11:10 AM"),
                AXNodeSnapshot(role: "AXStaticText", value: "1"),
                AXNodeSnapshot(role: "AXStaticText", value: "Are you free?"),
            ]
        )
        let outgoingRow = AXNodeSnapshot(
            role: "AXRow",
            identifier: "chat-row-2",
            descriptionText: "1 unread message",
            children: [
                AXNodeSnapshot(role: "AXStaticText", value: "Vikram"),
                AXNodeSnapshot(role: "AXStaticText", value: "You: Sent the deck"),
            ]
        )
        let window = AXNodeSnapshot(
            role: "AXWindow",
            title: "WhatsApp",
            children: [
                AXNodeSnapshot(role: "AXTable", children: [unreadIncomingRow, outgoingRow])
            ]
        )

        let candidates = extractor.extractFromWindowSnapshot(window)
        XCTAssertEqual(candidates.count, 2)
        XCTAssertEqual(candidates[0].direction, .incoming)
        XCTAssertEqual(candidates[0].sender, "Neha")
        XCTAssertEqual(candidates[0].text, "Are you free?")
        XCTAssertEqual(candidates[1].direction, .outgoing)
    }

    func testIPCFrameEncodeAndPartialDecode() {
        let msg = WhatsAppMessage(
            id: "m-1",
            sender: "PingGlass Test",
            chatName: "Bridge Verification",
            text: "Hello ✨",
            timestamp: "11:50 PM",
            confidence: 1.0,
            isTest: true
        )
        let env1 = BridgeEnvelope(type: "incoming_message", message: msg)
        let env2 = BridgeEnvelope(type: "pong", helperConnected: true)

        guard let frame1 = NativeMessagingServer.encodeFrame(env1),
              let frame2 = NativeMessagingServer.encodeFrame(env2) else {
            return XCTFail("Expected valid frames")
        }

        var combined = Data()
        combined.append(frame1.prefix(6))
        XCTAssertEqual(NativeMessagingServer.decodeFrames(from: &combined).count, 0)

        combined.append(frame1.dropFirst(6))
        combined.append(frame2)
        let decoded = NativeMessagingServer.decodeFrames(from: &combined)
        XCTAssertEqual(decoded.count, 2)
        XCTAssertEqual(decoded[0].type, "incoming_message")
        XCTAssertEqual(decoded[0].message?.text, "Hello ✨")
        XCTAssertEqual(decoded[1].type, "pong")
        XCTAssertEqual(combined.count, 0)
    }

    // MARK: - Global Notification Stack, Layout & Config Tests

    func testDisplayScreenLocatorAllPositionsAndMultiMonitorBounds() {
        let visibleFrame = CGRect(x: 1440, y: 60, width: 1920, height: 995) // secondary display with Dock at bottom
        let sizes = [
            CGSize(width: 350, height: 100),
            CGSize(width: 350, height: 110),
            CGSize(width: 350, height: 90),
        ]

        // Bottom-right stacks upward without overlap
        let brFrames = DisplayScreenLocator.computeStackedFrames(
            cardSizes: sizes,
            in: visibleFrame,
            position: .bottomRight,
            edgeMargin: 28,
            stackSpacing: 10
        )
        XCTAssertEqual(brFrames.count, 3)
        XCTAssertEqual(brFrames[0].origin.x, 1440 + 1920 - 28 - 350)
        XCTAssertEqual(brFrames[0].origin.y, 60 + 28)
        XCTAssertEqual(brFrames[1].origin.y, brFrames[0].maxY + 10)
        XCTAssertEqual(brFrames[2].origin.y, brFrames[1].maxY + 10)
        XCTAssertFalse(brFrames[0].intersects(brFrames[1]))
        XCTAssertFalse(brFrames[1].intersects(brFrames[2]))

        // Top-right, top-left, bottom-left, center-right stay inside visibleFrame
        for position in NotificationPosition.allCases {
            let frames = DisplayScreenLocator.computeStackedFrames(
                cardSizes: sizes,
                in: visibleFrame,
                position: position,
                edgeMargin: 28,
                stackSpacing: 10
            )
            XCTAssertEqual(frames.count, 3)
            for frame in frames {
                XCTAssertTrue(visibleFrame.contains(frame), "Frame \(frame) must fit inside \(visibleFrame) for \(position)")
            }
            XCTAssertFalse(frames[0].intersects(frames[1]))
            XCTAssertFalse(frames[1].intersects(frames[2]))
        }
    }

    func testNotificationStackQueueEnforcesMaxVisibleAndFIFO() {
        let queue = NotificationStackQueue(maxVisible: 3, maxPendingCapacity: 5)
        let messages = (1...5).map { idx in
            WhatsAppMessage(id: "msg-\(idx)", sender: "User \(idx)", text: "Hi \(idx)")
        }

        XCTAssertEqual(queue.enqueue(messages[0]), .displayNow)
        XCTAssertEqual(queue.enqueue(messages[1]), .displayNow)
        XCTAssertEqual(queue.enqueue(messages[2]), .displayNow)
        XCTAssertEqual(queue.enqueue(messages[2]), .ignoredDuplicate)
        XCTAssertEqual(queue.enqueue(messages[3]), .queued)
        XCTAssertEqual(queue.enqueue(messages[4]), .queued)

        XCTAssertEqual(queue.visibleMessages.count, 3)
        XCTAssertEqual(queue.pendingMessages.map(\.id), ["msg-4", "msg-5"])

        let promoted1 = queue.remove(id: "msg-1")
        XCTAssertEqual(promoted1?.id, "msg-4")
        let promoted2 = queue.remove(id: "msg-2")
        XCTAssertEqual(promoted2?.id, "msg-5")
        XCTAssertEqual(queue.pendingMessages.count, 0)

        queue.clearAll()
        XCTAssertEqual(queue.visibleMessages.count, 0)
        XCTAssertEqual(queue.pendingMessages.count, 0)
    }

    func testHelperConfigurationBackwardCompatibleDecodingAndPauseState() throws {
        let legacyJSON = """
        {
          "monitoringEnabled": true,
          "fallbackPollingIntervalSeconds": 4.5,
          "ambiguousDirectionPolicy": "forward_low_confidence",
          "maxPreviewLength": 240
        }
        """
        let decoded = try JSONDecoder().decode(HelperConfiguration.self, from: Data(legacyJSON.utf8))
        XCTAssertTrue(decoded.monitoringEnabled)
        XCTAssertEqual(decoded.fallbackPollingIntervalSeconds, 4.5)
        XCTAssertEqual(decoded.ambiguousDirectionPolicy, .forwardLowConfidence)
        XCTAssertEqual(decoded.maxPreviewLength, 240)
        XCTAssertTrue(decoded.globalNotificationsEnabled)
        XCTAssertEqual(decoded.notificationDurationSeconds, 0)
        XCTAssertEqual(decoded.maxVisibleNotifications, 3)
        XCTAssertEqual(decoded.notificationPosition, .bottomRight)
        XCTAssertEqual(decoded.edgeMargin, 28.0)
        XCTAssertEqual(decoded.appearanceMode, .dark)
        XCTAssertFalse(decoded.soundEnabled)

        var timedPause = decoded
        let now = Date(timeIntervalSince1970: 5000)
        timedPause.pausedUntil = now.addingTimeInterval(900)
        XCTAssertTrue(timedPause.isNotificationsPaused(at: now))
        XCTAssertFalse(timedPause.isNotificationsPaused(at: now.addingTimeInterval(1000)))

        timedPause.pausedUntil = nil
        timedPause.pausedIndefinitely = true
        XCTAssertTrue(timedPause.isNotificationsPaused(at: now.addingTimeInterval(10000)))
    }

    @MainActor
    func testNonActivatingPanelPropertiesAndWindowManagerLifecycle() {
        _ = NSApplication.shared

        let panel = FloatingNotificationPanel(contentRect: NSRect(x: 0, y: 0, width: 350, height: 100))
        XCTAssertFalse(panel.canBecomeKey)
        XCTAssertFalse(panel.canBecomeMain)
        XCTAssertFalse(panel.hidesOnDeactivate)
        XCTAssertTrue(panel.styleMask.contains(.borderless))
        XCTAssertTrue(panel.styleMask.contains(.nonactivatingPanel))
        XCTAssertEqual(panel.level, .statusBar)
        XCTAssertTrue(panel.collectionBehavior.contains(.canJoinAllSpaces))
        XCTAssertTrue(panel.collectionBehavior.contains(.fullScreenAuxiliary))
        XCTAssertTrue(panel.collectionBehavior.contains(.ignoresCycle))
        panel.close()

        // Test burst of 5 messages through GlobalNotificationWindowManager:
        // 3 active windows, 2 queued, pause clears cleanly without leaks.
        var cfg = HelperConfiguration(
            globalNotificationsEnabled: true,
            animationEnabled: false,
            notificationDurationSeconds: 6,
            maxVisibleNotifications: 3
        )
        let manager = GlobalNotificationWindowManager(config: cfg)

        for i in 1...5 {
            manager.enqueue(
                WhatsAppMessage(
                    id: "wm-\(i)",
                    sender: "Sender \(i)",
                    chatName: "Chat \(i)",
                    text: "Message \(i)",
                    timestamp: "NOW"
                ),
                config: cfg
            )
        }
        XCTAssertEqual(manager.activeWindowCount, 3)
        XCTAssertEqual(manager.queuedCount, 2)
        XCTAssertTrue(manager.isClearAllBarVisible)

        // Dismiss one -> promotes queued #4 immediately
        manager.dismiss(id: "wm-1", animated: false)
        XCTAssertEqual(manager.activeWindowCount, 3)
        XCTAssertEqual(manager.queuedCount, 1)
        XCTAssertTrue(manager.isClearAllBarVisible)

        // Clear All -> dismisses all active windows, clears queue, hides Clear All bar
        manager.dismissAll(animated: false)
        XCTAssertEqual(manager.activeWindowCount, 0)
        XCTAssertEqual(manager.queuedCount, 0)
        XCTAssertFalse(manager.isClearAllBarVisible)

        // Re-enqueue and pause -> clears cleanly
        manager.enqueue(
            WhatsAppMessage(id: "wm-6", sender: "Sender 6", text: "Message 6"),
            config: cfg
        )
        XCTAssertEqual(manager.activeWindowCount, 1)
        XCTAssertTrue(manager.isClearAllBarVisible)
        cfg.pausedIndefinitely = true
        manager.updateConfiguration(cfg)
        XCTAssertEqual(manager.activeWindowCount, 0)
        XCTAssertEqual(manager.queuedCount, 0)
        XCTAssertFalse(manager.isClearAllBarVisible)

        // Verify ClearAllBarFrame stays strictly inside visibleFrame across all 5 positions
        let sampleBounds = CGRect(x: 0, y: 40, width: 1440, height: 835)
        let sampleCards = [CGRect(x: 1062, y: 68, width: 350, height: 100)]
        for pos in NotificationPosition.allCases {
            let barFrame = DisplayScreenLocator.computeClearAllBarFrame(
                for: sampleCards,
                barSize: CGSize(width: 112, height: 30),
                in: sampleBounds,
                position: pos,
                edgeMargin: 28
            )
            XCTAssertTrue(sampleBounds.contains(barFrame))
            let chatFrame = DisplayScreenLocator.computeChatPopupFrame(
                size: GlassChatPopupView.popupSize,
                in: sampleBounds,
                position: pos,
                edgeMargin: 28
            )
            XCTAssertTrue(sampleBounds.contains(chatFrame))
        }

        // Verify clicking a notification opens the floating Glass Chat Popup cleanly in place
        var clickConfig = HelperConfiguration(
            globalNotificationsEnabled: true,
            animationEnabled: false,
            notificationDurationSeconds: 0,
            notificationClickAction: .openGlassChatPopup
        )
        let clickedMsg = WhatsAppMessage(
            id: "click-1",
            sender: "Rahul Sharma",
            chatName: "Rahul Sharma",
            text: "Bhai kal milte hain",
            timestamp: "NOW"
        )
        manager.enqueue(clickedMsg, config: clickConfig)
        XCTAssertEqual(manager.activeWindowCount, 1)
        manager.handleNotificationCardClick(clickedMsg)
        XCTAssertEqual(manager.activeWindowCount, 0)
        XCTAssertTrue(manager.isChatPopupVisible)
        manager.closeChatPopup()
        XCTAssertFalse(manager.isChatPopupVisible)

        // Verify direct WhatsApp click mode triggers onOpenWhatsAppRequested
        clickConfig.notificationClickAction = .openWhatsAppDirectly
        var openRequestedForId: String?
        manager.onOpenWhatsAppRequested = { msg in
            openRequestedForId = msg.id
        }
        manager.updateConfiguration(clickConfig)
        manager.enqueue(clickedMsg, config: clickConfig)
        manager.handleNotificationCardClick(clickedMsg)
        XCTAssertEqual(openRequestedForId, "click-1")
    }

    func testSidebarRowMatchAndSessionChatStore() {
        let extractor = AccessibilityExtractor()
        let rahulRow = AXNodeSnapshot(
            role: "AXRow",
            identifier: "row-rahul",
            children: [
                AXNodeSnapshot(role: "AXStaticText", value: "Rahul Sharma"),
                AXNodeSnapshot(role: "AXStaticText", value: "Bhai kal milte hain"),
            ]
        )
        let nehaRow = AXNodeSnapshot(
            role: "AXRow",
            identifier: "row-neha",
            children: [
                AXNodeSnapshot(role: "AXStaticText", value: "Neha"),
                AXNodeSnapshot(role: "AXStaticText", value: "Hello"),
            ]
        )
        let window = AXNodeSnapshot(
            role: "AXWindow",
            title: "WhatsApp",
            children: [AXNodeSnapshot(role: "AXTable", children: [nehaRow, rahulRow])]
        )
        let matched = extractor.findMatchingSidebarRow(in: window, targetChatTitle: "rahul sharma")
        XCTAssertEqual(matched?.identifier, "row-rahul")

        let store = SessionChatStore(maxChats: 5, maxMessagesPerChat: 10)
        let m1 = WhatsAppMessage(id: "c1", sender: "Rahul Sharma", chatName: "Rahul Sharma", text: "One", timestamp: "10:00")
        let m2 = WhatsAppMessage(id: "c2", sender: "Rahul Sharma", chatName: "Rahul Sharma", text: "Two", timestamp: "10:01")
        store.record(m1)
        store.record(m2)
        XCTAssertEqual(store.messages(for: m1).map(\.text), ["One", "Two"])
        store.clearAll()
        XCTAssertEqual(store.messages(for: m1).count, 0)
    }

    func testExtendedBridgeSettingsAndSnapshotRoundTrip() throws {
        let payload = BridgeSettingsPayload(
            monitoringEnabled: true,
            ambiguousDirectionPolicy: .ignore,
            maxPreviewLength: 280,
            globalNotificationsEnabled: true,
            chromeForwardingEnabled: true,
            notificationsPaused: false,
            pauseMinutes: 15,
            pausedIndefinitely: false,
            animationEnabled: true,
            soundEnabled: false,
            autoDismissSeconds: 0,
            maxVisibleNotifications: 3,
            notificationPosition: .bottomRight,
            edgeMargin: 24,
            appearanceMode: .dark,
            notificationClickAction: .openGlassChatPopup,
            showAvatar: true,
            showSender: true,
            showChatName: true,
            showTimestamp: true,
            showPreview: true,
            showCopyButton: true
        )
        let snap = HelperStatusSnapshot(
            monitoringState: .monitoringActive,
            monitoringEnabled: true,
            whatsappRunning: true,
            whatsappActive: false,
            whatsappBundleId: "net.whatsapp.WhatsApp",
            whatsappVersion: "26.43.77",
            accessibilityGranted: true,
            observerAttached: true,
            fallbackPollingActive: false,
            extractionMode: "AXObserver + Live Sync",
            statusDetail: "Observing WhatsApp Desktop via Accessibility APIs.",
            sessionMessagesForwarded: 3,
            globalNotificationsEnabled: true,
            notificationsPaused: false,
            activeNotificationCount: 1,
            pauseSummary: "Active",
            config: payload
        )
        let envelope = BridgeEnvelope(type: "monitoring_status", status: snap, helperConnected: true)
        let data = try JSONEncoder().encode(envelope)
        let decoded = try JSONDecoder().decode(BridgeEnvelope.self, from: data)
        XCTAssertEqual(decoded.status?.activeNotificationCount, 1)
        XCTAssertEqual(decoded.status?.pauseSummary, "Active")
        XCTAssertEqual(decoded.status?.config?.notificationPosition, .bottomRight)
        XCTAssertEqual(decoded.status?.config?.notificationClickAction, .openGlassChatPopup)
        XCTAssertEqual(decoded.status?.config?.pauseMinutes, 15)
    }
}
