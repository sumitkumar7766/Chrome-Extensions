# PingGlass — Global macOS Glass Notifications for WhatsApp Desktop

PingGlass is a local, privacy-first macOS notification utility that observes incoming messages from the **official native macOS WhatsApp Desktop app** (`net.whatsapp.WhatsApp`) via macOS Accessibility APIs and displays **native floating glass notifications globally above your entire macOS desktop** — regardless of whether you are working in Chrome, Safari, VS Code, Cursor, Terminal, Finder, Xcode, or any other app.

The existing Chrome Extension (MV3) and Native Messaging bridge remain preserved as an optional browser integration; **Chrome does not need to be open for global desktop notifications to work.**

> **Important:** PingGlass targets the native macOS **WhatsApp Desktop** application (`net.whatsapp.WhatsApp`), **not** WhatsApp Web.

---

## 1. Technical Reality & macOS Limitations

- **Accessibility permission is required**: macOS does not allow third-party apps to read another app's Notification Center banners directly. PingGlass uses public `AXUIElement` / `AXObserver` APIs with explicit user consent in **System Settings → Privacy & Security → Accessibility**.
- **Closed or minimized WhatsApp windows**: WhatsApp Desktop (`net.whatsapp.WhatsApp` v26.43.77, Mac Catalyst / `WAAppKitBridge`) may expose limited or no Accessibility nodes when its window is closed or minimized (`Monitoring Limited` state).
- **Zero fabricated data**: Missing Accessibility fields (`sender`, `chatName`, `text`, `timestamp`, `avatar`) remain `null`. Outgoing messages (`"You:"` labels or right-aligned bubbles) are filtered out; uncertain-direction messages are ignored by default (`AmbiguousDirectionPolicy.ignore`).
- **Fullscreen Spaces**: `FloatingNotificationPanel` configures `.nonactivatingPanel`, `level = .statusBar`, `.canJoinAllSpaces`, and `.fullScreenAuxiliary` so notifications appear above normal apps and standard macOS fullscreen apps without switching Spaces or stealing focus. However, macOS WindowServer may still prevent auxiliary panels from appearing above exclusive Metal/DRM fullscreen games or protected video players.

---

## 2. Project Structure

```text
PingGlass/
├── macOS/
│   ├── Package.swift
│   ├── PingGlassApp/
│   │   ├── Info.plist
│   │   ├── PingGlassApp.swift
│   │   ├── AppState.swift
│   │   ├── StatusView.swift
│   │   ├── SettingsView.swift
│   │   ├── WhatsAppDetector.swift
│   │   ├── AccessibilityMonitor.swift
│   │   ├── AccessibilityExtractor.swift
│   │   ├── MessageProcessor.swift
│   │   ├── MessageFingerprint.swift
│   │   ├── NativeMessagingClient.swift
│   │   ├── PermissionManager.swift
│   │   ├── LaunchAtLoginManager.swift
│   │   ├── Notifications/
│   │   │   ├── GlobalNotificationWindowManager.swift
│   │   │   ├── FloatingNotificationPanel.swift
│   │   │   ├── GlassNotificationCardView.swift
│   │   │   ├── DisplayScreenLocator.swift
│   │   │   └── NotificationStackQueue.swift
│   │   └── Models/
│   │       └── WhatsAppMessage.swift
│   ├── Tests/PingGlassTests/
│   │   └── PingGlassTests.swift
│   └── NativeMessagingHost/
│       ├── pingglass_native_host.py
│       ├── host_manifest.json
│       └── install_native_host.sh
├── chrome-extension/                 # Optional browser extension & overlay
│   ├── manifest.json
│   ├── background.js
│   ├── popup.html / popup.css / popup.js
│   ├── content.js
│   ├── content.css
│   ├── options.html / options.css / options.js
│   └── icons/
│       ├── icon16.png
│       ├── icon48.png
│       └── icon128.png
├── scripts/
│   ├── build_macos.sh
│   ├── install.sh
│   ├── uninstall.sh
│   └── verify.sh
└── README.md
```

---

## 3. Global Notification Architecture (Upgraded)

1. **Primary Renderer — Native macOS Global Floating Panels**:
   - `GlobalNotificationWindowManager` subscribes to `AccessibilityMonitor.onMessagesDetected` via `AppState` and renders floating `FloatingNotificationPanel` (`NSPanel`) windows globally on the active display (`DisplayScreenLocator`, using `NSScreen.visibleFrame` to avoid Dock & Menu Bar overlap).
   - **Non-activating focus preservation**: Panels use `[.borderless, .nonactivatingPanel]`, `canBecomeKey = false`, `canBecomeMain = false`, `hidesOnDeactivate = false`, and `orderFrontRegardless()` so active apps (Chrome, VS Code, Cursor, Terminal, Finder, Xcode) **never lose keyboard or window focus**.
   - **Native macOS Glass UI**: `GlassNotificationCardView` combines `NSVisualEffectView` (`.behindWindow`, `.hudWindow` / `.popover`) with SwiftUI card layout, initials avatar fallback, WhatsApp badge, Copy (`Copied ✓`), explicit Open WhatsApp button, Dismiss (`×`), and `NSTrackingArea(.activeAlways)` hover pause.
   - **Stacking, Queue & Animations**: `NotificationStackQueue` caps visible panels (default `3`, configurable `1–6`) and bounds pending items in memory. Entry slides upward + fades + subtle scale (`460ms`), exit fades upward (`240ms`), and Reduce Motion falls back to a simple fade.
   - **Click-to-Open Chat Popup or WhatsApp Chat**: Clicking a notification card opens a floating glass **Chat Popup** (`GlassChatPopupView`) right at the notification corner displaying session messages (plus live Accessibility bubbles if that chat is open in WhatsApp), along with an **Open in WhatsApp** button that activates WhatsApp Desktop and selects the matching sidebar chat row via public AX actions (`kAXPressAction`). You can also switch **On Card Click** in Settings to open WhatsApp directly.
   - **Persistent Notifications & Clear All**: By default, notifications stay visible until you manually close them (`Auto-Dismiss = Until closed (Never)`), and a floating **Clear All** glass pill (plus a **Clear All Notifications** button in the menu bar and Chrome popup) lets you remove all active and queued notifications with one click.
   - **Pause Modes & Settings**: Supports Pause for 15 minutes, Pause for 1 hour, Pause until manually resumed, 5 screen positions (`Bottom Right` default, `Center Right`, `Top Right`, `Top Left`, `Bottom Left`), configurable edge margin (`28px` default), preferred display (`Active`, `Primary`, `Secondary`), auto-dismiss durations (`Until closed (Never)` default, or `3s/5s/6s/8s/10s`), Dark/Light glass, and optional subtle system sound (`Pop`, off by default).

2. **Optional Chrome Bridge (Preserved)**:
   - `NativeMessagingServer` (`~/.pingglass/bridge.sock`), `pingglass_native_host.py` (`com.pingglass.bridge`), and `chrome-extension/` remain intact and optional.

---

## 4. Setup Guide (Global Desktop + Optional Chrome Extension)

### Step 1: Build & Install the macOS App
```bash
cd /Users/sumitkumar776693/Desktop/Project/extension/PingGlass
./scripts/build_macos.sh --install
```
This builds the Swift release binary, packages `build/PingGlass.app`, ad-hoc signs it, and installs `~/Applications/PingGlass.app`.

### Step 2: Launch PingGlass & Grant Accessibility Permission
1. Launch the app:
   ```bash
   open ~/Applications/PingGlass.app
   ```
2. Click the **PingGlass** icon in the macOS menu bar → **Open Settings** (or **Request Prompt**).
3. In **System Settings → Privacy & Security → Accessibility**, toggle ON **PingGlass**.
   > Note: If you rebuild `PingGlass.app` with ad-hoc signing, toggle PingGlass off and back on in Accessibility settings if macOS resets trust.

### Step 3: Test Global Desktop Notifications Immediately
1. Click **Test** in the PingGlass menu bar popover (works over any app — Chrome, VS Code, Terminal, Finder — even if Chrome or WhatsApp is closed).
2. Confirm a native dark-glass notification (`PingGlass Test` — `"Your global glass notification is working beautifully! ✨"`) slides up in the bottom-right corner without stealing focus from your active app.

### Step 4: Start Monitoring WhatsApp Desktop
1. Open **WhatsApp Desktop** (`/Applications/WhatsApp.app`).
2. Click **Start Monitoring** in the PingGlass menu bar popover.

### Step 5: *(Optional)* Connect the Chrome Extension
Only needed if you also want browser-tab overlays or status in Chrome:
1. Open `chrome://extensions`, enable **Developer mode**, click **Load unpacked**, and select `PingGlass/chrome-extension`.
2. Copy the 32-character Extension ID and run:
   ```bash
   ./macOS/NativeMessagingHost/install_native_host.sh <YOUR_32_CHAR_EXTENSION_ID>
   ```
3. Click **Reload (`↻`)** on the PingGlass card in `chrome://extensions`.

---

## 5. Privacy & Security

- **100% local processing**: Zero internet requests, zero cloud APIs, zero analytics, zero telemetry.
- **No message history persisted**: Deduplication fingerprints live in RAM (`MessageFingerprintStore`, SHA-256, 300s TTL, max 500 entries) and dismissed notifications are immediately freed.
- **No private text in logs**: `os_log` and `stderr` never print message bodies or sender names.

---

## 6. Verification & Uninstall

Run all build, unit, IPC, and JS checks:
```bash
./scripts/verify.sh
```

Remove PingGlass cleanly:
```bash
./scripts/uninstall.sh
```
