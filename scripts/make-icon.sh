#!/usr/bin/env bash
set -euo pipefail

# Regenerate Assets/AppIcon.icns from Sources/Resources/OpenClawLogo.svg
# Requires: rsvg-convert (brew install librsvg), iconutil (built-in)

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SVG="$ROOT/Sources/Resources/OpenClawLogo.svg"
ICONSET="$(mktemp -d)/Clawmac.iconset"
OUT="$ROOT/Assets/AppIcon.icns"

if [[ ! -f "$SVG" ]]; then
  echo "error: $SVG not found" >&2
  exit 1
fi

if ! command -v rsvg-convert >/dev/null 2>&1; then
  echo "error: rsvg-convert not found. Install with: brew install librsvg" >&2
  exit 1
fi

mkdir -p "$ICONSET"

for s in 16 32 64 128 256 512 1024; do
  rsvg-convert -w "$s" -h "$s" "$SVG" -o "$ICONSET/icon_${s}x${s}.png"
done

rsvg-convert -w 32   -h 32   "$SVG" -o "$ICONSET/icon_16x16@2x.png"
rsvg-convert -w 64   -h 64   "$SVG" -o "$ICONSET/icon_32x32@2x.png"
rsvg-convert -w 256  -h 256  "$SVG" -o "$ICONSET/icon_128x128@2x.png"
rsvg-convert -w 512  -h 512  "$SVG" -o "$ICONSET/icon_256x256@2x.png"
rsvg-convert -w 1024 -h 1024 "$SVG" -o "$ICONSET/icon_512x512@2x.png"

mkdir -p "$(dirname "$OUT")"
iconutil -c icns "$ICONSET" -o "$OUT"

echo "wrote $OUT"
