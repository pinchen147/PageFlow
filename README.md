<div align="center">

<img src="docs/icon.png" alt="PageFlow Icon" width="128">

# PageFlow

**An ultra-minimalistic, lightweight, native macOS PDF viewer**

[![GitHub stars](https://img.shields.io/github/stars/pinchen147/PageFlow?style=flat-square)](https://github.com/pinchen147/PageFlow/stargazers)
[![License](https://img.shields.io/badge/License-Apache_2.0-blue?style=flat-square)](LICENSE)
[![macOS](https://img.shields.io/badge/macOS-14%2B-blue?style=flat-square)](https://www.apple.com/macos/)

<img src="docs/screenshot.png" alt="PageFlow Screenshot" width="600">

</div>

---

## Features

- **Pure SwiftUI + PDFKit** — Fast, native performance
- **Annotations** — Highlight, underline, and comment on PDFs
- **Bookmarks** — Mark and navigate to important pages
- **Tabs** — Open multiple PDFs in one window
- **Search** — Find text across your documents
- **View Modes** — Single page, continuous, or two-up display
- **Privacy First** — Fully offline, no telemetry

## Installation

Download the [latest release](https://pageflow.pinchen.me) or build from source:

```bash
git clone https://github.com/pinchen147/PageFlow.git
cd PageFlow
xcodebuild -project PageFlow.xcodeproj -scheme PageFlow -configuration Release build
```

## Keyboard Shortcuts

| Action | Shortcut |
|--------|----------|
| Open File | `⌘O` |
| New Tab | `⌘T` |
| Find | `⌘F` |
| Zoom In/Out | `⌘+` / `⌘-` |
| Next/Prev Page | `⌘↓` / `⌘↑` |
| Highlight | `⌘Y` |
| Underline | `⌘U` |
| Bookmark | `⌘D` |

## Requirements

- macOS 14 (Sonoma) or later

## License

[Apache 2.0](LICENSE)

---

<div align="center">
Made with SwiftUI
</div>
