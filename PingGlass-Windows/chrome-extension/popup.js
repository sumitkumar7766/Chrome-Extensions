(() => {
  "use strict";

  const elements = {
    statusPanel: document.getElementById("status-panel"),
    settingsPanel: document.getElementById("settings-panel"),

    monitoringStatus: document.getElementById("monitoring-status"),
    bridgeStatus: document.getElementById("bridge-status"),
    whatsappStatus: document.getElementById("whatsapp-status"),
    accessibilityStatus: document.getElementById("accessibility-status"),
    desktopOverlayStatus: document.getElementById("desktop-overlay-status"),
    overlayStatus: document.getElementById("overlay-status"),
    detectionModeStatus: document.getElementById("detection-mode-status"),
    sessionCount: document.getElementById("session-count"),
    statusDetail: document.getElementById("status-detail"),

    dotWhatsapp: document.getElementById("dot-whatsapp"),
    dotAx: document.getElementById("dot-ax"),
    dotGlobal: document.getElementById("dot-global"),
    dotBridge: document.getElementById("dot-bridge"),
    dotOverlay: document.getElementById("dot-overlay"),
    dotMode: document.getElementById("dot-mode"),

    recoveryBox: document.getElementById("recovery-box"),
    recoveryTitle: document.getElementById("recovery-title"),
    recoveryDesc: document.getElementById("recovery-desc"),
    recoveryCmd: document.getElementById("recovery-cmd"),
    copyIdBtn: document.getElementById("copy-id-btn"),
    reconnectBtn: document.getElementById("reconnect-btn"),
    recoveryOpenAppBtn: document.getElementById("recovery-open-app-btn"),

    inlinePreviewCard: document.getElementById("inline-preview-card"),
    closeInlinePreview: document.getElementById("close-inline-preview"),

    toggleMonitoringBtn: document.getElementById("toggle-monitoring-btn"),
    monitoringBtnIcon: document.getElementById("monitoring-btn-icon"),
    monitoringBtnLabel: document.getElementById("monitoring-btn-label"),
    testNotificationBtn: document.getElementById("test-notification-btn"),
    clearAllBtn: document.getElementById("clear-all-btn"),
    pauseBtn: document.getElementById("pause-btn"),
    resumeBtn: document.getElementById("resume-btn"),
    pauseMenu: document.getElementById("pause-menu"),

    settingsBtn: document.getElementById("settings-btn"),
    openSettingsBtn: document.getElementById("open-settings-btn"),
    settingsBackBtn: document.getElementById("settings-back-btn"),
    openFullOptionsBtn: document.getElementById("open-full-options-btn"),
    refreshStatusBtn: document.getElementById("refresh-status-btn"),
    openAppBtn: document.getElementById("open-app-btn"),
    toggleTabOverlayBtn: document.getElementById("toggle-tab-overlay-btn"),
    extIdLabel: document.getElementById("ext-id-label"),
    popupToast: document.getElementById("popup-toast"),
  };

  const SETTING_BOOLEANS = [
    "chromeAutoOverlay",
    "notificationsEnabled",
    "chromeForwardingEnabled",
    "enableAnimation",
    "soundEnabled",
    "showAvatar",
    "showSender",
    "showChatName",
    "showTimestamp",
    "showPreview",
    "showCopyButton",
    "monitoringEnabled",
  ];
  const SETTING_SELECTS = ["theme", "position", "clickAction", "ambiguousDirectionPolicy"];
  const SETTING_NUMBERS = ["autoDismissSeconds", "maxVisible", "maxPreviewLength"];

  let currentTabId = null;
  let currentTabUrl = "";
  let overlayActive = false;
  let latestState = null;
  let latestSettings = null;
  let toastTimer = null;

  function showToast(text) {
    if (toastTimer) clearTimeout(toastTimer);
    elements.popupToast.textContent = text;
    elements.popupToast.hidden = false;
    toastTimer = setTimeout(() => {
      elements.popupToast.hidden = true;
      toastTimer = null;
    }, 2400);
  }

  function isContextValid() {
    try {
      return Boolean(typeof chrome !== "undefined" && chrome.runtime && chrome.runtime.id);
    } catch {
      return false;
    }
  }

  function isInjectable(url) {
    return typeof url === "string" && (url.startsWith("http://") || url.startsWith("https://") || url.startsWith("file://"));
  }

  async function sendRuntimeMessage(payload) {
    if (!isContextValid()) {
      return { ok: false, error: "Extension reloaded. Reopen popup." };
    }
    try {
      return await chrome.runtime.sendMessage(payload);
    } catch (err) {
      return {
        ok: false,
        error: err instanceof Error ? err.message : "Extension context unavailable.",
      };
    }
  }

  function switchTab(tab) {
    const showSettings = tab === "settings";
    elements.statusPanel.hidden = showSettings;
    elements.settingsPanel.hidden = !showSettings;
  }

  function formatLifecycleSubtitle(state, helper) {
    if (!state?.bridgeConnected) {
      return state?.nativeHostMissing ? { text: "Native Host Missing", tone: "error" } : { text: "Bridge Disconnected", tone: "error" };
    }
    if (!state?.helperConnected || !helper) {
      return { text: "Windows App Offline", tone: "warn" };
    }
    switch (helper.monitoringState) {
      case "monitoring_active":
        return { text: "Monitoring Active", tone: "ok" };
      case "monitoring_limited":
        return { text: "Monitoring Limited", tone: "warn" };
      case "accessibility_required":
        return { text: "Accessibility Required", tone: "warn" };
      case "whatsapp_detected":
        return { text: "WhatsApp Detected", tone: "blue" };
      case "error":
        return { text: "Error", tone: "error" };
      default:
        return { text: "WhatsApp Not Running", tone: "neutral" };
    }
  }

  function applySettingsToEmbeddedForm(settings) {
    if (!settings) return;
    for (const key of SETTING_BOOLEANS) {
      const el = document.getElementById(`s-${key}`);
      if (el) el.checked = Boolean(settings[key]);
    }
    for (const key of SETTING_SELECTS) {
      const el = document.getElementById(`s-${key}`);
      if (el && settings[key] !== undefined) el.value = String(settings[key]);
    }
    for (const key of SETTING_NUMBERS) {
      const el = document.getElementById(`s-${key}`);
      if (el && settings[key] !== undefined) el.value = String(settings[key]);
    }
  }

  function renderUI(state, settings, isOverlayActive) {
    latestState = state;
    latestSettings = settings;
    overlayActive = Boolean(isOverlayActive);

    const extId = chrome.runtime.id || "unknown";
    elements.extIdLabel.textContent = `ID: ${extId.slice(0, 10)}…`;

    const helper = state?.helperStatus || null;
    const bridgeOk = Boolean(state?.bridgeConnected);
    const helperOk = Boolean(state?.helperConnected);

    // Header Subtitle
    const subtitle = formatLifecycleSubtitle(state, helper);
    elements.monitoringStatus.textContent = subtitle.text;
    elements.monitoringStatus.dataset.tone = subtitle.tone;

    // 1. WhatsApp Desktop
    if (!helperOk || !helper) {
      elements.whatsappStatus.textContent = "App Offline";
      elements.dotWhatsapp.dataset.dot = "muted";
    } else if (helper.whatsappRunning) {
      const ver = helper.whatsappVersion ? ` (v${helper.whatsappVersion})` : "";
      elements.whatsappStatus.textContent = `Running${ver}`;
      elements.dotWhatsapp.dataset.dot = "ok";
    } else {
      elements.whatsappStatus.textContent = "Not Running";
      elements.dotWhatsapp.dataset.dot = "muted";
    }

    // 2. Accessibility
    if (!helperOk || !helper) {
      elements.accessibilityStatus.textContent = "Unknown";
      elements.dotAx.dataset.dot = "muted";
    } else if (helper.accessibilityGranted) {
      elements.accessibilityStatus.textContent = "Granted";
      elements.dotAx.dataset.dot = "ok";
    } else {
      elements.accessibilityStatus.textContent = "Permission Required";
      elements.dotAx.dataset.dot = "warn";
    }

    // 3. Global Notifications
    if (!helperOk || !helper) {
      elements.desktopOverlayStatus.textContent = "App Offline";
      elements.dotGlobal.dataset.dot = "muted";
    } else if (helper.globalNotificationsEnabled === false) {
      elements.desktopOverlayStatus.textContent = "Disabled";
      elements.dotGlobal.dataset.dot = "warn";
    } else if (helper.notificationsPaused) {
      elements.desktopOverlayStatus.textContent = helper.pauseSummary || "Paused";
      elements.dotGlobal.dataset.dot = "warn";
    } else {
      elements.desktopOverlayStatus.textContent = "Active";
      elements.dotGlobal.dataset.dot = "ok";
    }

    // 4. Chrome Bridge
    if (!bridgeOk) {
      elements.bridgeStatus.textContent = "Disconnected";
      elements.dotBridge.dataset.dot = "error";
    } else if (!helperOk) {
      elements.bridgeStatus.textContent = "Host Ready (App Offline)";
      elements.dotBridge.dataset.dot = "warn";
    } else {
      elements.bridgeStatus.textContent = "Connected";
      elements.dotBridge.dataset.dot = "ok";
    }

    // 5. Chrome Tab Overlay
    const autoOn = settings?.chromeAutoOverlay !== false;
    if (overlayActive) {
      elements.overlayStatus.textContent = "Active on Tab";
      elements.dotOverlay.dataset.dot = "ok";
    } else if (!isInjectable(currentTabUrl) && currentTabUrl) {
      elements.overlayStatus.textContent = autoOn ? "Auto (Webpages)" : "Inactive";
      elements.dotOverlay.dataset.dot = autoOn ? "blue" : "muted";
    } else if (autoOn) {
      elements.overlayStatus.textContent = "Auto-Enabled";
      elements.dotOverlay.dataset.dot = "ok";
    } else {
      elements.overlayStatus.textContent = "Paused";
      elements.dotOverlay.dataset.dot = "muted";
    }

    // 6. Detection Mode
    if (!helperOk || !helper) {
      elements.detectionModeStatus.textContent = "Idle";
      elements.dotMode.dataset.dot = "muted";
    } else {
      elements.detectionModeStatus.textContent = helper.extractionMode || "Idle";
      elements.dotMode.dataset.dot = helper.observerAttached ? "ok" : helper.fallbackPollingActive ? "warn" : "muted";
    }

    // 7. Session Messages & Status Detail
    const msgCount = helperOk && helper ? helper.sessionMessagesForwarded ?? 0 : state?.sessionMessagesReceived ?? 0;
    elements.sessionCount.textContent = `${msgCount} message${msgCount === 1 ? "" : "s"}`;
    elements.statusDetail.textContent =
      helperOk && helper?.statusDetail
        ? helper.statusDetail
        : !bridgeOk
          ? state?.lastError || "Chrome Native Bridge is not connected."
          : "Open PingGlass Windows app to monitor WhatsApp Desktop.";

    // Monitoring Toggle Button (matches StatusView.swift green/orange toggle)
    const isMonitoringOn = Boolean(helperOk && helper ? helper.monitoringEnabled : settings?.monitoringEnabled);
    elements.toggleMonitoringBtn.dataset.active = isMonitoringOn ? "true" : "false";
    elements.monitoringBtnIcon.textContent = isMonitoringOn ? "❚❚" : "▶";
    elements.monitoringBtnLabel.textContent = isMonitoringOn ? "Stop Monitoring" : "Start Monitoring";
    elements.toggleMonitoringBtn.disabled = !helperOk;

    // Clear All & Pause / Resume Buttons
    const activeCount = helperOk && helper ? helper.activeNotificationCount ?? 0 : 0;
    elements.clearAllBtn.textContent = activeCount > 0 ? `Clear All (${activeCount})` : "Clear All";
    elements.clearAllBtn.dataset.danger = activeCount > 0 ? "true" : "false";

    const isPaused = Boolean(helperOk && helper ? helper.notificationsPaused : settings?.notificationsPaused);
    elements.pauseBtn.hidden = isPaused;
    elements.resumeBtn.hidden = !isPaused;
    if (isPaused) {
      elements.pauseMenu.hidden = true;
    }

    applySettingsToEmbeddedForm(settings);
    renderRecoveryBanner(state, helper, extId);
  }

  function renderRecoveryBanner(state, helper, extId) {
    elements.recoveryBox.hidden = true;
    elements.recoveryCmd.hidden = true;
    elements.copyIdBtn.hidden = true;
    elements.reconnectBtn.hidden = true;
    elements.recoveryOpenAppBtn.hidden = true;

    if (!state?.bridgeConnected) {
      elements.recoveryBox.hidden = false;
      if (state?.nativeHostMissing) {
        elements.recoveryTitle.textContent = "Install Native Messaging Host";
        elements.recoveryDesc.textContent = "Run this once in Terminal with your Extension ID, then click Reconnect:";
        elements.recoveryCmd.textContent = `.\\WindowsNativeHost\\install_native_host.ps1 ${extId}`;
        elements.recoveryCmd.hidden = false;
        elements.copyIdBtn.hidden = false;
      } else {
        elements.recoveryTitle.textContent = "Chrome Bridge Disconnected";
        elements.recoveryDesc.textContent = state?.lastError || "Native Messaging host disconnected.";
      }
      elements.reconnectBtn.hidden = false;
      return;
    }

    if (!state?.helperConnected || !helper) {
      elements.recoveryBox.hidden = false;
      elements.recoveryTitle.textContent = "PingGlass Windows App Offline";
      elements.recoveryDesc.textContent = "Launch the Windows PingGlass app to enable WhatsApp monitoring and global notifications.";
      elements.recoveryOpenAppBtn.hidden = false;
      elements.reconnectBtn.hidden = false;
      return;
    }

    if (!helper.accessibilityGranted) {
      elements.recoveryBox.hidden = false;
      elements.recoveryTitle.textContent = "Accessibility Access Needed";
      elements.recoveryDesc.textContent = "Enable PingGlass in System Settings → Privacy & Security → Accessibility.";
      elements.recoveryOpenAppBtn.hidden = false;
      return;
    }

    if (!helper.whatsappRunning) {
      elements.recoveryBox.hidden = false;
      elements.recoveryTitle.textContent = "WhatsApp Desktop Is Closed";
      elements.recoveryDesc.textContent = "Open WhatsApp Desktop to monitor incoming messages. Test notifications still work.";
    }
  }

  async function refreshStatus() {
    if (!isContextValid()) return;
    try {
      const tabs = await chrome.tabs.query({ active: true, currentWindow: true });
      currentTabId = tabs[0]?.id ?? null;
      currentTabUrl = tabs[0]?.url || "";
    } catch {
      currentTabId = null;
      currentTabUrl = "";
    }

    const response = await sendRuntimeMessage({
      type: "popup_get_status",
      tabId: currentTabId,
    });
    if (response?.ok) {
      renderUI(response.state, response.settings, response.overlayActive);
    }
  }

  async function persistSettingPatch(patch) {
    const res = await sendRuntimeMessage({
      type: "options_save_settings",
      settings: patch,
    });
    if (res?.ok && res.settings) {
      latestSettings = res.settings;
      renderUI(latestState, latestSettings, overlayActive);
      showToast("Saved & synced");
    }
  }

  function bindEvents() {
    elements.settingsBtn.addEventListener("click", () => switchTab("settings"));
    elements.openSettingsBtn.addEventListener("click", () => switchTab("settings"));
    elements.settingsBackBtn.addEventListener("click", () => switchTab("status"));
    elements.openFullOptionsBtn.addEventListener("click", () => chrome.runtime.openOptionsPage());

    elements.toggleMonitoringBtn.addEventListener("click", async () => {
      const isMonitoringOn = elements.toggleMonitoringBtn.dataset.active === "true";
      const res = await sendRuntimeMessage({
        type: isMonitoringOn ? "popup_pause_monitoring" : "popup_start_monitoring",
      });
      showToast(res?.ok ? (isMonitoringOn ? "Monitoring paused" : "Monitoring active") : "Windows app offline");
      await refreshStatus();
    });

    elements.testNotificationBtn.addEventListener("click", async () => {
      const res = await sendRuntimeMessage({
        type: "popup_test_notification",
        tabId: currentTabId,
      });
      if (!res?.ok) {
        showToast(res?.error || "Unable to send test notification");
        return;
      }
      if (res.pipeline === "native-bridge") {
        showToast(res.activeTabInjectable ? "Test notification displayed" : "Displayed on Windows & active webpage tab");
      } else if (res.deliveredCount > 0) {
        showToast("Glass notification shown on page");
      } else {
        elements.inlinePreviewCard.hidden = false;
        showToast("Displayed inside popup (internal chrome:// tab)");
      }
      await refreshStatus();
    });

    elements.closeInlinePreview.addEventListener("click", () => {
      elements.inlinePreviewCard.hidden = true;
    });

    elements.clearAllBtn.addEventListener("click", async () => {
      elements.inlinePreviewCard.hidden = true;
      await sendRuntimeMessage({ type: "popup_clear_all" });
      showToast("Cleared all notifications");
      await refreshStatus();
    });

    elements.pauseBtn.addEventListener("click", (e) => {
      e.stopPropagation();
      elements.pauseMenu.hidden = !elements.pauseMenu.hidden;
    });

    document.addEventListener("click", () => {
      elements.pauseMenu.hidden = true;
    });

    elements.pauseMenu.addEventListener("click", async (e) => {
      const btn = e.target.closest("button");
      if (!btn) return;
      elements.pauseMenu.hidden = true;
      const mins = Number(btn.dataset.minutes || 0);
      const indefinitely = btn.dataset.indefinite === "true";
      await sendRuntimeMessage({
        type: "popup_pause_notifications",
        minutes: mins,
        indefinitely,
        resume: false,
      });
      showToast(mins > 0 ? `Paused for ${mins} min` : "Notifications paused");
      await refreshStatus();
    });

    elements.resumeBtn.addEventListener("click", async () => {
      await sendRuntimeMessage({
        type: "popup_pause_notifications",
        resume: true,
      });
      showToast("Notifications resumed");
      await refreshStatus();
    });

    elements.refreshStatusBtn.addEventListener("click", async () => {
      await refreshStatus();
      showToast("Status refreshed");
    });

    const launchApp = async () => {
      const res = await sendRuntimeMessage({ type: "popup_launch_helper" });
      if (res?.ok) {
        showToast("Opening PingGlass.app…");
        setTimeout(() => void refreshStatus(), 1100);
      } else {
        showToast(res?.error || "Native host unavailable");
      }
    };
    elements.openAppBtn.addEventListener("click", launchApp);
    elements.recoveryOpenAppBtn.addEventListener("click", launchApp);

    elements.reconnectBtn.addEventListener("click", async () => {
      await sendRuntimeMessage({ type: "popup_reconnect" });
      await refreshStatus();
    });

    elements.copyIdBtn.addEventListener("click", async () => {
      try {
        await navigator.clipboard.writeText(chrome.runtime.id);
        showToast("Copied Extension ID");
      } catch {
        showToast("Copy failed");
      }
    });

    elements.toggleTabOverlayBtn.addEventListener("click", async () => {
      if (!currentTabId) {
        showToast("No active tab");
        return;
      }
      if (overlayActive) {
        await sendRuntimeMessage({ type: "popup_disable_overlay", tabId: currentTabId });
        showToast("Overlay hidden on this tab");
      } else {
        const res = await sendRuntimeMessage({ type: "popup_enable_overlay", tabId: currentTabId });
        showToast(res?.ok ? "Overlay enabled on this tab" : res?.error || "Restricted browser page");
      }
      await refreshStatus();
    });

    for (const key of SETTING_BOOLEANS) {
      const el = document.getElementById(`s-${key}`);
      if (el) {
        el.addEventListener("change", () => {
          void persistSettingPatch({ [key]: Boolean(el.checked) });
        });
      }
    }
    for (const key of SETTING_SELECTS) {
      const el = document.getElementById(`s-${key}`);
      if (el) {
        el.addEventListener("change", () => {
          void persistSettingPatch({ [key]: el.value });
        });
      }
    }
    for (const key of SETTING_NUMBERS) {
      const el = document.getElementById(`s-${key}`);
      if (el) {
        el.addEventListener("change", () => {
          const val = Number(el.value);
          if (Number.isFinite(val)) {
            void persistSettingPatch({ [key]: val });
          }
        });
      }
    }

    try {
      if (isContextValid()) {
        chrome.runtime.onMessage.addListener((msg) => {
          if (!isContextValid()) return;
          if (msg?.type === "pingglass_state_updated" && msg.state) {
            renderUI(msg.state, latestSettings, overlayActive);
          }
        });
      }
    } catch {
      // Context invalidated while closing.
    }
  }

  document.addEventListener("DOMContentLoaded", () => {
    bindEvents();
    void refreshStatus();
  });
})();
