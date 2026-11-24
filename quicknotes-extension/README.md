# QuickNotes

A lightweight, fast, offline-first Chrome Extension (Manifest V3) for writing, searching, copying, and managing notes directly from your browser toolbar popup.

## Features

- **Notes Dashboard**: View saved notes ordered by most recently updated, with titles, short previews, timestamps, and a friendly empty state.
- **Instant Capture**: Click **New Note** to open the editor with automatic focus on the note content area. Prevents saving completely empty notes.
- **Debounced Auto-Save**: Automatically persists changes to `chrome.storage.local` with a 400ms debounce, a live `Saving...` / `Saved` status pill, and flush-on-close protection.
- **Edit & Navigate**: Click any note card to edit its title or content, and click **Back** to return to the dashboard.
- **Safe Deletion**: Delete notes from the dashboard card or editor toolbar with an in-popup confirmation dialog.
- **One-Click Copy**: Copy the complete note text to your clipboard with a `"Copied to clipboard"` toast notification.
- **Real-Time Search**: Filter notes instantly by title or content, with a clear button and a `"No matching notes"` state.
- **Character Counter**: Live character count displayed in the editor footer.
- **100% Offline & Private**: No login, no backend, no external APIs, and no CDN dependencies.

## Project Structure

```text
quicknotes-extension/
├── manifest.json
├── popup.html
├── popup.css
├── popup.js
├── icons/
│   ├── icon16.png
│   ├── icon48.png
│   └── icon128.png
└── README.md
```

## Tech Stack

- HTML5
- CSS3
- Vanilla JavaScript
- Chrome Extension Manifest V3
- Chrome Storage API (`chrome.storage.local`)

## Installation (Load Unpacked in Chrome)

1. Open Google Chrome and navigate to `chrome://extensions`.
2. Enable **Developer mode** using the toggle switch in the top-right corner.
3. Click **Load unpacked**.
4. Select the `quicknotes-extension` folder.
5. *(Optional)* Click the puzzle-piece **Extensions** icon in the Chrome toolbar and pin **QuickNotes** for one-click access.

## Testing All Features

1. **Empty State & New Note**:
   - Open the **QuickNotes** popup. Verify the empty state (`"No notes yet"`) appears when no notes exist.
   - Click **New Note** (or **Create your first note**). Confirm the editor opens and the content textarea is focused automatically.
   - Leave both title and content empty and click **Back** — confirm no empty note is saved.

2. **Auto-Save & Persistence**:
   - Click **New Note**, type a title and body text.
   - Observe the status indicator switch from `Saving...` to `Saved` shortly after you pause typing.
   - Close the popup (or completely quit and reopen Chrome), then reopen **QuickNotes** — verify the note persists.

3. **Character Counter**:
   - Inside the editor, type or delete characters in the note content area and confirm the character counter in the bottom-right updates in real time.

4. **Edit Notes & Back Navigation**:
   - Click an existing note card on the dashboard to open edit mode.
   - Modify the title or content, wait for `Saved` (or click **Back** immediately), and verify the updated text and timestamp appear at the top of the dashboard list.

5. **Search**:
   - Create 2–3 notes with distinct titles and contents.
   - Type a matching word into the search bar and verify results filter instantly.
   - Type a non-matching term (e.g., `zzzznotfound`) and confirm `"No matching notes"` is displayed.
   - Click the clear (`×`) button or **Clear search** to restore the full list.

6. **Copy to Clipboard**:
   - Click the copy icon on a note card (or inside the editor).
   - Confirm the `"Copied to clipboard"` toast appears and paste (`Ctrl+V` / `Cmd+V`) into any text field to verify the full note text was copied.

7. **Delete Confirmation**:
   - Click the delete (trash) icon on a note card or inside the editor.
   - Click **Cancel** (or press `Escape`) in the confirmation dialog to verify the note is kept.
   - Click the delete icon again and click **Delete** — verify the note disappears immediately and `"Note deleted"` toast is shown.
