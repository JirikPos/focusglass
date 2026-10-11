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

# Stálý podpis (scripts/make-cert.sh), aby si macOS pamatoval oprávnění mezi sestaveními.
# Bez certifikátu ad-hoc podpis – funguje, ale Kalendář/Automatizace se po každém buildu ptají znovu.
IDENTITY="FocusGlass Dev"
if security find-identity -p codesigning | grep -q "\"$IDENTITY\""; then
    if ! codesign --force --sign "$IDENTITY" --timestamp=none "$APP" 2>/dev/null; then
        echo "! Podpis certifikátem „${IDENTITY}“ selhal (codesign nemá přístup ke klíči) – podepisuji ad-hoc."
        echo "  Oprava: security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k <heslo-k-Macu> ~/Library/Keychains/login.keychain-db"
        codesign --force --sign - --timestamp=none "$APP"
    fi
else
    echo "! Certifikát „${IDENTITY}“ chybí (make cert) – podepisuji ad-hoc"
    codesign --force --sign - --timestamp=none "$APP"
fi
echo "✓ Sestaveno: $APP"

if [[ "${1:-}" == "--install" ]]; then
    pkill -x "$APP_NAME" 2>/dev/null || true
    rm -rf "/Applications/${APP_NAME}.app"
    cp -R "$APP" /Applications/
    open "/Applications/${APP_NAME}.app"
    echo "✓ Nainstalováno do /Applications a spuštěno"
fi
