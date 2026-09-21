# MD Lite

**A little space to read.** A lightweight, native Markdown reader for macOS, built with SwiftUI and AppKit/TextKit.

A clean window, a translucent sidebar, system-aware accent colors, and comfortable typography keep your documents at the center. MD Lite runs locally, with no accounts or telemetry.

## Screenshots

### Light

![MD Lite in light appearance](docs/screenshots/light.png)

### Dark

![MD Lite in dark appearance](docs/screenshots/dark.png)

## Features

- Open `.md`, `.markdown`, and UTF-8 text files from Finder, the file picker, or drag and drop.
- Navigate documents with an automatically generated heading outline.
- Find text with native macOS search, and select and copy content.
- Switch between rendered Markdown and source view.
- Read in focus mode with one-click **A− / A+** controls and a size reset button.
- Paste or type Markdown, then open it in Reading View; use ⇧⌘V to read clipboard text directly.
- Create notes inside MD Lite with a writing view, live preview, headings, emphasis, lists, and table insertion, then save them as standard `.md` files.
- Render GFM tables with native cells, borders, wrapping, and column alignment.
- Follow macOS language, appearance, and accent color by default, or override each in Reading Preferences.
- Native Liquid Glass controls and sidebar on macOS 26; translucent material on macOS 14 and 15.
- Reopen recent files and automatically refresh when your editor saves changes.
- Installing the app registers `.md` and `.markdown` files with Finder so they can be opened directly in MD Lite.
- See an approximate word count and reading time.

Built entirely with native macOS technologies. No Electron, React Native, WebView, or JavaScript runtime.

## Installation

Requires **macOS 14 Sonoma or later**. The current DMG is built for **Apple silicon (arm64)**.

1. Open `MD-Lite-0.2.1-arm64.dmg`.
2. Drag **MD Lite** into **Applications**.
3. Launch MD Lite and open a Markdown file.

This development build is ad hoc signed, not Developer ID signed or notarized. If macOS shows a malware verification warning after downloading the DMG, close the warning, then Control-click **MD Lite.app** in Applications and choose **Open**. Confirm **Open** once. Developer ID signing and Apple notarization are still needed to remove this first-launch step for public distribution. You can also build the app locally using the instructions below.

The interface supports **English and Spanish**. System mode follows your macOS preferred language order and falls back to English when no supported language is available. The preferences button in the toolbar lets you override language, light/dark appearance, and accent color. Changes apply immediately and are saved locally. Native system dialogs use the OS language.

To read pasted Markdown, click **Paste Markdown**, paste or type your text, then choose **Reading View**. **⇧⌘V** reads text directly from the clipboard. Pasted documents are temporary and are not saved when the app closes.

## Build from source

Use **Xcode 26 or later** to compile the Liquid Glass APIs. The project targets macOS 14 and uses a Swift 5.9 package manifest; the current build has been verified with Xcode's Swift 6.3.3 toolchain. The first build needs internet access to fetch Swift package dependencies.

Open `Package.swift` in Xcode, or run:

```sh
swift run MDLite
```

Build the release application:

```sh
./scripts/build-app.sh
open "dist/MD Lite.app"
```

Build a disk image:

```sh
./scripts/build-dmg.sh
```

The scripts build for your Mac's architecture, generate the app icon, bundle dependency license notices, and apply an ad hoc signature. The DMG includes the app, an Applications shortcut, and installation instructions. Artifacts are written to `dist/`.

## Keyboard shortcuts

| Action | Shortcut |
| --- | --- |
| Open a document | ⌘O |
| Find in document | ⌘F |
| Paste and read clipboard Markdown | ⇧⌘V |
| Toggle focus mode | ⇧⌘F |
| Toggle source view | ⇧⌘S |
| Increase text size | ⌘+ |
| Decrease text size | ⌘− |
| Reset text size | ⌘0 |
| Reload document | ⌘R |

## Markdown support

MD Lite uses [Swift Markdown](https://github.com/swiftlang/swift-markdown), powered by cmark-gfm, to parse documents and renders the result as native attributed text.

Supported elements include ATX and Setext headings, paragraphs, bold and italic text, blockquotes, ordered and nested lists, thematic breaks, inline and fenced code, escaped characters, reference links, and line breaks. GFM strikethrough, task lists, and tables are also supported. Tables use native TextKit cells with equal-width columns, header styling, borders, text wrapping, and left/center/right alignment.

Local images are displayed inline. Remote images are presented as links and are only opened when you choose to open them.

### Current limitations

- HTML is displayed as text, except for `<br>` line breaks.
- Mermaid, LaTeX, syntax highlighting, and internal anchor navigation are not implemented.
- Documents are limited to 5 MB and local images to 20 MB. Very complex content may still affect rendering performance.
- MD Lite is a reader and does not edit or save changes to your documents.

## Privacy

Documents stay in their original locations on your Mac. Preferences and recent file paths are stored locally in UserDefaults. The app makes no automatic network requests and includes no accounts, analytics, or telemetry. Opening an external link hands it to the appropriate application.

## Development

```sh
swift build
swift test
```

| File | Responsibility |
| --- | --- |
| `Sources/MDLite/MDLiteApp.swift` | Window, menus, sidebar, and application lifecycle |
| `Sources/MDLite/ReaderStore.swift` | Documents, preferences, recent files, and file observation |
| `Sources/MDLite/MarkdownRenderer.swift` | Markdown tree to attributed text and document outline |
| `Sources/MDLite/ReadingPreferences.swift` | English/Spanish strings, language resolution, and accent colors |
| `Sources/MDLite/NativeReader.swift` | NSTextView integration and native search |
| `scripts/build-app.sh` | Release app packaging and ad hoc signing |
| `scripts/build-dmg.sh` | Compressed disk image packaging and verification |

Tests cover Unicode heading ranges, reference and relative links, text formatting, lists, code, line breaks, renderer reuse, link scheme filtering, table structure and alignment, system language selection, and preservation of pasted text when changing preferences. GitHub Actions runs the tests and builds the app on macOS.

Contributions are welcome. Please include a small Markdown example when reporting a rendering issue, along with your macOS version and the expected result.

## Inspiration

Inspired by the syntax documented in [Markdown Guide](https://www.markdownguide.org/basic-syntax/), the direct reading experience of [QuickMD](https://qmd.app/), and the visual clarity of [Typora](https://typora.io/). MD Lite is an independent native implementation and is not affiliated with these projects.

## License

MD Lite is released under the [MIT License](LICENSE).

Swift Markdown and cmark-gfm retain their own licenses. Their license notices are included in the packaged application under `Contents/Resources/Licenses`.
