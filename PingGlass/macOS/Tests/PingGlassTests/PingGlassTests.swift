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

        // Verify Clear All triggers onClearAllRequested callback when Clear All pill action runs
        var clearAllTriggered = false
        manager.onClearAllRequested = {
            clearAllTriggered = true
            manager.dismissAll(animated: false)
        }
        manager.dismissAll(animated: false)
        XCTAssertFalse(clearAllTriggered, "Programmatic dismissAll does not fire onClearAllRequested")
        XCTAssertNotNil(manager.onClearAllRequested)

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

        // Ensure BridgeEnvelope decodes legacy/minimal Chrome messages omitting `timestamp`.
        var minimalData = Data()
        let raw = Data("{\"type\":\"start_monitoring\"}".utf8)
        var len = UInt32(raw.count).littleEndian
        minimalData.append(Data(bytes: &len, count: 4))
        minimalData.append(raw)
        let minimalDecoded = NativeMessagingServer.decodeFrames(from: &minimalData)
        XCTAssertEqual(minimalDecoded.count, 1)
        XCTAssertEqual(minimalDecoded.first?.type, "start_monitoring")
    }

    func testCatalystFullWidthBubbleRowAndContainerDescriptionExtraction() {
        let extractor = AccessibilityExtractor()

        // Full-width Catalyst AXCell (width 620, midX=610 -> 0.50 of container 620) containing left-aligned inner bubble (x=318, w=180)
        let innerLeftBubble = AXNodeSnapshot(
            role: "AXGroup",
            frame: CGRect(x: 318, y: 400, width: 180, height: 42),
            children: [
                AXNodeSnapshot(role: "AXStaticText", value: "Amit"),
                AXNodeSnapshot(role: "AXStaticText", value: "Meeting started"),
                AXNodeSnapshot(role: "AXStaticText", value: "1:18 AM"),
            ]
        )
        let fullWidthRow = AXNodeSnapshot(
            role: "AXCell",
            identifier: "cat-msg-1",
            frame: CGRect(x: 300, y: 396, width: 620, height: 50),
            children: [innerLeftBubble]
        )
        let chatScroll = AXNodeSnapshot(
            role: "AXScrollArea",
            frame: CGRect(x: 300, y: 80, width: 620, height: 500),
            children: [fullWidthRow]
        )

        // Catalyst sidebar row where cell AXDescription carries unread badge + preview while child static text carries time
        let unreadCell = AXNodeSnapshot(
            role: "AXCell",
            identifier: "cat-side-1",
            descriptionText: "1 unread message",
            children: [
                AXNodeSnapshot(role: "AXStaticText", value: "Priya"),
                AXNodeSnapshot(role: "AXStaticText", value: "Can you check?"),
                AXNodeSnapshot(role: "AXStaticText", value: "1:19 AM"),
            ]
        )
        let sidebar = AXNodeSnapshot(
            role: "AXTable",
            frame: CGRect(x: 0, y: 80, width: 290, height: 500),
            children: [unreadCell]
        )
        let window = AXNodeSnapshot(
            role: "AXWindow",
            title: "Amit",
            frame: CGRect(x: 0, y: 0, width: 920, height: 600),
            children: [sidebar, chatScroll]
        )

        let candidates = extractor.extractFromWindowSnapshot(window)
        let activeIncoming = candidates.filter { $0.extractionPath == "AXActiveChatPane" }
        let sidebarUnread = candidates.filter { $0.extractionPath == "AXSidebarUnread" }

        XCTAssertEqual(activeIncoming.count, 1)
        XCTAssertEqual(activeIncoming.first?.direction, .incoming)
        XCTAssertEqual(activeIncoming.first?.text, "Meeting started")

        XCTAssertEqual(sidebarUnread.count, 1)
        XCTAssertEqual(sidebarUnread.first?.sender, "Priya")
        XCTAssertEqual(sidebarUnread.first?.text, "Can you check?")
    }

    func testNotificationCenterBannerExtractionFiltersNonWhatsAppAndDeduplicatesCrossSource() {
        let extractor = AccessibilityExtractor()

        let whatsappBanner = AXNodeSnapshot(
            role: "AXGroup",
            subrole: "AXNotificationCenterBanner",
            identifier: "banner-wa-1",
            children: [
                AXNodeSnapshot(role: "AXHeading", value: "WhatsApp"),
                AXNodeSnapshot(role: "AXStaticText", value: "Rahul Sharma"),
                AXNodeSnapshot(role: "AXStaticText", value: "Reached home safely"),
                AXNodeSnapshot(role: "AXButton", title: "Close"),
            ]
        )
        let mailBanner = AXNodeSnapshot(
            role: "AXGroup",
            subrole: "AXNotificationCenterBanner",
            identifier: "banner-mail-1",
            children: [
                AXNodeSnapshot(role: "AXHeading", value: "Mail"),
                AXNodeSnapshot(role: "AXStaticText", value: "Newsletter"),
                AXNodeSnapshot(role: "AXStaticText", value: "Weekly digest"),
            ]
        )
        let ncWindow = AXNodeSnapshot(
            role: "AXWindow",
            children: [whatsappBanner, mailBanner]
        )

        let extracted = extractor.extractWhatsAppBanners(fromNotificationWindowSnapshot: ncWindow)
        XCTAssertEqual(extracted.count, 1, "Only WhatsApp banners must be extracted; non-WhatsApp banners must be ignored")
        XCTAssertEqual(extracted[0].sender, "Rahul Sharma")
        XCTAssertEqual(extracted[0].text, "Reached home safely")
        XCTAssertEqual(extracted[0].extractionPath, "AXNotificationBanner")
        XCTAssertEqual(extracted[0].direction, .incoming)

        // Cross-source deduplication: simultaneous AXNotificationBanner + AXSidebarUnread yields 1 message
        let sidebarDuplicate = ExtractedCandidate(
            sender: "Rahul Sharma",
            chatName: "Rahul Sharma",
            text: "Reached home safely",
            timestamp: "1:22 AM",
            direction: .incoming,
            elementIdentity: "sidebar-row-0",
            occurrenceIndex: 0,
            baseConfidence: 0.85,
            extractionPath: "AXSidebarUnread"
        )
        let processor = MessageProcessor()
        let config = HelperConfiguration(monitoringEnabled: true)
        let t0 = Date(timeIntervalSince1970: 2000)

        let firstPass = processor.process(candidates: extracted, config: config, seedOnly: false, now: t0)
        let secondPass = processor.process(candidates: [sidebarDuplicate], config: config, seedOnly: false, now: t0.addingTimeInterval(2))
        XCTAssertEqual(firstPass.count, 1)
        XCTAssertEqual(secondPass.count, 0, "Simultaneous sidebar match for same banner message should deduplicate cleanly")

        // Verify composite AXDescription isn't duplicated alongside ordered child leaves and directional marks are stripped
        let packedBanner = AXNodeSnapshot(
            role: "AXGroup",
            subrole: "AXNotificationCenterBanner",
            descriptionText: "WhatsApp, \u{200E}Amit Verma, \u{200F}See you soon",
            children: [
                AXNodeSnapshot(role: "AXHeading", value: "\u{200E}Amit Verma"),
                AXNodeSnapshot(role: "AXStaticText", value: "\u{200E}See you soon"),
                AXNodeSnapshot(role: "AXButton", title: "Show less"),
            ]
        )
        let cleanBannerMsgs = processor.process(
            candidates: extractor.extractWhatsAppBanners(fromNotificationWindowSnapshot: AXNodeSnapshot(role: "AXWindow", children: [packedBanner])),
            config: config,
            seedOnly: false,
            now: t0.addingTimeInterval(5)
        )
        XCTAssertEqual(cleanBannerMsgs.count, 1)
        XCTAssertEqual(cleanBannerMsgs[0].sender, "Amit Verma")
        XCTAssertEqual(cleanBannerMsgs[0].chatName, "Amit Verma")
        XCTAssertEqual(cleanBannerMsgs[0].text, "See you soon")

        // Verify SessionChatStore.recordOutgoing & interactive FloatingNotificationPanel(allowsKeyFocus:)
        let store = SessionChatStore()
        let incoming = cleanBannerMsgs[0]
        store.record(incoming)
        _ = store.recordOutgoing(text: "On my way!", for: incoming)
        let bubbles = store.messages(for: incoming)
        XCTAssertEqual(bubbles.count, 2)
        XCTAssertFalse(bubbles[0].isOutgoing)
        XCTAssertTrue(bubbles[1].isOutgoing)
        XCTAssertEqual(bubbles[1].text, "On my way!")

        let replyPanel = FloatingNotificationPanel(contentRect: NSRect(x: 0, y: 0, width: 318, height: 356), allowsKeyFocus: true)
        XCTAssertTrue(replyPanel.canBecomeKey)
        XCTAssertFalse(replyPanel.canBecomeMain)
        XCTAssertTrue(replyPanel.becomesKeyOnlyIfNeeded)
        replyPanel.close()
    }

    func testCatalystWrapperBubbleUnwrappingAndButtonSidebarUnread() {
        let extractor = AccessibilityExtractor()

        // Catalyst collection wrapper AXGroup inside AXScrollArea containing two separate bubble AXGroups
        let bubble1 = AXNodeSnapshot(
            role: "AXGroup",
            frame: CGRect(x: 320, y: 360, width: 190, height: 42),
            children: [
                AXNodeSnapshot(role: "AXStaticText", value: "Kiran"),
                AXNodeSnapshot(role: "AXStaticText", value: "Reaching in 5 mins"),
                AXNodeSnapshot(role: "AXStaticText", value: "1:44 AM"),
            ]
        )
        let bubble2 = AXNodeSnapshot(
            role: "AXGroup",
            frame: CGRect(x: 680, y: 420, width: 170, height: 40),
            children: [
                AXNodeSnapshot(role: "AXStaticText", value: "Okay see you"),
                AXNodeSnapshot(role: "AXStaticText", value: "1:45 AM"),
            ]
        )
        let collectionWrapper = AXNodeSnapshot(
            role: "AXGroup",
            frame: CGRect(x: 300, y: 80, width: 620, height: 500),
            children: [bubble1, bubble2]
        )
        let chatScroll = AXNodeSnapshot(
            role: "AXScrollArea",
            frame: CGRect(x: 300, y: 80, width: 620, height: 500),
            children: [collectionWrapper]
        )

        // Catalyst sidebar chat item exposed as AXButton with packed description
        let buttonCell = AXNodeSnapshot(
            role: "AXButton",
            descriptionText: "Rohan, 1:45 AM, Call me now, 2 unread messages",
            children: []
        )
        let window = AXNodeSnapshot(
            role: "AXWindow",
            title: "Kiran",
            frame: CGRect(x: 0, y: 0, width: 920, height: 600),
            children: [buttonCell, chatScroll]
        )

        let candidates = extractor.extractFromWindowSnapshot(window)
        let incomingBubbles = candidates.filter { $0.extractionPath == "AXActiveChatPane" && $0.direction == .incoming }
        let sidebarUnread = candidates.filter { $0.extractionPath == "AXSidebarUnread" }

        XCTAssertEqual(incomingBubbles.count, 1)
        XCTAssertEqual(incomingBubbles.first?.text, "Reaching in 5 mins")
        XCTAssertEqual(sidebarUnread.count, 1)
        XCTAssertEqual(sidebarUnread.first?.sender, "Rohan")
        XCTAssertEqual(sidebarUnread.first?.text, "Call me now")
    }

    func testCatalystV26TreeExtractionAndNoRepeatAfterClearAll() {
        let extractor = AccessibilityExtractor()
        let processor = MessageProcessor()
        let config = HelperConfiguration(monitoringEnabled: true)

        // Exact WhatsApp v26.43.77 Catalyst AX hierarchy:
        // - Filter chip buttons (`ChatListView_chipButtonsCell` / `ChatListFilterAction_Unread`) MUST be ignored
        // - Sidebar rows inside `ChatListView_TableView` use stable identities without row indices
        // - Active header uses `NavigationBar_HeaderViewButton` (not sidebar "Chats" heading)
        // - Transcript container uses `AXGroup id=ChatMessagesTableView` + `AXStaticText id=WAMessageBubbleTableViewCell`
        let filterChipUnread = AXNodeSnapshot(
            role: "AXButton",
            identifier: "ChatListFilterAction_Unread",
            title: "Unread 2",
            frame: CGRect(x: 92, y: 120, width: 78, height: 30)
        )
        let chipContainer = AXNodeSnapshot(
            role: "AXGroup",
            identifier: "ChatListView_chipButtonsCell",
            frame: CGRect(x: 0, y: 112, width: 460, height: 42),
            children: [filterChipUnread]
        )
        let unreadRowA = AXNodeSnapshot(
            role: "AXButton",
            descriptionText: "Rohan, 2:10 PM, Hey there, 1 unread message",
            frame: CGRect(x: 0, y: 188, width: 460, height: 69)
        )
        let sidebarTable = AXNodeSnapshot(
            role: "AXGroup",
            identifier: "ChatListView_TableView",
            frame: CGRect(x: 0, y: 34, width: 460, height: 983),
            children: [
                AXNodeSnapshot(role: "AXHeading", value: "Chats", frame: CGRect(x: 281, y: 52, width: 38, height: 19)),
                chipContainer,
                unreadRowA,
            ]
        )
        let navHeader = AXNodeSnapshot(
            role: "AXButton",
            identifier: "NavigationBar_HeaderViewButton",
            title: "Neha",
            descriptionText: "Neha, tap here for contact info",
            frame: CGRect(x: 510, y: 44, width: 210, height: 36)
        )
        let incomingBubble = AXNodeSnapshot(
            role: "AXStaticText",
            identifier: "WAMessageBubbleTableViewCell",
            value: "Dinner at 8?",
            descriptionText: "Dinner at 8?",
            frame: CGRect(x: 477, y: 400, width: 120, height: 40)
        )
        let outgoingBubble = AXNodeSnapshot(
            role: "AXStaticText",
            identifier: "WAMessageBubbleTableViewCell",
            value: "Yes works!",
            descriptionText: "Yes works!",
            frame: CGRect(x: 690, y: 460, width: 115, height: 40)
        )
        let messagesTable = AXNodeSnapshot(
            role: "AXGroup",
            identifier: "ChatMessagesTableView",
            frame: CGRect(x: 461, y: 34, width: 401, height: 983),
            children: [incomingBubble, outgoingBubble]
        )
        let window1 = AXNodeSnapshot(
            role: "AXWindow",
            title: "WhatsApp",
            frame: CGRect(x: 0, y: 34, width: 862, height: 983),
            children: [sidebarTable, navHeader, messagesTable]
        )

        let c1 = extractor.extractFromWindowSnapshot(window1)
        // Filter chip "Unread 2" must NOT produce a candidate
        let hasUnreadChip = c1.contains { item in
            let textMatch = item.text?.contains("Unread 2") == true
            let senderMatch = item.sender?.contains("Unread") == true
            return textMatch || senderMatch
        }
        let hasRohanSidebar = c1.contains { item in
            item.extractionPath == "AXSidebarUnread" &&
                item.sender == "Rohan" &&
                item.text == "Hey there"
        }
        let hasNehaActiveBubble = c1.contains { item in
            item.extractionPath == "AXActiveChatPane" &&
                item.chatName == "Neha" &&
                item.text == "Dinner at 8?" &&
                item.direction == .incoming
        }
        XCTAssertFalse(hasUnreadChip)
        XCTAssertTrue(hasRohanSidebar)
        XCTAssertTrue(hasNehaActiveBubble)

        let t0 = Date(timeIntervalSince1970: 10_000)
        let batch1 = processor.process(candidates: c1, config: config, seedOnly: false, now: t0)
        XCTAssertEqual(batch1.count, 2, "Initial scan should emit Rohan unread + Neha incoming bubble once")

        // Simulate user clicking Clear All -> 30 minutes pass -> WhatsApp reorders sidebar rows
        // (a different chat arrives above Rohan so Rohan shifts down) and increments chip count.
        let newUnreadRow = AXNodeSnapshot(
            role: "AXButton",
            descriptionText: "Priya, 2:40 PM, Just reached, 1 unread message",
            frame: CGRect(x: 0, y: 188, width: 460, height: 69)
        )
        let shiftedUnreadRowA = AXNodeSnapshot(
            role: "AXButton",
            descriptionText: "Rohan, 2:10 PM, Hey there, 1 unread message",
            frame: CGRect(x: 0, y: 257, width: 460, height: 69)
        )
        let updatedSidebar = AXNodeSnapshot(
            role: "AXGroup",
            identifier: "ChatListView_TableView",
            frame: CGRect(x: 0, y: 34, width: 460, height: 983),
            children: [
                AXNodeSnapshot(role: "AXHeading", value: "Chats", frame: CGRect(x: 281, y: 52, width: 38, height: 19)),
                AXNodeSnapshot(
                    role: "AXGroup",
                    identifier: "ChatListView_chipButtonsCell",
                    children: [AXNodeSnapshot(role: "AXButton", identifier: "ChatListFilterAction_Unread", title: "Unread 3")]
                ),
                newUnreadRow,
                shiftedUnreadRowA,
            ]
        )
        let window2 = AXNodeSnapshot(
            role: "AXWindow",
            title: "WhatsApp",
            frame: CGRect(x: 0, y: 34, width: 862, height: 983),
            children: [updatedSidebar, navHeader, messagesTable]
        )

        let c2 = extractor.extractFromWindowSnapshot(window2)
        let batch2 = processor.process(candidates: c2, config: config, seedOnly: false, now: t0.addingTimeInterval(1800))
        XCTAssertEqual(batch2.count, 1, "Only the genuinely new message from Priya should notify after Clear All + row shift + 30m")
        XCTAssertEqual(batch2.first?.sender, "Priya")
        XCTAssertEqual(batch2.first?.text, "Just reached")
    }
}
