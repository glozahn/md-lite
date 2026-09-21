# MD Lite

**A little space to read.** A lightweight, native Markdown reader for macOS, built with SwiftUI and AppKit/TextKit.

A clean window, a translucent sidebar, subtle teal accents, and comfortable typography keep your documents at the center. MD Lite runs locally, with no accounts or telemetry.

## Features

- Open `.md`, `.markdown`, and UTF-8 text files from Finder, the file picker, or drag and drop.
- Navigate documents with an automatically generated heading outline.
- Find text with native macOS search, and select and copy content.
- Switch between rendered Markdown and source view.
- Read in focus mode with adjustable text size.
- Choose light, dark, or system appearance.
- Reopen recent files and automatically refresh when your editor saves changes.
- See an approximate word count and reading time.

Built entirely with native macOS technologies. No Electron, React Native, WebView, or JavaScript runtime.

## Installation

Requires **macOS 14 Sonoma or later**. The current DMG is built for **Apple silicon (arm64)**.

1. Open `MD-Lite-0.1.0-arm64.dmg`.
2. Drag **MD Lite** into **Applications**.
3. Launch MD Lite and open a Markdown file.

This development build is ad hoc signed, not Developer ID signed or notarized. macOS may block a downloaded copy. Developer ID signing and Apple notarization are still needed for a standard public distribution. You can also build the app locally using the instructions below.

The app is currently in Spanish; this project documentation is in English.

## Build from source

Use Xcode with a compatible Swift toolchain. The project targets macOS 14 and uses a Swift 5.9 package manifest; the current build has been verified with Xcode's Swift 6.3.3 toolchain. The first build needs internet access to fetch Swift package dependencies.

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
| Toggle focus mode | ⇧⌘F |
| Toggle source view | ⇧⌘S |
| Increase text size | ⌘+ |
| Decrease text size | ⌘− |
| Reset text size | ⌘0 |
| Reload document | ⌘R |

## Markdown support

MD Lite uses [Swift Markdown](https://github.com/swiftlang/swift-markdown), powered by cmark-gfm, to parse documents and renders the result as native attributed text.

Supported elements include ATX and Setext headings, paragraphs, bold and italic text, blockquotes, ordered and nested lists, thematic breaks, inline and fenced code, escaped characters, reference links, and line breaks. GFM strikethrough and task lists are also supported.

Local images are displayed inline. Remote images are presented as links and are only opened when you choose to open them.

### Current limitations

- GFM tables use a basic text representation, without a full grid or complex column alignment.
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
| `Sources/MDLite/NativeReader.swift` | NSTextView integration and native search |
| `scripts/build-app.sh` | Release app packaging and ad hoc signing |
| `scripts/build-dmg.sh` | Compressed disk image packaging and verification |

Tests cover Unicode heading ranges, reference and relative links, text formatting, lists, code, line breaks, renderer reuse, and link scheme filtering. GitHub Actions runs the tests and builds the app on macOS.

Contributions are welcome. Please include a small Markdown example when reporting a rendering issue, along with your macOS version and the expected result.

## Inspiration

Inspired by the syntax documented in [Markdown Guide](https://www.markdownguide.org/basic-syntax/), the direct reading experience of [QuickMD](https://qmd.app/), and the visual clarity of [Typora](https://typora.io/). MD Lite is an independent native implementation and is not affiliated with these projects.

## License

MD Lite is released under the [MIT License](LICENSE).

Swift Markdown and cmark-gfm retain their own licenses. Their license notices are included in the packaged application under `Contents/Resources/Licenses`.
