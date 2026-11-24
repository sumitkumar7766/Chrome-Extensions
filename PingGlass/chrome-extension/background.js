/**
 * PingGlass Background Service Worker (Manifest V3)
 *
 * Manages:
 *  - Chrome Native Messaging port (`com.pingglass.bridge`) with bounded reconnects
 *  - Live two-way status & settings sync with PingGlass.app (macOS helper is source of truth)
 *  - In-memory per-chat session store for the floating glass Chat Popup (zero disk history)
 *  - Automatic active-tab overlay delivery & explicit tab overlay management
 *  - CSP-safe stylesheet preloading for isolated Shadow DOM rendering
 */

"use strict";

const NATIVE_HOST_NAME = "com.pingglass.bridge";
const SETTINGS_KEY = "pingglass_settings";
const SESSION_STATE_KEY = "pingglass_session_state";

const MAX_AUTO_RECONNECT_ATTEMPTS = 5;
const RECONNECT_DELAYS_MS = [2000, 4000, 8000, 16000, 30000];

const DEFAULT_SETTINGS = Object.freeze({
  notificationsEnabled: true,
  chromeAutoOverlay: true,
  chromeForwardingEnabled: true,
  monitoringEnabled: false,
  autoDismissSeconds: 0,
  maxVisible: 3,
  edgeMargin: 20,
  showSender: true,
  showChatName: true,
  showAvatar: true,
  showTimestamp: true,
  showPreview: true,
  showCopyButton: true,
  position: "bottom-right", // "bottom-right" | "center-right" | "top-right" | "bottom-left" | "top-left"
  theme: "dark", // "dark" | "light"
  clickAction: "open_glass_chat_popup", // "open_glass_chat_popup" | "open_whatsapp_directly"
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

const POSITION_SWIFT_TO_EXT = Object.freeze({
  bottom_right: "bottom-right",
  center_right: "center-right",
  top_right: "top-right",
  bottom_left: "bottom-left",
  top_left: "top-left",
});

const POSITION_EXT_TO_SWIFT = Object.freeze({
  "bottom-right": "bottom_right",
  "center-right": "center_right",
  "top-right": "top_right",
  "bottom-left": "bottom_left",
  "top-left": "top_left",
});

let nativePort = null;
let reconnectTimerId = null;
let connectInFlight = null;
let bootConnectStarted = false;
let cachedContentCss = null;

// Ephemeral in-memory session chat store (never written to disk or synced).
const sessionChats = new Map();
const MAX_CHATS = 30;
const MAX_MESSAGES_PER_CHAT = 40;

function isExtensionContextValid() {
  try {
    return Boolean(typeof chrome !== "undefined" && chrome.runtime && chrome.runtime.id);
  } catch {
    return false;
  }
}

/* -------------------------------------------------------------------------- */
/* Ephemeral Session Chat Store                                               */
/* -------------------------------------------------------------------------- */

function getChatKey(message) {
  const raw = message?.chatName || message?.sender || message?.id || "whatsapp";
  return String(raw).trim().toLowerCase();
}

function recordSessionMessage(message) {
  if (!message || !message.text) return;
  const key = getChatKey(message);
  let entries = sessionChats.get(key);
  if (!entries) {
    entries = [];
  } else {
    sessionChats.delete(key); // refresh LRU order
  }

  if (!entries.some((e) => e.id === message.id)) {
    entries.push({
      id: message.id,
      sender: message.sender || null,
      text: message.text,
      timestamp: message.timestamp || null,
      isOutgoing: false,
      isTest: Boolean(message.isTest),
    });
    if (entries.length > MAX_MESSAGES_PER_CHAT) {
      entries = entries.slice(entries.length - MAX_MESSAGES_PER_CHAT);
    }
  }
  sessionChats.set(key, entries);

  while (sessionChats.size > MAX_CHATS) {
    const oldestKey = sessionChats.keys().next().value;
    sessionChats.delete(oldestKey);
  }
}

function getSessionChatMessages(message) {
  if (!message) return [];
  return sessionChats.get(getChatKey(message)) || [];
}

function clearSessionChats() {
  sessionChats.clear();
}

/* -------------------------------------------------------------------------- */
/* CSS Preloader (Immune to Webpage CSP)                                      */
/* -------------------------------------------------------------------------- */

async function getOverlayCssText() {
  if (cachedContentCss) {
    return cachedContentCss;
  }
  try {
    if (
      typeof chrome !== "undefined" &&
      chrome.runtime &&
      typeof chrome.runtime.getURL === "function" &&
      typeof fetch === "function"
    ) {
      const res = await fetch(chrome.runtime.getURL("content.css"));
      if (res.ok) {
        const txt = await res.text();
        if (txt && txt.includes(".pg-card")) {
          cachedContentCss = txt;
          return cachedContentCss;
        }
      }
    }
  } catch {
    // Fallback to content script loader when URL fetch isn't available (e.g., isolated VM test).
  }
  return null;
}

/* -------------------------------------------------------------------------- */
/* Storage & State Helpers                                                    */
/* -------------------------------------------------------------------------- */

async function getSettings() {
  try {
    const stored = await chrome.storage.local.get([SETTINGS_KEY, "pingglass_persistent_default_v3"]);
    const base = { ...DEFAULT_SETTINGS, ...(stored[SETTINGS_KEY] || {}) };
    if (!stored.pingglass_persistent_default_v3) {
      if (stored[SETTINGS_KEY] && stored[SETTINGS_KEY].autoDismissSeconds === 6) {
        base.autoDismissSeconds = 0;
      }
      if (stored[SETTINGS_KEY] && stored[SETTINGS_KEY].chromeAutoOverlay === undefined) {
        base.chromeAutoOverlay = true;
      }
      await chrome.storage.local.set({ [SETTINGS_KEY]: base, pingglass_persistent_default_v3: true });
    }
    return base;
  } catch {
    return { ...DEFAULT_SETTINGS };
  }
}

async function saveSettings(partialSettings, { syncToHelper = true } = {}) {
  const current = await getSettings();
  const next = { ...current, ...partialSettings };
  await chrome.storage.local.set({ [SETTINGS_KEY]: next });
  await broadcastSettingsToActiveTabs(next);
  if (syncToHelper) {
    sendHelperSettings(next);
  }
  return next;
}

function mapHelperConfigToExtensionPatch(helperStatus) {
  if (!helperStatus || typeof helperStatus !== "object") {
    return null;
  }
  const patch = {};
  if (typeof helperStatus.monitoringEnabled === "boolean") {
    patch.monitoringEnabled = helperStatus.monitoringEnabled;
  }
  if (typeof helperStatus.globalNotificationsEnabled === "boolean") {
    patch.notificationsEnabled = helperStatus.globalNotificationsEnabled;
  }
  if (typeof helperStatus.notificationsPaused === "boolean") {
    patch.notificationsPaused = helperStatus.notificationsPaused;
  }

  const cfg = helperStatus.config;
  if (cfg && typeof cfg === "object") {
    if (typeof cfg.ambiguousDirectionPolicy === "string") {
      patch.ambiguousDirectionPolicy = cfg.ambiguousDirectionPolicy;
    }
    if (typeof cfg.maxPreviewLength === "number") {
      patch.maxPreviewLength = cfg.maxPreviewLength;
    }
    if (typeof cfg.chromeForwardingEnabled === "boolean") {
      patch.chromeForwardingEnabled = cfg.chromeForwardingEnabled;
    }
    if (typeof cfg.animationEnabled === "boolean") {
      patch.enableAnimation = cfg.animationEnabled;
    }
    if (typeof cfg.soundEnabled === "boolean") {
      patch.soundEnabled = cfg.soundEnabled;
    }
    if (typeof cfg.autoDismissSeconds === "number") {
      patch.autoDismissSeconds = cfg.autoDismissSeconds;
    }
    if (typeof cfg.maxVisibleNotifications === "number") {
      patch.maxVisible = cfg.maxVisibleNotifications;
    }
    if (typeof cfg.notificationPosition === "string" && POSITION_SWIFT_TO_EXT[cfg.notificationPosition]) {
      patch.position = POSITION_SWIFT_TO_EXT[cfg.notificationPosition];
    }
    if (typeof cfg.edgeMargin === "number") {
      patch.edgeMargin = cfg.edgeMargin;
    }
    if (typeof cfg.appearanceMode === "string") {
      patch.theme = cfg.appearanceMode === "light" ? "light" : "dark";
    }
    if (typeof cfg.notificationClickAction === "string") {
      patch.clickAction = cfg.notificationClickAction;
    }
    if (typeof cfg.showAvatar === "boolean") patch.showAvatar = cfg.showAvatar;
    if (typeof cfg.showSender === "boolean") patch.showSender = cfg.showSender;
    if (typeof cfg.showChatName === "boolean") patch.showChatName = cfg.showChatName;
    if (typeof cfg.showTimestamp === "boolean") patch.showTimestamp = cfg.showTimestamp;
    if (typeof cfg.showPreview === "boolean") patch.showPreview = cfg.showPreview;
    if (typeof cfg.showCopyButton === "boolean") patch.showCopyButton = cfg.showCopyButton;
  }

  return Object.keys(patch).length > 0 ? patch : null;
}

async function syncSettingsFromHelperStatus(helperStatus) {
  const patch = mapHelperConfigToExtensionPatch(helperStatus);
  if (!patch) return;
  const current = await getSettings();
  const changed = Object.entries(patch).some(([k, v]) => current[k] !== v);
  if (changed) {
    await saveSettings(patch, { syncToHelper: false });
  }
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

  if (nativePort !== port || !isExtensionContextValid()) {
    return false;
  }

  // Query live status from macOS helper instead of overwriting helper config on connect.
  sendToNativePort({ type: "ping" });
  sendToNativePort({ type: "request_status" });
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
      globalNotificationsEnabled: Boolean(settings.notificationsEnabled),
      chromeForwardingEnabled: settings.chromeForwardingEnabled !== false,
      notificationsPaused: Boolean(settings.notificationsPaused),
      animationEnabled: Boolean(settings.enableAnimation),
      soundEnabled: Boolean(settings.soundEnabled),
      autoDismissSeconds: Number(settings.autoDismissSeconds) || 0,
      maxVisibleNotifications: Number(settings.maxVisible) || 3,
      notificationPosition: POSITION_EXT_TO_SWIFT[settings.position] || "bottom_right",
      edgeMargin: Number(settings.edgeMargin) || 20,
      appearanceMode: settings.theme === "light" ? "light" : "dark",
      notificationClickAction: settings.clickAction || "open_glass_chat_popup",
      showAvatar: Boolean(settings.showAvatar),
      showSender: Boolean(settings.showSender),
      showChatName: Boolean(settings.showChatName),
      showTimestamp: Boolean(settings.showTimestamp),
      showPreview: Boolean(settings.showPreview),
      showCopyButton: Boolean(settings.showCopyButton),
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
      const nextStatus = helperConnected ? envelope.status || null : null;
      await updateSessionState({
        bridgeConnected: true,
        helperConnected,
        helperStatus: nextStatus,
        lastError: helperConnected ? null : envelope.error || "PingGlass macOS helper is not running.",
        reconnectAttempts: 0,
      });
      if (nextStatus) {
        await syncSettingsFromHelperStatus(nextStatus);
      }
      break;
    }

    case "pong":
    case "monitoring_status": {
      const helperConnected =
        envelope.helperConnected !== undefined ? Boolean(envelope.helperConnected) : Boolean(envelope.status);
      const nextStatus = envelope.status || null;
      await updateSessionState({
        bridgeConnected: true,
        helperConnected,
        helperStatus: nextStatus,
        lastError: helperConnected ? null : "PingGlass macOS helper is not running.",
        reconnectAttempts: 0,
      });
      if (nextStatus) {
        await syncSettingsFromHelperStatus(nextStatus);
      }
      break;
    }

    case "incoming_message": {
      const sanitized = validateIncomingMessagePayload(envelope.message);
      if (!sanitized) {
        return;
      }

      recordSessionMessage(sanitized);

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

    case "clear_all_notifications": {
      clearSessionChats();
      await clearOverlayAcrossTabs({ syncToHelper: false });
      break;
    }

    case "dismiss_notification": {
      if (envelope.message?.id) {
        await dismissCardAcrossTabs(envelope.message.id);
      }
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

async function ensureTabOverlayReady(tabId, settings) {
  let tab;
  try {
    tab = await chrome.tabs.get(tabId);
  } catch {
    return { ok: false, error: "Could not access active tab." };
  }

  if (!isInjectableUrl(tab.url)) {
    return {
      ok: false,
      internalPage: true,
      error: "Chrome restricts extensions from running overlays on chrome:// internal pages.",
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

  const cssText = await getOverlayCssText();
  try {
    await chrome.tabs.sendMessage(tabId, { type: "pingglass_init", settings, cssText });
  } catch {
    return { ok: false, error: "Overlay script did not respond after injection." };
  }

  const session = await getSessionState();
  if (!session.enabledTabIds.includes(tabId)) {
    await updateSessionState({
      enabledTabIds: Array.from(new Set([...session.enabledTabIds, tabId])),
    });
  }
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

async function broadcastSettingsToActiveTabs(settings) {
  if (!chrome.tabs || typeof chrome.tabs.query !== "function") {
    return;
  }
  let tabs = [];
  try {
    tabs = await chrome.tabs.query({});
  } catch {
    return;
  }

  const cssText = await getOverlayCssText();
  const aliveTabs = [];
  for (const tab of tabs) {
    if (!tab?.id || !isInjectableUrl(tab.url)) continue;
    try {
      await chrome.tabs.sendMessage(tab.id, { type: "pingglass_settings", settings, cssText });
      aliveTabs.push(tab.id);
    } catch {
      // Content script not mounted in this tab yet.
    }
  }

  if (aliveTabs.length > 0) {
    const session = await getSessionState();
    const merged = Array.from(new Set([...session.enabledTabIds.filter((id) => aliveTabs.includes(id)), ...aliveTabs]));
    await updateSessionState({ enabledTabIds: merged });
  }
}

async function clearOverlayAcrossTabs({ syncToHelper = false } = {}) {
  if (chrome.tabs && typeof chrome.tabs.query === "function") {
    try {
      const tabs = await chrome.tabs.query({});
      for (const tab of tabs) {
        if (!tab?.id || !isInjectableUrl(tab.url)) continue;
        try {
          await chrome.tabs.sendMessage(tab.id, { type: "pingglass_clear_all" });
        } catch {
          // Safe to ignore tabs without mounted script.
        }
      }
    } catch {
      // Safe to ignore query errors.
    }
  }

  if (syncToHelper && nativePort) {
    sendToNativePort({ type: "clear_all_notifications" });
  }
}

async function dismissCardAcrossTabs(messageId) {
  if (!messageId || !chrome.tabs || typeof chrome.tabs.query !== "function") return;
  try {
    const tabs = await chrome.tabs.query({});
    for (const tab of tabs) {
      if (!tab?.id || !isInjectableUrl(tab.url)) continue;
      try {
        await chrome.tabs.sendMessage(tab.id, { type: "pingglass_dismiss", id: messageId });
      } catch {
        // Safe to ignore.
      }
    }
  } catch {
    // Ignore query failures.
  }
}

async function findCandidateTargetTabs(settings) {
  const session = await getSessionState();
  const candidates = [];

  if (!chrome.tabs || typeof chrome.tabs.query !== "function") {
    return candidates;
  }

  // 1. Prefer the active tab in the user's current focused Chrome window.
  try {
    const activeTabs = await chrome.tabs.query({ active: true, lastFocusedWindow: true });
    const active = activeTabs[0];
    if (active?.id && isInjectableUrl(active.url)) {
      if (settings.chromeAutoOverlay !== false || session.enabledTabIds.includes(active.id)) {
        candidates.push(active.id);
      }
    }
  } catch {
    // Ignore.
  }

  // 2. Fallback to explicitly enabled tabs.
  for (const id of [...session.enabledTabIds].reverse()) {
    if (!candidates.includes(id)) {
      candidates.push(id);
    }
  }

  // 3. If chromeAutoOverlay is on and active tab was chrome://, check other normal webpage tabs.
  if (settings.chromeAutoOverlay !== false) {
    try {
      const allTabs = await chrome.tabs.query({ windowType: "normal" });
      const activeWeb = allTabs.filter((t) => t.active && t.id && isInjectableUrl(t.url));
      const anyWeb = allTabs.filter((t) => !t.active && t.id && isInjectableUrl(t.url));
      for (const tab of [...activeWeb, ...anyWeb]) {
        if (!candidates.includes(tab.id)) {
          candidates.push(tab.id);
        }
      }
    } catch {
      // Ignore.
    }
  }

  return candidates;
}

async function dispatchNotificationToActiveOverlay(message, settings) {
  const candidates = await findCandidateTargetTabs(settings);
  if (candidates.length === 0) {
    return { deliveredCount: 0 };
  }

  const cssText = await getOverlayCssText();
  const chatHistory = getSessionChatMessages(message);
  let deliveredCount = 0;

  for (const tabId of candidates) {
    const ready = await ensureTabOverlayReady(tabId, settings);
    if (!ready.ok) {
      continue;
    }

    try {
      const response = await chrome.tabs.sendMessage(tabId, {
        type: "pingglass_notify",
        message,
        settings,
        cssText,
        chatHistory,
      });
      if (response && response.ok) {
        deliveredCount += 1;
        break; // Show in one active/most-recent webpage tab instead of duplicating across tabs.
      }
    } catch {
      // Try next candidate tab.
    }
  }

  return { deliveredCount };
}

/* -------------------------------------------------------------------------- */
/* Chrome Lifecycle & Popup/Options/Content RPC                               */
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

chrome.tabs?.onRemoved?.addListener((tabId) => {
  void (async () => {
    const session = await getSessionState();
    if (session.enabledTabIds.includes(tabId)) {
      await updateSessionState({
        enabledTabIds: session.enabledTabIds.filter((id) => id !== tabId),
      });
    }
  })();
});

chrome.runtime.onMessage.addListener((request, sender, sendResponse) => {
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
          const [sessionState, settings] = await Promise.all([getSessionState(), getSettings()]);
          sendResponse({ ok: connected, state: sessionState, settings });
          break;
        }

        case "popup_start_monitoring": {
          if (!nativePort) {
            await connectNativeBridge({ resetAttempts: true });
          }
          const sent = sendToNativePort({ type: "start_monitoring" });
          await saveSettings({ monitoringEnabled: true }, { syncToHelper: false });
          sendResponse({ ok: sent });
          break;
        }

        case "popup_pause_monitoring": {
          const sent = sendToNativePort({ type: "pause_monitoring" });
          await saveSettings({ monitoringEnabled: false }, { syncToHelper: false });
          sendResponse({ ok: sent });
          break;
        }

        case "popup_pause_notifications": {
          const { minutes = 0, indefinitely = false, resume = false } = request;
          const nextPaused = !resume;
          if (!nativePort) {
            await connectNativeBridge({ resetAttempts: false });
          }
          const sent = sendToNativePort({
            type: "pause_notifications",
            settings: {
              pauseMinutes: minutes > 0 ? minutes : null,
              pausedIndefinitely: indefinitely,
              notificationsPaused: nextPaused,
            },
          });
          await saveSettings({ notificationsPaused: nextPaused }, { syncToHelper: false });
          sendResponse({ ok: true, syncedToHelper: sent });
          break;
        }

        case "popup_enable_overlay": {
          const settings = await getSettings();
          const res = await ensureTabOverlayReady(request.tabId, settings);
          sendResponse(res);
          break;
        }

        case "popup_disable_overlay": {
          const res = await disableOverlayOnTab(request.tabId);
          sendResponse(res);
          break;
        }

        case "popup_clear_all": {
          clearSessionChats();
          await clearOverlayAcrossTabs({ syncToHelper: true });
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

        case "popup_open_whatsapp": {
          if (!nativePort) {
            await connectNativeBridge({ resetAttempts: true });
          }
          const sent = sendToNativePort({
            type: "open_whatsapp",
            message: request.message || null,
          });
          sendResponse({
            ok: sent,
            error: sent ? null : "Native Messaging host is not connected.",
          });
          break;
        }

        case "popup_test_notification": {
          if (!nativePort) {
            await connectNativeBridge({ resetAttempts: false });
          }
          const session = await getSessionState();
          const settings = await getSettings();

          let activeTabUrl = null;
          if (request.tabId && chrome.tabs?.get) {
            try {
              const t = await chrome.tabs.get(request.tabId);
              activeTabUrl = t?.url || null;
            } catch {
              activeTabUrl = null;
            }
          }
          const activeTabInjectable = isInjectableUrl(activeTabUrl);

          if (nativePort && session.helperConnected) {
            sendToNativePort({ type: "test_notification" });
            sendResponse({
              ok: true,
              pipeline: "native-bridge",
              activeTabInjectable,
              chromeForwardingEnabled: settings.chromeForwardingEnabled !== false,
            });
            break;
          }

          const localTest = {
            id: `local-test-${crypto.randomUUID()}`,
            sender: "PingGlass Test",
            chatName: "Global Notification",
            text: "Your global glass notification is working beautifully! ✨",
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
          recordSessionMessage(localTest);
          const dispatchRes = await dispatchNotificationToActiveOverlay(localTest, settings);
          sendResponse({
            ok: true,
            pipeline: "chrome-local",
            deliveredCount: dispatchRes.deliveredCount,
            activeTabInjectable,
            previewMessage: localTest,
          });
          break;
        }

        case "content_get_chat_history": {
          sendResponse({
            ok: true,
            entries: getSessionChatMessages(request.message),
          });
          break;
        }

        case "content_open_whatsapp": {
          if (!nativePort) {
            await connectNativeBridge({ resetAttempts: false });
          }
          const sent = sendToNativePort({
            type: "open_whatsapp",
            message: request.message || null,
          });
          sendResponse({ ok: sent });
          break;
        }

        case "content_clear_all": {
          clearSessionChats();
          await clearOverlayAcrossTabs({ syncToHelper: true });
          sendResponse({ ok: true });
          break;
        }

        case "content_dismiss_notification": {
          if (nativePort && request.message) {
            sendToNativePort({ type: "dismiss_notification", message: request.message });
          }
          sendResponse({ ok: true });
          break;
        }

        case "options_get_settings": {
          const [settings, sessionState] = await Promise.all([getSettings(), getSessionState()]);
          sendResponse({ ok: true, settings, state: sessionState });
          break;
        }

        case "options_save_settings": {
          const next = await saveSettings(request.settings || {}, { syncToHelper: true });
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

if (!bootConnectStarted) {
  bootConnectStarted = true;
  void connectNativeBridge({ resetAttempts: false });
}
