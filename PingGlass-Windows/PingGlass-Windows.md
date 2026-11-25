# PingGlass-Windows — Complete Guide & Setup Manual

**PingGlass-Windows** is the full Windows 10 / Windows 11 port of PingGlass. It provides **global Acrylic / Liquid Glass floating WhatsApp Desktop notifications**, an interactive **Floating Chat & Reply Popup** with Quick Replies, a **Windows System Tray (`NotifyIcon`) Control & Settings App**, and optional **Chrome / Edge / Brave Extension** live two-way integration — all running **100% locally** via public **Windows UI Automation (`System.Windows.Automation`)**.

> **Zero macOS changes:** This folder (`PingGlass-Windows/`) is completely separate from `PingGlass/macOS/` and targets native **WhatsApp Desktop for Windows** (`Microsoft Store / WinUI 3 / Electron`) without reading WhatsApp SQLite databases or using unofficial APIs.

---

## 1. Folder Structure & Architecture Overview

```text
PingGlass-Windows/
├── PingGlass-Windows.md                   # Complete documentation & setup guide (this file)
├── chrome-extension/                      # Standalone Chromium MV3 extension (Chrome / Edge / Brave)
│   ├── manifest.json                      # MV3 manifest with nativeMessaging, storage, activeTab, scripting, tabs
│   ├── background.js                      # Native Messaging client, session chat store, Clear All reset (= 0)
│   ├── popup.html / popup.css / popup.js  # Glass extension popup synced with Windows app
│   ├── options.html / options.css / options.js
│   ├── content.js / content.css           # Shadow DOM global tab glass cards & 342x414 interactive chat popup
│   └── icons/                             # icon16.png, icon48.png, icon128.png
├── WindowsApp/                            # Native .NET 8 WPF + WinForms desktop app (`PingGlassWindows.exe`)
│   ├── PingGlassWindows.csproj            # .NET 8 desktop project (`net8.0-windows`, WPF + WinForms + UIA)
│   ├── App.xaml / App.xaml.cs             # Single-instance mutex + System Tray (`NotifyIcon`) & context menu
│   ├── Models/
│   │   └── WhatsAppMessage.cs             # Shared wire models, settings, lifecycle enums, envelopes
│   ├── Core/
│   │   ├── WhatsAppDetector.cs            # Detects WhatsApp.exe / ApplicationFrameHost & foreground state
│   │   ├── WindowsUiaExtractor.cs         # UIA sidebar/chat bubble reader, chat selector & reply dispatcher
│   │   ├── WindowsUiaMonitor.cs           # UIA StructureChanged/PropertyChanged hooks + fallback polling + baseline seed
│   │   ├── MessageProcessor.cs            # Directional control char stripping, outgoing filtering, dedup gate
│   │   ├── MessageFingerprint.cs          # In-memory SHA-256 deduplication (24h TTL, 2000 entries, cross-source)
│   │   ├── SessionChatStore.cs            # Ephemeral RAM-only per-chat bubble cache (clears on Clear All)
│   │   ├── LocalIpcServer.cs              # Token-authenticated loopback TCP bridge (4-byte LE JSON framing)
│   │   ├── LaunchAtLoginManager.cs        # HKCU\...\Run sign-in startup registration
│   │   └── AppState.cs                    # App coordinator, config persistence, Clear All session=0 reset
│   ├── Notifications/
│   │   ├── Win32GlassHelper.cs            # WS_EX_NOACTIVATE, DWM rounded corners, Acrylic blur helper
│   │   ├── DisplayScreenLocator.cs        # Multi-monitor DPI-aware Screen WorkArea layout & stacking
│   │   ├── NotificationStackQueue.cs      # Bounded FIFO visible/pending queue (1-6 visible, 50 pending)
│   │   ├── NotificationCardWindow.xaml(.cs)# Floating glass card (copy, open, expand, click-to-chat, hover pause)
│   │   ├── ClearAllPillWindow.xaml(.cs)   # Floating Clear All pill button
│   │   ├── FloatingChatPopupWindow.xaml(.cs)# 342x414 interactive glass chat popup + Quick Reply chips
│   │   └── GlobalNotificationWindowManager.cs # Window lifecycle, stacking, timers, chat popup & tray sound
│   └── Views/
│       └── TrayControlWindow.xaml(.cs)    # System Tray Status & Settings panel
├── WindowsNativeHost/                     # Chromium Native Messaging bridge for Windows
│   ├── pingglass_native_host.py           # Binary stdio <-> authenticated TCP bridge (uses msvcrt O_BINARY)
│   ├── pingglass_native_host.bat          # Wrapper executed by Chrome/Edge/Brave
│   ├── host_manifest.json                 # Native Messaging host JSON template
│   └── install_native_host.ps1            # Writes manifest & HKCU Chrome/Edge/Brave registry keys
└── scripts/
    ├── build_windows.ps1                  # Publishes Release binary and optionally installs to %LOCALAPPDATA%\PingGlass\App
    ├── install_windows.ps1                # Full Windows build/install + Native Messaging registration helper
    ├── uninstall_windows.ps1              # Stops app, removes registry entries & %LOCALAPPDATA%\PingGlass
    └── verify_windows.sh                  # Cross-platform validator for manifests, JS, Python bridge & files
```

---

## 2. Requirements (Windows PC)

1. **Windows 10 (1809+) or Windows 11** (`x64`).
2. **.NET 8 Desktop SDK** (to build from source):
   - Download **.NET 8.0 SDK** from Microsoft or install via WinGet:
     ```powershell
     winget install Microsoft.DotNet.SDK.8
     ```
3. **Python 3.10+** (required only if using the Chrome/Edge/Brave Extension bridge):
   ```powershell
   winget install Python.Python.3.12
   ```
   Make sure `py` or `python` is in your `PATH`.
4. **WhatsApp Desktop for Windows** (official Microsoft Store app).
5. **Google Chrome** (or Microsoft Edge / Brave) — optional, only if you also want browser-tab overlays and Chrome popup control.

---

## 3. Complete Step-by-Step Setup Guide (Windows)

### Step 1: Copy `PingGlass-Windows` to Your Windows Machine
Copy the entire `PingGlass-Windows` folder (for example to `C:\Tools\PingGlass-Windows`).

Open **PowerShell** inside `PingGlass-Windows`:
```powershell
cd C:\Tools\PingGlass-Windows
```
*(If PowerShell blocks local scripts on a fresh PC, allow CurrentUser script execution once:)*
```powershell
Set-ExecutionPolicy -Scope CurrentUser -ExecutionPolicy RemoteSigned
```

---

### Step 2: Build & Install the PingGlass Windows Desktop App
Run the build + install script:
```powershell
.\scripts\build_windows.ps1 -Install
```
This compiles `WindowsApp\PingGlassWindows.csproj` in Release mode and installs `PingGlassWindows.exe` into:
```text
%LOCALAPPDATA%\PingGlass\App\PingGlassWindows.exe
```

Launch the app:
```powershell
Start-Process "$env:LOCALAPPDATA\PingGlass\App\PingGlassWindows.exe"
```
You will see a green **`P`** **PingGlass** icon appear in your Windows System Tray (bottom-right taskbar overflow area).

---

### Step 3: Verify Floating Desktop Notifications Immediately
1. Left-click the green **PingGlass** icon in the Windows System Tray (or right-click → **Open PingGlass Control**).
2. Click **✦ Test**.
3. A sleek floating dark-glass notification card (`PingGlass Test`) slides into the bottom-right corner **above all open apps** without stealing focus from your keyboard.
4. Click the notification card to open the **342×414 Floating Glass Chat & Reply Popup** with selectable message bubbles, **Copy**, **Copy All**, **Quick Reply chips** (`👍`, `Ok`, `On my way`, `Call soon`), and live reply box.

---

### Step 4: Connect Real-Time WhatsApp Desktop Monitoring (Even With Windows Notifications OFF)
1. Open **WhatsApp Desktop** on Windows and keep its window open behind your other apps (e.g., Chrome, VS Code, Terminal — avoid closing it completely or minimizing it to zero UI elements if UIA pauses).
2. *(Optional Privacy Setup)* You can turn **WhatsApp notifications OFF** in **Windows Settings → System → Notifications → WhatsApp**: PingGlass still detects incoming messages via public **Windows UI Automation (`System.Windows.Automation`)**!
3. Click **Start Monitoring** (it is enabled by default) in PingGlass Control.
4. Incoming messages from sidebar unread chats or open chats pop up cleanly in real time:
   - Existing unread chats present when PingGlass starts are **baseline-seeded** silently (no startup flood).
   - Clicking **Clear All** dismisses all visible/queued cards, closes any open chat popup, **resets `Session Messages` to `0`**, and keeps cleared fingerprints suppressed for 24 hours so old notifications never re-appear — **until a genuinely new message arrives from anyone**.

---

### Step 5: *(Optional)* Install & Connect the Chrome / Edge / Brave Extension
Only needed if you also want PingGlass floating overlays inside browser tabs and Chrome toolbar status controls:

1. Open Chrome and navigate to:
   ```text
   chrome://extensions
   ```
   *(For Edge use `edge://extensions`; for Brave use `brave://extensions`.)*
2. Turn ON **Developer mode** (top-right toggle).
3. Click **Load unpacked** and select:
   ```text
   C:\Tools\PingGlass-Windows\chrome-extension
   ```
4. Copy the **32-character Extension ID** displayed on the **PingGlass** extension card (e.g. `abcdefghijklmnopabcdefghijklmnop`).
5. Back in PowerShell inside `C:\Tools\PingGlass-Windows`, register the Windows Native Messaging Host:
   ```powershell
   .\WindowsNativeHost\install_native_host.ps1 -ExtensionId YOUR_32_CHAR_EXTENSION_ID
   ```
   This creates `%LOCALAPPDATA%\PingGlass\NativeHost\com.pingglass.bridge.json` pointing to `pingglass_native_host.bat` and automatically registers the Native Messaging Host under `HKCU:\Software\...\NativeMessagingHosts\com.pingglass.bridge` for Chrome, Edge, and Brave (no Administrator privileges required).
6. Return to `chrome://extensions` and click **Reload (`↻`)** on PingGlass.
7. Open the PingGlass Chrome extension popup — it should now show **Monitoring Active** and **Bridge Connected**.

*(Tip: You can also combine Step 2 + Step 5 in one command using `.\scripts\install_windows.ps1 -ExtensionId YOUR_32_CHAR_EXTENSION_ID` after loading the unpacked extension once to obtain its ID.)*

---

## 4. Key Settings & Features

| Setting / Action | Behavior |
|---|---|
| **Global Desktop Notifications** | Toggle native WPF Acrylic floating cards on/off globally |
| **Also Forward to Chrome** | Mirrors incoming alerts & replies to connected Chrome tabs |
| **Windows Acrylic Glass Blur** | Uses Win32 `ACCENT_ENABLE_ACRYLICBLURBEHIND` + DWM rounded corners |
| **Appearance** | `Dark Glass` or `Light Glass` |
| **Screen Position** | `Bottom Right`, `Center Right`, `Top Right`, `Bottom Left`, `Top Left` |
| **Auto-Dismiss Duration** | `Until closed (Never)` (default) or `3s / 5s / 6s / 8s / 10s` |
| **On Card Click** | `Open Floating Glass Chat Popup` (default) or `Open Chat in WhatsApp Desktop` |
| **Clear All** | Clears active/queued cards, clears session bubbles, resets `Session Messages` counter to `0`, syncs Chrome, and keeps cleared messages muted until a new message arrives |
| **Launch at Windows Sign-In** | Adds/removes `PingGlassWindows` under `HKCU\Software\Microsoft\Windows\CurrentVersion\Run` |

---

## 5. Privacy & Security Guarantees

- **100% Local Processing:** Zero cloud servers, zero external HTTP connections, zero telemetry.
- **Public OS APIs Only:** Uses Windows `System.Windows.Automation` (UIA) exclusively; never reads WhatsApp SQLite databases or injects into WhatsApp memory.
- **No Persistent Message Storage:** Fingerprints (`SHA-256`, 24h TTL, max 2000 entries) and session chat bubbles live strictly in RAM and clear immediately on Clear All or exit.
- **Authenticated Loopback IPC:** Chrome's `pingglass_native_host.py` connects to `127.0.0.1` using the ephemeral port and constant-time 256-bit random session token generated by `LocalIpcServer` inside `%LOCALAPPDATA%\PingGlass\`.
- **Safe Chrome DOM:** All Chrome overlay/popup rendering uses `textContent` and `createElement` (`0` `innerHTML` usage).

---

## 6. Verification & Uninstall

- **Run cross-platform verification checks** (manifests, Chrome JS syntax + zero `innerHTML`, Windows Native Host Python IPC framing with auth token, file completeness):
  ```bash
  bash ./scripts/verify_windows.sh
  ```
- **Build check on Windows (`dotnet`)**:
  ```powershell
  dotnet build .\WindowsApp\PingGlassWindows.csproj -c Release
  ```
- **Uninstall completely on Windows**:
  ```powershell
  .\scripts\uninstall_windows.ps1
  ```
