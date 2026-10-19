#!/usr/bin/env bash
# Vytvoří dist/FocusGlass.dmg: otevřeš, přetáhneš FocusGlass do Applications, hotovo.
#   ./scripts/make-dmg.sh
set -euo pipefail
cd "$(dirname "$0")/.."

APP_NAME="FocusGlass"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)"
DMG="dist/${APP_NAME}.dmg"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

BUNDLE_TOOLS="${BUNDLE_TOOLS:-1}" UNIVERSAL=1 ./scripts/build-app.sh

# Složka s aplikací, odkazem na Applications a návodem pro první spuštění.
cp -R "build/${APP_NAME}.app" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
cat > "$STAGE/První spuštění.txt" <<TXT
1. Přetáhni FocusGlass do složky Applications.
2. Otevři Applications, klikni na FocusGlass PRAVÝM tlačítkem → Otevřít → Otevřít.
   (Stačí poprvé. Aplikace není z App Storu, proto se macOS ptá.)
3. Ikona oka se objeví v horní liště vedle hodin.
TXT

mkdir -p dist
rm -f "$DMG"
hdiutil create -volname "${APP_NAME} ${VERSION}" -srcfolder "$STAGE" \
    -fs HFS+ -format UDZO -ov "$DMG" >/dev/null

echo "✓ Hotovo: $DMG ($(du -h "$DMG" | cut -f1))"
