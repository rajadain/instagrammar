# Instagrammar — Implementation Plan

A small, fast, native macOS app that turns one wide photo into N seamless Instagram
carousel tiles. You pick the tile aspect and count, then zoom, pan and straighten the
image under a fixed "strip" of tiles and export them as JPEGs.

**Read [MEMORY.md](MEMORY.md) first.** It records every product and technical decision,
and this plan assumes them. If you have to make a new non-trivial decision, append it to
MEMORY.md in the same commit.

---

## 0. Ground rules for implementing agents

- **Toolchain:** Swift 6.2 with Command Line Tools only. There is no Xcode, so `xcodebuild`
  does not exist. Build with `swift build` and run tests with `scripts/test.sh`, never bare
  `swift test` (see §2.3). Get a runnable app with `scripts/build-app.sh` and then
  `open build/Instagrammar.app`.
- **No custom pixel code.** All decoding, rotation, cropping, resampling, colour conversion
  and encoding go through ImageIO and Core Image. Our code only computes *geometry*
  (affine transforms and rectangles) and passes it to those frameworks.
- **One source of geometry truth.** The preview canvas and the exporter must both get their
  transforms from `TilerCore/CropGeometry.swift`. Never duplicate the math in the UI.
- **Coordinate convention (critical):** all crop state lives in **S-space**: pixel coordinates
  of the *working source image* (after EXIF orientation and the user's 90° turns), with the
  origin at the **top-left** and **y pointing down**. Core Image uses a bottom-left origin with
  y up, so convert in exactly one helper (`CIBridge`, §4.4) and test it with an asymmetric
  fixture.
- **Commits:** one commit per finished phase or sub-step on `main`. Write imperative messages
  prefixed with the phase, e.g. `Phase 3: tile exporter with metadata handling`. Every
  commit must build, and `scripts/test.sh` must pass.
- **Definition of done** for each phase: the acceptance criteria listed for it pass, tests
  are added where the phase says so, and the commit is made.

---

## 1. Architecture overview

```
┌─────────────────────────── Instagrammar.app (SwiftUI) ────────────────────────────┐
│  InstagrammarApp (@main, Window scene, menu commands, AppDelegate for Dock-open)   │
│  AppModel (@Observable) — document state, settings, export orchestration           │
│  ContentView = HSplit[ CropCanvas (NSViewRepresentable → CropCanvasView: NSView) │ │
│                        InspectorView (SwiftUI Form) ]                              │
└───────────────────────────────────────┬────────────────────────────────────────────┘
                                        │ uses
┌───────────────────────────────────────▼────────────────────────────────────────────┐
│ TilerCore (library, no SwiftUI/AppKit)                                              │
│  TileSpec / AspectRatio   — what to produce                                        │
│  CropState + CropGeometry — where the strip sits; clamping; S→view/S→tile transforms│
│  SourceImage              — ImageIO load, metadata, oriented size, preview CGImage │
│  ExportSettings / Naming  — output size, quality, file names                       │
│  TileExporter             — Core Image render + ImageIO JPEG write                 │
└───────────────────────────────────────▲────────────────────────────────────────────┘
                                        │ uses
                          tiler (CLI)  ─┘   headless export for tests & scripts
```

### 1.1 Repository layout (target state)

```
Package.swift
Sources/
  TilerCore/
    AspectRatio.swift        // AspectRatio, presets, TileSpec
    CropState.swift          // CropState value type
    CropGeometry.swift       // clamping, fit, tile rects, transforms
    CIBridge.swift           // S-space (y-down) ⇄ Core Image (y-up) conversion
    SourceImage.swift        // loading, metadata, preview generation, quarter turns
    ExportSettings.swift     // OutputSize, quality, ExportPlan, file naming
    TileExporter.swift       // rendering + writing
  Instagrammar/
    InstagrammarApp.swift    // @main, AppDelegate, commands
    AppModel.swift
    ContentView.swift        // split layout, empty state, drag & drop
    Canvas/
      CropCanvas.swift       // NSViewRepresentable
      CropCanvasView.swift   // NSView + CALayers + gestures
    Inspector/
      InspectorView.swift
      TileSection.swift
      AdjustSection.swift
      ExportSection.swift
    Export/
      ExportCoordinator.swift // folder panel, overwrite check, progress, reveal
  tiler/
    main.swift               // CLI
Tests/
  TilerCoreTests/
    Fixtures.swift           // synthesises test images at runtime (no binary fixtures)
    AspectRatioTests.swift
    CropGeometryTests.swift
    SourceImageTests.swift
    ExportSettingsTests.swift
    TileExporterTests.swift
Resources/
  Info.plist
  AppIcon.icns               // Phase 7
scripts/
  build-app.sh
  test.sh
  smoke-export.sh            // Phase 3
  make-icon.sh               // Phase 7
```

### 1.2 Phase dependency graph

```
Phase 0 (scaffold)
   ├── Phase 1 (geometry) ──┐
   └── Phase 2 (loading) ───┼── Phase 3 (exporter + CLI) ──┐
                            │                              ├── Phase 6 (export UI) ── Phase 7 (polish) ── Phase 8 (QA)
         Phase 4 (app shell, needs 1+2) ── Phase 5 (canvas) ┘
```
Phases 1 and 2 can run in parallel. Phase 4 can start once 1 and 2 have landed, and it
can run in parallel with Phase 3.

---

## 2. Phase 0 — Scaffold

**Goal:** an empty-window app builds and launches as a real `.app`, and the test runner works.

### 2.1 `Package.swift`
```swift
// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Instagrammar",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "Instagrammar", targets: ["Instagrammar"])],
    targets: [
        .target(name: "TilerCore"),
        .executableTarget(name: "Instagrammar", dependencies: ["TilerCore"]),
        .executableTarget(name: "tiler", dependencies: ["TilerCore"]),
        .testTarget(name: "TilerCoreTests", dependencies: ["TilerCore"]),
    ],
    swiftLanguageModes: [.v5]
)
```
Don't add any third-party dependencies, including swift-argument-parser. Parse CLI
arguments by hand.

### 2.2 App entry point
- `InstagrammarApp` uses a single `Window("Instagrammar", id: "main")` scene, **not**
  `WindowGroup`, so opening files never spawns extra windows. Default size 1280×800, minimum
  900×600.
- Add `@NSApplicationDelegateAdaptor(AppDelegate.self)`. In
  `applicationDidFinishLaunching`, call `NSApp.setActivationPolicy(.regular)` and
  `NSApp.activate(ignoringOtherApps: true)`. This is needed so a SwiftPM-built binary gets a
  menu bar and focus.
- A placeholder `ContentView` showing "Drop an image here".

### 2.3 `scripts/test.sh`
Swift Testing ships in the Command Line Tools but isn't on the default search path. Verified
working invocation:
```bash
#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
F=/Library/Developer/CommandLineTools/Library/Developer/Frameworks
exec swift test -Xswiftc -F -Xswiftc "$F" -Xlinker -F -Xlinker "$F" -Xlinker -rpath -Xlinker "$F" "$@"
```
Add one trivial `@Test` so the script passes.

### 2.4 `scripts/build-app.sh`
1. `swift build -c release --product Instagrammar`.
2. Create `build/Instagrammar.app/Contents/{MacOS,Resources}`.
3. Copy `.build/release/Instagrammar` to `Contents/MacOS/Instagrammar`, copy
   `Resources/Info.plist` to `Contents/Info.plist`, and copy `Resources/AppIcon.icns` if it
   exists.
4. Run `codesign --force --sign - build/Instagrammar.app` (ad-hoc).
5. Print the bundle path. Support a `--debug` flag that builds debug instead.

### 2.5 `Resources/Info.plist`
Keys: `CFBundleIdentifier=dev.instagrammar.app`, `CFBundleName`/`CFBundleDisplayName=Instagrammar`,
`CFBundleExecutable=Instagrammar`, `CFBundlePackageType=APPL`, `CFBundleShortVersionString=0.1.0`,
`CFBundleVersion=1`, `LSMinimumSystemVersion=14.0`, `NSHighResolutionCapable=true`,
`NSPrincipalClass=NSApplication`, `CFBundleIconFile=AppIcon`, and
`CFBundleDocumentTypes` with one entry: `CFBundleTypeRole=Viewer`,
`LSHandlerRank=Alternate`, `LSItemContentTypes=[public.image]`. The document type makes
"Open With" and dropping onto the Dock icon work.

### Acceptance
- `scripts/test.sh` passes.
- `scripts/build-app.sh && open build/Instagrammar.app` shows a focused window with a menu bar.

---

## 3. Phase 1 — Crop geometry (`TilerCore`, pure math, heavily tested)

This is the heart of the app. Every other phase depends on it being right.

### 3.1 Types
```swift
public struct AspectRatio: Hashable, Codable, Sendable {
    public var width: Double   // e.g. 4
    public var height: Double  // e.g. 5
    public var value: Double { width / height }        // w/h
    public static let portrait4x5, portrait3x4, square, landscape191 // 1.91:1
}
public enum AspectPreset: String, CaseIterable, Codable, Sendable {
    case portrait4x5, portrait3x4, square, landscape191, custom
    // displayName, e.g. "Portrait 4:5"; aspect(for custom: AspectRatio) -> AspectRatio
}
public struct TileSpec: Hashable, Codable, Sendable {
    public var aspect: AspectRatio          // per tile
    public var count: Int                   // 1...20
    public var stripAspect: Double { Double(count) * aspect.value }   // "A"
}
public struct CropState: Hashable, Codable, Sendable {
    public var center: CGPoint   // S-space
    public var width: Double     // strip width in S pixels (zoom: smaller = zoomed in)
    public var angle: Double     // radians; strip rotation in S-space (see 3.2)
    public func height(for spec: TileSpec) -> Double { width / spec.stripAspect }
}
```

### 3.2 Conventions
- The **strip** is the rectangle of size `w × h` (`h = w / A`) centred at `center` and rotated
  by `angle` about it.
- A strip-local point `(u, v)` with `u ∈ [−w/2, w/2]`, `v ∈ [−h/2, h/2]` maps to S-space as
  `center + R(angle)·(u, v)`, where `R(θ) = [[cos θ, −sin θ], [sin θ, cos θ]]`.
- On screen the strip is always drawn axis-aligned, so the *image* appears rotated by `−angle`.
- **UI "Straighten" value σ (degrees) relates to angle by `angle = −σ·π/180`.** Positive σ
  turns the image clockwise on screen. Write a test that pins this down: with σ = +10°, a
  marker in the top-right of the source should move *down* on screen.
- Tile `i` (0-based) covers strip-local `u ∈ [−w/2 + i·w/N, −w/2 + (i+1)·w/N]`, `v ∈ [−h/2, h/2]`.
  Its centre in S-space is `center + R(angle)·(−w/2 + (i+0.5)·w/N, 0)`.

### 3.3 Functions (`CropGeometry`, as static functions or extensions)
1. **`maxWidth(spec:, angle:, imageSize:)`**: the largest strip width whose rotated rectangle
   fits inside the image when centred. A rectangle fits inside an axis-aligned box exactly
   when its axis-aligned bounding box (AABB) does, so with `c = |cos θ|` and `s = |sin θ|`:
   `wMax = min( W / (c + s/A),  H / (s + c/A) )`.
2. **`minWidth(spec:, imageSize:)`**: `min(wMax(0), Double(N) * 100)`. Each tile is at least
   100 source px wide, which caps the zoom-in.
3. **`halfExtents(state:, spec:)`** gives the AABB half extents
   `ex = (w·c + h·s)/2` and `ey = (w·s + h·c)/2`.
4. **`clamp(_ state:, spec:, imageSize:) -> CropState`**:
   - `width = clamp(width, minWidth, maxWidth(angle))`. This is the "auto-zoom on rotate"
     behaviour from decision P6.
   - Then `center.x = clamp(cx, ex, W − ex)` and `center.y = clamp(cy, ey, H − ey)`.
   - The function is idempotent, and its result always satisfies the containment invariant
     (all 4 strip corners inside `[0,W]×[0,H]` within a 1e-6 tolerance).
5. **`fit(spec:, imageSize:, angle: = 0) -> CropState`**: the image centre with `width = maxWidth`.
   This is the initial state and the "Reset" state.
6. **`respec(_ state:, from old: TileSpec, to new: TileSpec, imageSize:)`**: used when the
   tile count or aspect changes. Keep `center`, `angle` and the **strip height**
   (`h_old`), set `width = h_old · A_new`, then `clamp`. Adding a tile extends the strip
   sideways, and the result zooms in automatically if the new strip no longer fits.
7. **`tileCorners(state:, spec:, index:) -> [CGPoint]`**: four S-space corners, used in tests.
8. **`nativeTilePixelSize(state:, spec:) -> (width: Int, height: Int)`**:
   `tw = floor(w / N)` and `th = floor(tw / a)`. This is "Maximum" export size.
9. **Transforms** (`CGAffineTransform`, all in y-down spaces):
   - `sToView(state:, spec:, viewSize:, padding:) -> CGAffineTransform` maps S-space to canvas
     points so the strip is centred and axis-aligned and fills the view minus padding.
     `viewScale = min((Vw − 2p)/w, (Vh − 2p)/h)`, and
     `T = translate(Vw/2, Vh/2) · scale(viewScale) · rotate(−angle) · translate(−center)`.
     Also return `viewScale` and the strip rect in view coordinates.
   - `sToTile(state:, spec:, index:, scale k:) -> CGAffineTransform` maps S-space to output
     pixel space of tile `i` (y-down, origin at the tile's top-left):
     `translate(outW/2, outH/2) · scale(k) · rotate(−angle) · translate(−tileCenter_i)`.
   - Careful with `CGAffineTransform` concatenation order. Write the helpers once and test
     them with point round-trips.
10. **Interaction helpers** (pure functions, so the canvas stays thin):
    - `panned(state, byViewDelta: CGVector, viewScale:)`: the image follows the cursor, so
      `center −= R(angle)·(Δ / viewScale)`.
    - `zoomed(state, factor:, anchorInS: CGPoint)`: `w' = w / factor` and
      `center' = anchor + (center − anchor)·(w'/w)`, which keeps the anchor fixed under the cursor.
    - `rotated(state, toAngle:)`: rotate about the strip centre.
    - Callers always run `clamp` afterwards. Helpers may call it internally if they take
      `spec` and `imageSize`.

### 3.4 Tests (`CropGeometryTests`, `AspectRatioTests`)
- `fit` on 6000×2000 with 3×4:5 (A = 2.4): `h = 2000` and `w = 4800`, centred.
- `fit` on an image narrower than the strip aspect is limited by width.
- `maxWidth` at 0° and at 45° matches hand-computed values.
- Rotating from 0° to 10° shrinks the width, and the corners stay inside.
- `clamp` is idempotent. Property-style loop: 1,000 random states (random centre, width and
  angle in ±45°, specs N ∈ 1…20, mixed aspects, mixed image sizes), and every clamped
  result has all corners inside the image.
- The `respec` 3 → 4 tiles case keeps the height when it fits and shrinks it when it doesn't.
- `sToView` maps the strip corners to the strip rect in the view, and `sToTile(i)` maps tile
  `i`'s corners to `(0,0)…(outW,outH)`.
- Seam test: the right edge of tile `i` and the left edge of tile `i+1` map from the same
  S-space line.
- `zoomed` keeps the anchor point fixed. `panned` moves the centre opposite to the drag in
  the rotated frame.
- The straighten sign convention test from 3.2.

### Acceptance
All the tests above pass. There are no AppKit or SwiftUI imports in `TilerCore`.

---

## 4. Phase 2 — Source image loading (`TilerCore/SourceImage.swift`)

### 4.1 API
```swift
public final class SourceImage: @unchecked Sendable {
    public let url: URL
    public let stem: String                       // file name without extension
    public let orientedSize: CGSize               // after EXIF orientation, before quarter turns
    public let properties: [CFString: Any]        // CGImageSourceCopyPropertiesAtIndex(…, 0, nil)
    public static func load(url: URL) throws -> SourceImage   // cheap: header + metadata only
    public func makePreview(maxPixelSize: Int = 6144) throws -> CGImage
    public func fullResolutionCIImage() -> CIImage   // lazy; decoded by CI at render time
}
public enum QuarterTurns: Int, Codable, Sendable { case r0, r90, r180, r270 }   // clockwise
public func workingSize(_ oriented: CGSize, _ q: QuarterTurns) -> CGSize        // swap for 90/270
```

### 4.2 Loading rules
- `load` uses `CGImageSourceCreateWithURL` and reads properties at index 0 to get pixel
  size and orientation. It computes the oriented size and doesn't decode pixels. It throws a
  friendly `SourceImageError.unreadable` when ImageIO returns nil or the image has 0 images.
- `makePreview` uses `CGImageSourceCreateThumbnailAtIndex` with
  `kCGImageSourceCreateThumbnailFromImageAlways: true`,
  `kCGImageSourceCreateThumbnailWithTransform: true` (applies EXIF orientation),
  `kCGImageSourceThumbnailMaxPixelSize: min(maxPixelSize, longEdge)` and
  `kCGImageSourceShouldCacheImmediately: true`. Run it off the main thread. The app shows a
  spinner while it runs.
- `fullResolutionCIImage` returns `CIImage(contentsOf: url, options: [.applyOrientationProperty: true])`.
  For RAW files this gives Apple's default RAW render, which is acceptable for v1.
- **Quarter turns** are applied as a pre-transform. The working S-space is the oriented
  image turned by `q`. Provide `quarterTurnTransform(q, orientedSize:) -> CGAffineTransform`
  (y-down) that maps oriented-image coordinates to working S-space. The canvas and exporter
  both concatenate it. When `q` changes, the app resets the crop with `fit`.

### 4.3 Supported files
- Files you open must conform to `UTType.image`.
- Readable types are whatever `CGImageSourceCopyTypeIdentifiers()` lists.

### 4.4 `CIBridge.swift`
- `func toCI(_ t: CGAffineTransform, srcHeight: CGFloat, dstHeight: CGFloat) -> CGAffineTransform`
  converts a y-down transform into the equivalent Core Image transform:
  `flip(dstHeight) · t · flip(srcHeight)`, where `flip(H) = (x, H − y)`, i.e.
  `CGAffineTransform(a:1,b:0,c:0,d:-1,tx:0,ty:H)`.

### 4.5 Tests (`Fixtures.swift` + `SourceImageTests`)
- `Fixtures` writes synthetic JPEGs into a temp directory at test time using CGContext and
  `CGImageDestination`. No binary fixtures are committed. Provide:
  - `quadrants(w,h)`: TL red, TR green, BL blue, BR white. Also a variant with a 1-px black
    grid every 100 px, for seam checks.
  - The same, saved with `kCGImagePropertyOrientation = 6`, plus EXIF
    (`LensModel`, `DateTimeOriginal`), `{GPS}` and an Adobe RGB or Display P3 profile.
- Tests:
  - The oriented size swaps for orientation 6.
  - The preview has the correct oriented aspect, with the top-left pixel red after
    orientation is applied.
  - Quarter-turn transforms map corners correctly.
  - `CIBridge` round-trips.
  - An unreadable file throws.

---

## 5. Phase 3 — Export pipeline + CLI (`TilerCore`)

### 5.1 Settings & naming (`ExportSettings.swift`)
```swift
public enum OutputSize: Hashable, Codable, Sendable {
    case native                 // "Maximum"
    case width(Int)             // height derived: round(width / aspect)
    public static let presets: [OutputSize] = [.native, .width(2160), .width(1440), .width(1080)]
}
public struct ExportSettings: Hashable, Codable, Sendable {
    public var size: OutputSize = .native
    public var quality: Double = 1.0           // 0.5...1.0, JPEG lossy quality
}
public struct TileOutput { public let index: Int; public let pixelWidth: Int; public let pixelHeight: Int; public let fileName: String }
public func plan(state:, spec:, quarterTurns:, settings:, stem:) -> [TileOutput]
public func fileName(stem: String, index: Int, count: Int) -> String   // "IMG_1234-tile-1.jpg" / "-tile-01.jpg"
```
- Output pixel size: `native = nativeTilePixelSize`. For `.width(x)`, use
  `outW = min(x, nativeW)` and `outH = round(outW / aspect)`, never larger than the native
  size. Every tile in a set has identical dimensions.
- `isAvailable(_ size:, native:)` is false when `x > nativeW`. The UI disables those options.
- Tests: file naming (pad when N ≥ 10, and keep a stem that contains dashes or spaces as is),
  size derivation for each preset, and the no-upscale clamp.

### 5.2 Renderer (`TileExporter.swift`)
```swift
public final class TileExporter: @unchecked Sendable {
    public init()                                    // owns one CIContext (reuse it; it is expensive)
    public func export(source: SourceImage, quarterTurns:, state:, spec:, settings:,
                       to folder: URL, progress: @Sendable (Int, Int) -> Void) async throws -> [URL]
    public func renderTile(...) throws -> CGImage    // exposed for tests
}
```
Pipeline per tile `i`. Every step is a stock Core Image or ImageIO call.
1. `base = source.fullResolutionCIImage()`, then apply quarter turns with
   `.transformed(by: CIBridge.toCI(quarterTurnTransform…))` and re-origin to `(0,0)`.
2. Flatten any alpha over white (`base.composited(over: CIImage(color: .white).cropped(to: base.extent))`,
   per decision P14), then `clamped = flat.clampedToExtent()`. This prevents transparent or
   dark fringes from edge interpolation at fractional borders.
3. Geometry at **native scale** (`k = 1`): `t = CIBridge.toCI(sToTile(state, spec, i, k: 1), srcHeight: H, dstHeight: nativeH)`,
   then `tile = clamped.transformed(by: t).cropped(to: CGRect(0, 0, nativeW, nativeH))`.
4. If the output is smaller than native, apply `CIFilter.lanczosScaleTransform()` with
   `scale = outH / nativeH` and `aspectRatio = (outW/nativeW)/(outH/nativeH)`, then crop to
   the integer rect `(0, 0, outW, outH)`. Lanczos gives high-quality downsampling. Don't do
   large downscales through the affine transform alone.
5. Render with `context.createCGImage(tile, from: rect, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))`.
   This is the sRGB conversion from decision P11. Create the CIContext with
   `[.workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!, .cacheIntermediates: false]`.
6. Write with `CGImageDestinationCreateWithURL(url, UTType.jpeg.identifier, 1, nil)`. For
   properties, start from `source.properties` and:
   - remove `kCGImagePropertyGPSDictionary`, `kCGImagePropertyPixelWidth`/`Height` and
     `kCGImagePropertyExifPixelXDimension`/`YDimension` (set the last two to the output size
     instead);
   - set `kCGImagePropertyOrientation = 1` and `kCGImagePropertyTIFFOrientation = 1` in
     `{TIFF}`;
   - drop `kCGImagePropertyProfileName` and any embedded ICC/colour model keys so the sRGB
     profile from the CGImage wins;
   - keep `{ExifAux}` (lens info) but drop `{MakerApple}` (large and opaque);
   - set `kCGImageDestinationLossyCompressionQuality = settings.quality`.
   - Write to a temp file in the same folder, then rename it over the destination. This is
     an atomic replace, so you never get a half-written tile.
7. Run tiles with bounded concurrency (`withThrowingTaskGroup`, at most 3 in flight). Report
   progress after each tile and check `Task.checkCancellation()` between tiles.
8. The exporter **does not** decide about overwriting. The caller (UI or CLI) resolves
   collisions before calling `export`.

### 5.3 CLI (`Sources/tiler/main.swift`)
```
tiler <input> --out <dir> [--tiles 3] [--aspect 4:5] [--quarter-turns 0..3]
      [--straighten <deg>] [--zoom <factor ≥1, relative to fit>] [--offset <dx,dy in S px>]
      [--width <px>|max] [--quality 0.5..1.0] [--force]
```
It builds `fit`, applies the straighten/zoom/offset options, runs `clamp`, and exports. It
prints each written path and exits non-zero with a message on error. Without `--force` it
refuses to overwrite existing files.

### 5.4 Tests (`TileExporterTests`) + `scripts/smoke-export.sh`
Unit tests (on synthetic fixtures):
- The tile count and every tile's pixel size match `plan`.
- **Seamlessness:** export N = 3 at native size, and render one tile with N = 1 and aspect
  `3·a` over the same strip. Compare tile `i` against the matching third of the single
  render. Read pixels back with a CGContext and treat a mean absolute difference below 2/255
  as a pass. This uses only stock APIs.
- Quadrant fixture with angle 0 and full fit: tile 0's top-left pixel is red and the last
  tile's bottom-right pixel is white.
- Orientation-6 fixture: the output has `Orientation == 1` and is visually upright (check a
  corner colour).
- Metadata: the output has no `{GPS}` and has `LensModel`, `DateTimeOriginal` and an sRGB
  profile (`CGImage.colorSpace?.name == sRGB`).
- Quality 0.6 gives smaller files than 1.0.

`scripts/smoke-export.sh` (dev only, uses ImageMagick):
1. `magick -size 6000x2000 gradient:red-blue -fill white -draw "..." fixture.jpg` (or reuse
   any real photo passed as `$1`).
2. `swift run -c release tiler fixture.jpg --out $TMP --tiles 3`.
3. `magick $TMP/*-tile-*.jpg +append $TMP/joined.png`. Then run `tiler` with `--tiles 1`
   and aspect `12:5` into `$TMP/single`, and `magick compare -metric RMSE joined.png single/*.jpg null:`.
   The script fails if the normalised RMSE is above 0.01.
4. `magick identify -verbose` shows sRGB and no GPS.

### Acceptance
`scripts/test.sh` and `scripts/smoke-export.sh` both pass. Exporting 3 native tiles from a
6000×4000 JPEG takes under 2 s in a release build on Apple Silicon. Record the measured
time in the commit message.

---

## 6. Phase 4 — App shell & state (`Sources/Instagrammar`)

### 6.1 `AppModel` (`@Observable`, `@MainActor`)
```swift
var source: SourceImage?
var preview: CGImage?               // working orientation applied by the canvas transform
var isLoading = false
var quarterTurns: QuarterTurns = .r0
var aspectPreset: AspectPreset       // persisted
var customAspect: AspectRatio        // persisted, default 4:5
var tileCount: Int                   // persisted, default 3
var crop: CropState                  // always clamped
var exportSettings: ExportSettings   // persisted
var straightenDegrees: Double { get set }   // derived from crop.angle (σ = −angle in degrees); setter clamps to ±45, re-clamps crop
var spec: TileSpec { … }
var nativeTileSize: (Int, Int) { … }
func open(url:) async                // load, preview (detached Task), fit, reset quarter turns
func rotateLeft() / rotateRight()    // quarterTurns ∓ 1, reset crop with fit
func resetCrop()                     // fit at angle 0
func update(crop:)                   // single entry point; always runs CropGeometry.clamp
```
- Persist settings with `UserDefaults` (JSON for the Codable structs) in `didSet`. Load them in `init`.
- When `tileCount`, `aspectPreset` or `customAspect` change, call `CropGeometry.respec`.
- Opening a new image while another is open just replaces it. There is no "unsaved" state.

### 6.2 Opening files
- **⌘O** opens an `NSOpenPanel` limited to `[.image]`.
- **Drag & drop** onto the window: `.dropDestination(for: URL.self)` on the root view, with
  a highlighted drop target while hovering.
- **Dock / Finder "Open With"**: `AppDelegate.application(_:open:)` forwards the first URL to
  the model. Use a shared model instance owned by the App and injected into the
  delegate, or a `NotificationCenter` hop.
- **Launch argument**: if `CommandLine.arguments` contains a file path, open it. This lets
  agents run `open build/Instagrammar.app --args /path/to/img.jpg` to verify the UI.
- Show errors (unreadable file) as an `.alert`.
- File menu: Open… (⌘O), Open Recent (via `NSDocumentController.shared.noteNewRecentDocumentURL`;
  optional), Export Tiles… (⌘E, disabled without an image).

### 6.3 Layout (`ContentView`)
- `HSplitView` or `NavigationSplitView`: the canvas fills the left, and a fixed-width
  (~280 pt) inspector sits on the right.
- With no image, show a large empty state: an SF Symbol (`photo.on.rectangle.angled`), the
  text "Drop a photo here or press ⌘O", and an Open button.
- Toolbar: Open, Rotate Left (⌘[), Rotate Right (⌘]), Reset (⌘0), Export (⌘E, prominent).

### 6.4 Inspector (`InspectorView` with a `Form` and `.formStyle(.grouped)`)
- **Tiles**
  - Aspect `Picker` with the presets. Choosing Custom reveals two `TextField`s (W : H,
    positive decimals) next to each other.
  - Count `Stepper` (1–20) with a numeric field.
  - A read-only line: "Each tile: 3024 × 3780 px (native)".
  - An orange warning label when the native tile width is under 1080 px.
- **Adjust**
  - Straighten `Slider` (−45…45, step 0.1) with a numeric field and a reset button.
  - Zoom `Slider` (1×…max, logarithmic) mapped to `width = maxWidth / zoom`.
  - Rotate 90° left/right buttons and a Reset button.
- **Export**
  - Size `Picker` with "Maximum (W × H)", "2160 × …", "1440 × …", "1080 × …" and
    "Custom width…" (with a numeric field). Disable options above native and show the
    resulting H for each.
  - Quality `Slider` (50–100%, default 100) with its % value.
  - An "Export Tiles…" button.

At this phase the canvas can be a placeholder showing the preview image scaled to fit.

### Acceptance
- Opening by every route (⌘O, drop on the window, drop on the Dock icon, launch argument)
  works.
- Inspector controls change model state, and settings persist across relaunches.

---

## 7. Phase 5 — Crop canvas (`Canvas/CropCanvasView.swift`)

### 7.1 Structure
- An `NSView` subclass with `wantsLayer = true`, `layerContentsRedrawPolicy = .never`, and these
  sublayers:
  1. `imageLayer: CALayer`: `contents = preview`, `bounds` = preview pixel size,
     `anchorPoint = (0,0)`, `minificationFilter = .trilinear` and
     `magnificationFilter = .linear`.
  2. `dimLayer: CAShapeLayer`: a path made of the full bounds plus the strip rect, with
     `fillRule = .evenOdd`, filled with black at 55% alpha.
  3. `gridLayer: CAShapeLayer`: a 1-pt white strip border, tile dividers (white at 80%) and
     optional rule-of-thirds lines per tile (white at 25%, shown only during interaction).
  4. Tile number labels (`CATextLayer`, small, top-left of each tile, shown during
     interaction or on hover).
- Override `isFlipped = true` so view coordinates are y-down like S-space.
- `layout()` and every state change call `updateLayers()`. That function computes
  `T = sToView(...)` and the preview-to-S scale `p = orientedLongEdge / previewLongEdge`.
  It sets `imageLayer.setAffineTransform(T · quarterTurnTransform · scale(p))`, with the order
  checked against the Phase 1 tests, and rebuilds the dim and grid paths from the strip rect.
  Wrap updates in `CATransaction.setDisableActions(true)` so nothing animates implicitly.
- **No re-rendering of pixels during interaction.** Only the layer transform changes, and
  the GPU does the compositing. This is what keeps the canvas fast.

### 7.2 Input → `CropGeometry` helpers → `model.update(crop:)`
| Input | Action |
|---|---|
| Mouse drag (left button) | Pan (`panned`). The image follows the cursor. Show the closed-hand cursor while dragging. |
| Trackpad two-finger scroll (`hasPreciseScrollingDeltas`) | Pan. |
| Mouse wheel (non-precise) or ⌘ + scroll | Zoom around the cursor (`zoomed`, factor `1.0015^deltaY` or similar). |
| Pinch (`magnify(with:)`) | Zoom around the cursor (`factor = 1 + event.magnification`). |
| Trackpad rotate (`rotate(with:)`) | Straighten by `event.rotation` degrees. Pick the sign so the image follows the fingers, verify by hand, and record it in a code comment. |
| Double-click | Reset the crop with `fit`, keeping the current angle. |
| Arrow keys | Pan 1 view pt (⇧: 10 pt). |
| `+` / `-` | Zoom ×1.1 / ÷1.1 around the strip centre. |
| `,` / `.` | Straighten −0.1° / +0.1° (⇧: 1°). |

- The view must `acceptsFirstResponder` and become first responder on click.
- Every gesture goes through clamping, so the strip is never uncovered (decision P6).
- Optional extra: a short gesture-end "settle" animation is **not** needed. Clamping is
  immediate, like Photos.

### 7.3 `CropCanvas` (`NSViewRepresentable`)
- `updateNSView` pushes `preview`, `quarterTurns`, `crop` and `spec` into the view. The view
  calls back through a closure `onCropChange: (CropState) -> Void`.
- Avoid feedback loops: only call `updateLayers()` when the incoming values differ.

### Acceptance
- Pan, zoom and rotate feel smooth (no visible stutter) on a 50 MP image.
- The strip never shows empty space, including at ±45°.
- Changing the tile count or aspect in the inspector updates the canvas instantly.
- What you see is what gets exported: export, open the tiles in Preview, and compare by eye
  against the canvas at several angles.

---

## 8. Phase 6 — Export UI (`Export/ExportCoordinator.swift`)

1. ⌘E or the Export button opens an `NSOpenPanel` with `canChooseDirectories = true`,
   `canChooseFiles = false`, `canCreateDirectories = true` and `prompt = "Export Here"`. Its
   `directoryURL` is the last export folder (persisted path) if it still exists, otherwise
   the source image's folder.
2. Compute the `plan`. If any target file exists, show an alert: "3 files already exist in
   ‘Instagram’. Replace them?" with **Replace** and **Cancel** (Cancel is the default button).
3. Run `TileExporter.export` in a `Task`. Show a sheet or overlay with a determinate progress
   bar ("Exporting tile 2 of 3…") and a Cancel button. Cancelling deletes any tiles already
   written in this run.
4. On success, show a non-blocking banner or toast for about 4 seconds: "Exported 3 tiles"
   with a **Show in Finder** button (`NSWorkspace.shared.activateFileViewerSelecting(urls)`).
5. Errors (disk full, permission) appear in an alert with the underlying message.
6. Persist the chosen folder.

### Acceptance
- An end-to-end export from the GUI produces correctly named, correctly sized and seamless
  files.
- The overwrite prompt and Cancel both behave as described.

---

## 9. Phase 7 — Polish

- **App icon**: `scripts/make-icon.sh` renders a simple 1024² icon. For example, a rounded
  square with three tile outlines drawn by `magick`, run once at dev time. The script builds
  an `.iconset` at all sizes with `sips` and converts it with `iconutil -c icns`. Commit the
  resulting `Resources/AppIcon.icns`.
- **Carousel preview** (⌘P): a sheet showing tiles one at a time at phone size (~390 pt
  wide), with left/right arrows and swipe. It renders from the preview image with the same
  `sToTile` math at screen resolution, so it costs no full-res decode.
- **Undo/Redo** for crop changes: register with the window's `UndoManager` at gesture end,
  not per event.
- **Hi-res refinement (only if Phase 8 shows blur at high zoom)**: when `viewScale · p > 1.5`,
  render the visible region at full resolution in the background with CIContext and show it in
  a second layer. Skip this if the 6144 px preview looks sharp enough.
- **About window / version**: use the standard `orderFrontStandardAboutPanel`.
- **README.md**: what the app does, how to build and install
  (`scripts/build-app.sh && cp -R build/Instagrammar.app /Applications/`), and the keyboard
  shortcuts.

---

## 10. Phase 8 — QA & performance pass

Use a manual checklist and record the results in the commit message or in `docs/QA.md`:
- Formats: JPEG, HEIC (iPhone), TIFF 16-bit, DNG/CR3/NEF RAW, and PNG with alpha. JPEG
  has no alpha, so composite transparent PNG pixels over white before encoding
  (`CIImage.composited(over: CIImage(color: .white))`). Verify this produces white, not black.
- Orientations: portrait iPhone shots (EXIF 6 and 8).
- Extremes: N = 1, N = 20, 1.91:1 with N = 20 on a non-panoramic image (the strip becomes
  very thin), tiny images (native tile < 1080 shows the warning), and 100 MP+ panoramas.
- Performance targets on Apple Silicon (release build):
  - Preview visible less than 500 ms after opening a 50 MP JPEG.
  - Interaction at display refresh rate.
  - Exporting 10 native tiles from a 100 MP panorama in under 8 s.
  - Idle CPU at 0%.
  - Memory under 1 GB while editing.
- Profiling with no Instruments available: use `/usr/bin/time -l` on the CLI for peak memory,
  and Activity Monitor for the app.

---

## 11. Out of scope for v1 (possible later)
- Batch processing several images.
- Export formats other than JPEG (HEIC/PNG).
- Gaps or borders between tiles, and fill colours.
- Perspective correction and flip/mirror.
- Notarisation and distribution beyond this Mac.
