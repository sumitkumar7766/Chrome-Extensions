/**
 * PingGlass Floating Glass Overlay Content Script
 *
 * Renders floating Liquid Glass notifications and an interactive Glass Chat Popup
 * inside an isolated Shadow DOM host matching the native macOS PingGlass app.
 * Uses pure DOM creation APIs (`createElement`, `createElementNS`, `textContent`) and extension-preloaded CSS.
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
    chromeAutoOverlay: true,
    autoDismissSeconds: 0,
    maxVisible: 3,
    edgeMargin: 20,
    showSender: true,
    showChatName: true,
    showAvatar: true,
    showTimestamp: true,
    showPreview: true,
    showCopyButton: true,
    position: "bottom-right",
    theme: "dark",
    clickAction: "open_glass_chat_popup",
    enableAnimation: true,
    soundEnabled: false,
    maxPreviewLength: 280,
  };

  let hostElement = null;
  let shadowRoot = null;
  let styleEl = null;
  let stackContainer = null;
  let clearAllBar = null;
  let clearAllBtn = null;
  let clearAllLabelEl = null;
  let chatPopupEl = null;
  let activeChatMessage = null;
  let stylesLoaded = false;

  const activeCards = new Map(); // id -> record
  const pendingQueue = [];
  const localChatCache = new Map(); // chatKey -> [entries]

  const FALLBACK_CSS =
    ":host{all:initial;position:fixed;z-index:2147483647;pointer-events:none;font-family:-apple-system,sans-serif;}" +
    ".pg-stack{position:fixed;right:20px;bottom:20px;width:318px;display:flex;flex-direction:column;gap:8px;pointer-events:none;}" +
    ".pg-card{pointer-events:auto;border-radius:18px;padding:10px 13px;color:#fff;background:rgba(18,20,24,.78);border:1px solid rgba(255,255,255,.24);cursor:pointer;}" +
    ".pg-clear-all-bar{display:flex;justify-content:flex-end;pointer-events:none;}" +
    ".pg-clear-all-btn{pointer-events:auto;display:inline-flex;align-items:center;gap:5px;height:26px;padding:0 11px;border-radius:13px;color:#fff;background:rgba(20,22,27,.78);border:1px solid rgba(255,255,255,.24);cursor:pointer;}" +
    ".pg-top-header{display:flex;align-items:center;justify-content:space-between;gap:6px;margin-bottom:8px;}" +
    ".pg-brand-left{display:flex;align-items:center;gap:6px;}" +
    ".pg-wa-square{width:17px;height:17px;border-radius:5px;background:#25d366;color:#fff;display:inline-flex;align-items:center;justify-content:center;}" +
    ".pg-controls{display:flex;align-items:center;gap:4px;}" +
    ".pg-btn{width:22px;height:22px;border-radius:6px;background:rgba(255,255,255,.1);border:1px solid rgba(255,255,255,.2);color:#fff;display:inline-flex;align-items:center;justify-content:center;cursor:pointer;}" +
    ".pg-body-row{display:flex;align-items:stretch;gap:10px;}" +
    ".pg-avatar-initials{width:34px;height:34px;border-radius:50%;border:1.25px solid #25d366;display:flex;align-items:center;justify-content:center;}" +
    ".pg-divider{width:1px;background:rgba(255,255,255,.14);}" +
    ".pg-main{flex:1;min-width:0;display:flex;flex-direction:column;gap:2px;}" +
    ".pg-chat-popup{position:fixed;right:20px;bottom:20px;width:318px;height:336px;border-radius:18px;pointer-events:auto;color:#fff;background:rgba(18,20,24,.88);border:1px solid rgba(255,255,255,.24);display:flex;flex-direction:column;overflow:hidden;}";

  /* -------------------------------------------------------------------------- */
  /* Local Chat Cache & Runtime Helper                                          */
  /* -------------------------------------------------------------------------- */

  function chatKey(message) {
    return String(message?.chatName || message?.sender || message?.id || "whatsapp")
      .trim()
      .toLowerCase();
  }

  function recordLocalChat(message) {
    if (!message || !message.text) return;
    const key = chatKey(message);
    const list = localChatCache.get(key) || [];
    if (!list.some((item) => item.id === message.id)) {
      list.push({
        id: message.id,
        sender: message.sender || null,
        text: message.text,
        timestamp: message.timestamp || null,
        isOutgoing: false,
        isTest: Boolean(message.isTest),
      });
      if (list.length > 40) list.shift();
      localChatCache.set(key, list);
    }
  }

  function safeSendBackgroundMessage(payload) {
    if (!isExtensionContextValid() || typeof chrome.runtime.sendMessage !== "function") {
      return Promise.resolve(null);
    }
    try {
      const res = chrome.runtime.sendMessage(payload);
      return res && typeof res.catch === "function" ? res.catch(() => null) : Promise.resolve(null);
    } catch {
      return Promise.resolve(null);
    }
  }

  /* -------------------------------------------------------------------------- */
  /* Shadow DOM Setup & Styling                                                 */
  /* -------------------------------------------------------------------------- */

  async function ensureOverlayMounted(cssTextFromBg = null) {
    if (!hostElement || !document.documentElement.contains(hostElement)) {
      hostElement = document.createElement("div");
      hostElement.id = HOST_ID;
      hostElement.setAttribute("aria-live", "polite");
      hostElement.setAttribute("aria-label", "PingGlass notifications");

      shadowRoot = hostElement.attachShadow({ mode: "open" });

      styleEl = document.createElement("style");
      shadowRoot.appendChild(styleEl);

      stackContainer = document.createElement("div");
      stackContainer.className = "pg-stack";
      shadowRoot.appendChild(stackContainer);
      document.documentElement.appendChild(hostElement);
      stylesLoaded = false;
    }

    if (styleEl && cssTextFromBg && typeof cssTextFromBg === "string") {
      styleEl.textContent = cssTextFromBg;
      stylesLoaded = true;
    } else if (styleEl && !stylesLoaded) {
      try {
        if (!isExtensionContextValid()) {
          throw new Error("Extension context invalidated");
        }
        const cssUrl = chrome.runtime.getURL("content.css");
        const response = await fetch(cssUrl);
        styleEl.textContent = await response.text();
      } catch {
        styleEl.textContent = FALLBACK_CSS;
      }
      stylesLoaded = true;
    }

    applyContainerSettings();
  }

  function applyContainerSettings() {
    const allowedPositions = new Set([
      "bottom-right",
      "center-right",
      "top-right",
      "bottom-left",
      "top-left",
    ]);
    const pos = allowedPositions.has(settings.position) ? settings.position : "bottom-right";
    const theme = settings.theme === "light" ? "light" : "dark";
    const margin = Math.max(12, Math.min(48, Number(settings.edgeMargin) || 20));
    if (hostElement) {
      hostElement.style.setProperty("--pg-margin", `${margin}px`);
    }

    if (stackContainer) {
      stackContainer.dataset.position = pos;
      stackContainer.dataset.theme = theme;
      const reducedMotion = window.matchMedia?.("(prefers-reduced-motion: reduce)")?.matches;
      stackContainer.dataset.animations = settings.enableAnimation && !reducedMotion ? "on" : "off";
    }

    if (chatPopupEl) {
      chatPopupEl.dataset.theme = theme;
      positionChatPopupElement(chatPopupEl);
    }
  }

  function cleanupOverlay() {
    pendingQueue.length = 0;
    for (const record of activeCards.values()) {
      if (record.timerId !== null) {
        clearTimeout(record.timerId);
      }
    }
    activeCards.clear();
    localChatCache.clear();
    closeChatPopup();

    if (hostElement && hostElement.parentNode) {
      hostElement.parentNode.removeChild(hostElement);
    }
    hostElement = null;
    shadowRoot = null;
    styleEl = null;
    stackContainer = null;
    clearAllBar = null;
    clearAllBtn = null;
    clearAllLabelEl = null;
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
      clearAllLabelEl = null;
      return;
    }

    if (!clearAllBar) {
      clearAllBar = document.createElement("div");
      clearAllBar.className = "pg-clear-all-bar";
      clearAllBtn = document.createElement("button");
      clearAllBtn.type = "button";
      clearAllBtn.className = "pg-clear-all-btn";
      clearAllBtn.setAttribute("aria-label", "Clear all notifications");

      const layersIcon = createSvgIcon(
        [
          { tag: "path", attrs: { d: "M8 2.2 13.5 5 8 7.8 2.5 5 8 2.2Z", stroke: "currentColor", "stroke-width": "1.3", "stroke-linejoin": "round" } },
          { tag: "path", attrs: { d: "M2.5 8 8 10.8 13.5 8", stroke: "currentColor", "stroke-width": "1.3", "stroke-linecap": "round", "stroke-linejoin": "round" } },
          { tag: "path", attrs: { d: "M2.5 11 8 13.8 13.5 11", stroke: "currentColor", "stroke-width": "1.3", "stroke-linecap": "round", "stroke-linejoin": "round" } },
        ],
        "0 0 16 16"
      );
      clearAllLabelEl = document.createElement("span");
      clearAllBtn.appendChild(layersIcon);
      clearAllBtn.appendChild(clearAllLabelEl);

      clearAllBtn.addEventListener("click", (e) => {
        e.stopPropagation();
        clearAllNotifications({ notifyBackground: true });
      });
      clearAllBar.appendChild(clearAllBtn);
      stackContainer.prepend(clearAllBar);
    }

    if (clearAllLabelEl) {
      clearAllLabelEl.textContent = totalCount > 1 ? `Clear All (${totalCount})` : "Clear All";
    }
  }

  function clearAllNotifications({ notifyBackground = false } = {}) {
    pendingQueue.length = 0;
    closeChatPopup();
    const ids = Array.from(activeCards.keys());
    for (const id of ids) {
      dismissCard(id, { notifyBackground: false });
    }
    updateClearAllBar();
    if (notifyBackground) {
      void safeSendBackgroundMessage({ type: "content_clear_all" });
    }
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
      // Autoplay policies may block audio without prior user gesture.
    }
  }

  /* -------------------------------------------------------------------------- */
  /* Safe SVG & DOM Builders                                                    */
  /* -------------------------------------------------------------------------- */

  function computeInitials(name) {
    if (!name || typeof name !== "string") return "WA";
    const parts = name.trim().split(/\s+/).filter(Boolean);
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

  function createOpenIcon() {
    return createSvgIcon([
      {
        tag: "path",
        attrs: {
          d: "M7 3.5H4.5A1.5 1.5 0 0 0 3 5v6.5A1.5 1.5 0 0 0 4.5 13H11a1.5 1.5 0 0 0 1.5-1.5V9",
          stroke: "currentColor",
          "stroke-width": "1.35",
          "stroke-linecap": "round",
        },
      },
      {
        tag: "path",
        attrs: {
          d: "M9.5 3H13v3.5M13 3L7.5 8.5",
          stroke: "currentColor",
          "stroke-width": "1.35",
          "stroke-linecap": "round",
          "stroke-linejoin": "round",
        },
      },
    ]);
  }

  function createCopyIcon() {
    return createSvgIcon([
      {
        tag: "rect",
        attrs: {
          x: "5.5",
          y: "5.5",
          width: "7.5",
          height: "8.5",
          rx: "1.5",
          stroke: "currentColor",
          "stroke-width": "1.35",
        },
      },
      {
        tag: "path",
        attrs: {
          d: "M10.5 5.5V3.5A1.5 1.5 0 0 0 9 2H4a1.5 1.5 0 0 0-1.5 1.5v6A1.5 1.5 0 0 0 4 11h1.5",
          stroke: "currentColor",
          "stroke-width": "1.35",
        },
      },
    ]);
  }

  function createCheckIcon() {
    return createSvgIcon([
      {
        tag: "path",
        attrs: {
          d: "M3.5 8.5 6.5 11.5 12.5 4.8",
          stroke: "currentColor",
          "stroke-width": "1.6",
          "stroke-linecap": "round",
          "stroke-linejoin": "round",
        },
      },
    ]);
  }

  function createCloseIcon() {
    return createSvgIcon([
      {
        tag: "path",
        attrs: {
          d: "M4.2 4.2L11.8 11.8M11.8 4.2L4.2 11.8",
          stroke: "currentColor",
          "stroke-width": "1.55",
          "stroke-linecap": "round",
        },
      },
    ]);
  }

  function createWhatsAppPhoneBubbleIcon() {
    return createSvgIcon(
      [
        {
          tag: "path",
          attrs: {
            d: "M8 2.2a5.5 5.5 0 0 0-4.78 8.23L2.5 13.5l3.15-.7A5.5 5.5 0 1 0 8 2.2Z",
            fill: "currentColor",
          },
        },
        {
          tag: "path",
          attrs: {
            d: "M6.1 5.8c-.2.2-.35.6-.1 1.25.35.95 1.35 1.95 2.3 2.3.65.25 1.05.1 1.25-.1l.45-.45-.9-.65-.4.3c-.2-.08-.85-.65-.95-.95l.3-.4-.65-.9-.45.4Z",
            fill: "#25d366",
          },
        },
      ],
      "0 0 16 16"
    );
  }

  function triggerOpenWhatsApp(message) {
    void safeSendBackgroundMessage({
      type: "content_open_whatsapp",
      message,
    });
  }

  function handleCardClick(message) {
    dismissCard(message.id, { notifyBackground: true });
    if (settings.clickAction === "open_whatsapp_directly") {
      triggerOpenWhatsApp(message);
    } else {
      void openChatPopup(message);
    }
  }

  /* -------------------------------------------------------------------------- */
  /* Notification Card Builder (Matches GlassNotificationCardView)              */
  /* -------------------------------------------------------------------------- */

  function buildNotificationCard(message) {
    const card = document.createElement("article");
    card.className = "pg-card";
    if (stackContainer?.dataset.animations === "on") {
      card.classList.add("pg-entering");
    }
    card.setAttribute("role", "status");

    const displaySender = message.sender || message.chatName || "WhatsApp Message";

    // Top Header Bar: [WA Badge + WhatsApp + TEST] .... [Timestamp + Open + Copy + Close]
    const topHeader = document.createElement("div");
    topHeader.className = "pg-top-header";

    const brandLeft = document.createElement("div");
    brandLeft.className = "pg-brand-left";

    const waSquare = document.createElement("span");
    waSquare.className = "pg-wa-square";
    waSquare.appendChild(createWhatsAppPhoneBubbleIcon());
    brandLeft.appendChild(waSquare);

    const brandName = document.createElement("span");
    brandName.className = "pg-brand-name";
    brandName.textContent = "WhatsApp";
    brandLeft.appendChild(brandName);

    if (message.isTest) {
      const testPill = document.createElement("span");
      testPill.className = "pg-test-pill";
      testPill.textContent = "TEST";
      brandLeft.appendChild(testPill);
    }

    topHeader.appendChild(brandLeft);

    const controls = document.createElement("div");
    controls.className = "pg-controls";

    const timeEl = document.createElement("span");
    timeEl.className = "pg-time";
    if (settings.showTimestamp) {
      timeEl.textContent = message.timestamp || "NOW";
      controls.appendChild(timeEl);
    }

    const copiedPill = document.createElement("span");
    copiedPill.className = "pg-copied-pill";
    copiedPill.textContent = "Copied ✓";
    copiedPill.hidden = true;
    controls.appendChild(copiedPill);

    const openBtn = document.createElement("button");
    openBtn.type = "button";
    openBtn.className = "pg-btn";
    openBtn.title = "Open in WhatsApp";
    openBtn.setAttribute("aria-label", "Open in WhatsApp");
    openBtn.appendChild(createOpenIcon());
    openBtn.addEventListener("click", (e) => {
      e.stopPropagation();
      triggerOpenWhatsApp(message);
    });
    controls.appendChild(openBtn);

    if (settings.showCopyButton && message.text) {
      const copyBtn = document.createElement("button");
      copyBtn.type = "button";
      copyBtn.className = "pg-btn";
      copyBtn.title = "Copy message";
      copyBtn.setAttribute("aria-label", "Copy message");
      copyBtn.appendChild(createCopyIcon());
      copyBtn.addEventListener("click", (e) => {
        e.stopPropagation();
        void copyMessageToClipboard(message.text, () => {
          timeEl.hidden = true;
          copiedPill.hidden = false;
          copyBtn.dataset.active = "copied";
          copyBtn.replaceChildren(createCheckIcon());
          setTimeout(() => {
            timeEl.hidden = false;
            copiedPill.hidden = true;
            delete copyBtn.dataset.active;
            copyBtn.replaceChildren(createCopyIcon());
          }, 1400);
        });
      });
      controls.appendChild(copyBtn);
    }

    const closeBtn = document.createElement("button");
    closeBtn.type = "button";
    closeBtn.className = "pg-btn";
    closeBtn.title = "Dismiss notification";
    closeBtn.setAttribute("aria-label", "Dismiss notification");
    closeBtn.appendChild(createCloseIcon());
    closeBtn.addEventListener("click", (e) => {
      e.stopPropagation();
      dismissCard(message.id, { notifyBackground: true });
    });
    controls.appendChild(closeBtn);

    topHeader.appendChild(controls);
    card.appendChild(topHeader);

    // Body Row: [Avatar 34x34] | [1px Hairline Divider] | [Sender + Context + Message]
    const bodyRow = document.createElement("div");
    bodyRow.className = "pg-body-row";

    if (settings.showAvatar) {
      const avatarCol = document.createElement("div");
      avatarCol.className = "pg-avatar-col";

      if (message.avatar) {
        const img = document.createElement("img");
        img.className = "pg-avatar-img";
        img.src = message.avatar;
        img.alt = "";
        avatarCol.appendChild(img);
      } else {
        const initials = document.createElement("div");
        initials.className = "pg-avatar-initials";
        initials.textContent = computeInitials(displaySender);
        avatarCol.appendChild(initials);
      }

      const divider = document.createElement("div");
      divider.className = "pg-divider";

      bodyRow.appendChild(avatarCol);
      bodyRow.appendChild(divider);
    }

    const main = document.createElement("div");
    main.className = "pg-main";

    if (settings.showSender) {
      const senderEl = document.createElement("div");
      senderEl.className = "pg-sender";
      senderEl.textContent = displaySender;
      main.appendChild(senderEl);
    }

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

    bodyRow.appendChild(main);
    card.appendChild(bodyRow);

    const hintEl = document.createElement("div");
    hintEl.className = "pg-card-hint";
    hintEl.textContent = "Click to view & reply →";
    card.appendChild(hintEl);

    card.addEventListener("click", () => {
      handleCardClick(message);
    });

    return card;
  }

  /* -------------------------------------------------------------------------- */
  /* Floating Glass Chat Popup (Matches GlassChatPopupView.swift)               */
  /* -------------------------------------------------------------------------- */

  function positionChatPopupElement(el) {
    if (!el) return;
    const pos = settings.position || "bottom-right";
    const margin = Math.max(12, Math.min(48, Number(settings.edgeMargin) || 20));
    const hasCards = activeCards.size > 0;
    const offsetX = hasCards ? 332 : 0;

    el.style.left = "auto";
    el.style.right = "auto";
    el.style.top = "auto";
    el.style.bottom = "auto";
    el.style.transform = "none";

    if (pos === "bottom-left" || pos === "top-left") {
      el.style.left = `${margin + offsetX}px`;
    } else {
      el.style.right = `${margin + offsetX}px`;
    }

    if (pos === "top-right" || pos === "top-left") {
      el.style.top = `${margin}px`;
    } else if (pos === "center-right") {
      el.style.top = "50%";
      el.style.transform = "translateY(-50%)";
    } else {
      el.style.bottom = `${margin}px`;
    }
  }

  function closeChatPopup() {
    if (chatPopupEl && chatPopupEl.parentNode) {
      chatPopupEl.parentNode.removeChild(chatPopupEl);
    }
    chatPopupEl = null;
    activeChatMessage = null;
  }

  async function openChatPopup(message) {
    await ensureOverlayMounted();
    if (!shadowRoot) return;

    activeChatMessage = message;
    let entries = localChatCache.get(chatKey(message)) || [];
    const bgRes = await safeSendBackgroundMessage({
      type: "content_get_chat_history",
      message,
    });
    if (bgRes?.ok && Array.isArray(bgRes.entries) && bgRes.entries.length > 0) {
      entries = bgRes.entries;
      localChatCache.set(chatKey(message), entries);
    } else if (entries.length === 0 && message.text) {
      entries = [
        {
          id: message.id,
          sender: message.sender || null,
          text: message.text,
          timestamp: message.timestamp || null,
          isOutgoing: false,
          isTest: Boolean(message.isTest),
        },
      ];
    }

    renderChatPopup(message, entries);
  }

  function renderChatPopup(message, entries) {
    if (!shadowRoot) return;
    closeChatPopup();
    activeChatMessage = message;

    const chatTitle = message.chatName && message.chatName !== "Global Notification"
      ? message.chatName
      : message.sender || "WhatsApp Chat";
    const countSuffix = entries.length > 0 ? ` · ${entries.length} msg${entries.length === 1 ? "" : "s"}` : "";
    const subtitle =
      (message.sender && message.chatName && message.sender !== message.chatName
        ? message.sender
        : "Session Chat") + countSuffix;

    const popup = document.createElement("section");
    popup.className = "pg-chat-popup";
    if (stackContainer?.dataset.animations === "on") {
      popup.classList.add("pg-entering");
    }
    popup.dataset.theme = settings.theme === "light" ? "light" : "dark";
    popup.setAttribute("aria-label", `Chat popup: ${chatTitle}`);

    // Header
    const header = document.createElement("header");
    header.className = "pg-chat-header";

    const avatar = document.createElement("div");
    avatar.className = "pg-chat-avatar";
    avatar.textContent = computeInitials(chatTitle);
    header.appendChild(avatar);

    const meta = document.createElement("div");
    meta.className = "pg-chat-meta";

    const titleRow = document.createElement("div");
    titleRow.className = "pg-chat-title-row";

    const titleEl = document.createElement("span");
    titleEl.className = "pg-chat-title";
    titleEl.textContent = chatTitle;
    titleRow.appendChild(titleEl);

    if (message.isTest) {
      const pill = document.createElement("span");
      pill.className = "pg-test-pill";
      pill.textContent = "TEST";
      titleRow.appendChild(pill);
    }

    const subtitleEl = document.createElement("div");
    subtitleEl.className = "pg-chat-subtitle";
    subtitleEl.textContent = subtitle;

    meta.appendChild(titleRow);
    meta.appendChild(subtitleEl);
    header.appendChild(meta);

    const controls = document.createElement("div");
    controls.className = "pg-controls";

    const copyAllBtn = document.createElement("button");
    copyAllBtn.type = "button";
    copyAllBtn.className = "pg-btn";
    copyAllBtn.title = "Copy full conversation";
    copyAllBtn.setAttribute("aria-label", "Copy full conversation");
    copyAllBtn.appendChild(createCopyIcon());
    copyAllBtn.addEventListener("click", (e) => {
      e.stopPropagation();
      const sourceEntries = localChatCache.get(chatKey(message)) || entries;
      const transcript = (sourceEntries || [])
        .map((item) => {
          const author = item.isOutgoing ? "You" : item.sender || chatTitle;
          const timePart = item.timestamp ? ` [${item.timestamp}]` : "";
          return `${author}${timePart}: ${item.text}`;
        })
        .join("\n");
      if (!transcript) return;
      void copyMessageToClipboard(transcript, () => {
        copyAllBtn.dataset.active = "copied";
        copyAllBtn.replaceChildren(createCheckIcon());
        setTimeout(() => {
          delete copyAllBtn.dataset.active;
          copyAllBtn.replaceChildren(createCopyIcon());
        }, 1200);
      });
    });
    if (entries.length > 0) {
      controls.appendChild(copyAllBtn);
    }

    const openBtn = document.createElement("button");
    openBtn.type = "button";
    openBtn.className = "pg-btn";
    openBtn.title = "Open in WhatsApp";
    openBtn.setAttribute("aria-label", "Open in WhatsApp");
    openBtn.appendChild(createOpenIcon());
    openBtn.addEventListener("click", (e) => {
      e.stopPropagation();
      triggerOpenWhatsApp(message);
    });
    controls.appendChild(openBtn);

    const refreshBtn = document.createElement("button");
    refreshBtn.type = "button";
    refreshBtn.className = "pg-btn";
    refreshBtn.title = "Refresh messages";
    refreshBtn.setAttribute("aria-label", "Refresh messages");
    refreshBtn.appendChild(
      createSvgIcon([
        {
          tag: "path",
          attrs: {
            d: "M12.5 8a4.5 4.5 0 1 1-1.2-3.05M12.5 2.5v2.7H9.8",
            stroke: "currentColor",
            "stroke-width": "1.35",
            "stroke-linecap": "round",
            "stroke-linejoin": "round",
          },
        },
      ])
    );
    refreshBtn.addEventListener("click", (e) => {
      e.stopPropagation();
      void openChatPopup(message);
    });
    controls.appendChild(refreshBtn);

    const closeBtn = document.createElement("button");
    closeBtn.type = "button";
    closeBtn.className = "pg-btn";
    closeBtn.title = "Close chat popup";
    closeBtn.setAttribute("aria-label", "Close chat popup");
    closeBtn.appendChild(createCloseIcon());
    closeBtn.addEventListener("click", (e) => {
      e.stopPropagation();
      closeChatPopup();
    });
    controls.appendChild(closeBtn);

    header.appendChild(controls);
    popup.appendChild(header);

    // Message List
    const body = document.createElement("div");
    body.className = "pg-chat-messages";

    function renderBubbles(bubbleList) {
      body.replaceChildren();
      if (!bubbleList || bubbleList.length === 0) {
        const empty = document.createElement("div");
        empty.className = "pg-chat-empty";
        empty.textContent = "No accessible messages captured for this chat yet.";
        body.appendChild(empty);
        return;
      }
      for (const entry of bubbleList) {
        const bRow = document.createElement("div");
        bRow.className = entry.isOutgoing ? "pg-bubble-row pg-outgoing" : "pg-bubble-row";

        const bubble = document.createElement("div");
        bubble.className = "pg-bubble";

        if (!entry.isOutgoing && entry.sender && entry.sender !== chatTitle) {
          const senderTag = document.createElement("span");
          senderTag.className = "pg-bubble-sender";
          senderTag.textContent = entry.sender;
          bubble.appendChild(senderTag);
        }

        const msgText = document.createElement("p");
        msgText.className = "pg-bubble-text";
        msgText.textContent = entry.text;
        bubble.appendChild(msgText);

        const bMeta = document.createElement("div");
        bMeta.className = "pg-bubble-meta";

        const timeSpan = document.createElement("span");
        timeSpan.className = "pg-bubble-time";
        timeSpan.textContent = entry.timestamp || "";
        bMeta.appendChild(timeSpan);

        const copyBubbleBtn = document.createElement("button");
        copyBubbleBtn.type = "button";
        copyBubbleBtn.className = "pg-bubble-copy";
        copyBubbleBtn.textContent = "Copy";
        copyBubbleBtn.addEventListener("click", (e) => {
          e.stopPropagation();
          void copyMessageToClipboard(entry.text, () => {
            copyBubbleBtn.textContent = "Copied ✓";
            copyBubbleBtn.dataset.copied = "true";
            setTimeout(() => {
              copyBubbleBtn.textContent = "Copy";
              delete copyBubbleBtn.dataset.copied;
            }, 1200);
          });
        });
        bMeta.appendChild(copyBubbleBtn);

        bubble.appendChild(bMeta);
        bRow.appendChild(bubble);
        body.appendChild(bRow);
      }

      if (!message.isTest && bubbleList.length <= 1) {
        const syncBtn = document.createElement("button");
        syncBtn.type = "button";
        syncBtn.className = "pg-open-history-btn";
        syncBtn.textContent = "Open in WhatsApp to sync full chat";
        syncBtn.addEventListener("click", (e) => {
          e.stopPropagation();
          triggerOpenWhatsApp(message);
        });
        body.appendChild(syncBtn);
      }

      body.scrollTop = body.scrollHeight;
    }

    renderBubbles(entries);
    popup.appendChild(body);

    // Reply Composer Footer
    const footer = document.createElement("footer");
    footer.className = "pg-chat-footer";

    const quickRow = document.createElement("div");
    quickRow.className = "pg-quick-replies";
    const quickChips = ["👍", "Ok", "On my way", "Call soon"];
    const chipButtons = [];

    const replyRow = document.createElement("div");
    replyRow.className = "pg-reply-row";

    const replyInput = document.createElement("textarea");
    replyInput.rows = 1;
    replyInput.className = "pg-reply-input";
    replyInput.placeholder = `Reply to ${chatTitle}…`;
    replyInput.setAttribute("aria-label", `Reply to ${chatTitle}`);

    const sendBtn = document.createElement("button");
    sendBtn.type = "button";
    sendBtn.className = "pg-reply-send";
    sendBtn.disabled = true;
    sendBtn.title = "Send reply via WhatsApp Desktop";
    sendBtn.setAttribute("aria-label", "Send reply");
    sendBtn.appendChild(
      createSvgIcon([
        {
          tag: "path",
          attrs: {
            d: "M13.5 2.5 6.8 9.2M13.5 2.5 9.6 13.5l-2.8-4.3L2.5 6.4 13.5 2.5Z",
            stroke: "currentColor",
            "stroke-width": "1.35",
            "stroke-linecap": "round",
            "stroke-linejoin": "round",
          },
        },
      ])
    );

    const statusLine = document.createElement("span");
    statusLine.className = "pg-reply-status";
    statusLine.textContent = "Local-only · Enter to reply via WhatsApp";

    let isSending = false;
    async function sendReplyText(rawText, { clearInput = false } = {}) {
      const text = String(rawText || "").trim();
      if (!text || isSending) return;
      isSending = true;
      replyInput.disabled = true;
      sendBtn.disabled = true;
      for (const chipBtn of chipButtons) chipBtn.disabled = true;
      statusLine.textContent = "Sending via WhatsApp Desktop…";
      delete statusLine.dataset.tone;

      const res = await safeSendBackgroundMessage({
        type: "content_send_reply",
        message,
        replyText: text,
      });

      isSending = false;
      replyInput.disabled = false;
      for (const chipBtn of chipButtons) chipBtn.disabled = false;
      if (res?.ok) {
        if (clearInput) {
          replyInput.value = "";
          replyInput.style.height = "auto";
        }
        sendBtn.disabled = !replyInput.value.trim();
        if (Array.isArray(res.entries) && res.entries.length > 0) {
          localChatCache.set(chatKey(message), res.entries);
          renderBubbles(res.entries);
          subtitleEl.textContent = `${
            message.sender && message.chatName && message.sender !== message.chatName
              ? message.sender
              : "Session Chat"
          } · ${res.entries.length} msg${res.entries.length === 1 ? "" : "s"}`;
        }
        statusLine.textContent = "Sent ✓";
        statusLine.dataset.tone = "ok";
        setTimeout(() => {
          if (statusLine.textContent === "Sent ✓") {
            statusLine.textContent = "Local-only · Enter to reply via WhatsApp";
            delete statusLine.dataset.tone;
          }
        }, 2000);
      } else {
        sendBtn.disabled = !replyInput.value.trim();
        statusLine.textContent = res?.error || "Could not send reply through WhatsApp.";
        statusLine.dataset.tone = "error";
      }
    }

    async function submitReply() {
      await sendReplyText(replyInput.value, { clearInput: true });
    }

    for (const chipLabel of quickChips) {
      const chipBtn = document.createElement("button");
      chipBtn.type = "button";
      chipBtn.className = "pg-quick-chip";
      chipBtn.textContent = chipLabel;
      chipBtn.addEventListener("click", (e) => {
        e.stopPropagation();
        void sendReplyText(chipLabel, { clearInput: false });
      });
      chipButtons.push(chipBtn);
      quickRow.appendChild(chipBtn);
    }

    replyInput.addEventListener("input", () => {
      replyInput.style.height = "auto";
      replyInput.style.height = `${Math.min(68, replyInput.scrollHeight)}px`;
      sendBtn.disabled = isSending || !replyInput.value.trim();
    });
    replyInput.addEventListener("keydown", (e) => {
      e.stopPropagation();
      if (e.key === "Enter" && !e.shiftKey) {
        e.preventDefault();
        void submitReply();
      }
    });
    replyInput.addEventListener("click", (e) => e.stopPropagation());
    sendBtn.addEventListener("click", (e) => {
      e.stopPropagation();
      void submitReply();
    });

    replyRow.appendChild(replyInput);
    replyRow.appendChild(sendBtn);
    footer.appendChild(quickRow);
    footer.appendChild(replyRow);
    footer.appendChild(statusLine);
    popup.appendChild(footer);

    chatPopupEl = popup;
    positionChatPopupElement(popup);
    shadowRoot.appendChild(popup);
    body.scrollTop = body.scrollHeight;
    setTimeout(() => {
      replyInput.focus();
    }, 30);
  }

  /* -------------------------------------------------------------------------- */
  /* Clipboard Helper                                                           */
  /* -------------------------------------------------------------------------- */

  async function copyMessageToClipboard(text, onSuccess) {
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

    if (copied && typeof onSuccess === "function") {
      onSuccess();
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
      return;
    }

    record.startedAt = Date.now();
    record.timerId = setTimeout(() => {
      dismissCard(record.id, { notifyBackground: false });
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

  function dismissCard(id, { notifyBackground = false } = {}) {
    const record = activeCards.get(id);
    if (!record || record.exiting) {
      return;
    }

    record.exiting = true;
    if (record.timerId !== null) {
      clearTimeout(record.timerId);
      record.timerId = null;
    }

    if (notifyBackground && record.message) {
      void safeSendBackgroundMessage({
        type: "content_dismiss_notification",
        message: record.message,
      });
    }

    const finalizeRemoval = () => {
      if (record.element.parentNode) {
        record.element.parentNode.removeChild(record.element);
      }
      activeCards.delete(id);
      drainQueue();
      updateClearAllBar();
      if (chatPopupEl) {
        positionChatPopupElement(chatPopupEl);
      }
    };

    const animationsOn = stackContainer?.dataset.animations === "on";
    if (!animationsOn) {
      finalizeRemoval();
      return;
    }

    record.element.classList.remove("pg-entering");
    record.element.classList.add("pg-exiting");
    record.element.addEventListener("animationend", finalizeRemoval, { once: true });
    setTimeout(finalizeRemoval, 340);
  }

  async function enqueueNotification(message, cssText = null, chatHistory = null) {
    await ensureOverlayMounted(cssText);
    recordLocalChat(message);
    if (Array.isArray(chatHistory) && chatHistory.length > 0) {
      localChatCache.set(chatKey(message), chatHistory);
    }

    if (activeChatMessage && chatKey(activeChatMessage) === chatKey(message)) {
      renderChatPopup(activeChatMessage, localChatCache.get(chatKey(message)) || []);
    }

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
      message,
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
    if (chatPopupEl) {
      positionChatPopupElement(chatPopupEl);
    }
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
          void ensureOverlayMounted(msg.cssText || null).then(() => sendResponse({ ok: true }));
          return true;

        case "pingglass_settings":
          if (msg.settings) {
            settings = { ...settings, ...msg.settings };
            if (msg.cssText && styleEl) {
              styleEl.textContent = msg.cssText;
              stylesLoaded = true;
            }
            applyContainerSettings();
          }
          sendResponse({ ok: true });
          return false;

        case "pingglass_notify":
          if (msg.settings) {
            settings = { ...settings, ...msg.settings };
          }
          if (msg.message) {
            void enqueueNotification(msg.message, msg.cssText || null, msg.chatHistory || null).then(() =>
              sendResponse({ ok: true })
            );
            return true;
          }
          sendResponse({ ok: false });
          return false;

        case "pingglass_dismiss":
          if (msg.id) {
            dismissCard(msg.id, { notifyBackground: false });
          }
          sendResponse({ ok: true });
          return false;

        case "pingglass_cleanup":
          cleanupOverlay();
          sendResponse({ ok: true });
          return false;

        case "pingglass_clear_all":
          clearAllNotifications({ notifyBackground: false });
          sendResponse({ ok: true });
          return false;

        case "pingglass_chat_updated":
          if (msg.message && Array.isArray(msg.chatHistory)) {
            localChatCache.set(chatKey(msg.message), msg.chatHistory);
            if (activeChatMessage && chatKey(activeChatMessage) === chatKey(msg.message)) {
              renderChatPopup(activeChatMessage, msg.chatHistory);
            }
          }
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
