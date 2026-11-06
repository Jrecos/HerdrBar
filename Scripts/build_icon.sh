#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$ROOT/.build/icon"
ICONSET="$WORK/Icon.iconset"
mkdir -p "$ICONSET"
swift "$ROOT/Scripts/render_icon.swift" "$WORK/Icon.png"
for size in 16 32 128 256 512; do
  sips -z "$size" "$size" "$WORK/Icon.png" --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
  double=$((size * 2))
  sips -z "$double" "$double" "$WORK/Icon.png" --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$ROOT/Icon.icns"
echo "Created Icon.icns"
