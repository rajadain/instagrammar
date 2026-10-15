# Instagrammar — Decision Log

Durable decisions for this project. Agents: read this before starting any phase in
[PLAN.md](PLAN.md). Append new decisions at the bottom with a date; don't rewrite history
— if a decision is reversed, add a new entry that supersedes the old one.

## Product

| # | Decision | Date | Source |
|---|----------|------|--------|
| P1 | Native macOS app that splits one wide photo into N seamless Instagram carousel tiles. | 2026-10-15 | User |
| P2 | Inputs: any image macOS ImageIO can read (JPEG, PNG, HEIC, TIFF, RAW/DNG, …). | 2026-10-15 | User |
| P3 | Tile aspect presets: **Portrait 4:5 (default)**, Portrait 3:4, Square 1:1, Landscape 1.91:1, Custom W:H. | 2026-10-15 | User asked for portrait/square/custom; 3:4 and 1.91:1 added since Instagram supports them |
| P4 | Tile count: 1–20 (Instagram carousel max is 20), **default 3**. | 2026-10-15 | Claude default |
| P5 | Editing: zoom, pan, free rotation ("Straighten", ±45°), plus 90° rotate left/right. | 2026-10-15 | User |
| P6 | **Never allow empty space**: the tile strip must always be fully covered by the image. Rotating/zooming auto-zooms in as needed (Lightroom/Photos crop behaviour). No fill colours. | 2026-10-15 | User |
| P7 | Export naming: `<ORIGINAL_STEM>-tile-<n>.jpg`, 1-based. Zero-pad when N ≥ 10 (`-tile-01`) so files sort correctly. | 2026-10-15 | User + Claude (padding) |
| P8 | Export to a user-picked folder (defaults to last-used folder, else the source image's folder). Confirm before overwriting existing files. | 2026-10-15 | User + Claude |
| P9 | Export quality: JPEG quality slider, **default 100%**. | 2026-10-15 | User ("default to max") |
| P10 | Export pixel size: **default "Maximum"** = native source pixels covered by one tile. Smaller presets (2160 / 1440 / 1080 wide) and custom width; height follows the aspect. **Never upscale**: presets larger than native are disabled. | 2026-10-15 | User |
| P11 | Output colour: **convert to sRGB** and embed the sRGB profile. | 2026-10-15 | User |
| P12 | Output metadata: **keep EXIF/TIFF/IPTC** (camera, lens, date, copyright), **strip GPS**, set Orientation = 1, fix pixel dimensions. | 2026-10-15 | User |
| P13 | Output format: JPEG only (v1). | 2026-10-15 | Claude default |
| P14 | Sources with transparency (PNG/TIFF alpha) are flattened over **white** before JPEG encoding. | 2026-10-15 | Claude default |

## Technical

| # | Decision | Date | Source |
|---|----------|------|--------|
| T1 | Image processing uses **Apple ImageIO + Core Image** only (system frameworks). No custom pixel code, no ImageMagick/vips at runtime. The same transform math drives the preview and the export, so they match. | 2026-10-15 | User |
| T2 | **Swift Package Manager**, no Xcode project. Full Xcode is *not* installed; only Command Line Tools (Swift 6.2). `scripts/build-app.sh` wraps the binary into `build/Instagrammar.app` with an Info.plist and ad-hoc signature. | 2026-10-15 | User |
| T3 | UI: SwiftUI for windows/inspector/menus; the crop canvas is an **AppKit `NSView` with CALayers** (wrapped in `NSViewRepresentable`) for GPU-composited 60–120 fps pan/zoom/rotate and native trackpad gestures. | 2026-10-15 | Claude |
| T4 | Minimum macOS **14 (Sonoma)** (for `@Observable`). Dev machine is macOS 15.7, Apple Silicon. | 2026-10-15 | Claude |
| T5 | Swift tools 6.0, **Swift 5 language mode** (`swiftLanguageModes: [.v5]`) to avoid strict-concurrency friction with Core Image types. | 2026-10-15 | Claude |
| T6 | Tests use **Swift Testing** (`import Testing`). XCTest is not available without Xcode. Swift Testing needs extra framework flags with CLT: always run tests via `scripts/test.sh`. | 2026-10-15 | Verified by spike |
| T7 | App is **not sandboxed** (personal tool, ad-hoc signed). No security-scoped bookmarks needed. | 2026-10-15 | Claude |
| T8 | A headless CLI target `tiler` shares `TilerCore` with the app, so agents and scripts can test export end-to-end without a GUI. ImageMagick (installed via Homebrew) may be used **only in dev/test scripts** for verification (e.g. `magick compare`), never by the app. | 2026-10-15 | Claude |
| T9 | Editing uses a downsampled preview (long edge ≤ 6144 px). The full-res image is decoded only during export. | 2026-10-15 | Claude |
| T10 | Bundle identifier `dev.instagrammar.app`. App name "Instagrammar". | 2026-10-15 | Claude |
| T11 | Git: one commit per completed plan phase (or sub-step) directly on `main`. Commit messages are imperative and reference the phase, e.g. `Phase 1: crop geometry and clamping`. | 2026-10-15 | Claude |
