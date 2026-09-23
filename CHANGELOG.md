# Changelog

Every release of MD Lite. The newest is at the top; each one is also on [GitHub](https://github.com/glozahn/md-lite/releases).

## 0.3.5 — 2026-09-23

MD Lite now keeps itself up to date, tabs can leave the window, and the changelog lives inside the app.

### Updates install themselves

MD Lite checks GitHub Releases, downloads the disk image in the background, and installs it after three checks: the download matches its published SHA-256, it is signed by the same developer as the copy you are running, and Gatekeeper confirms Apple notarized it. A quiet button in the footer restarts into the new version and reopens your documents; ignore it and the update lands when you quit. Settings has a switch to turn it off.

### A tab can become a window

**⌃⌘N** (or *Move to New Window* in a tab's menu) moves the tab into its own window, keeping its undo history and reading position. *Keep on Top* in the Window menu leaves a window floating above your other apps while you read.

### What's New, inside the app

*Help ▸ What's New* opens the full changelog as a document, with its own outline. It also opens once after an update installs.

### Lighter settings

The toolbar popover and the Settings window were heavy: big controls, lots of air. Both are compact now — small controls in labelled rows, and a grouped form in the window, like System Settings.

### Also

- Clear the recent files list from the sidebar, or remove a single entry.
- The typography button answers every click. The click that closes a popover never reaches the button under it, so toggling there left the button doing nothing every other time.
- Windows no longer come back empty after a relaunch: MD Lite decides what opens, not window restoration.

### Windows and Linux

Same version number, with no new features in this release.

## 0.3.4 — 2026-09-22

A small fix release for 0.3.3.

### Settings and About come back

Opening Settings (**⌘,**, the menu, or the button at the bottom of the sidebar) or About while its window was already open behind the document did nothing: the window stayed behind and the button looked dead. Both now come to the front. The Settings menu item is MD Lite's own, because the system one stopped answering on macOS 26.

### Popovers open on the first click

macOS closes a popover when its window stops being active without telling SwiftUI, so the next click on the typography button (and on a tab's title) only reset it and a second click was needed. They open on the first click again.

### Windows and Linux

Same version number, with no new features in this release.


## 0.3.3 — 2026-09-22

A polish release for 0.3.2: one tab bar, calmer scrolling, and a fix for files opened from Finder.

### One bar for tabs

Tabs now share the top bar with the document controls instead of sitting in a second row above them. They take even widths, like Safari's compact tabs, close with an ✕ on the left when you point at them, and the Reading / Editor / Source / Split switcher shrinks to icons when the tabs need the room.

### Scrolling

Scrolling with the sidebar open stuttered because the whole window was redrawn whenever the reading percentage or the outline highlight changed, which is many times a second.

- The outline highlight and the percentage now refresh at most four times a second, and once more as soon as you stop.
- The percentage in the footer is an AppKit label that updates on its own, so it no longer redraws the window.
- The outline works out its rows once per pass instead of once per row, its highlight no longer animates, and the current title keeps its weight so the list never re-flows.
- The reader no longer scrolls itself while it resizes, which is what made a document open at its end in a new tab.

### Fixes

- Opening a `.md` from Finder no longer brings up the About window.
- About is gone from the Window menu, the close-pane button has a proper accessibility label, and a clean new tab no longer shows the view controls it has nothing to apply to.

### Windows and Linux

Same version number, with no new features in this release.


## 0.3.2 — 2026-09-22

### Tabs and panes, rebuilt

- Tabs now live in each window's own tab strip instead of macOS window tabs, so the sidebar stays put and switching tabs no longer reloads the document. Every tab keeps its own undo history and scroll position.
- **New Tab (⌘T) opens a clean page**: drop a Markdown file on it, or open, create, or paste a document.
- **Drag and drop with a preview**: drag a tab, a sidebar file, or a file from Finder onto a document to see where it lands. Drop on the left or right half to open it side by side, or in the middle to add it as a tab there.
- **Two panes**: ⌃⌘← / ⌃⌘→ move a tab between panes, ⌥⌘W closes a pane and moves its tabs to the other one, and ⇧⌘] / ⇧⌘[ switch tabs. ⌘W closes the tab, and its pane when it was the last one.

### Right-click a file or a tab

- Open in a new tab or in the other pane
- Save a Copy As…, Duplicate, Export as HTML or PDF, Print (⌘P)
- **Favorites**, a new sidebar section
- **Finder tags and colors**, plus custom tags
- Show in Finder, Copy Path

Hover a file to see its full path, or click the tab title for a breadcrumb with *Show in Finder* and *Copy Path*.

### Focus mode

**⇧⌘F** now hides everything except the text: sidebar, the other pane, toolbars, and footer. Press ⇧⌘F again, press Esc, or use the small button in the corner to bring it all back.

### Fixes

- Scrolling with the sidebar open is smooth again.
- Fixed a crash when a tab was moved while its pane was closing.
- The drop highlight no longer stays on screen after a drag.
- Files opened in a new tab start at the top instead of the end.
- Checked task boxes show their checkmark.
- PDFs and printouts keep alert icons and link colors, and leave out the copy button.

The keyboard shortcuts sheet (⌘/) has a new *Tabs* section.

### Windows and Linux

Same version number, with no new features in this release; tabs, panes, and focus mode for Windows and Linux will come later.


## 0.3.1 — 2026-09-22

### Tabs

- Every document opens in its own **native tab** (⌘T) with its own undo history. Opening a file that is already open jumps to its tab.
- **⌘W closes the innermost thing first**: a popover or sheet, then About or Settings, then the tab. Closing the last tab keeps MD Lite running.
- Closing a tab never loses work: files save, and unsaved untitled text is kept as a recovery file in *Recent*.

### Split view

- **⌘4** shows the Markdown source on the left and the finished page on the right, scrolling together. Drag the divider to resize.

### Working folder

- Open a folder with **⇧⌘O**, or drop it on the window, to browse all its Markdown files as a tree in the sidebar. Hidden and generated folders (`node_modules`, `.git`, `build`…) are skipped. ⌘-click opens a file in a new tab.

### Also new

- **Settings** window with **⌘,**.
- Refreshed sidebar: brand card, cards for actions, a blue pill for the current heading, and a footer with *Settings*.
- The disk image now includes a `README.md` with install steps and shortcuts.

### Windows and Linux

The Windows and Linux app gets the same tabs (Ctrl+T, Ctrl+W, Ctrl+Tab), split view (Ctrl+4), working folders (Ctrl+Shift+O), and sidebar design.


## 0.3.0 — 2026-09-21

### Read, edit, and look at the source

- **Three modes**: Reading (⌘1), Editor (⌘2), and Source (⌘3). ⌘E toggles between reading and editing.
- **Edit in the pretty view**: the editor keeps the reading typography and hides Markdown markers until the caret reaches their line.
- **Undo and redo everywhere** (⌘Z / ⇧⌘Z), including checking a task in the reading view.
- Formatting bar and shortcuts: bold, italic, strikethrough, code, links, headings, lists, tasks, quotes, code blocks, tables. Lists and quotes continue on Return; Tab and Shift-Tab indent.
- Open files save automatically; new notes ask where to save on ⌘S.

### GitHub Flavored Markdown

- Real HTML rendering: `<p align="center">`, images with `width`, `<picture>`, `<details>`, `<kbd>`, `<sub>`, `<sup>`, HTML tables, comments hidden, unsafe tags filtered.
- Code blocks drawn as a single box with syntax highlighting, language label, and a copy button.
- GitHub alerts (`> [!NOTE]`, `[!TIP]`, `[!IMPORTANT]`, `[!WARNING]`, `[!CAUTION]`).
- Extended autolinks, clickable task lists, heading anchors, YAML front matter, no smart punctuation.
- **Mermaid diagrams**, drawn offline. The library ships compressed and only loads when a document has a diagram.

### Navigation and comfort

- Collapsible outline that follows your reading position, with a filter for long documents and ⌥⌘↑ / ⌥⌘↓.
- Hide the sidebar with ⌃⌘S or ⌘\. Focus mode with ⇧⌘F.
- Centered text column with the scroller at the window edge; choose narrow, normal, wide, or full width.
- Keyboard shortcut sheet (⌘/).
- Guided setup to open `.md` files with MD Lite.
- **Check for Updates…** against GitHub Releases (manual, or daily when enabled).
- Remote images stay blocked until you choose to show them.

The app is smaller than before: about 3.6 MB installed.

### Windows and Linux

MD Lite now runs on **Windows** (`MD-Lite-0.3.0-windows-x64-setup.exe`, installs for the current user) and **Linux** (`.deb`, or the self-contained `.AppImage`). Same rendering, Reading/Editor/Source modes, autosave, outline, and `Ctrl` shortcuts. The Windows installer is not code-signed yet; SmartScreen may ask you to confirm the first launch.


## 0.2.2 — 2026-09-21


## 0.2.1 — 2026-09-21

### MD Lite v0.2.1

This release adds the reverse workflow: create Markdown notes inside MD Lite, then save them as files.

### Highlights

- New Note editor with writing and live preview modes.
- Toolbar actions for headings, subheadings, bold text, lists, and Markdown tables.
- Save notes directly as `.md` files through the native macOS save panel.
- Finder registration for `.md` and `.markdown` files with MD Lite as the preferred application.
- System-aware language, appearance, and accent color.
- Native Liquid Glass controls on macOS 26.
- One-click A−, reset, and A+ text controls.
- Native Markdown table cells with wrapping and alignment.
- A quieter sidebar empty state.

### Download

Download `MD-Lite-0.2.1-arm64.dmg`, open it, and drag **MD Lite** into **Applications**.

Requires macOS 14 or later and Apple silicon. This development build is ad hoc signed and is not notarized by Apple. If Gatekeeper shows a warning, close it, Control-click **MD Lite.app** in Applications, choose **Open**, and confirm **Open** once. A Developer ID certificate and Apple notarization are required to remove that first-launch step.

Verify the download with:

```sh
shasum -a 256 -c MD-Lite-0.2.1-arm64.dmg.sha256
```

## 0.2.0 — 2026-09-21

### MD Lite v0.2.0

This release makes MD Lite more native, more configurable, and easier to use.

### Highlights

- Follow the macOS system language, appearance, and accent color by default.
- English and Spanish interface with immediate language switching.
- Native Liquid Glass controls and sidebar on macOS 26, with translucent material fallback on macOS 14 and 15.
- One-click A−, size reset, and A+ controls in the toolbar.
- Paste or type Markdown and open it directly in Reading View.
- ⇧⌘V reads Markdown text directly from the clipboard.
- Native TextKit tables with borders, wrapping, header styling, and column alignment.
- Removed the decorative sidebar footer to keep the reading space quieter.
- Added light, dark, and table screenshots to the README.

### Download

Download `MD-Lite-0.2.0-arm64.dmg`, open it, and drag **MD Lite** into **Applications**.

Requires macOS 14 or later and Apple silicon. This release is ad hoc signed and not notarized by Apple.

Verify the download with:

```sh
shasum -a 256 -c MD-Lite-0.2.0-arm64.dmg.sha256
```

### Validation

Nine tests pass locally, including native table structure and alignment, system language resolution, pasted Markdown preservation, rendering, links, lists, and Unicode headings. The DMG checksum and bundled app signature were verified.

## 0.1.0 — 2026-09-21

The first release of **MD Lite**, a lightweight, native Markdown reader for macOS built with SwiftUI and AppKit/TextKit.

### Features

- Native Markdown rendering with a navigable document outline.
- Native search, text selection, and copying.
- Focus mode, source view, and adjustable text size.
- Light, dark, and system appearance.
- Recent files and automatic refresh when your editor saves changes.
- Local document reading without accounts or telemetry.
- Open source under the MIT license.

### Download and install

Download **MD-Lite-0.1.0-arm64.dmg**, open it, and drag **MD Lite** into **Applications**.

Requires **macOS 14 Sonoma or later** and **Apple silicon (M1 or newer)**. This release does not include an Intel build. The app interface is currently in Spanish; project documentation is in English.

This development build is **ad hoc signed**, not Developer ID signed or notarized by Apple. macOS may block downloaded copies. You can also build from source using the README instructions.

### Verify the download

Download the DMG and its `.sha256` file into the same folder, then run:

```sh
shasum -a 256 -c MD-Lite-0.1.0-arm64.dmg.sha256
```

### Known limitations

- Tables have a basic text representation.
- HTML is shown as text, except for line breaks.
- Mermaid, LaTeX, syntax highlighting, and internal anchor navigation are not included.
- Documents are limited to 5 MB and local images to 20 MB.
- This is a reader; it does not edit documents.

### Validation

Release build completed, all six Markdown tests passed locally, and the DMG checksum and bundled app signature were verified. File opening, search, and outline navigation were checked in the running app.
