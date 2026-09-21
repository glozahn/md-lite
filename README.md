# MD Lite

![MD Lite logo](docs/brand/md-lite-mark.svg)

**A little space to read.**

A lightweight, native Markdown reader and note maker for macOS. Built with SwiftUI, AppKit, TextKit, and Swift Markdown.

[![Latest release](https://img.shields.io/github/v/release/glozahn/md-lite?style=flat-square&color=167c87&label=download)](https://github.com/glozahn/md-lite/releases/latest) [![Build status](https://img.shields.io/github/actions/workflow/status/glozahn/md-lite/swift.yml?style=flat-square&label=tests)](https://github.com/glozahn/md-lite/actions/workflows/swift.yml) [![MIT license](https://img.shields.io/github/license/glozahn/md-lite?style=flat-square&color=167c87)](LICENSE) ![macOS 14 or later](https://img.shields.io/badge/macOS-14%2B-111820?style=flat-square)

[Download MD Lite](https://github.com/glozahn/md-lite/releases/latest) · [Build from source](#build-from-source) · [Contribute](#contributing)

## Read without noise

MD Lite turns Markdown into a calm, native reading experience. A focused canvas, a navigable outline, excellent typography, and no account or web runtime.

## Write it back

Create a note, add headings and tables, preview it live, and save a standard `.md` file. Reading and writing stay in the same small app.

## Screenshots

![MD Lite in light appearance](docs/screenshots/light.png)

![MD Lite in dark appearance](docs/screenshots/dark.png)

![Native Markdown table rendering](docs/screenshots/tables.png)

## What it does

| Read | Create | Feel at home |
| --- | --- | --- |
| Native Markdown rendering | New note editor with live preview | Follows macOS language and appearance |
| Heading outline and recent files | Headings, emphasis, lists, and tables | Liquid Glass on macOS 26 |
| Native search and copy | Save directly as `.md` | One-click A−, reset, and A+ |
| Auto-refresh when a file changes | Paste Markdown into Reading View | System or custom accent color |

MD Lite supports ATX and Setext headings, paragraphs, emphasis, quotes, ordered and nested lists, code, links, images, task lists, strikethrough, line breaks, and GFM tables with native TextKit cells.

## Download

Requires **macOS 14 Sonoma or later** and **Apple silicon**.

1. Download the latest [DMG from GitHub Releases](https://github.com/glozahn/md-lite/releases/latest).
2. Drag **MD Lite** into **Applications**.
3. Open a `.md` file from Finder or press **⌘O** inside the app.

Signed and notarized releases are published on GitHub. macOS registers MD Lite as the default application for `.md` and `.markdown` files during installation.

## Build from source

Use Xcode 26 or later. The package targets macOS 14 and uses Swift 5.9 or later.

```sh
git clone https://github.com/glozahn/md-lite.git
cd md-lite
swift test
./scripts/build-app.sh
open "dist/MD Lite.app"
```

Create a DMG with `./scripts/build-dmg.sh`. The repository also includes `scripts/notarize-app.sh` for Developer ID signing and Apple notarization. Certificates and private keys are never stored in the repository.

## Shortcuts

| Action | Shortcut |
| --- | --- |
| Open a document | ⌘O |
| Find in document | ⌘F |
| Paste and read clipboard Markdown | ⇧⌘V |
| New note | ⌘N |
| Toggle focus mode | ⇧⌘F |
| Toggle source view | ⇧⌘S |
| Increase / reset / decrease text | ⌘+ · ⌘0 · ⌘− |
| Reload document | ⌘R |

## Privacy and scope

Documents stay on your Mac. Preferences and recent file paths are stored locally. MD Lite has no account, analytics, telemetry, or automatic network requests. It is a reader and note maker, not a collaborative editor.

## Contributing

Issues and pull requests are welcome. For rendering issues, include a small Markdown example, your macOS version, and the expected result.

## Credits and license

Inspired by [Markdown Guide](https://www.markdownguide.org/basic-syntax/), [QuickMD](https://qmd.app/), and [Typora](https://typora.io/). MD Lite is an independent project and is not affiliated with them.

MD Lite is released under the [MIT License](LICENSE). Swift Markdown and cmark-gfm retain their own licenses; their notices ship inside the application bundle.
