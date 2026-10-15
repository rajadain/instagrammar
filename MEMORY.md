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
| T12 | Full **Xcode 26.3** installed at `/Applications/Xcode.app` (license acceptance + `xcode-select` switch pending as of 2026-10-15). `scripts/test.sh` auto-uses Xcode when usable, else falls back to CLT + Swift Testing framework flags. Prefer Swift Testing for all tests either way. | 2026-10-15 | User installed |
| T13 | `exiftool` 13.55 installed; use it in dev/test scripts to verify output metadata (GPS stripped, EXIF kept, sRGB profile). | 2026-10-15 | User installed |
| T14 | Real sample photos live in `scratch/samples/` (git-ignored, never commit). Contents: Fuji X-S20 JPEGs 5949×3966, 6240×3120 (2:1), 5790×3860; a Fuji `.RAF`; an iPhone `.HEIC` 4032×3024 **with GPS and Display P3 profile** (tests GPS stripping + P3→sRGB). No EXIF-rotated samples — synthetic fixtures cover orientation 6/8. | 2026-10-15 | User |
| T15 | Agents cannot currently see other apps' windows in screenshots (no Screen Recording permission) or use System Events (no Accessibility). Verify window existence with `CGWindowListCopyWindowInfo`; verify pixels via the `tiler` CLI. UI look-and-feel is checked by the user. | 2026-10-15 | Observed |
| T16 | Delegation: high-complexity phases (1 geometry, 3 exporter, 5 canvas) go to Opus 5.5 sub-agents; the rest to Sonnet 5.5. Parallel agents work in isolated git worktrees; the coordinator merges into `main`. | 2026-10-15 | User |
| T17 | Exporter maps S-space → tile with `CropGeometry.sToTile(state:spec:index:outputSize:)` at the integer (floored) native size, not `scale: 1` + crop, so seams land on exact pixel boundaries (sub-0.1% anisotropic stretch is acceptable). | 2026-10-15 | Phase 1 agent |
| T18 | `CropGeometry.clamp` lets the max width win over the 100 px/tile min when they conflict (strip is never uncovered). It never changes the angle; the ±45° Straighten limit is enforced by AppModel. Interaction helpers (`panned`/`zoomed`/`rotated`) don't clamp; callers do. | 2026-10-15 | Phase 1 agent |
| T19 | **RAW files (e.g. Fuji `.RAF`) are out of scope.** This Mac's ImageIO/CI can't decode the sample RAF anyway; `SourceImage.load` throws `.unreadable` and the UI shows a friendly error. Don't spend effort on RAW fallbacks. | 2026-10-15 | User |
| T20 | `quarterTurnTransform(q, orientedSize:)` is clockwise, y-down, result origin at (0,0). Oriented → S-space in Core Image: `CIBridge.toCI(quarterTurnTransform(q, orientedSize), srcHeight: oriented.height, dstHeight: working.height)`. | 2026-10-15 | Phase 2 agent |
| T21 | Test fixtures (`Tests/TilerCoreTests/Fixtures.swift`) take *displayed* width/height; orientation 6/8 files store pre-rotated pixels. Read pixels with `Fixtures.pixel` (y-down) and compare with a tolerance. | 2026-10-15 | Phase 2 agent |
| T22 | Preview timing (load + 6144 px preview, release): 50–210 ms on the sample JPEG/HEIC files — well inside the 500 ms target. | 2026-10-15 | Phase 2 agent |
| T23 | AppKit treats any bare argv path as a document to open and SwiftUI then creates no window. `InstagrammarApp.init` registers `NSTreatUnknownArgumentsAsOpen=NO`; the AppDelegate opens launch-arg files itself. | 2026-10-15 | Phase 4 agent |
| T24 | `AppModel.update(crop:)` is the single crop entry point (limits angle to ±45°, then clamps). Zoom slider is log-scaled in the view. Quarter turns reset the crop to `fit` at angle 0. | 2026-10-15 | Phase 4 agent |
| T25 | Settings persist as one JSON blob in UserDefaults under `InstagrammarSettings.v1` (aspect preset, custom aspect, tile count, export settings, `lastExportFolderPath`). | 2026-10-15 | Phase 4 agent |
| T26 | Canvas interface is fixed: `CropCanvas(preview:quarterTurns:crop:spec:orientedSize:onCropChange:)`; `onCropChange` passes a *proposed* crop, the model clamps. | 2026-10-15 | Phase 4 agent |
