# Kolo souborů: architektura

Převody a nástroje se spouštějí kolem, které se otevře při tažení souboru. Kód je ve dvou částech:

```
Sources/ConvertKit/      jádro bez UI (testuje se samostatně)
  Model/                 FileKind, Selection, FileOperation, Tool, ToolOption (schéma voleb)
  Engine/                JobQueue (souběžnost, zrušení), ProcessRunner, ToolLocator, OutputPolicy
  Backends/              ImageIO, AVFoundation, PDFKit, NSAttributedString, ffmpeg, iWork, LibreOffice
  Formats/               Markdown, EPUB, DOCX/XLSX/PPTX zapisovače, titulky, tabulky
  Operations/Catalog     matice převodů (vstup → cíl → cesty)
  Tools/                 nástroje pro ⌘ podle druhu souboru (Image, PDF, Media, Text)
Sources/FocusGlass/Convert/
  Wheel*, DragWatcher    kolo, sledování tažení a modifikátorů
  ConvertService         spojuje kolo, frontu a notch
  Tools/                 okno nástroje (formulář ze schématu voleb, editory)
```

## Tři kola

| Modifikátor | Kolo | Co nabízí |
|---|---|---|
| ⇧ | Převést | `ConvertOperation` z `Catalog.conversions()` |
| ⌘ | Nástroje | `Tool` z `ToolCatalog` |
| ⌃ | Akce | AirDrop, Float, Kopírovat, Přesunout, Cesta, Terminál |

Klávesy jdou změnit v nastavení. ⌃⌥K otevře kolo pro soubory vybrané ve Finderu.

## Jak přidat převod

V `Catalog` přidej `ConvertOperation(skupina, to: formát, from: přípony, converter: …)`. Víc cest
(`routes:`) se zkouší popořadě a vybere se první, na kterou jsou nástroje: nativní → ffmpeg / iWork → LibreOffice.
Převodník dostane `ConversionJob` s prázdnou dočasnou složkou a vrátí hotový soubor; ukládání pod unikátní
jméno a atomický přesun řeší `OutputPolicy`.

## Jak přidat nástroj

1. Napiš `Tool(id:, title:, symbol:, options:, editor:, accepts:, preview:, run:)`.
2. `options` je schéma voleb (`ToolOption`) – okno z něj samo sestaví formulář (přepínače, posuvníky,
   výběry, barvy, soubory, skrytá hesla) včetně podmíněné viditelnosti.
3. `preview` (nepovinné) vrací obrázek a popisek pro živý náhled; běží s odkladem a zrušitelně.
4. Složitější vstup (ořez, anotace, krytí, stránky PDF, střih, pořadí souborů) se zadává přes `editor:`;
   data z editoru dorazí do `run` jako `OptionValue.data` (JSON) – `context.decoded(…)`.
5. Zařaď nástroj do `ToolCatalog`. Hotovo – kolo ho nabídne pro soubory, na které `accepts` odpoví ano.

Pravidla, která drží všechny nástroje:
- výsledek jde vedle originálu pod novým jménem „x (štítek).přípona“ a nikdy nepřepíše existující soubor;
- zápis je přes dočasný soubor, takže zrušená nebo selhaná úloha nenechá rozepsaný výsledek;
- dlouhé úlohy hlásí průběh a reagují na zrušení (`Task.checkCancellation()`);
- chyby jsou `ConvertError` s větou pro uživatele, technický detail jde jen do logu.

## Volitelné nástroje

Aplikace funguje i bez nich, jen nabídne méně. Nainstalují se přes Homebrew a najdou se automaticky
(`ToolLocator`); lístek, kterému nástroj chybí, je šedý a ve středu kola řekne, co doinstalovat.

| Nástroj | Pro co | Instalace |
|---|---|---|
| ffmpeg (+ ffprobe) | MKV, WebM, AVI, WMV, MP3, OGG, Opus, WMA; všechny nástroje pro video a zvuk | `brew install ffmpeg` |
| cwebp | zápis WebP | `brew install webp` |
| avifenc | zápis AVIF | `brew install libavif` |
| LibreOffice | ODS, PPT, záloha pro Pages / Keynote / Numbers | `brew install --cask libreoffice` |
| Pages, Keynote, Numbers | export z formátů iWork (AppleScript) | App Store |

## Vývoj

```bash
swift test                                   # všechny testy (video a zvuk se generují ffmpegem)
.build/debug/FocusGlass --render-tool out.png image.tool.compress foto.jpg mode=target targetKB=150
.build/debug/FocusGlass --render-wheel out.png convert foto.png
```

`--render-*` vykreslí okno do PNG ještě před startem `AppModel`, takže se nečte Klíčenka a nic nezůstane běžet.
`--wheel [kolo] [soubor]` ukáže živé kolo uprostřed obrazovky bez tažení.

## Čeho si být vědom

- PDF → DOCX / PPTX / XLSX je vždy přibližné (rekonstrukce rozvržení); v kole je označené ≈.
- Přidání vodoznaku a OCR vykreslí stránky znovu: vektory i text zůstanou, odkazy a formuláře ne.
- Krytí textu v PDF stránku s nalezeným textem převede na obrázek, aby pod černým obdélníkem nic nezůstalo.
- Zip s heslem nejde vytvořit (systémový `zip` umí jen slabé šifrování ZipCrypto); rozbalit se dá.
