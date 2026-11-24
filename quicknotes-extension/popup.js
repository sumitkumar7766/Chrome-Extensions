/**
 * QuickNotes - Chrome Extension (Manifest V3)
 * Offline notes manager backed by chrome.storage.local.
 */

(() => {
  "use strict";

  const STORAGE_KEY = "quicknotes_items";
  const AUTOSAVE_DELAY_MS = 400;
  const TOAST_DURATION_MS = 2200;

  /**
   * Central in-memory state synchronized with chrome.storage.local.
   */
  const state = {
    notes: [],
    view: "dashboard", // "dashboard" | "editor"
    activeNoteId: null,
    searchQuery: "",
    pendingDelete: null, // { id: string | null, isDraft: boolean }
    saveTimerId: null,
    toastTimerId: null,
    writeQueue: Promise.resolve(),
    lastFocusedBeforeModal: null,
  };

  /**
   * Cached DOM element references.
   */
  const elements = {
    dashboardView: document.getElementById("dashboard-view"),
    editorView: document.getElementById("editor-view"),
    notesCount: document.getElementById("notes-count"),
    newNoteBtn: document.getElementById("new-note-btn"),
    emptyNewNoteBtn: document.getElementById("empty-new-note-btn"),
    searchInput: document.getElementById("search-input"),
    clearSearchBtn: document.getElementById("clear-search-btn"),
    resetSearchBtn: document.getElementById("reset-search-btn"),
    notesList: document.getElementById("notes-list"),
    emptyState: document.getElementById("empty-state"),
    noResultsState: document.getElementById("no-results-state"),
    noteCardTemplate: document.getElementById("note-card-template"),

    backBtn: document.getElementById("back-btn"),
    saveStatus: document.getElementById("save-status"),
    saveStatusText: document.getElementById("save-status-text"),
    editorCopyBtn: document.getElementById("editor-copy-btn"),
    editorDeleteBtn: document.getElementById("editor-delete-btn"),
    titleInput: document.getElementById("note-title-input"),
    contentInput: document.getElementById("note-content-input"),
    editorUpdatedAt: document.getElementById("editor-updated-at"),
    charCount: document.getElementById("char-count"),

    deleteModal: document.getElementById("delete-modal"),
    deleteModalDesc: document.getElementById("delete-modal-desc"),
    cancelDeleteBtn: document.getElementById("cancel-delete-btn"),
    confirmDeleteBtn: document.getElementById("confirm-delete-btn"),

    toast: document.getElementById("toast"),
    toastMessage: document.getElementById("toast-message"),
  };

  /* -------------------------------------------------------------------------- */
  /* Storage Helpers                                                            */
  /* -------------------------------------------------------------------------- */

  /**
   * Validate and normalize notes read from storage so unexpected values never break the UI.
   * @param {unknown} rawNotes
   * @returns {Array<{id: string, title: string, content: string, createdAt: number, updatedAt: number}>}
   */
  function sanitizeStoredNotes(rawNotes) {
    if (!Array.isArray(rawNotes)) {
      return [];
    }

    const validNotes = [];
    for (const item of rawNotes) {
      if (!item || typeof item !== "object") {
        continue;
      }

      const id = typeof item.id === "string" && item.id.trim() ? item.id : "";
      const title = typeof item.title === "string" ? item.title : "";
      const content = typeof item.content === "string" ? item.content : "";

      if (!id || isNoteEmpty(title, content)) {
        continue;
      }

      const createdAt =
        typeof item.createdAt === "number" && Number.isFinite(item.createdAt)
          ? item.createdAt
          : Date.now();
      const updatedAt =
        typeof item.updatedAt === "number" && Number.isFinite(item.updatedAt)
          ? item.updatedAt
          : createdAt;

      validNotes.push({ id, title, content, createdAt, updatedAt });
    }

    return sortNotesByUpdated(validNotes);
  }

  /**
   * Load notes from chrome.storage.local with error handling.
   * @returns {Promise<Array>}
   */
  async function loadNotesFromStorage() {
    if (typeof chrome === "undefined" || !chrome.storage || !chrome.storage.local) {
      throw new Error("Chrome Storage API is unavailable.");
    }

    const result = await chrome.storage.local.get(STORAGE_KEY);
    if (chrome.runtime && chrome.runtime.lastError) {
      throw new Error(chrome.runtime.lastError.message);
    }

    return sanitizeStoredNotes(result ? result[STORAGE_KEY] : []);
  }

  /**
   * Persist the notes snapshot sequentially to prevent out-of-order overwrites.
   * @param {Array} notesSnapshot
   * @returns {Promise<{ok: boolean, error?: Error}>}
   */
  function persistNotesToStorage(notesSnapshot) {
    const task = async () => {
      if (typeof chrome === "undefined" || !chrome.storage || !chrome.storage.local) {
        throw new Error("Chrome Storage API is unavailable.");
      }

      await chrome.storage.local.set({ [STORAGE_KEY]: notesSnapshot });
      if (chrome.runtime && chrome.runtime.lastError) {
        throw new Error(chrome.runtime.lastError.message);
      }
      return { ok: true };
    };

    // Chain onto writeQueue so later saves always resolve after earlier ones.
    const queued = state.writeQueue.then(task, task);
    state.writeQueue = queued.catch(() => {});

    return queued.catch((error) => {
      console.error("QuickNotes storage error:", error);
      return { ok: false, error };
    });
  }

  /* -------------------------------------------------------------------------- */
  /* Domain & Formatting Helpers                                                */
  /* -------------------------------------------------------------------------- */

  /**
   * Generate a unique note identifier.
   * @returns {string}
   */
  function generateNoteId() {
    if (typeof crypto !== "undefined" && typeof crypto.randomUUID === "function") {
      return crypto.randomUUID();
    }
    return `note-${Date.now().toString(36)}-${Math.random().toString(36).slice(2, 10)}`;
  }

  /**
   * Check whether both title and content contain only whitespace or are empty.
   * @param {string} title
   * @param {string} content
   * @returns {boolean}
   */
  function isNoteEmpty(title, content) {
    return title.trim().length === 0 && content.trim().length === 0;
  }

  /**
   * Return a new array sorted by most recently updated note first.
   * @param {Array} notes
   * @returns {Array}
   */
  function sortNotesByUpdated(notes) {
    return [...notes].sort((a, b) => b.updatedAt - a.updatedAt);
  }

  /**
   * Filter notes case-insensitively by title or content.
   * @param {Array} notes
   * @param {string} query
   * @returns {Array}
   */
  function filterNotes(notes, query) {
    const normalized = query.trim().toLowerCase();
    if (!normalized) {
      return notes;
    }

    return notes.filter((note) => {
      return (
        note.title.toLowerCase().includes(normalized) ||
        note.content.toLowerCase().includes(normalized)
      );
    });
  }

  /**
   * Find a note in state by ID.
   * @param {string | null} noteId
   */
  function findNoteById(noteId) {
    if (!noteId) {
      return null;
    }
    return state.notes.find((note) => note.id === noteId) || null;
  }

  /**
   * Format a timestamp into a compact, readable label for note cards.
   * @param {number} timestamp
   * @returns {string}
   */
  function formatCardDate(timestamp) {
    const date = new Date(timestamp);
    if (Number.isNaN(date.getTime())) {
      return "";
    }

    const now = new Date();
    const diffMs = now.getTime() - date.getTime();
    const diffMinutes = Math.floor(diffMs / 60000);

    if (diffMs >= 0 && diffMinutes < 1) {
      return "Just now";
    }
    if (diffMs >= 0 && diffMinutes < 60) {
      return `${diffMinutes}m ago`;
    }

    const sameDay =
      date.getFullYear() === now.getFullYear() &&
      date.getMonth() === now.getMonth() &&
      date.getDate() === now.getDate();

    if (sameDay) {
      return new Intl.DateTimeFormat(undefined, {
        hour: "numeric",
        minute: "2-digit",
      }).format(date);
    }

    const sameYear = date.getFullYear() === now.getFullYear();
    return new Intl.DateTimeFormat(undefined, {
      month: "short",
      day: "numeric",
      ...(sameYear ? {} : { year: "numeric" }),
    }).format(date);
  }

  /**
   * Format a full date/time string for tooltips and editor metadata.
   * @param {number} timestamp
   * @returns {string}
   */
  function formatFullDate(timestamp) {
    const date = new Date(timestamp);
    if (Number.isNaN(date.getTime())) {
      return "";
    }

    return new Intl.DateTimeFormat(undefined, {
      month: "short",
      day: "numeric",
      year: "numeric",
      hour: "numeric",
      minute: "2-digit",
    }).format(date);
  }

  /**
   * Combine title and content cleanly when copying a complete note.
   * @param {string} title
   * @param {string} content
   * @returns {string}
   */
  function formatNoteForClipboard(title, content) {
    const trimmedTitle = title.trim();
    const hasContent = content.trim().length > 0;

    if (trimmedTitle && hasContent) {
      return `${trimmedTitle}\n\n${content}`;
    }
    if (trimmedTitle) {
      return trimmedTitle;
    }
    if (hasContent) {
      return content;
    }
    return "";
  }

  /**
   * Truncate long titles cleanly for confirmation dialog text.
   * @param {string} text
   * @param {number} maxLength
   * @returns {string}
   */
  function truncateLabel(text, maxLength = 42) {
    const trimmed = text.trim();
    if (trimmed.length <= maxLength) {
      return trimmed;
    }
    return `${trimmed.slice(0, maxLength - 1)}…`;
  }

  /* -------------------------------------------------------------------------- */
  /* Safe DOM Rendering                                                         */
  /* -------------------------------------------------------------------------- */

  /**
   * Build a note card DOM element using the static <template> and textContent only.
   * @param {{id: string, title: string, content: string, createdAt: number, updatedAt: number}} note
   * @returns {HTMLElement}
   */
  function createNoteCardElement(note) {
    const fragment = elements.noteCardTemplate.content.cloneNode(true);
    const card = fragment.querySelector(".note-card");
    const titleEl = fragment.querySelector(".note-card-title");
    const previewEl = fragment.querySelector(".note-card-preview");
    const dateEl = fragment.querySelector(".note-card-date");
    const copyBtn = fragment.querySelector(".btn-copy");
    const deleteBtn = fragment.querySelector(".btn-delete");

    card.dataset.noteId = note.id;

    const trimmedTitle = note.title.trim();
    if (trimmedTitle) {
      titleEl.textContent = trimmedTitle;
      titleEl.classList.remove("is-untitled");
    } else {
      titleEl.textContent = "Untitled note";
      titleEl.classList.add("is-untitled");
    }

    const normalizedPreview = note.content.replace(/\s+/g, " ").trim();
    if (normalizedPreview) {
      previewEl.textContent = normalizedPreview;
      previewEl.classList.remove("is-empty");
    } else {
      previewEl.textContent = "No additional text";
      previewEl.classList.add("is-empty");
    }

    const displayDate = formatCardDate(note.updatedAt);
    dateEl.textContent = displayDate;
    dateEl.setAttribute("datetime", new Date(note.updatedAt).toISOString());
    dateEl.title = `Created ${formatFullDate(note.createdAt)} · Updated ${formatFullDate(note.updatedAt)}`;

    const accessibleTitle = trimmedTitle || "Untitled note";
    card.setAttribute("aria-label", `Open note: ${accessibleTitle}`);
    copyBtn.setAttribute("aria-label", `Copy note: ${accessibleTitle}`);
    deleteBtn.setAttribute("aria-label", `Delete note: ${accessibleTitle}`);

    return card;
  }

  /**
   * Render the dashboard list, note count badge, and empty/no-results states.
   */
  function renderDashboard() {
    const totalCount = state.notes.length;
    elements.notesCount.textContent = String(totalCount);
    elements.notesCount.setAttribute(
      "aria-label",
      `${totalCount} saved ${totalCount === 1 ? "note" : "notes"}`
    );

    const hasSearch = state.searchQuery.trim().length > 0;
    elements.clearSearchBtn.hidden = state.searchQuery.length === 0;

    if (totalCount === 0) {
      elements.notesList.replaceChildren();
      elements.emptyState.hidden = false;
      elements.noResultsState.hidden = true;
      return;
    }

    const filtered = filterNotes(state.notes, state.searchQuery);
    if (filtered.length === 0 && hasSearch) {
      elements.notesList.replaceChildren();
      elements.emptyState.hidden = true;
      elements.noResultsState.hidden = false;
      return;
    }

    elements.emptyState.hidden = true;
    elements.noResultsState.hidden = true;

    const listFragment = document.createDocumentFragment();
    for (const note of filtered) {
      listFragment.appendChild(createNoteCardElement(note));
    }
    elements.notesList.replaceChildren(listFragment);
  }

  /**
   * Update the real-time character counter in the editor footer.
   * @param {string} content
   */
  function updateCharacterCount(content) {
    const count = content.length;
    const label = count === 1 ? "character" : "characters";
    elements.charCount.textContent = `${count.toLocaleString()} ${label}`;
  }

  /**
   * Update the editor auto-save status pill.
   * @param {"ready" | "saving" | "saved" | "empty" | "error"} statusState
   * @param {string} text
   */
  function updateSaveStatus(statusState, text) {
    elements.saveStatus.dataset.state = statusState;
    elements.saveStatusText.textContent = text;
  }

  /**
   * Refresh enabled/disabled state for editor Copy and Delete buttons.
   */
  function updateEditorActionButtons() {
    const title = elements.titleInput.value;
    const content = elements.contentInput.value;
    const empty = isNoteEmpty(title, content);

    elements.editorCopyBtn.disabled = empty;
    elements.editorDeleteBtn.disabled = state.activeNoteId === null && empty;
  }

  /**
   * Display a temporary toast notification message.
   * @param {string} message
   * @param {"info" | "error"} [type="info"]
   */
  function showToast(message, type = "info") {
    if (state.toastTimerId !== null) {
      clearTimeout(state.toastTimerId);
      state.toastTimerId = null;
    }

    elements.toastMessage.textContent = message;
    elements.toast.dataset.type = type;
    elements.toast.hidden = false;

    // Force layout before adding visibility class for smooth CSS transition.
    void elements.toast.offsetWidth;
    elements.toast.classList.add("is-visible");

    state.toastTimerId = setTimeout(() => {
      elements.toast.classList.remove("is-visible");
      state.toastTimerId = setTimeout(() => {
        elements.toast.hidden = true;
        state.toastTimerId = null;
      }, 160);
    }, TOAST_DURATION_MS);
  }

  /* -------------------------------------------------------------------------- */
  /* View Switching & Auto-Save Lifecycle                                       */
  /* -------------------------------------------------------------------------- */

  /**
   * Cancel any pending debounced auto-save timer.
   */
  function clearPendingSaveTimer() {
    if (state.saveTimerId !== null) {
      clearTimeout(state.saveTimerId);
      state.saveTimerId = null;
    }
  }

  /**
   * Switch to dashboard view and re-render notes.
   */
  function showDashboardView() {
    state.view = "dashboard";
    state.activeNoteId = null;
    elements.editorView.hidden = true;
    elements.dashboardView.hidden = false;
    renderDashboard();
  }

  /**
   * Open the note editor in "new note" mode and focus content input automatically.
   */
  function openNewNoteEditor() {
    clearPendingSaveTimer();
    state.view = "editor";
    state.activeNoteId = null;

    elements.titleInput.value = "";
    elements.contentInput.value = "";
    elements.editorUpdatedAt.textContent = "New note";
    updateCharacterCount("");
    updateSaveStatus("ready", "Ready");
    updateEditorActionButtons();

    elements.dashboardView.hidden = true;
    elements.editorView.hidden = false;
    elements.contentInput.focus();
  }

  /**
   * Open an existing note in edit mode.
   * @param {string} noteId
   */
  function openEditNoteEditor(noteId) {
    const note = findNoteById(noteId);
    if (!note) {
      showToast("Note could not be found.", "error");
      return;
    }

    clearPendingSaveTimer();
    state.view = "editor";
    state.activeNoteId = note.id;

    elements.titleInput.value = note.title;
    elements.contentInput.value = note.content;
    elements.editorUpdatedAt.textContent = `Updated ${formatFullDate(note.updatedAt)}`;
    updateCharacterCount(note.content);
    updateSaveStatus("saved", "Saved");
    updateEditorActionButtons();

    elements.dashboardView.hidden = true;
    elements.editorView.hidden = false;
    elements.contentInput.scrollTop = 0;
    elements.contentInput.focus();
  }

  /**
   * Apply current editor input values to in-memory state if valid and changed.
   * Returns true if in-memory notes were updated and need persistence.
   * @returns {{changed: boolean, noteId: string | null, snapshotTitle: string, snapshotContent: string}}
   */
  function applyEditorChangesToState() {
    const snapshotTitle = elements.titleInput.value;
    const snapshotContent = elements.contentInput.value;

    if (isNoteEmpty(snapshotTitle, snapshotContent)) {
      return {
        changed: false,
        noteId: state.activeNoteId,
        snapshotTitle,
        snapshotContent,
      };
    }

    const now = Date.now();

    if (state.activeNoteId === null) {
      const newNote = {
        id: generateNoteId(),
        title: snapshotTitle,
        content: snapshotContent,
        createdAt: now,
        updatedAt: now,
      };
      state.activeNoteId = newNote.id;
      state.notes = sortNotesByUpdated([newNote, ...state.notes]);
      return {
        changed: true,
        noteId: newNote.id,
        snapshotTitle,
        snapshotContent,
      };
    }

    const existing = findNoteById(state.activeNoteId);
    if (!existing) {
      return {
        changed: false,
        noteId: state.activeNoteId,
        snapshotTitle,
        snapshotContent,
      };
    }

    if (existing.title === snapshotTitle && existing.content === snapshotContent) {
      return {
        changed: false,
        noteId: existing.id,
        snapshotTitle,
        snapshotContent,
      };
    }

    const updatedNotes = state.notes.map((note) =>
      note.id === existing.id
        ? { ...note, title: snapshotTitle, content: snapshotContent, updatedAt: now }
        : note
    );
    state.notes = sortNotesByUpdated(updatedNotes);

    return {
      changed: true,
      noteId: existing.id,
      snapshotTitle,
      snapshotContent,
    };
  }

  /**
   * Commit current editor inputs to chrome.storage.local.
   * @returns {Promise<boolean>}
   */
  async function commitEditorSave() {
    clearPendingSaveTimer();

    const { changed, noteId, snapshotTitle, snapshotContent } = applyEditorChangesToState();

    if (isNoteEmpty(snapshotTitle, snapshotContent)) {
      if (state.activeNoteId !== null) {
        updateSaveStatus("empty", "Empty note not saved");
      } else {
        updateSaveStatus("ready", "Ready");
      }
      return true;
    }

    if (!changed) {
      updateSaveStatus("saved", "Saved");
      return true;
    }

    updateSaveStatus("saving", "Saving...");
    const result = await persistNotesToStorage([...state.notes]);

    if (!result.ok) {
      updateSaveStatus("error", "Save failed");
      showToast("Could not save note. Check storage availability.", "error");
      return false;
    }

    // Only update UI status to Saved if the editor still reflects this saved note/content.
    if (state.view === "editor" && state.activeNoteId === noteId) {
      const savedNote = findNoteById(noteId);
      if (savedNote) {
        elements.editorUpdatedAt.textContent = `Updated ${formatFullDate(savedNote.updatedAt)}`;
      }
      updateEditorActionButtons();

      const stillMatches =
        elements.titleInput.value === snapshotTitle &&
        elements.contentInput.value === snapshotContent;
      if (stillMatches) {
        updateSaveStatus("saved", "Saved");
      }
    }

    return true;
  }

  /**
   * Handle real-time typing inside the title or content inputs.
   */
  function handleEditorInput() {
    const title = elements.titleInput.value;
    const content = elements.contentInput.value;

    updateCharacterCount(content);
    updateEditorActionButtons();

    if (isNoteEmpty(title, content)) {
      clearPendingSaveTimer();
      if (state.activeNoteId !== null) {
        updateSaveStatus("empty", "Empty note not saved");
      } else {
        updateSaveStatus("ready", "Ready");
      }
      return;
    }

    const existing = findNoteById(state.activeNoteId);
    if (existing && existing.title === title && existing.content === content) {
      clearPendingSaveTimer();
      updateSaveStatus("saved", "Saved");
      return;
    }

    updateSaveStatus("saving", "Saving...");
    clearPendingSaveTimer();
    state.saveTimerId = setTimeout(() => {
      state.saveTimerId = null;
      void commitEditorSave();
    }, AUTOSAVE_DELAY_MS);
  }

  /**
   * Flush any pending debounced edits and return to the dashboard view.
   */
  async function handleBackToDashboard() {
    if (state.saveTimerId !== null) {
      await commitEditorSave();
    } else if (
      state.view === "editor" &&
      !isNoteEmpty(elements.titleInput.value, elements.contentInput.value)
    ) {
      // Ensure any unpersisted change is saved before leaving editor.
      const existing = findNoteById(state.activeNoteId);
      if (
        !existing ||
        existing.title !== elements.titleInput.value ||
        existing.content !== elements.contentInput.value
      ) {
        await commitEditorSave();
      }
    }

    await state.writeQueue;
    showDashboardView();
    elements.newNoteBtn.focus();
  }

  /**
   * Flush pending edits synchronously if the popup closes before the debounce finishes.
   */
  function flushSaveOnPopupClose() {
    if (state.view !== "editor" || state.saveTimerId === null) {
      return;
    }

    clearPendingSaveTimer();
    const { changed } = applyEditorChangesToState();
    if (!changed) {
      return;
    }

    try {
      if (typeof chrome !== "undefined" && chrome.storage && chrome.storage.local) {
        chrome.storage.local.set({ [STORAGE_KEY]: state.notes });
      }
    } catch (error) {
      console.error("QuickNotes flush-on-close error:", error);
    }
  }

  /* -------------------------------------------------------------------------- */
  /* Clipboard & Delete Confirmation                                            */
  /* -------------------------------------------------------------------------- */

  /**
   * Copy text to clipboard using the modern Clipboard API with execCommand fallback.
   * @param {string} text
   * @returns {Promise<boolean>}
   */
  async function writeTextToClipboard(text) {
    if (navigator.clipboard && typeof navigator.clipboard.writeText === "function") {
      try {
        await navigator.clipboard.writeText(text);
        return true;
      } catch (err) {
        console.warn("navigator.clipboard.writeText failed, falling back:", err);
      }
    }

    // Fallback for environments where async Clipboard API is unavailable or blocked.
    const helperTextarea = document.createElement("textarea");
    helperTextarea.value = text;
    helperTextarea.setAttribute("readonly", "");
    helperTextarea.style.position = "fixed";
    helperTextarea.style.top = "-9999px";
    helperTextarea.style.left = "-9999px";
    document.body.appendChild(helperTextarea);
    helperTextarea.select();

    let copied = false;
    try {
      copied = document.execCommand("copy");
    } catch (err) {
      console.error("Fallback clipboard copy failed:", err);
      copied = false;
    } finally {
      document.body.removeChild(helperTextarea);
    }

    return copied;
  }

  /**
   * Copy a note's full text and show feedback toast.
   * @param {string} title
   * @param {string} content
   */
  async function copyNoteContent(title, content) {
    const text = formatNoteForClipboard(title, content);
    if (!text) {
      showToast("Nothing to copy");
      return;
    }

    const ok = await writeTextToClipboard(text);
    if (ok) {
      showToast("Copied to clipboard");
    } else {
      showToast("Unable to copy note", "error");
    }
  }

  /**
   * Open the delete confirmation dialog for a saved note or unsaved non-empty draft.
   * @param {string | null} noteId
   * @param {boolean} isDraft
   */
  function openDeleteModal(noteId, isDraft = false) {
    let noteTitle = "";
    if (isDraft) {
      noteTitle = elements.titleInput.value.trim();
    } else {
      const note = findNoteById(noteId);
      if (!note) {
        return;
      }
      noteTitle = note.title.trim();
    }

    state.pendingDelete = { id: noteId, isDraft };
    state.lastFocusedBeforeModal = document.activeElement;

    if (noteTitle) {
      elements.deleteModalDesc.textContent = `Are you sure you want to delete "${truncateLabel(noteTitle)}"? This action cannot be undone.`;
    } else {
      elements.deleteModalDesc.textContent =
        "Are you sure you want to delete this note? This action cannot be undone.";
    }

    elements.deleteModal.hidden = false;
    elements.cancelDeleteBtn.focus();
  }

  /**
   * Close the delete confirmation modal and restore focus.
   */
  function closeDeleteModal() {
    elements.deleteModal.hidden = true;
    state.pendingDelete = null;

    if (
      state.lastFocusedBeforeModal &&
      typeof state.lastFocusedBeforeModal.focus === "function" &&
      document.contains(state.lastFocusedBeforeModal)
    ) {
      state.lastFocusedBeforeModal.focus();
    }
    state.lastFocusedBeforeModal = null;
  }

  /**
   * Execute deletion after user confirmation.
   */
  async function confirmDeleteNote() {
    if (!state.pendingDelete) {
      return;
    }

    const { id, isDraft } = state.pendingDelete;

    if (isDraft) {
      clearPendingSaveTimer();
      closeDeleteModal();
      showDashboardView();
      elements.newNoteBtn.focus();
      showToast("Note deleted");
      return;
    }

    const previousNotes = [...state.notes];
    const targetExists = previousNotes.some((note) => note.id === id);
    if (!targetExists) {
      closeDeleteModal();
      return;
    }

    // Cancel pending auto-save if deleting the note currently open in editor.
    if (state.view === "editor" && state.activeNoteId === id) {
      clearPendingSaveTimer();
    }

    state.notes = previousNotes.filter((note) => note.id !== id);

    const deletingFromEditor = state.view === "editor" && state.activeNoteId === id;
    closeDeleteModal();

    if (deletingFromEditor) {
      showDashboardView();
      elements.newNoteBtn.focus();
    } else if (state.view === "dashboard") {
      renderDashboard();
    }

    const result = await persistNotesToStorage([...state.notes]);
    if (!result.ok) {
      // Roll back local state if storage write fails.
      state.notes = previousNotes;
      if (state.view === "dashboard") {
        renderDashboard();
      }
      showToast("Failed to delete note", "error");
      return;
    }

    showToast("Note deleted");
  }

  /* -------------------------------------------------------------------------- */
  /* Event Binding & Initialization                                             */
  /* -------------------------------------------------------------------------- */

  function bindEvents() {
    elements.newNoteBtn.addEventListener("click", openNewNoteEditor);
    elements.emptyNewNoteBtn.addEventListener("click", openNewNoteEditor);

    elements.searchInput.addEventListener("input", (event) => {
      state.searchQuery = event.target.value;
      renderDashboard();
    });

    const clearSearch = () => {
      state.searchQuery = "";
      elements.searchInput.value = "";
      renderDashboard();
      elements.searchInput.focus();
    };

    elements.clearSearchBtn.addEventListener("click", clearSearch);
    elements.resetSearchBtn.addEventListener("click", clearSearch);

    // Event delegation for note cards (open, copy, delete).
    elements.notesList.addEventListener("click", (event) => {
      const card = event.target.closest(".note-card");
      if (!card) {
        return;
      }

      const noteId = card.dataset.noteId;
      if (!noteId) {
        return;
      }

      if (event.target.closest(".btn-copy")) {
        event.stopPropagation();
        const note = findNoteById(noteId);
        if (note) {
          void copyNoteContent(note.title, note.content);
        }
        return;
      }

      if (event.target.closest(".btn-delete")) {
        event.stopPropagation();
        openDeleteModal(noteId, false);
        return;
      }

      openEditNoteEditor(noteId);
    });

    elements.notesList.addEventListener("keydown", (event) => {
      if (event.target.classList.contains("note-card") && (event.key === "Enter" || event.key === " ")) {
        event.preventDefault();
        const noteId = event.target.dataset.noteId;
        if (noteId) {
          openEditNoteEditor(noteId);
        }
      }
    });

    elements.backBtn.addEventListener("click", () => {
      void handleBackToDashboard();
    });

    elements.titleInput.addEventListener("input", handleEditorInput);
    elements.contentInput.addEventListener("input", handleEditorInput);

    elements.editorCopyBtn.addEventListener("click", () => {
      if (state.saveTimerId !== null) {
        void commitEditorSave();
      }
      void copyNoteContent(elements.titleInput.value, elements.contentInput.value);
    });

    elements.editorDeleteBtn.addEventListener("click", () => {
      if (state.activeNoteId === null) {
        if (isNoteEmpty(elements.titleInput.value, elements.contentInput.value)) {
          return;
        }
        openDeleteModal(null, true);
        return;
      }
      openDeleteModal(state.activeNoteId, false);
    });

    elements.cancelDeleteBtn.addEventListener("click", closeDeleteModal);
    elements.confirmDeleteBtn.addEventListener("click", () => {
      void confirmDeleteNote();
    });

    elements.deleteModal.addEventListener("click", (event) => {
      if (event.target === elements.deleteModal) {
        closeDeleteModal();
      }
    });

    document.addEventListener("keydown", (event) => {
      if (elements.deleteModal.hidden) {
        return;
      }

      if (event.key === "Escape") {
        event.preventDefault();
        event.stopPropagation();
        closeDeleteModal();
        return;
      }

      // Keep keyboard focus trapped inside the confirmation dialog.
      if (event.key === "Tab") {
        const focusables = [elements.cancelDeleteBtn, elements.confirmDeleteBtn];
        const currentIndex = focusables.indexOf(document.activeElement);
        event.preventDefault();
        if (event.shiftKey) {
          const prev = currentIndex <= 0 ? focusables.length - 1 : currentIndex - 1;
          focusables[prev].focus();
        } else {
          const next = currentIndex === focusables.length - 1 ? 0 : currentIndex + 1;
          focusables[next].focus();
        }
      }
    });

    window.addEventListener("pagehide", flushSaveOnPopupClose);
    document.addEventListener("visibilitychange", () => {
      if (document.visibilityState === "hidden") {
        flushSaveOnPopupClose();
      }
    });
  }

  /**
   * Initialize extension popup on load.
   */
  async function init() {
    bindEvents();

    try {
      state.notes = await loadNotesFromStorage();
    } catch (error) {
      console.error("QuickNotes initialization error:", error);
      state.notes = [];
      showToast("Could not load saved notes", "error");
    }

    renderDashboard();
  }

  document.addEventListener("DOMContentLoaded", () => {
    void init();
  });
})();
