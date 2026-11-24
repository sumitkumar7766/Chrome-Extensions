/**
 * PingGlass Background Service Worker (Manifest V3)
 *
 * Manages:
 *  - Chrome Native Messaging port (`com.pingglass.bridge`) with bounded reconnects
 *  - Real connection & macOS helper status tracking in chrome.storage.session
 *  - Settings persistence in chrome.storage.local
 *  - Explicit per-tab overlay activation via activeTab + chrome.scripting
 *  - Safe validation & dispatch of incoming WhatsApp messages to active overlays
 */

"use strict";

const NATIVE_HOST_NAME = "com.pingglass.bridge";
const SETTINGS_KEY = "pingglass_settings";
const SESSION_STATE_KEY = "pingglass_session_state";

const MAX_AUTO_RECONNECT_ATTEMPTS = 5;
const RECONNECT_DELAYS_MS = [2000, 4000, 8000, 16000, 30000];

const DEFAULT_SETTINGS = Object.freeze({
  notificationsEnabled: true,
  monitoringEnabled: false,
  autoDismissSeconds: 0,
  maxVisible: 3,
  showSender: true,
  showChatName: true,
  showAvatar: true,
  showTimestamp: true,
  showPreview: true,
  showCopyButton: true,
  position: "bottom-right", // "bottom-right" | "top-right"
  theme: "dark", // "dark" | "light"
  enableAnimation: true,
  soundEnabled: false,
  notificationsPaused: false,
  maxPreviewLength: 280,
  ambiguousDirectionPolicy: "ignore",
});

const DEFAULT_SESSION_STATE = Object.freeze({
  bridgeConnected: false,
  helperConnected: false,
  helperStatus: null,
  lastError: null,
  nativeHostMissing: false,
  sessionMessagesReceived: 0,
  enabledTabIds: [],
  reconnectAttempts: 0,
});

let nativePort = null;
let reconnectTimerId = null;
let connectInFlight = null;
let bootConnectStarted = false;

function isExtensionContextValid() {
  try {
    return Boolean(typeof chrome !== "undefined" && chrome.runtime && chrome.runtime.id);
  } catch {
    return false;
  }
}

/* -------------------------------------------------------------------------- */
/* Storage & State Helpers                                                    */
/* -------------------------------------------------------------------------- */

async function getSettings() {
  try {
    const stored = await chrome.storage.local.get([SETTINGS_KEY, "pingglass_persistent_default_v2"]);
    const base = { ...DEFAULT_SETTINGS, ...(stored[SETTINGS_KEY] || {}) };
    if (!stored.pingglass_persistent_default_v2) {
      if (stored[SETTINGS_KEY] && stored[SETTINGS_KEY].autoDismissSeconds === 6) {
        base.autoDismissSeconds = 0;
        await chrome.storage.local.set({ [SETTINGS_KEY]: base, pingglass_persistent_default_v2: true });
      } else {
        await chrome.storage.local.set({ pingglass_persistent_default_v2: true });
      }
    }
    return base;
  } catch {
    return { ...DEFAULT_SETTINGS };
  }
}

async function saveSettings(partialSettings) {
  const current = await getSettings();
  const next = { ...current, ...partialSettings };
  await chrome.storage.local.set({ [SETTINGS_KEY]: next });
  await broadcastSettingsToEnabledTabs(next);
  sendHelperSettings(next);
  return next;
}

async function getSessionState() {
  try {
    const stored = await chrome.storage.session.get(SESSION_STATE_KEY);
    return { ...DEFAULT_SESSION_STATE, ...(stored[SESSION_STATE_KEY] || {}) };
  } catch {
    return { ...DEFAULT_SESSION_STATE };
  }
}

async function updateSessionState(patch) {
  const current = await getSessionState();
  const next = { ...current, ...patch };
  await chrome.storage.session.set({ [SESSION_STATE_KEY]: next });
  notifyPopupStateChanged(next);
  return next;
}

function notifyPopupStateChanged(sessionState) {
  if (!isExtensionContextValid()) {
    return;
  }
  try {
    const maybePromise = chrome.runtime.sendMessage({
      type: "pingglass_state_updated",
      state: sessionState,
    });
    if (maybePromise && typeof maybePromise.catch === "function") {
      maybePromise.catch(() => {
        // Popup is not open; safe to ignore.
      });
    }
  } catch {
    // Context invalidated or no receiver.
  }
}

/* -------------------------------------------------------------------------- */
/* Native Messaging Connection Management                                     */
/* -------------------------------------------------------------------------- */

function clearReconnectTimer() {
  if (reconnectTimerId !== null) {
    clearTimeout(reconnectTimerId);
    reconnectTimerId = null;
  }
}

function isFatalNativeHostError(message) {
  const lower = (message || "").toLowerCase();
  return (
    lower.includes("not found") ||
    lower.includes("forbidden") ||
    lower.includes("access to the specified native messaging host")
  );
}

async function connectNativeBridge({ resetAttempts = false } = {}) {
  if (!isExtensionContextValid()) {
    return false;
  }

  if (connectInFlight) {
    return connectInFlight;
  }

  connectInFlight = connectNativeBridgeInternal({ resetAttempts }).finally(() => {
    connectInFlight = null;
  });
  return connectInFlight;
}

async function connectNativeBridgeInternal({ resetAttempts = false } = {}) {
  clearReconnectTimer();

  if (!isExtensionContextValid()) {
    return false;
  }

  if (nativePort) {
    return true;
  }

  if (resetAttempts) {
    await updateSessionState({ reconnectAttempts: 0, nativeHostMissing: false });
  }

  if (!isExtensionContextValid() || nativePort) {
    return Boolean(nativePort);
  }

  let port;
  try {
    port = chrome.runtime.connectNative(NATIVE_HOST_NAME);
  } catch (err) {
    const errorMsg = err instanceof Error ? err.message : String(err);
    await updateSessionState({
      bridgeConnected: false,
      helperConnected: false,
      helperStatus: null,
      nativeHostMissing: isFatalNativeHostError(errorMsg),
      lastError: errorMsg,
    });
    return false;
  }

  // Attach onMessage and onDisconnect synchronously BEFORE any `await` so Chrome
  // never misses an immediate disconnect or leaves `chrome.runtime.lastError` unchecked,
  // and never reads `port.onMessage` after an invalidated async suspension.
  nativePort = port;
  try {
    port.onMessage.addListener((rawPayload) => {
      if (!isExtensionContextValid()) return;
      void handleNativeMessage(rawPayload);
    });

    port.onDisconnect.addListener((disconnectedPort) => {
      let lastErr = "Native messaging host disconnected.";
      try {
        lastErr =
          chrome.runtime?.lastError?.message ||
          disconnectedPort?.error?.message ||
          lastErr;
      } catch {
        lastErr = "Extension context invalidated.";
      }
      if (nativePort === port) {
        nativePort = null;
      }
      if (isExtensionContextValid()) {
        void handleNativeDisconnect(lastErr);
      }
    });
  } catch (err) {
    nativePort = null;
    const errorMsg = err instanceof Error ? err.message : String(err);
    if (isExtensionContextValid()) {
      await updateSessionState({
        bridgeConnected: false,
        helperConnected: false,
        helperStatus: null,
        nativeHostMissing: isFatalNativeHostError(errorMsg),
        lastError: errorMsg,
      });
    }
    return false;
  }

  await updateSessionState({
    bridgeConnected: true,
    nativeHostMissing: false,
    lastError: null,
  });

  // Re-verify port did not disconnect while awaiting storage update.
  if (nativePort !== port || !isExtensionContextValid()) {
    return false;
  }

  // Request current status and sync helper settings immediately.
  sendToNativePort({ type: "ping" });
  sendToNativePort({ type: "request_status" });
  const settings = await getSettings();
  if (nativePort === port && isExtensionContextValid()) {
    sendHelperSettings(settings);
  }
  return nativePort === port;
}

async function handleNativeDisconnect(reason) {
  const fatal = isFatalNativeHostError(reason);
  const current = await getSessionState();
  const nextAttempts = current.reconnectAttempts + 1;

  await updateSessionState({
    bridgeConnected: false,
    helperConnected: false,
    helperStatus: null,
    nativeHostMissing: fatal,
    lastError: reason,
    reconnectAttempts: nextAttempts,
  });

  // Avoid infinite retry loops or retrying when manifest is missing/forbidden.
  if (fatal || nextAttempts > MAX_AUTO_RECONNECT_ATTEMPTS) {
    return;
  }

  const delay = RECONNECT_DELAYS_MS[Math.min(nextAttempts - 1, RECONNECT_DELAYS_MS.length - 1)];
  clearReconnectTimer();
  reconnectTimerId = setTimeout(() => {
    reconnectTimerId = null;
    void connectNativeBridge();
  }, delay);
}

function sendToNativePort(payload) {
  if (!nativePort) {
    return false;
  }
  try {
    nativePort.postMessage(payload);
    return true;
  } catch {
    nativePort = null;
    return false;
  }
}

function sendHelperSettings(settings) {
  sendToNativePort({
    type: "settings_update",
    settings: {
      monitoringEnabled: Boolean(settings.monitoringEnabled),
      ambiguousDirectionPolicy: settings.ambiguousDirectionPolicy || "ignore",
      maxPreviewLength: Number(settings.maxPreviewLength) || 280,
    },
  });
}

/* -------------------------------------------------------------------------- */
/* Payload Validation & Message Routing                                       */
/* -------------------------------------------------------------------------- */

function validateIncomingMessagePayload(raw) {
  if (!raw || typeof raw !== "object") {
    return null;
  }

  const id = typeof raw.id === "string" && raw.id.trim() ? raw.id.trim() : crypto.randomUUID();
  const sender = typeof raw.sender === "string" && raw.sender.trim() ? raw.sender.trim().slice(0, 120) : null;
  const chatName = typeof raw.chatName === "string" && raw.chatName.trim() ? raw.chatName.trim().slice(0, 120) : null;
  const text = typeof raw.text === "string" && raw.text.trim() ? raw.text.slice(0, 1200) : null;
  const timestamp = typeof raw.timestamp === "string" && raw.timestamp.trim() ? raw.timestamp.trim().slice(0, 40) : null;
  const receivedAt = typeof raw.receivedAt === "string" ? raw.receivedAt : new Date().toISOString();
  const source = typeof raw.source === "string" ? raw.source : "whatsapp-desktop";
  const confidence = typeof raw.confidence === "number" && Number.isFinite(raw.confidence) ? raw.confidence : 0;
  const isTest = Boolean(raw.isTest);

  let avatar = null;
  if (
    typeof raw.avatar === "string" &&
    (raw.avatar.startsWith("data:image/png;base64,") || raw.avatar.startsWith("data:image/jpeg;base64,")) &&
    raw.avatar.length <= 131072
  ) {
    avatar = raw.avatar;
  }

  if (!sender && !chatName && !text) {
    return null;
  }

  return {
    id,
    sender,
    chatName,
    text,
    timestamp,
    avatar,
    receivedAt,
    source,
    confidence,
    isTest,
  };
}

async function handleNativeMessage(envelope) {
  if (!envelope || typeof envelope !== "object" || typeof envelope.type !== "string") {
    return;
  }

  switch (envelope.type) {
    case "connection_status": {
      const helperConnected = Boolean(envelope.helperConnected);
      await updateSessionState({
        bridgeConnected: true,
        helperConnected,
        helperStatus: helperConnected ? envelope.status || null : null,
        lastError: helperConnected ? null : envelope.error || "PingGlass macOS helper is not running.",
        reconnectAttempts: 0,
      });
      break;
    }

    case "pong":
    case "monitoring_status": {
      const helperConnected = envelope.helperConnected !== undefined ? Boolean(envelope.helperConnected) : Boolean(envelope.status);
      await updateSessionState({
        bridgeConnected: true,
        helperConnected,
        helperStatus: envelope.status || null,
        lastError: helperConnected ? null : "PingGlass macOS helper is not running.",
        reconnectAttempts: 0,
      });
      break;
    }

    case "incoming_message": {
      const sanitized = validateIncomingMessagePayload(envelope.message);
      if (!sanitized) {
        return;
      }

      if (!sanitized.isTest) {
        const current = await getSessionState();
        await updateSessionState({
          sessionMessagesReceived: current.sessionMessagesReceived + 1,
        });
      }

      const settings = await getSettings();
      if (!sanitized.isTest && (!settings.notificationsEnabled || settings.notificationsPaused)) {
        return;
      }

      await dispatchNotificationToActiveOverlay(sanitized, settings);
      break;
    }

    case "error": {
      await updateSessionState({
        lastError: typeof envelope.error === "string" ? envelope.error : "Bridge error.",
      });
      break;
    }

    default:
      break;
  }
}

/* -------------------------------------------------------------------------- */
/* Tab Overlay Injection & Dispatch                                           */
/* -------------------------------------------------------------------------- */

function isInjectableUrl(url) {
  if (!url || typeof url !== "string") {
    return false;
  }
  return url.startsWith("http://") || url.startsWith("https://") || url.startsWith("file://");
}

async function pingTabOverlay(tabId) {
  try {
    const response = await chrome.tabs.sendMessage(tabId, { type: "pingglass_ping" });
    return Boolean(response && response.alive);
  } catch {
    return false;
  }
}

async function enableOverlayOnTab(tabId) {
  let tab;
  try {
    tab = await chrome.tabs.get(tabId);
  } catch {
    return { ok: false, error: "Could not access active tab." };
  }

  if (!isInjectableUrl(tab.url)) {
    return {
      ok: false,
      error: "Chrome restricts extensions from running overlays on internal browser pages.",
    };
  }

  const alreadyAlive = await pingTabOverlay(tabId);
  if (!alreadyAlive) {
    try {
      await chrome.scripting.executeScript({
        target: { tabId },
        files: ["content.js"],
      });
    } catch (err) {
      return {
        ok: false,
        error: err instanceof Error ? err.message : "Failed to inject Glass Overlay into tab.",
      };
    }
  }

  const settings = await getSettings();
  try {
    await chrome.tabs.sendMessage(tabId, { type: "pingglass_init", settings });
  } catch {
    return { ok: false, error: "Overlay script did not respond after injection." };
  }

  const session = await getSessionState();
  const nextIds = Array.from(new Set([...session.enabledTabIds, tabId]));
  await updateSessionState({ enabledTabIds: nextIds });
  return { ok: true };
}

async function disableOverlayOnTab(tabId) {
  try {
    await chrome.tabs.sendMessage(tabId, { type: "pingglass_cleanup" });
  } catch {
    // Tab may have navigated or closed already.
  }

  const session = await getSessionState();
  const nextIds = session.enabledTabIds.filter((id) => id !== tabId);
  await updateSessionState({ enabledTabIds: nextIds });
  return { ok: true };
}

async function checkTabOverlayStatus(tabId) {
  if (!tabId) {
    return false;
  }
  const alive = await pingTabOverlay(tabId);
  const session = await getSessionState();
  const listed = session.enabledTabIds.includes(tabId);

  if (!alive && listed) {
    await updateSessionState({
      enabledTabIds: session.enabledTabIds.filter((id) => id !== tabId),
    });
  } else if (alive && !listed) {
    await updateSessionState({
      enabledTabIds: [...session.enabledTabIds, tabId],
    });
  }
  return alive;
}

async function broadcastSettingsToEnabledTabs(settings) {
  const session = await getSessionState();
  if (!session.enabledTabIds.length) {
    return;
  }

  const aliveTabs = [];
  for (const tabId of session.enabledTabIds) {
    try {
      await chrome.tabs.sendMessage(tabId, { type: "pingglass_settings", settings });
      aliveTabs.push(tabId);
    } catch {
      // Prune stale/navigated tab ID.
    }
  }

  if (aliveTabs.length !== session.enabledTabIds.length) {
    await updateSessionState({ enabledTabIds: aliveTabs });
  }
}

async function dispatchNotificationToActiveOverlay(message, settings) {
  const session = await getSessionState();
  const enabledSet = new Set(session.enabledTabIds);
  if (enabledSet.size === 0) {
    return { deliveredCount: 0 };
  }

  let candidateTabIds = [];
  try {
    const activeTabs = await chrome.tabs.query({ active: true, lastFocusedWindow: true });
    if (activeTabs[0]?.id && enabledSet.has(activeTabs[0].id)) {
      candidateTabIds.push(activeTabs[0].id);
    }
  } catch {
    // Ignore query failure.
  }

  // Fallback to most recently enabled tab if current focused tab isn't the enabled tab.
  for (const id of [...session.enabledTabIds].reverse()) {
    if (!candidateTabIds.includes(id)) {
      candidateTabIds.push(id);
    }
  }

  let deliveredCount = 0;
  const deadIds = new Set();

  for (const tabId of candidateTabIds) {
    try {
      const response = await chrome.tabs.sendMessage(tabId, {
        type: "pingglass_notify",
        message,
        settings,
      });
      if (response && response.ok) {
        deliveredCount += 1;
        break; // Show in one active overlay tab rather than duplicating across tabs.
      }
    } catch {
      deadIds.add(tabId);
    }
  }

  if (deadIds.size > 0) {
    await updateSessionState({
      enabledTabIds: session.enabledTabIds.filter((id) => !deadIds.has(id)),
    });
  }

  return { deliveredCount };
}

/* -------------------------------------------------------------------------- */
/* Chrome Lifecycle & Popup/Options RPC                                       */
/* -------------------------------------------------------------------------- */

chrome.runtime.onInstalled.addListener(() => {
  if (!bootConnectStarted && !nativePort) {
    bootConnectStarted = true;
    void connectNativeBridge({ resetAttempts: true });
  }
});

chrome.runtime.onStartup.addListener(() => {
  if (!bootConnectStarted && !nativePort) {
    bootConnectStarted = true;
    void connectNativeBridge({ resetAttempts: true });
  }
});

chrome.tabs.onRemoved.addListener((tabId) => {
  void (async () => {
    const session = await getSessionState();
    if (session.enabledTabIds.includes(tabId)) {
      await updateSessionState({
        enabledTabIds: session.enabledTabIds.filter((id) => id !== tabId),
      });
    }
  })();
});

chrome.runtime.onMessage.addListener((request, _sender, sendResponse) => {
  if (!request || typeof request !== "object") {
    return false;
  }

  void (async () => {
    try {
      switch (request.type) {
        case "popup_get_status": {
          if (!nativePort) {
            await connectNativeBridge({ resetAttempts: false });
          } else {
            sendToNativePort({ type: "request_status" });
          }
          const [sessionState, settings, overlayActive] = await Promise.all([
            getSessionState(),
            getSettings(),
            checkTabOverlayStatus(request.tabId),
          ]);
          sendResponse({ ok: true, state: sessionState, settings, overlayActive });
          break;
        }

        case "popup_reconnect": {
          const connected = await connectNativeBridge({ resetAttempts: true });
          const sessionState = await getSessionState();
          sendResponse({ ok: connected, state: sessionState });
          break;
        }

        case "popup_start_monitoring": {
          await saveSettings({ monitoringEnabled: true });
          if (!nativePort) {
            await connectNativeBridge({ resetAttempts: true });
          }
          const sent = sendToNativePort({ type: "start_monitoring" });
          sendResponse({ ok: sent });
          break;
        }

        case "popup_pause_monitoring": {
          await saveSettings({ monitoringEnabled: false });
          const sent = sendToNativePort({ type: "pause_monitoring" });
          sendResponse({ ok: sent });
          break;
        }

        case "popup_enable_overlay": {
          const res = await enableOverlayOnTab(request.tabId);
          sendResponse(res);
          break;
        }

        case "popup_disable_overlay": {
          const res = await disableOverlayOnTab(request.tabId);
          sendResponse(res);
          break;
        }

        case "popup_clear_all": {
          const session = await getSessionState();
          for (const tabId of session.enabledTabIds) {
            try {
              await chrome.tabs.sendMessage(tabId, { type: "pingglass_clear_all" });
            } catch {
              // Ignore dead/navigated tab.
            }
          }
          if (nativePort) {
            sendToNativePort({ type: "clear_all_notifications" });
          }
          sendResponse({ ok: true });
          break;
        }

        case "popup_launch_helper": {
          if (!nativePort) {
            await connectNativeBridge({ resetAttempts: true });
          }
          const sent = sendToNativePort({ type: "launch_helper" });
          sendResponse({
            ok: sent,
            error: sent ? null : "Native Messaging host is not connected.",
          });
          break;
        }

        case "popup_test_notification": {
          const session = await getSessionState();
          const settings = await getSettings();

          // Ensure overlay is checked/enabled on target tab if user clicked Test directly.
          const overlayAlive = await checkTabOverlayStatus(request.tabId);
          if (!overlayAlive) {
            sendResponse({
              ok: false,
              error: "Enable Glass Overlay on This Tab first to preview notifications.",
            });
            break;
          }

          if (nativePort && session.helperConnected) {
            sendToNativePort({ type: "test_notification" });
            sendResponse({ ok: true, pipeline: "native-bridge" });
          } else {
            // Honest local overlay fallback when macOS helper is not running.
            const localTest = {
              id: `local-test-${crypto.randomUUID()}`,
              sender: "PingGlass Test",
              chatName: "Local Overlay Test (macOS helper offline)",
              text: "Your WhatsApp desktop bridge is working! ✨",
              timestamp: new Intl.DateTimeFormat(undefined, {
                hour: "numeric",
                minute: "2-digit",
              }).format(new Date()),
              avatar: null,
              receivedAt: new Date().toISOString(),
              source: "pingglass-local-test",
              confidence: 1.0,
              isTest: true,
            };
            const dispatchRes = await dispatchNotificationToActiveOverlay(localTest, settings);
            sendResponse({
              ok: dispatchRes.deliveredCount > 0,
              pipeline: "chrome-local",
            });
          }
          break;
        }

        case "options_get_settings": {
          const [settings, sessionState] = await Promise.all([getSettings(), getSessionState()]);
          sendResponse({ ok: true, settings, state: sessionState });
          break;
        }

        case "options_save_settings": {
          const next = await saveSettings(request.settings || {});
          sendResponse({ ok: true, settings: next });
          break;
        }

        default:
          sendResponse({ ok: false, error: "Unknown request type." });
      }
    } catch (err) {
      sendResponse({
        ok: false,
        error: err instanceof Error ? err.message : "Unexpected service worker error.",
      });
    }
  })();

  return true;
});

// Attempt initial bridge connection once when service worker activates.
if (!bootConnectStarted) {
  bootConnectStarted = true;
  void connectNativeBridge({ resetAttempts: false });
}
