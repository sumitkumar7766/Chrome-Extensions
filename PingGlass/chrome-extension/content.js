/**
 * PingGlass Floating Glass Overlay Content Script
 *
 * Injected explicitly into the active tab when the user enables the overlay.
 * Renders notifications inside an isolated Shadow DOM host so page CSS cannot
 * leak in and overlay styles never affect the host webpage.
 */

(() => {
  "use strict";

  const HOST_ID = "pingglass-overlay-host";

  function isExtensionContextValid() {
    try {
      return Boolean(typeof chrome !== "undefined" && chrome.runtime && chrome.runtime.id);
    } catch {
      return false;
    }
  }

  if (!isExtensionContextValid()) {
    return;
  }

  // Prevent duplicate listeners within the same extension instance, while allowing
  // clean replacement if the extension was reloaded in chrome://extensions.
  if (window.__pingGlassController) {
    if (window.__pingGlassController.extensionId === chrome.runtime.id) {
      return;
    }
    try {
      window.__pingGlassController.cleanup();
    } catch {
      // Previous context was already invalidated.
    }
  }

  let settings = {
    notificationsEnabled: true,
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
    maxPreviewLength: 280,
  };

  let hostElement = null;
  let shadowRoot = null;
  let stackContainer = null;
  let clearAllBar = null;
  let clearAllBtn = null;
  let stylesLoaded = false;

  const activeCards = new Map(); // id -> record
  const pendingQueue = [];

  /* -------------------------------------------------------------------------- */
  /* Shadow DOM Setup & Styling                                                 */
  /* -------------------------------------------------------------------------- */

  async function ensureOverlayMounted() {
    if (!hostElement || !document.documentElement.contains(hostElement)) {
      hostElement = document.createElement("div");
      hostElement.id = HOST_ID;
      hostElement.setAttribute("aria-live", "polite");
      hostElement.setAttribute("aria-label", "PingGlass notifications");

      shadowRoot = hostElement.attachShadow({ mode: "open" });

      stackContainer = document.createElement("div");
      stackContainer.className = "pg-stack";
      shadowRoot.appendChild(stackContainer);
      document.documentElement.appendChild(hostElement);
      stylesLoaded = false;
    }

    if (!stylesLoaded && shadowRoot) {
      const styleEl = document.createElement("style");
      try {
        if (!isExtensionContextValid()) {
          throw new Error("Extension context invalidated");
        }
        const cssUrl = chrome.runtime.getURL("content.css");
        const response = await fetch(cssUrl);
        styleEl.textContent = await response.text();
      } catch {
        // Minimal fallback CSS if content.css fetch fails or extension reloaded
        styleEl.textContent =
          ".pg-stack{position:fixed;right:20px;bottom:20px;width:344px;display:flex;flex-direction:column;gap:10px;pointer-events:none;font-family:-apple-system,sans-serif;}" +
          ".pg-card{pointer-events:auto;background:rgba(17,22,32,.85);color:#fff;border-radius:14px;padding:12px 14px;border:1px solid rgba(255,255,255,.15);}";
      }
      shadowRoot.prepend(styleEl);
      stylesLoaded = true;
    }

    applyContainerSettings();
  }

  function applyContainerSettings() {
    if (!stackContainer) return;
    stackContainer.dataset.position = settings.position === "top-right" ? "top-right" : "bottom-right";
    stackContainer.dataset.theme = settings.theme === "light" ? "light" : "dark";
    const reducedMotion = window.matchMedia?.("(prefers-reduced-motion: reduce)")?.matches;
    stackContainer.dataset.animations = settings.enableAnimation && !reducedMotion ? "on" : "off";
  }

  function cleanupOverlay() {
    pendingQueue.length = 0;
    for (const record of activeCards.values()) {
      if (record.timerId !== null) {
        clearTimeout(record.timerId);
      }
    }
    activeCards.clear();

    if (hostElement && hostElement.parentNode) {
      hostElement.parentNode.removeChild(hostElement);
    }
    hostElement = null;
    shadowRoot = null;
    stackContainer = null;
    clearAllBar = null;
    clearAllBtn = null;
    stylesLoaded = false;
  }

  function updateClearAllBar() {
    if (!stackContainer) return;
    const totalCount = activeCards.size + pendingQueue.length;
    if (totalCount <= 0) {
      if (clearAllBar && clearAllBar.parentNode) {
        clearAllBar.parentNode.removeChild(clearAllBar);
      }
      clearAllBar = null;
      clearAllBtn = null;
      return;
    }

    if (!clearAllBar) {
      clearAllBar = document.createElement("div");
      clearAllBar.className = "pg-clear-all-bar";
      clearAllBtn = document.createElement("button");
      clearAllBtn.type = "button";
      clearAllBtn.className = "pg-clear-all-btn";
      clearAllBtn.setAttribute("aria-label", "Clear all notifications");
      clearAllBtn.addEventListener("click", (e) => {
        e.stopPropagation();
        clearAllNotifications();
      });
      clearAllBar.appendChild(clearAllBtn);
      stackContainer.prepend(clearAllBar);
    }

    if (clearAllBtn) {
      clearAllBtn.textContent = totalCount > 1 ? `Clear All (${totalCount})` : "Clear All";
    }
  }

  function clearAllNotifications() {
    pendingQueue.length = 0;
    const ids = Array.from(activeCards.keys());
    for (const id of ids) {
      dismissCard(id);
    }
    updateClearAllBar();
  }

  /* -------------------------------------------------------------------------- */
  /* Notification Sound (Optional, Local Web Audio API)                         */
  /* -------------------------------------------------------------------------- */

  function playSubtleChime() {
    if (!settings.soundEnabled) return;
    try {
      const AudioCtx = window.AudioContext || window.webkitAudioContext;
      if (!AudioCtx) return;
      const ctx = new AudioCtx();
      const now = ctx.currentTime;

      const osc = ctx.createOscillator();
      const gain = ctx.createGain();
      osc.type = "sine";
      osc.frequency.setValueAtTime(660, now);
      osc.frequency.exponentialRampToValueAtTime(880, now + 0.09);

      gain.gain.setValueAtTime(0.001, now);
      gain.gain.exponentialRampToValueAtTime(0.06, now + 0.02);
      gain.gain.exponentialRampToValueAtTime(0.0001, now + 0.22);

      osc.connect(gain);
      gain.connect(ctx.destination);
      osc.start(now);
      osc.stop(now + 0.24);
      setTimeout(() => {
        ctx.close().catch(() => {});
      }, 350);
    } catch {
      // Autoplay policies may block audio without prior user gesture; ignore gracefully.
    }
  }

  /* -------------------------------------------------------------------------- */
  /* Safe DOM Element Builders                                                  */
  /* -------------------------------------------------------------------------- */

  function computeInitials(name) {
    if (!name || typeof name !== "string") return "WA";
    const parts = name
      .trim()
      .split(/\s+/)
      .filter(Boolean);
    if (parts.length === 0) return "WA";
    if (parts.length === 1) return parts[0].slice(0, 2).toUpperCase();
    return (parts[0][0] + parts[parts.length - 1][0]).toUpperCase();
  }

  function createSvgIcon(paths, viewBox = "0 0 16 16") {
    const svgNS = "http://www.w3.org/2000/svg";
    const svg = document.createElementNS(svgNS, "svg");
    svg.setAttribute("viewBox", viewBox);
    svg.setAttribute("fill", "none");
    svg.setAttribute("aria-hidden", "true");
    for (const def of paths) {
      const el = document.createElementNS(svgNS, def.tag);
      for (const [k, v] of Object.entries(def.attrs)) {
        el.setAttribute(k, v);
      }
      svg.appendChild(el);
    }
    return svg;
  }

  function buildNotificationCard(message) {
    const card = document.createElement("article");
    card.className = "pg-card";
    if (stackContainer?.dataset.animations === "on") {
      card.classList.add("pg-entering");
    }
    card.setAttribute("role", "status");

    const row = document.createElement("div");
    row.className = "pg-row";

    const displaySender = message.sender || message.chatName || "WhatsApp Message";

    // Avatar + WhatsApp badge
    if (settings.showAvatar) {
      const avatarWrap = document.createElement("div");
      avatarWrap.className = "pg-avatar-wrap";

      if (message.avatar) {
        const img = document.createElement("img");
        img.className = "pg-avatar-img";
        img.src = message.avatar;
        img.alt = "";
        avatarWrap.appendChild(img);
      } else {
        const initials = document.createElement("div");
        initials.className = "pg-avatar-initials";
        initials.textContent = computeInitials(displaySender);
        avatarWrap.appendChild(initials);
      }

      const badge = document.createElement("div");
      badge.className = "pg-wa-badge";
      badge.appendChild(
        createSvgIcon(
          [
            {
              tag: "path",
              attrs: {
                d: "M12 6.8A5.2 5.2 0 0 0 2.5 9.6L2 12l2.5-.5A5.2 5.2 0 0 0 12 6.8Z",
                stroke: "currentColor",
                "stroke-width": "1.5",
                "stroke-linejoin": "round",
              },
            },
          ],
          "0 0 14 14"
        )
      );
      avatarWrap.appendChild(badge);
      row.appendChild(avatarWrap);
    }

    const main = document.createElement("div");
    main.className = "pg-main";

    const headerLine = document.createElement("div");
    headerLine.className = "pg-header-line";

    const titleGroup = document.createElement("div");
    titleGroup.className = "pg-title-group";

    if (settings.showSender) {
      const senderEl = document.createElement("span");
      senderEl.className = "pg-sender";
      senderEl.textContent = displaySender;
      titleGroup.appendChild(senderEl);
    }

    if (message.isTest) {
      const pill = document.createElement("span");
      pill.className = "pg-test-pill";
      pill.textContent = "Test";
      titleGroup.appendChild(pill);
    }

    headerLine.appendChild(titleGroup);

    const controls = document.createElement("div");
    controls.className = "pg-controls";

    if (settings.showTimestamp && message.timestamp) {
      const timeEl = document.createElement("span");
      timeEl.className = "pg-time";
      timeEl.textContent = message.timestamp;
      controls.appendChild(timeEl);
    }

    if (settings.showCopyButton && message.text) {
      const copyBtn = document.createElement("button");
      copyBtn.type = "button";
      copyBtn.className = "pg-btn";
      copyBtn.title = "Copy message";
      copyBtn.setAttribute("aria-label", "Copy message");
      copyBtn.appendChild(
        createSvgIcon([
          {
            tag: "rect",
            attrs: {
              x: "5.5",
              y: "5.5",
              width: "7.5",
              height: "8.5",
              rx: "1.5",
              stroke: "currentColor",
              "stroke-width": "1.4",
            },
          },
          {
            tag: "path",
            attrs: {
              d: "M10.5 5.5V3.5A1.5 1.5 0 0 0 9 2H4a1.5 1.5 0 0 0-1.5 1.5v6A1.5 1.5 0 0 0 4 11h1.5",
              stroke: "currentColor",
              "stroke-width": "1.4",
            },
          },
        ])
      );
      copyBtn.addEventListener("click", (e) => {
        e.stopPropagation();
        void copyMessageToClipboard(message.text, card);
      });
      controls.appendChild(copyBtn);
    }

    const closeBtn = document.createElement("button");
    closeBtn.type = "button";
    closeBtn.className = "pg-btn";
    closeBtn.title = "Dismiss notification";
    closeBtn.setAttribute("aria-label", "Dismiss notification");
    closeBtn.appendChild(
      createSvgIcon([
        {
          tag: "path",
          attrs: {
            d: "M4.2 4.2L11.8 11.8M11.8 4.2L4.2 11.8",
            stroke: "currentColor",
            "stroke-width": "1.6",
            "stroke-linecap": "round",
          },
        },
      ])
    );
    closeBtn.addEventListener("click", (e) => {
      e.stopPropagation();
      dismissCard(message.id);
    });
    controls.appendChild(closeBtn);

    headerLine.appendChild(controls);
    main.appendChild(headerLine);

    if (settings.showChatName && message.chatName && message.chatName !== displaySender) {
      const chatEl = document.createElement("div");
      chatEl.className = "pg-chat-name";
      chatEl.textContent = message.chatName;
      main.appendChild(chatEl);
    }

    if (settings.showPreview && message.text) {
      const limit = Math.max(60, Number(settings.maxPreviewLength) || 280);
      const fullText = message.text;
      const needsTruncation = fullText.length > limit;
      let expanded = false;

      const previewEl = document.createElement("p");
      previewEl.className = "pg-preview";
      previewEl.textContent = needsTruncation ? `${fullText.slice(0, limit - 1)}…` : fullText;
      main.appendChild(previewEl);

      if (needsTruncation) {
        const toggleBtn = document.createElement("button");
        toggleBtn.type = "button";
        toggleBtn.className = "pg-expand-btn";
        toggleBtn.textContent = "Show more";
        toggleBtn.addEventListener("click", (e) => {
          e.stopPropagation();
          expanded = !expanded;
          previewEl.textContent = expanded ? fullText : `${fullText.slice(0, limit - 1)}…`;
          toggleBtn.textContent = expanded ? "Show less" : "Show more";
        });
        main.appendChild(toggleBtn);
      }
    }

    row.appendChild(main);
    card.appendChild(row);
    return card;
  }

  async function copyMessageToClipboard(text, card) {
    let copied = false;
    if (navigator.clipboard && typeof navigator.clipboard.writeText === "function") {
      try {
        await navigator.clipboard.writeText(text);
        copied = true;
      } catch {
        copied = false;
      }
    }
    if (!copied) {
      const ta = document.createElement("textarea");
      ta.value = text;
      ta.setAttribute("readonly", "");
      ta.style.position = "fixed";
      ta.style.opacity = "0";
      document.body.appendChild(ta);
      ta.select();
      try {
        copied = document.execCommand("copy");
      } catch {
        copied = false;
      } finally {
        document.body.removeChild(ta);
      }
    }

    if (copied && card) {
      const existing = card.querySelector(".pg-copied-badge");
      if (existing) existing.remove();
      const badge = document.createElement("span");
      badge.className = "pg-copied-badge";
      badge.textContent = "Copied";
      card.appendChild(badge);
      setTimeout(() => badge.remove(), 1400);
    }
  }

  /* -------------------------------------------------------------------------- */
  /* Queue, Stacking & Auto-Dismiss Lifecycle                                   */
  /* -------------------------------------------------------------------------- */

  function scheduleAutoDismiss(record) {
    if (record.timerId !== null) {
      clearTimeout(record.timerId);
      record.timerId = null;
    }
    const seconds = Number(settings.autoDismissSeconds);
    if (!Number.isFinite(seconds) || seconds <= 0) {
      return; // 0 means stay until manually closed
    }

    record.startedAt = Date.now();
    record.timerId = setTimeout(() => {
      dismissCard(record.id);
    }, record.remainingMs);
  }

  function pauseAutoDismiss(record) {
    if (record.timerId !== null) {
      clearTimeout(record.timerId);
      record.timerId = null;
      const elapsed = Date.now() - record.startedAt;
      record.remainingMs = Math.max(800, record.remainingMs - elapsed);
    }
  }

  function dismissCard(id) {
    const record = activeCards.get(id);
    if (!record || record.exiting) {
      return;
    }

    record.exiting = true;
    if (record.timerId !== null) {
      clearTimeout(record.timerId);
      record.timerId = null;
    }

    const finalizeRemoval = () => {
      if (record.element.parentNode) {
        record.element.parentNode.removeChild(record.element);
      }
      activeCards.delete(id);
      drainQueue();
      updateClearAllBar();
    };

    const animationsOn = stackContainer?.dataset.animations === "on";
    if (!animationsOn) {
      finalizeRemoval();
      return;
    }

    record.element.classList.remove("pg-entering");
    record.element.classList.add("pg-exiting");
    record.element.addEventListener("animationend", finalizeRemoval, { once: true });
    // Safety fallback if animationend does not fire (e.g., background tab).
    setTimeout(finalizeRemoval, 360);
  }

  async function enqueueNotification(message) {
    await ensureOverlayMounted();
    if (activeCards.has(message.id)) {
      return;
    }

    const maxVisible = Math.max(1, Math.min(6, Number(settings.maxVisible) || 3));
    if (activeCards.size >= maxVisible) {
      pendingQueue.push(message);
      updateClearAllBar();
      return;
    }

    showCardNow(message);
  }

  function showCardNow(message) {
    if (!stackContainer) return;

    const card = buildNotificationCard(message);
    const rawSec = Number(settings.autoDismissSeconds);
    const durationMs = Number.isFinite(rawSec) && rawSec > 0 ? Math.max(1500, rawSec * 1000) : 0;
    const record = {
      id: message.id,
      element: card,
      timerId: null,
      startedAt: Date.now(),
      remainingMs: durationMs,
      exiting: false,
    };

    card.addEventListener("mouseenter", () => pauseAutoDismiss(record));
    card.addEventListener("mouseleave", () => {
      if (!record.exiting) scheduleAutoDismiss(record);
    });
    card.addEventListener("focusin", () => pauseAutoDismiss(record));
    card.addEventListener("focusout", () => {
      if (!record.exiting) scheduleAutoDismiss(record);
    });

    activeCards.set(message.id, record);
    stackContainer.appendChild(card);

    scheduleAutoDismiss(record);
    updateClearAllBar();
    playSubtleChime();
  }

  function drainQueue() {
    const maxVisible = Math.max(1, Math.min(6, Number(settings.maxVisible) || 3));
    while (activeCards.size < maxVisible && pendingQueue.length > 0) {
      const next = pendingQueue.shift();
      if (next && !activeCards.has(next.id)) {
        showCardNow(next);
      }
    }
  }

  /* -------------------------------------------------------------------------- */
  /* Extension Message Listener                                                 */
  /* -------------------------------------------------------------------------- */

  try {
    chrome.runtime.onMessage.addListener((msg, _sender, sendResponse) => {
      if (!isExtensionContextValid() || !msg || typeof msg !== "object") {
        return false;
      }

      switch (msg.type) {
        case "pingglass_ping":
          sendResponse({ alive: true });
          return false;

        case "pingglass_init":
          if (msg.settings) {
            settings = { ...settings, ...msg.settings };
          }
          void ensureOverlayMounted().then(() => sendResponse({ ok: true }));
          return true;

        case "pingglass_settings":
          if (msg.settings) {
            settings = { ...settings, ...msg.settings };
            applyContainerSettings();
          }
          sendResponse({ ok: true });
          return false;

        case "pingglass_notify":
          if (msg.settings) {
            settings = { ...settings, ...msg.settings };
          }
          if (msg.message) {
            void enqueueNotification(msg.message).then(() => sendResponse({ ok: true }));
            return true;
          }
          sendResponse({ ok: false });
          return false;

        case "pingglass_cleanup":
          cleanupOverlay();
          sendResponse({ ok: true });
          return false;

        case "pingglass_clear_all":
          clearAllNotifications();
          sendResponse({ ok: true });
          return false;

        default:
          return false;
      }
    });

    window.__pingGlassController = {
      extensionId: chrome.runtime.id,
      cleanup: cleanupOverlay,
    };
  } catch {
    cleanupOverlay();
  }
})();
