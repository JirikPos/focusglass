#!/usr/bin/env bash
# Přibalí ffmpeg, ffprobe, cwebp a avifenc (i s knihovnami) do FocusGlass.app, aby aplikace
# fungovala po instalaci hned, bez Homebrew.
#   ./scripts/bundle-tools.sh build/FocusGlass.app
#
# Zdroj: nástroje nainstalované přes Homebrew (brew install ffmpeg webp libavif).
# Binárky jsou jen pro architekturu tohoto Macu (Apple Silicon → arm64); na jiné architektuře
# aplikace sáhne po nástrojích nainstalovaných v systému.
set -euo pipefail
cd "$(dirname "$0")/.."

APP="${1:?použití: bundle-tools.sh cesta/k/FocusGlass.app}"
RES="$APP/Contents/Resources"
BIN="$RES/bin"
LIB="$RES/lib"
TOOLS=(ffmpeg ffprobe cwebp avifenc)

for tool in "${TOOLS[@]}"; do
    command -v "$tool" >/dev/null || { echo "! Chybí $tool: brew install ffmpeg webp libavif"; exit 1; }
done

rm -rf "$BIN" "$LIB"
mkdir -p "$BIN" "$LIB"

for tool in "${TOOLS[@]}"; do
    cp "$(command -v "$tool")" "$BIN/$tool"
    chmod u+w "$BIN/$tool"
done

# Všechny knihovny do jedné složky; cesty v binárkách přepsat na relativní k balíčku.
# (dylibbundler se u ffmpeg zacyklil, proto vlastní skript.)
python3 scripts/relocate_libs.py "$BIN" "$LIB"

# Úprava binárek neplatí podpis; na Apple Silicon bez podpisu nic nespustí.
find "$LIB" -name '*.dylib' -print0 | xargs -0 -n1 codesign --force --sign - --timestamp=none 2>/dev/null
for tool in "${TOOLS[@]}"; do codesign --force --sign - --timestamp=none "$BIN/$tool"; done

# Přibalené programy běží jen na architektuře, na které vznikly; aplikace si to před použitím ověří.
uname -m > "$BIN/.arch"

# Kontrola: nic nesmí odkazovat mimo balíček.
bad=0
for file in "$BIN"/* "$LIB"/*.dylib; do
    if otool -L "$file" | tail -n +2 | grep -E '/opt/homebrew|/usr/local' >/dev/null; then
        echo "! $file pořád odkazuje na Homebrew"; bad=1
    fi
done
[[ $bad == 0 ]] || exit 1

# Licence: ffmpeg se x264 / x265 je GPL – k aplikaci patří upozornění a odkaz na zdroj.
FFMPEG_VERSION="$("$BIN/ffmpeg" -version | head -1)"
cat > "$RES/THIRD-PARTY.txt" <<TXT
FocusGlass obsahuje samostatné programy třetích stran (spouští se jako vlastní procesy):

  ffmpeg, ffprobe   $FFMPEG_VERSION
                    Licence GPL v2+ (sestavení s libx264 a libx265). https://ffmpeg.org
                    Zdrojové kódy: https://ffmpeg.org/download.html
  cwebp             WebP, licence BSD-3. https://developers.google.com/speed/webp
  avifenc           libavif, licence BSD-2. https://github.com/AOMediaCodec/libavif

Použité knihovny (x264, x265, libvpx, opus, lame, aom a další) leží ve složce lib/ a řídí se
svými licencemi; seznam vypíše příkaz: ffmpeg -version.
Programy jsou beze změny převzaté z distribuce Homebrew (https://brew.sh).
TXT

echo "✓ Nástroje přibaleny: $(du -sh "$RES/bin" "$RES/lib" | awk '{printf "%s %s  ", $2, $1}')"
