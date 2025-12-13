# Custom Window Chrome Plan

- **Goal**: Full-bleed PDF viewer window with no standard title bar; only custom traffic-light controls that appear on hover near the top-left hotspot.
- **Constraints**: Pure SwiftUI + PDFKit; reuse DesignTokens; no extra dependencies; keep security-scoped and @Observable patterns intact.

## Approach
- Hide system chrome: configure `NSWindow` once on creation to keep `.hiddenTitleBar`, allow full-size content, set `titleVisibility = .hidden`, `titlebarAppearsTransparent = true`, hide standard window buttons, and enable drag-by-background.
- Window hook: add a lightweight `NSViewRepresentable` helper (e.g., `WindowConfigurator`) attached to the root view to run the window tweaks on the main thread without side effects.
- Custom traffic lights: keep `TrafficLightsView`, but ensure a reliable hover hotspot (larger hit area / contentShape) so buttons reveal when cursor nears the corner; actions remain close/minimize/zoom on the key window.
- Layout: let `MainView` occupy the full window (no inset), keep existing overlays (floating toolbar, page indicator) above content; ignore safe area if needed so PDF fills the canvas.
- Validation: manual pass — launch app, confirm default traffic lights are hidden, hover top-left to reveal custom controls, drag window from background, and verify open/zoom/navigation still work.

## Open Questions for You
- Should the window be draggable from anywhere in the background, or only near the top region?
- Do you want double-click in the background to toggle zoom/fullscreen like the default green button, or keep only the button actions?
- Is a small always-visible hotspot acceptable, or should the controls be fully hidden until hover with a larger invisible hover target?
