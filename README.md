# Instagrammar

A native macOS app that splits one wide photo into seamless Instagram carousel tiles. Pick an
aspect (portrait 4:5 by default), a tile count (1–20), then pan, zoom and straighten the photo
under a strip of tiles. Export writes full-resolution JPEGs that line up edge to edge when swiped.

<img width="1392" height="912" alt="image" src="https://github.com/user-attachments/assets/3e5a0475-0b87-452a-83b3-dd2b72ff9a93" />

## Requirements

- macOS 14 (Sonoma) or later
- Swift 6 toolchain (Xcode 26 or Command Line Tools) to build from source

## Build and install

```bash
scripts/build-app.sh && cp -R build/Instagrammar.app /Applications/
```

`scripts/build-app.sh` builds a release binary, wraps it in `build/Instagrammar.app` (Info.plist,
icon) and ad-hoc signs it. Pass `--debug` for a debug build. The app isn't sandboxed or notarized;
on first launch, right-click > Open if Gatekeeper complains.

## Usage

1. Open a photo (⌘O, drag it onto the window, or Open With). Any format macOS can read works
   (JPEG, PNG, HEIC, TIFF, …). RAW files aren't supported.
2. Choose the tile aspect and count in the inspector.
3. Position the photo on the canvas. The tile strip is always fully covered by the image, so
   rotating or zooming in auto-zooms as needed and there is never empty space.
4. Preview the carousel (⌘P) at phone size. Tiles slide edge to edge like on Instagram; drag or
   swipe slowly to inspect each seam.
5. Export (⌘E), choose a folder, and confirm if existing files would be overwritten.

## Keyboard shortcuts

| Shortcut | Action |
|----------|--------|
| ⌘O | Open a photo |
| ⌘E | Export tiles |
| ⌘P | Preview carousel (← / →, drag or swipe to slide between tiles, Esc to close) |
| ⌘[ / ⌘] | Rotate 90° left / right |
| ⌘0 | Reset crop |
| Drag, or two-finger scroll | Pan the photo |
| ← ↑ ↓ → | Pan by 1 point (canvas focused) |
| + / − | Zoom in / out |
| `,` / `.` | Straighten by 0.1° left / right |
| ⇧ + arrows or `,` `.` | Bigger steps (10 pt, 1°) |
| Mouse wheel, or ⌘ + scroll | Zoom around the cursor |
| Pinch / two-finger rotate | Zoom / straighten on the trackpad |
| Double-click canvas | Reset position and zoom (keeps the straighten angle) |

## Export

- **Files:** `<original name>-tile-<n>.jpg`, numbered from 1. With 10 or more tiles the numbers are
  zero-padded (`-tile-01`) so they sort correctly.
- **Size:** "Maximum" (default) is the native source pixels covered by one tile, so nothing is
  upscaled. Smaller presets (2160 / 1440 / 1080 wide) and a custom width are available; height
  follows the aspect. Sizes larger than native are disabled.
- **Quality:** JPEG quality slider, default 100%.
- **Colour:** converted to sRGB (tagged via EXIF ColorSpace; no ICC profile is embedded).
- **Transparency:** flattened over white.
- **Metadata:** camera, lens, date and copyright (EXIF, TIFF, IPTC) are kept; GPS is stripped and
  orientation is set to normal.

## Command-line tool

`tiler` runs the same export pipeline headlessly:

```bash
swift build -c release --product tiler
.build/release/tiler photo.jpg --out tiles/ --tiles 3 --aspect 4:5
```

| Option | Meaning |
|--------|---------|
| `<input>` | Image to split |
| `--out, -o <dir>` | Output folder (created if missing); required |
| `--tiles, -n <1..20>` | Tile count (default 3) |
| `--aspect W:H` | Tile aspect (default 4:5) |
| `--quarter-turns 0..3` | Clockwise 90° turns |
| `--straighten <deg>` | Rotation within ±45° |
| `--zoom <factor>` | Zoom relative to fit, at least 1 |
| `--offset dx,dy` | Pan in source pixels |
| `--width <px>\|max` | Output tile width (default `max`) |
| `--quality 0.5..1.0` | JPEG quality (default 1.0) |
| `--force, -f` | Overwrite existing files |

## Development

```bash
swift build                     # debug build
scripts/test.sh                 # unit tests (Swift Testing; use this, not bare `swift test`)
scripts/smoke-export.sh [image] # end-to-end CLI check: seams, metadata, timing (needs magick, exiftool)
scripts/make-icon.sh            # regenerate Resources/AppIcon.icns (needs ImageMagick)
```

Debug builds include headless self-tests that print PASS/FAIL to stderr and quit:

```bash
INSTAGRAMMAR_EXPORT_SELFTEST=<folder>  .build/debug/Instagrammar photo.jpg
INSTAGRAMMAR_PREVIEW_SELFTEST=<folder> .build/debug/Instagrammar photo.jpg
INSTAGRAMMAR_CANVAS_SELFTEST=1         .build/debug/Instagrammar photo.jpg
```

Layout: `Sources/TilerCore` (geometry, loading, export; no UI), `Sources/Instagrammar` (SwiftUI app
and AppKit canvas), `Sources/tiler` (CLI). Design notes are in `PLAN.md`; decisions are in
`MEMORY.md`.
