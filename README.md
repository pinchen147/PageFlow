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
- **Bookmarks** — Mark, navigate, and preserve across undo
- **Tabs & Windows** — Multi-tab, multi-window, per-window undo isolation
- **Search** — Find text across your documents
- **View Modes** — Single page, continuous, or two-up display
- **Always on Top** — Per-window floating, toggled from Settings
- **Customizable Toolbar** — Resize, pin, and tune to taste
- **Auto-Updates** — Built-in update checking via Sparkle (direct-download builds)
- **Privacy First** — Fully offline, no telemetry

## What's New in 1.3

- **Always on Top** — new per-window toggle in Settings (⌘,). Float one document above everything without pinning every window.
- **Toolbar customization** — resize the toolbar with a slider, or pin it so it never auto-hides.
- **No more duplicate windows** — opening a PDF that's already open just brings the existing window to the front.
- **Safer undo** — deleting pages no longer loses the bookmarks and comments attached to them; undo brings them back.
- **Reliable Open Recent** — recent files keep working across launches, even for documents in sandboxed locations.
- **Save As preserves your work** — bookmarks and annotations carry over cleanly when saving to a new file.
- **Password prompt fixes** — cancelling a password-protected PDF tidies up the empty tab instead of leaving it behind.
- **Quit protection** — if a save fails on quit, PageFlow warns you first instead of silently closing.

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
