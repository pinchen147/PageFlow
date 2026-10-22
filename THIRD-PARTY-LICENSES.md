# Third-Party Licenses

The complete app notice resource is
[`PageFlow/Resources/ThirdPartyNotices.txt`](PageFlow/Resources/ThirdPartyNotices.txt).
It contains the exact license texts from the vendored engine and the dependency
revisions recorded in
[`Package.resolved`](PageFlow.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved).
This document records their origins; the resource carries the full notices.

## Components

| Component | Version / revision | License text included in the app resource |
|---|---|---|
| [MarkdownEngine](https://github.com/nodes-app/swift-markdown-engine) | Vendored base `faa7b04701ee25ccaa6858b8d57c3c1764775d4f`, with PageFlow changes | Full `Vendor/swift-markdown-engine/LICENSE` (Apache-2.0), including its copyright statement. The vendored snapshot has no separate `NOTICE` file. |
| [BeautifulMermaid](https://github.com/lukilabs/beautiful-mermaid-swift/tree/6a23a29e91af8f5b3e9fc09945332ca193bd69ec) | 1.0.4 / `6a23a29e91af8f5b3e9fc09945332ca193bd69ec` | Full MIT `LICENSE`, Copyright (c) 2026 Craft Docs. |
| [ElkSwift](https://github.com/lukilabs/elk-swift/tree/32f8042e3509a4819f00ff9cd46e829ec2b26da0) | 1.0.2 / `32f8042e3509a4819f00ff9cd46e829ec2b26da0` | Full EPL-2.0 `LICENSE`, upstream README acknowledgments, source-file copyright notices, and the corresponding source URL. |
| [SwiftMath](https://github.com/mgriebling/SwiftMath/tree/fa8244ed032f4a1ade4cb0571bf87d2f1a9fd2d7) | 1.7.3 / `fa8244ed032f4a1ade4cb0571bf87d2f1a9fd2d7` | Full MIT `LICENSE`, Copyright (c) 2023 Computer Inspirations. Font notices are retained separately as described below. |
| [HighlighterSwift](https://github.com/smittytone/HighlighterSwift/tree/fe7aae9c9b31d3b296fd3d2dd575e1a207bb29e0) | 3.1.0 / `fe7aae9c9b31d3b296fd3d2dd575e1a207bb29e0` | Full `LICENCE.md` (MIT and BSD-3-Clause), plus `Sources/Assets/LICENCE` for the bundled highlight.js version. Both retain the upstream copyright notices. |

## ElkSwift source availability

The corresponding source code for ElkSwift 1.0.2 is available under the
[Eclipse Public License 2.0](https://www.eclipse.org/legal/epl-2.0/) at the
[pinned upstream revision](https://github.com/lukilabs/elk-swift/tree/32f8042e3509a4819f00ff9cd46e829ec2b26da0).
The app resource includes this source-availability statement alongside the full
license and upstream notices.

## Font notices retained in SwiftMath resources

SwiftMath's package target copies `Sources/SwiftMath/mathFonts.bundle` in full.
That bundle retains these upstream notice files alongside the fonts:

- `LICENSE` — MIT, Copyright (c) 2013 MathChat.
- `GUST-FONT-LICENSE.txt` — GUST Font License text referencing LPPL 1.3c or later.
- `OFL.txt` — STIX copyright notices and SIL Open Font License 1.1.

These files are distinct from SwiftMath's root MIT license, which is included in
`ThirdPartyNotices.txt`. Preserve the whole font bundle when packaging the app.

## Resource packaging

`ThirdPartyNotices.txt` is under the PageFlow target's synchronized `PageFlow`
folder. Keep it in the app's Copy Bundle Resources inputs and confirm its presence
in the built application when validating a release. Package-root license files
are not assumed to become bundle resources automatically.

When a dependency pin or the vendored license/notice files change, copy the exact
updated texts into the resource and update this inventory. The PageFlow app menu
exposes the bundled resource through **Third-Party Notices…**.
