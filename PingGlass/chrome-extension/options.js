(() => {
  "use strict";

  const BOOLEAN_KEYS = [
    "notificationsEnabled",
    "notificationsPaused",
    "monitoringEnabled",
    "enableAnimation",
    "soundEnabled",
    "showSender",
    "showChatName",
    "showAvatar",
    "showTimestamp",
    "showPreview",
    "showCopyButton",
  ];

  const NUMBER_KEYS = ["autoDismissSeconds", "maxVisible", "maxPreviewLength"];
  const SELECT_KEYS = ["theme", "position", "ambiguousDirectionPolicy"];

  const DEFAULTS = {
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
    position: "bottom-right",
    theme: "dark",
    enableAnimation: true,
    soundEnabled: false,
    notificationsPaused: false,
    maxPreviewLength: 280,
    ambiguousDirectionPolicy: "ignore",
  };

  const savePill = document.getElementById("save-pill");
  const extIdEl = document.getElementById("extension-id-value");
  const resetBtn = document.getElementById("reset-defaults-btn");

  let pillTimer = null;

  function showSavedPill() {
    if (pillTimer) clearTimeout(pillTimer);
    savePill.hidden = false;
    pillTimer = setTimeout(() => {
      savePill.hidden = true;
      pillTimer = null;
    }, 1500);
  }

  function applySettingsToForm(settings) {
    for (const key of BOOLEAN_KEYS) {
      const el = document.getElementById(key);
      if (el) el.checked = Boolean(settings[key]);
    }
    for (const key of NUMBER_KEYS) {
      const el = document.getElementById(key);
      if (el) el.value = String(settings[key] ?? DEFAULTS[key]);
    }
    for (const key of SELECT_KEYS) {
      const el = document.getElementById(key);
      if (el) el.value = String(settings[key] ?? DEFAULTS[key]);
    }
  }

  function readSettingsFromForm() {
    const payload = {};
    for (const key of BOOLEAN_KEYS) {
      const el = document.getElementById(key);
      if (el) payload[key] = Boolean(el.checked);
    }
    for (const key of NUMBER_KEYS) {
      const el = document.getElementById(key);
      if (el) {
        const num = Number(el.value);
        payload[key] = Number.isFinite(num) ? num : DEFAULTS[key];
      }
    }
    for (const key of SELECT_KEYS) {
      const el = document.getElementById(key);
      if (el) payload[key] = el.value;
    }

    payload.autoDismissSeconds = Math.max(0, Math.min(60, payload.autoDismissSeconds));
    payload.maxVisible = Math.max(1, Math.min(6, payload.maxVisible));
    payload.maxPreviewLength = Math.max(60, Math.min(800, payload.maxPreviewLength));
    return payload;
  }

  async function safeSendMessage(payload) {
    try {
      if (typeof chrome === "undefined" || !chrome.runtime || !chrome.runtime.id) {
        return null;
      }
      return await chrome.runtime.sendMessage(payload);
    } catch {
      return null;
    }
  }

  async function persistFromForm() {
    const next = readSettingsFromForm();
    applySettingsToForm(next);
    const res = await safeSendMessage({
      type: "options_save_settings",
      settings: next,
    });
    if (res?.ok) {
      showSavedPill();
    }
  }

  async function init() {
    extIdEl.textContent = chrome?.runtime?.id || "Load extension in chrome://extensions first";

    const res = await safeSendMessage({ type: "options_get_settings" });
    if (res?.ok && res.settings) {
      applySettingsToForm(res.settings);
    } else {
      applySettingsToForm(DEFAULTS);
    }

    const allIds = [...BOOLEAN_KEYS, ...NUMBER_KEYS, ...SELECT_KEYS];
    for (const id of allIds) {
      const el = document.getElementById(id);
      if (el) {
        el.addEventListener("change", () => {
          void persistFromForm();
        });
      }
    }

    resetBtn.addEventListener("click", async () => {
      applySettingsToForm(DEFAULTS);
      const resetRes = await safeSendMessage({
        type: "options_save_settings",
        settings: DEFAULTS,
      });
      if (resetRes?.ok) {
        showSavedPill();
      }
    });
  }

  document.addEventListener("DOMContentLoaded", () => {
    void init();
  });
})();
