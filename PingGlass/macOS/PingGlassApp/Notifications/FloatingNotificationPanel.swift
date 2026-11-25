import AppKit

/// Borderless, transparent floating panel that renders above active macOS apps.
/// By default (`allowsKeyFocus = false`), panels never become key or steal focus.
/// When interactive text input is needed inside the Chat Reply Popup, `allowsKeyFocus = true`
/// uses `.nonactivatingPanel` + `becomesKeyOnlyIfNeeded` so typing works only after explicit user click.
final class FloatingNotificationPanel: NSPanel {
    private let allowsKeyFocus: Bool

    init(contentRect: NSRect, allowsKeyFocus: Bool = false) {
        self.allowsKeyFocus = allowsKeyFocus
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        isFloatingPanel = true
        // Status bar level floats reliably above regular apps, Chrome, VS Code, Finder,
        // Terminal, and auxiliary fullscreen spaces where macOS permits.
        level = .statusBar
        collectionBehavior = [
            .canJoinAllSpaces,
            .fullScreenAuxiliary,
            .ignoresCycle,
            .stationary,
        ]

        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        isMovableByWindowBackground = false
        acceptsMouseMovedEvents = true
        ignoresMouseEvents = false
        animationBehavior = .none
        becomesKeyOnlyIfNeeded = allowsKeyFocus
    }

    override var canBecomeKey: Bool {
        allowsKeyFocus
    }

    override var canBecomeMain: Bool {
        false
    }
}
