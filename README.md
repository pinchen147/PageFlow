<div align="center">

<img src="docs/icon.png" alt="PageFlow Icon" width="128">

# PageFlow

**An ultra-minimalistic, lightweight, native macOS PDF viewer**

[![GitHub stars](https://img.shields.io/github/stars/pinchen147/PageFlow?style=flat-square)](https://github.com/pinchen147/PageFlow/stargazers)
[![License](https://img.shields.io/badge/License-Apache_2.0-blue?style=flat-square)](LICENSE)
[![macOS](https://img.shields.io/badge/macOS-15%2B-blue?style=flat-square)](https://www.apple.com/macos/)

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
- **Liquid Glass UI** — Light, readable glass chrome for tabs, toolbar, traffic lights, and sidebars
- **Always on Top** — Per-window floating, toggled from Settings
- **Customizable Toolbar** — Resize, pin, and tune to taste
- **Auto-Updates** — Built-in update checking via Sparkle (direct-download builds)
- **Privacy First** — Fully offline, no telemetry

## What's New in 1.4

- **Liquid Glass refresh** — tabs, toolbar, traffic lights, sidebars, and controls now use a lighter readable glass treatment.
- **Hover-reveal chrome** — the traffic lights, tabs, and toolbar can stay out of the way while preserving the native-feeling reveal behavior.
- **Smoother resizing** — PDF layout settling and stale view cleanup reduce resize lag and prevent delayed work from hitting old views.
- **More reliable PDF view modes** — display-mode changes now use one synchronization path, so menu changes and PDFKit updates stay in sync.
- **Cleaner tab architecture** — tab runtime ownership, click targets, sidebar state, and reorder state are split into focused components.
- **Better long-session stability** — stale PDF view references, unused scroll state, and delayed layout captures were cleaned up.

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

- macOS 15 (Sequoia) or later

## License

[Apache 2.0](LICENSE)

---

<div align="center">
Made with SwiftUI
</div>
