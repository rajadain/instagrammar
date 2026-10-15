#!/usr/bin/env bash
# End-to-end export smoke test for the release `tiler` CLI (dev only; uses ImageMagick and
# exiftool, which the app never does).
#
# Usage: scripts/smoke-export.sh [input-image] [output-dir]
#   input-image  defaults to a generated 6000x4000 ImageMagick fixture (with GPS + lens EXIF)
#   output-dir   defaults to a fresh `mktemp -d`
#
# Checks:
#   1. 3 native tiles export; prints wall time and peak memory (/usr/bin/time -l).
#   2. Seams: the 3 tiles appended side by side match one 12:5 single-tile export
#      (normalised RMSE <= 0.01).
#   3. Metadata (exiftool): no GPS tags, no maker notes, Orientation 1 or absent, LensModel kept
#      when the source has one, and sRGB colour (ICC description contains "sRGB", or no ICC
#      profile and EXIF ColorSpace = sRGB: ImageIO never embeds an ICC profile in sRGB JPEGs,
#      it tags them with EXIF ColorSpace = 1 instead).
set -euo pipefail
cd "$(dirname "$0")/.."

for tool in magick exiftool; do
    command -v "$tool" >/dev/null || { echo "smoke-export: '$tool' not found (brew install $tool)" >&2; exit 2; }
done

OUT="${2:-$(mktemp -d -t tiler-smoke)}"
mkdir -p "$OUT"
FAILED=0
fail() { echo "FAIL: $*" >&2; FAILED=1; }
pass() { echo "ok:   $*"; }

# --- Input ---------------------------------------------------------------------------------
if [[ $# -ge 1 && -n "$1" ]]; then
    INPUT="$1"
    [[ -f "$INPUT" ]] || { echo "smoke-export: no such file: $INPUT" >&2; exit 2; }
else
    INPUT="$OUT/fixture.jpg"
    magick -size 6000x4000 gradient:red-blue \
        -fill none -stroke white -strokewidth 9 \
        -draw "circle 3000,2000 3000,400" -draw "line 0,0 6000,4000" -draw "line 0,4000 6000,0" \
        -stroke black -strokewidth 3 \
        -draw "line 1000,0 1000,4000" -draw "line 2000,0 2000,4000" -draw "line 4000,0 4000,4000" \
        -draw "line 5000,0 5000,4000" -draw "line 0,1000 6000,1000" -draw "line 0,3000 6000,3000" \
        -quality 95 "$INPUT"
    exiftool -q -overwrite_original -Make=Smoke -Model=Fixture -LensModel="Smoke Lens 35mm" \
        -DateTimeOriginal="2024:05:17 13:45:00" \
        -GPSLatitude=40.6892 -GPSLatitudeRef=N -GPSLongitude=74.0445 -GPSLongitudeRef=W "$INPUT"
fi
echo "input:  $INPUT ($(magick identify -format '%wx%h' "$INPUT"))"
echo "output: $OUT"

# --- Build ---------------------------------------------------------------------------------
swift build -c release --product tiler >/dev/null
TILER="$(swift build -c release --show-bin-path)/tiler"

# --- 1. Export 3 native tiles (timed) -------------------------------------------------------
rm -rf "$OUT/tiles" "$OUT/single"
/usr/bin/time -l "$TILER" "$INPUT" --out "$OUT/tiles" --tiles 3 >"$OUT/tiles.log" 2>"$OUT/time.log" \
    || { cat "$OUT/time.log" >&2; echo "smoke-export: tiler failed" >&2; exit 1; }
REAL=$(awk '/ real /{print $1}' "$OUT/time.log")
PEAK=$(awk '/peak memory footprint/{printf "%.0f", $1/1048576}' "$OUT/time.log")
RSS=$(awk '/maximum resident set size/{printf "%.0f", $1/1048576}' "$OUT/time.log")
echo "time:   ${REAL}s wall, peak memory ${PEAK} MB (max RSS ${RSS} MB) for 3 native tiles"

TILES=()
while IFS= read -r line; do TILES+=("$line"); done <"$OUT/tiles.log"
if [[ ${#TILES[@]} -eq 3 ]]; then pass "3 tiles written"; else fail "expected 3 tiles, got ${#TILES[@]}"; fi
SIZES=$(for t in "${TILES[@]}"; do magick identify -format '%wx%h\n' "$t"; done | sort -u)
if [[ $(echo "$SIZES" | wc -l | tr -d ' ') -eq 1 ]]; then pass "identical tile size $SIZES"; else fail "tile sizes differ: $SIZES"; fi

# --- 2. Seams -------------------------------------------------------------------------------
"$TILER" "$INPUT" --out "$OUT/single" --tiles 1 --aspect 12:5 >"$OUT/single.log"
SINGLE=$(head -1 "$OUT/single.log")
magick "${TILES[@]}" +append "$OUT/joined.png"
# Floor rounding can make the joined strip up to 2 px narrower than the single render; compare
# the common area.
JW=$(magick identify -format '%w' "$OUT/joined.png"); JH=$(magick identify -format '%h' "$OUT/joined.png")
SW=$(magick identify -format '%w' "$SINGLE");        SH=$(magick identify -format '%h' "$SINGLE")
W=$(( JW < SW ? JW : SW )); H=$(( JH < SH ? JH : SH ))
RMSE_OUT=$(magick compare -metric RMSE \
    \( "$OUT/joined.png" -crop "${W}x${H}+0+0" +repage \) \
    \( "$SINGLE" -crop "${W}x${H}+0+0" +repage \) null: 2>&1 || true)
RMSE=$(sed -E 's/.*\(([0-9.eE+-]+)\).*/\1/' <<<"$RMSE_OUT")
if awk -v r="$RMSE" 'BEGIN { exit !(r + 0 <= 0.01) }'; then
    pass "seams: normalised RMSE $RMSE vs single 12:5 render (joined ${JW}x${JH}, single ${SW}x${SH})"
else
    fail "seams: normalised RMSE $RMSE > 0.01 ($RMSE_OUT)"
fi

# --- 3. Metadata ----------------------------------------------------------------------------
SRC_LENS=$(exiftool -s -s -s -LensModel "$INPUT")
for t in "${TILES[@]}"; do
    name=$(basename "$t")
    GPS=$(exiftool -a -s -G1 "$t" | awk '{print $2}' | grep -i '^GPS' || true)
    [[ -z "$GPS" ]] && pass "$name: no GPS tags" || fail "$name: GPS tags present: $(echo $GPS)"
    MAKER=$(exiftool -a -s -s -s -MakerNotes:all "$t")
    [[ -z "$MAKER" ]] && pass "$name: no maker notes" || fail "$name: maker notes present"
    ORI=$(exiftool -s -s -s -n -Orientation "$t")
    [[ -z "$ORI" || "$ORI" == 1 ]] && pass "$name: Orientation ${ORI:-absent}" || fail "$name: Orientation $ORI"
    if [[ -n "$SRC_LENS" ]]; then
        LENS=$(exiftool -s -s -s -LensModel "$t")
        [[ "$LENS" == "$SRC_LENS" ]] && pass "$name: LensModel '$LENS'" || fail "$name: LensModel '$LENS' != '$SRC_LENS'"
    fi
    ICC=$(exiftool -s -s -s -ProfileDescription "$t")
    CS=$(exiftool -s -s -s -ExifIFD:ColorSpace "$t")
    IM_CS=$(magick identify -format '%[colorspace]' "$t")
    if [[ "$ICC" == *sRGB* ]]; then
        pass "$name: ICC profile '$ICC'"
    elif [[ -z "$ICC" && "$CS" == sRGB && "$IM_CS" == sRGB ]]; then
        pass "$name: sRGB via EXIF ColorSpace (no ICC; ImageIO omits it for sRGB)"
    else
        fail "$name: not tagged sRGB (ICC '$ICC', EXIF ColorSpace '$CS', ImageMagick '$IM_CS')"
    fi
done

if [[ $FAILED -ne 0 ]]; then echo "smoke-export: FAILED ($OUT)" >&2; exit 1; fi
echo "smoke-export: passed"
