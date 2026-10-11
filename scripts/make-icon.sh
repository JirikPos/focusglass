#!/usr/bin/env bash
# Vygeneruje Resources/AppIcon.icns (+ náhled Resources/AppIcon.png).
set -euo pipefail
cd "$(dirname "$0")/.."

PNG="Resources/AppIcon.png"
ICONSET="build/AppIcon.iconset"

swift scripts/make-icon.swift "$PNG"

rm -rf "$ICONSET"
mkdir -p "$ICONSET"
for s in 16 32 128 256 512; do
    sips -z $s $s "$PNG" --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
    sips -z $((s * 2)) $((s * 2)) "$PNG" --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o Resources/AppIcon.icns
echo "✓ Resources/AppIcon.icns"
