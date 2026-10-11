#!/usr/bin/env bash
# Sestaví FocusGlass.app z Swift Packagu.
#   ./scripts/build-app.sh            → build/FocusGlass.app
#   ./scripts/build-app.sh --install  → navíc zkopíruje do /Applications a spustí
set -euo pipefail
cd "$(dirname "$0")/.."

APP_NAME="FocusGlass"
APP="build/${APP_NAME}.app"

swift build -c release
BIN="$(swift build -c release --show-bin-path)/${APP_NAME}"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/${APP_NAME}"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
strip -x "$APP/Contents/MacOS/${APP_NAME}"

# Ad-hoc podpis stačí pro lokální běh i SMAppService.
codesign --force --sign - --timestamp=none "$APP"
echo "✓ Sestaveno: $APP"

if [[ "${1:-}" == "--install" ]]; then
    pkill -x "$APP_NAME" 2>/dev/null || true
    rm -rf "/Applications/${APP_NAME}.app"
    cp -R "$APP" /Applications/
    open "/Applications/${APP_NAME}.app"
    echo "✓ Nainstalováno do /Applications a spuštěno"
fi
