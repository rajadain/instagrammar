#!/usr/bin/env bash
# Renders the app icon: Resources/AppIcon.icns (dev-time only; the .icns is committed).
# Needs ImageMagick (`magick`), `sips` and `iconutil` (T1: ImageMagick is never used by the app).
#
# Usage: scripts/make-icon.sh [master-png]
#   master-png  optional path to also keep the 1024x1024 master (default: discarded)
set -euo pipefail
cd "$(dirname "$0")/.."

command -v magick >/dev/null || { echo "make-icon: 'magick' not found (brew install imagemagick)" >&2; exit 2; }

WORK="$(mktemp -d -t instagrammar-icon)"
trap 'rm -rf "$WORK"' EXIT
MASTER="$WORK/master.png"
ICONSET="$WORK/AppIcon.iconset"

# --- Geometry (1024 canvas, Apple grid: ~10% transparent margin) ----------------------------
BODY=824        # rounded square edge
OFF=100         # margin
RADIUS=185      # ~22.4% corner radius
TILE_W=200
TILE_H=250      # 4:5 portrait, like the default tile
GAP=50
STROKE=26
TILE_R=38
X0=$(( (1024 - (3 * TILE_W + 2 * GAP)) / 2 ))
Y0=$(( (1024 - TILE_H) / 2 ))

t_rect() {      # tile i -> "x0,y0 x1,y1"
    local x=$(( X0 + $1 * (TILE_W + GAP) ))
    echo "$x,$Y0 $(( x + TILE_W )),$(( Y0 + TILE_H ))"
}

# --- Body: rounded square with a vertical sunset gradient ---------------------------------
magick -size ${BODY}x${BODY} gradient:'#FFA24A-#C5208F' "$WORK/gradient.png"
magick -size ${BODY}x${BODY} xc:black -fill white \
    -draw "roundrectangle 0,0 $((BODY - 1)),$((BODY - 1)) $RADIUS,$RADIUS" "$WORK/mask.png"
magick "$WORK/gradient.png" "$WORK/mask.png" -alpha off -compose CopyOpacity -composite "$WORK/cut.png"
magick "$WORK/cut.png" -background none -gravity center -extent 1024x1024 "$WORK/body.png"

# Soft drop shadow, like system icons.
magick "$WORK/body.png" -background black -shadow 35x14+0+10 \
    -background none -gravity center -extent 1024x1024 "$WORK/shadow.png"

# --- Panorama: a faint continuous horizon (hills + sun) running edge to edge, behind-and-over
# all three tiles. Drawn opaque, then faded and clipped to the rounded body.
magick -size 1024x1024 xc:none \
    -fill white -stroke none -draw "circle 640,420 640,346" \
    -fill none -stroke white -strokewidth 16 \
    -draw "path 'M 60,625 C 150,560 230,520 320,525 C 400,530 430,590 520,610 C 610,630 650,600 720,555 C 780,520 840,505 970,560'" \
    -channel A -evaluate multiply 0.5 +channel \
    "$WORK/horizon_raw.png"
magick "$WORK/horizon_raw.png" "$WORK/body.png" -compose DstIn -composite "$WORK/horizon.png"

# --- Three white tile outlines (slightly translucent fill so the horizon reads through) --------
magick -size 1024x1024 xc:none -fill 'rgba(255,255,255,0.10)' -stroke white \
    -strokewidth $STROKE \
    -draw "roundrectangle $(t_rect 0) $TILE_R,$TILE_R" \
    -draw "roundrectangle $(t_rect 1) $TILE_R,$TILE_R" \
    -draw "roundrectangle $(t_rect 2) $TILE_R,$TILE_R" \
    "$WORK/tiles.png"

# Layers: shadow, body, tile outlines, then the horizon on top so it visibly crosses the tiles.
# (body first: the shadow image is grey, and the result takes the first image's colour space)
magick "$WORK/body.png" "$WORK/shadow.png" -compose DstOver -composite -compose Over \
    "$WORK/tiles.png" -composite \
    "$WORK/horizon.png" -composite \
    -define png:color-type=6 "$MASTER"

[[ -n "${1:-}" ]] && cp "$MASTER" "$1"

# --- iconset at every required size, then .icns ---------------------------------------------
mkdir -p "$ICONSET"
for size in 16 32 128 256 512; do
    sips -z $size $size "$MASTER" --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
    sips -z $((size * 2)) $((size * 2)) "$MASTER" --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done
mkdir -p Resources
iconutil -c icns "$ICONSET" -o Resources/AppIcon.icns
echo "Resources/AppIcon.icns"
