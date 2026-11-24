import AppKit
import CoreGraphics
import Foundation

/// Pure screen bounds representation used for testable display placement math.
public struct ScreenBounds: Sendable, Equatable {
    public let frame: CGRect
    public let visibleFrame: CGRect

    public init(frame: CGRect, visibleFrame: CGRect) {
        self.frame = frame
        self.visibleFrame = visibleFrame
    }
}

/// Locates the target macOS display and computes non-overlapping notification frames within `visibleFrame`.
public enum DisplayScreenLocator {
    /// Selects the target `NSScreen` according to user preference without polling continuously.
    @MainActor
    public static func targetScreen(for mode: PreferredDisplayMode) -> NSScreen? {
        let screens = NSScreen.screens
        guard !screens.isEmpty else { return nil }

        switch mode {
        case .primaryDisplay:
            return screens.first
        case .secondaryDisplay:
            return screens.dropFirst().first ?? screens.first
        case .activeDisplay:
            let mouseLocation = NSEvent.mouseLocation
            if let cursorScreen = screens.first(where: { NSMouseInRect(mouseLocation, $0.frame, false) }) {
                return cursorScreen
            }
            return NSScreen.main ?? screens.first
        }
    }

    @MainActor
    public static func targetBounds(for mode: PreferredDisplayMode) -> ScreenBounds {
        guard let screen = targetScreen(for: mode) else {
            return ScreenBounds(
                frame: CGRect(x: 0, y: 0, width: 1440, height: 900),
                visibleFrame: CGRect(x: 0, y: 40, width: 1440, height: 835)
            )
        }
        return ScreenBounds(frame: screen.frame, visibleFrame: screen.visibleFrame)
    }

    /// Computes stacked `CGRect` frames in AppKit global screen coordinates (origin bottom-left).
    /// Index `0` sits closest to the primary corner anchor (e.g., newest notification sliding in at bottom-right).
    public static func computeStackedFrames(
        cardSizes: [CGSize],
        in visibleFrame: CGRect,
        position: NotificationPosition,
        edgeMargin: CGFloat,
        stackSpacing: CGFloat = 10.0
    ) -> [CGRect] {
        guard !cardSizes.isEmpty else { return [] }

        let safeMargin = max(8.0, min(64.0, edgeMargin))
        let safeInset: CGFloat = 8.0

        func clampedX(width: CGFloat) -> CGFloat {
            let rawX: CGFloat
            if position.isRightAligned {
                rawX = visibleFrame.maxX - safeMargin - width
            } else {
                rawX = visibleFrame.minX + safeMargin
            }
            let minAllowed = visibleFrame.minX + safeInset
            let maxAllowed = max(minAllowed, visibleFrame.maxX - width - safeInset)
            return min(max(rawX, minAllowed), maxAllowed)
        }

        func clampY(_ y: CGFloat, height: CGFloat) -> CGFloat {
            let minAllowed = visibleFrame.minY + safeInset
            let maxAllowed = max(minAllowed, visibleFrame.maxY - height - safeInset)
            return min(max(y, minAllowed), maxAllowed)
        }

        var frames: [CGRect] = []
        frames.reserveCapacity(cardSizes.count)

        switch position {
        case .bottomRight, .bottomLeft:
            var cursorY = visibleFrame.minY + safeMargin
            for size in cardSizes {
                let x = clampedX(width: size.width)
                let y = clampY(cursorY, height: size.height)
                frames.append(CGRect(origin: CGPoint(x: x, y: y), size: size))
                cursorY = y + size.height + stackSpacing
            }

        case .topRight, .topLeft:
            var cursorTopY = visibleFrame.maxY - safeMargin
            for size in cardSizes {
                let x = clampedX(width: size.width)
                let y = clampY(cursorTopY - size.height, height: size.height)
                frames.append(CGRect(origin: CGPoint(x: x, y: y), size: size))
                cursorTopY = y - stackSpacing
            }

        case .centerRight:
            let totalHeight = cardSizes.reduce(CGFloat(0)) { $0 + $1.height } +
                CGFloat(max(0, cardSizes.count - 1)) * stackSpacing
            // Stack centered around visibleFrame.midY, placing index 0 nearest center/top and subsequent below.
            var cursorTopY = min(
                visibleFrame.maxY - safeInset,
                visibleFrame.midY + totalHeight / 2.0
            )
            for size in cardSizes {
                let x = clampedX(width: size.width)
                let y = clampY(cursorTopY - size.height, height: size.height)
                frames.append(CGRect(origin: CGPoint(x: x, y: y), size: size))
                cursorTopY = y - stackSpacing
            }
        }

        return frames
    }
}
