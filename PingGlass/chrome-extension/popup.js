(() => {
  "use strict";

  const elements = {
    overallBadge: document.getElementById("overall-badge"),
    bridgeStatus: document.getElementById("bridge-status"),
    whatsappStatus: document.getElementById("whatsapp-status"),
    accessibilityStatus: document.getElementById("accessibility-status"),
    monitoringStatus: document.getElementById("monitoring-status"),
    desktopOverlayStatus: document.getElementById("desktop-overlay-status"),
    overlayStatus: document.getElementById("overlay-status"),
    sessionCount: document.getElementById("session-count"),

    recoveryBox: document.getElementById("recovery-box"),
    recoveryTitle: document.getElementById("recovery-title"),
    recoveryDesc: document.getElementById("recovery-desc"),
    recoveryCmd: document.getElementById("recovery-cmd"),
    copyIdBtn: document.getElementById("copy-id-btn"),
    reconnectBtn: document.getElementById("reconnect-btn"),

    startMonitoringBtn: document.getElementById("start-monitoring-btn"),
    pauseMonitoringBtn: document.getElementById("pause-monitoring-btn"),
    toggleOverlayBtn: document.getElementById("toggle-overlay-btn"),
    testNotificationBtn: document.getElementById("test-notification-btn"),
    clearAllBtn: document.getElementById("clear-all-btn"),
    openAppBtn: document.getElementById("open-app-btn"),
    settingsBtn: document.getElementById("settings-btn"),
    openSettingsBtn: document.getElementById("open-settings-btn"),
    extIdLabel: document.getElementById("ext-id-label"),
    popupToast: document.getElementById("popup-toast"),
  };

  let currentTabId = null;
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

  function setStatus(el, text, dot) {
    el.textContent = text;
    el.dataset.dot = dot;
  }

  function renderUI(state, settings, isOverlayActive) {
    latestState = state;
    latestSettings = settings;
    overlayActive = Boolean(isOverlayActive);

    const extId = chrome.runtime.id || "unknown";
    elements.extIdLabel.textContent = `ID: ${extId.slice(0, 8)}…`;

    const helper = state?.helperStatus || null;
    const bridgeOk = Boolean(state?.bridgeConnected);
    const helperOk = Boolean(state?.helperConnected);

    // 1. Native bridge
    if (!bridgeOk) {
      setStatus(elements.bridgeStatus, "Disconnected", "error");
    } else if (!helperOk) {
      setStatus(elements.bridgeStatus, "Host Ready (App Offline)", "warn");
    } else {
      setStatus(elements.bridgeStatus, "Connected", "ok");
    }

    // 2. WhatsApp Desktop
    if (!helperOk || !helper) {
      setStatus(elements.whatsappStatus, "Unknown (App Offline)", "muted");
    } else if (helper.whatsappRunning) {
      const ver = helper.whatsappVersion ? ` (v${helper.whatsappVersion})` : "";
      setStatus(elements.whatsappStatus, `Detected${ver}`, "ok");
    } else {
      setStatus(elements.whatsappStatus, "Not Detected", "warn");
    }

    // 3. Accessibility
    if (!helperOk || !helper) {
      setStatus(elements.accessibilityStatus, "Unknown", "muted");
    } else if (helper.accessibilityGranted) {
      setStatus(elements.accessibilityStatus, "Granted", "ok");
    } else {
      setStatus(elements.accessibilityStatus, "Permission Required", "error");
    }

    // 4. Monitoring
    if (!helperOk || !helper) {
      setStatus(elements.monitoringStatus, "Inactive", "muted");
    } else if (helper.monitoringState === "monitoring_active") {
      setStatus(elements.monitoringStatus, "Active", "ok");
    } else if (helper.monitoringState === "monitoring_limited") {
      setStatus(elements.monitoringStatus, "Limited (Polling)", "warn");
    } else if (helper.monitoringState === "error") {
      setStatus(elements.monitoringStatus, "Error", "error");
    } else {
      setStatus(elements.monitoringStatus, "Paused", "muted");
    }

    // 4b. Global macOS Desktop Glass status
    if (elements.desktopOverlayStatus) {
      if (!helperOk || !helper) {
        setStatus(elements.desktopOverlayStatus, "Unknown (App Offline)", "muted");
      } else if (helper.globalNotificationsEnabled === false) {
        setStatus(elements.desktopOverlayStatus, "Disabled", "muted");
      } else if (helper.notificationsPaused) {
        setStatus(elements.desktopOverlayStatus, "Paused", "warn");
      } else {
        setStatus(elements.desktopOverlayStatus, "Active", "ok");
      }
    }

    // 5. Chrome Tab Overlay (Optional)
    if (overlayActive) {
      setStatus(elements.overlayStatus, "Active on Current Tab", "ok");
      elements.toggleOverlayBtn.textContent = "Disable Overlay";
      elements.toggleOverlayBtn.classList.remove("btn-accent");
      elements.toggleOverlayBtn.classList.add("btn-danger-outline");
    } else {
      setStatus(elements.overlayStatus, "Inactive", "muted");
      elements.toggleOverlayBtn.textContent = "Enable Glass Overlay on This Tab";
      elements.toggleOverlayBtn.classList.add("btn-accent");
      elements.toggleOverlayBtn.classList.remove("btn-danger-outline");
    }

    elements.sessionCount.textContent = String(state?.sessionMessagesReceived ?? 0);

    // Monitoring control button availability
    const isMonitoringOn = Boolean(helper?.monitoringEnabled ?? settings?.monitoringEnabled);
    elements.startMonitoringBtn.disabled = !helperOk || isMonitoringOn;
    elements.pauseMonitoringBtn.disabled = !helperOk || !isMonitoringOn;

    renderOverallAndRecovery(state, helper, overlayActive, extId);
  }

  function renderOverallAndRecovery(state, helper, isOverlayActive, extId) {
    elements.recoveryBox.hidden = true;
    elements.recoveryCmd.hidden = true;
    elements.copyIdBtn.hidden = true;
    elements.reconnectBtn.hidden = true;

    if (!state?.bridgeConnected) {
      elements.overallBadge.textContent = state?.nativeHostMissing
        ? "Native host missing"
        : "Bridge disconnected";
      elements.overallBadge.dataset.tone = "error";

      elements.recoveryBox.hidden = false;
      if (state?.nativeHostMissing) {
        elements.recoveryTitle.textContent = "Install Native Messaging Host";
        elements.recoveryDesc.textContent =
          "Chrome cannot reach com.pingglass.bridge. Run the installer with your Extension ID, then click Reconnect:";
        elements.recoveryCmd.textContent = `./macOS/NativeMessagingHost/install_native_host.sh ${extId}`;
        elements.recoveryCmd.hidden = false;
        elements.copyIdBtn.hidden = false;
      } else {
        elements.recoveryTitle.textContent = "Chrome Bridge Disconnected";
        elements.recoveryDesc.textContent =
          state?.lastError || "Native Messaging host disconnected. Click Reconnect to retry.";
      }
      elements.reconnectBtn.hidden = false;
      return;
    }

    if (!state?.helperConnected || !helper) {
      elements.overallBadge.textContent = "macOS app offline";
      elements.overallBadge.dataset.tone = "warn";
      elements.recoveryBox.hidden = false;
      elements.recoveryTitle.textContent = "PingGlass macOS Helper Not Running";
      elements.recoveryDesc.textContent =
        "Click 'Open PingGlass macOS App' below to start the local menu bar helper.";
      elements.reconnectBtn.hidden = false;
      return;
    }

    if (!helper.accessibilityGranted) {
      elements.overallBadge.textContent = "Accessibility required";
      elements.overallBadge.dataset.tone = "error";
      elements.recoveryBox.hidden = false;
      elements.recoveryTitle.textContent = "Grant macOS Accessibility Permission";
      elements.recoveryDesc.textContent =
        "Open System Settings → Privacy & Security → Accessibility and enable PingGlass.";
      return;
    }

    if (!helper.whatsappRunning) {
      elements.overallBadge.textContent = "WhatsApp closed";
      elements.overallBadge.dataset.tone = "warn";
      elements.recoveryBox.hidden = false;
      elements.recoveryTitle.textContent = "WhatsApp Desktop Is Closed";
      elements.recoveryDesc.textContent =
        "Launch the official WhatsApp Desktop app to detect incoming messages.";
      return;
    }

    if (!isOverlayActive) {
      elements.overallBadge.textContent = "Overlay inactive on tab";
      elements.overallBadge.dataset.tone = "warn";
      elements.recoveryBox.hidden = false;
      elements.recoveryTitle.textContent = "Overlay Not Enabled on Current Tab";
      elements.recoveryDesc.textContent =
        "Click 'Enable Glass Overlay on This Tab' to display floating glass notifications here.";
      return;
    }

    if (helper.monitoringState === "monitoring_active") {
      elements.overallBadge.textContent = "Monitoring active";
      elements.overallBadge.dataset.tone = "ok";
    } else if (helper.monitoringState === "monitoring_limited") {
      elements.overallBadge.textContent = "Monitoring limited";
      elements.overallBadge.dataset.tone = "warn";
    } else {
      elements.overallBadge.textContent = "Monitoring paused";
      elements.overallBadge.dataset.tone = "neutral";
    }
  }

  async function refreshStatus() {
    if (!isContextValid()) {
      return;
    }
    try {
      const tabs = await chrome.tabs.query({ active: true, currentWindow: true });
      currentTabId = tabs[0]?.id ?? null;
    } catch {
      currentTabId = null;
    }

    const response = await sendRuntimeMessage({
      type: "popup_get_status",
      tabId: currentTabId,
    });
    if (response?.ok) {
      renderUI(response.state, response.settings, response.overlayActive);
    }
  }

  function bindEvents() {
    const openSettings = () => {
      chrome.runtime.openOptionsPage();
    };
    elements.settingsBtn.addEventListener("click", openSettings);
    elements.openSettingsBtn.addEventListener("click", openSettings);

    elements.startMonitoringBtn.addEventListener("click", async () => {
      const res = await sendRuntimeMessage({ type: "popup_start_monitoring" });
      showToast(res?.ok ? "Monitoring started" : "Helper not connected");
      await refreshStatus();
    });

    elements.pauseMonitoringBtn.addEventListener("click", async () => {
      const res = await sendRuntimeMessage({ type: "popup_pause_monitoring" });
      showToast(res?.ok ? "Monitoring paused" : "Helper not connected");
      await refreshStatus();
    });

    elements.toggleOverlayBtn.addEventListener("click", async () => {
      if (!currentTabId) {
        showToast("No active tab available");
        return;
      }

      if (overlayActive) {
        await sendRuntimeMessage({ type: "popup_disable_overlay", tabId: currentTabId });
        showToast("Overlay disabled on this tab");
      } else {
        const res = await sendRuntimeMessage({ type: "popup_enable_overlay", tabId: currentTabId });
        if (!res?.ok) {
          showToast(res?.error || "Cannot enable overlay on this page");
        } else {
          showToast("Glass Overlay enabled");
        }
      }
      await refreshStatus();
    });

    elements.testNotificationBtn.addEventListener("click", async () => {
      const res = await sendRuntimeMessage({
        type: "popup_test_notification",
        tabId: currentTabId,
      });
      if (!res?.ok) {
        showToast(res?.error || "Enable overlay on this tab first");
      } else if (res.pipeline === "native-bridge") {
        showToast("Sent test notification via macOS bridge");
      } else {
        showToast("Displayed local test (macOS app offline)");
      }
    });

    if (elements.clearAllBtn) {
      elements.clearAllBtn.addEventListener("click", async () => {
        await sendRuntimeMessage({ type: "popup_clear_all" });
        showToast("Cleared all notifications");
      });
    }

    elements.openAppBtn.addEventListener("click", async () => {
      const res = await sendRuntimeMessage({ type: "popup_launch_helper" });
      if (res?.ok) {
        showToast("Launching PingGlass macOS app…");
        setTimeout(() => {
          void refreshStatus();
        }, 1200);
      } else {
        showToast(res?.error || "Native host unavailable");
      }
    });

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
      // Context invalidated while popup was closing/reloading.
    }
  }

  document.addEventListener("DOMContentLoaded", () => {
    bindEvents();
    void refreshStatus();
  });
})();
