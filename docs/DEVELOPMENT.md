# FocusGlass: vývoj

Pro lidi, kteří aplikaci upravují. Běžný uživatel to nepotřebuje, viz [README](../README.md).

## Příkazy

`make` (nápověda), `make dmg` (instalační DMG do `dist/`), `make install`, `make dev`, `make run`, `make stop`, `make restart`, `make clean`, `make uninstall`, `make icon`, `make preview` (hned ukáže cvičení očí), `make notch` (hned rozbalí notch).

## Sestavení (doporučeno)

```bash
./scripts/build-app.sh            # → build/FocusGlass.app
./scripts/build-app.sh --install  # navíc zkopíruje do /Applications a spustí
```

Skript spustí `swift build -c release`, složí `.app` bundle s `Resources/Info.plist` (`LSUIElement = true`)
a podepíše ho ad-hoc podpisem.

> **Spustit po přihlášení** spolehlivě funguje jen u aplikace v `/Applications`, proto použij `--install`.
> Pokud macOS vyžaduje schválení, v nastavení aplikace se objeví tlačítko *Otevřít*
> (Nastavení systému → Obecné → Přihlašovací položky).

## Vývoj v Xcode

**Rychle:** `open Package.swift` otevře balíček v Xcode. Na úpravy UI a logiky to stačí, ale binárka neběží
jako bundle, takže se v Docku objeví ikona a *Spustit po přihlášení* nefunguje. Pro finální build použij skript.

**Plnohodnotný Xcode projekt:**

1. Xcode → *File → New → Project → macOS → App*. Název `FocusGlass`, Interface *SwiftUI*, Language *Swift*.
2. Smaž vygenerované `FocusGlassApp.swift` a `ContentView.swift` a přetáhni do projektu všechny soubory
   ze `Sources/FocusGlass/`.
3. Target → *General* → *Minimum Deployments*: **macOS 14.0**.
4. Target → *Info* → přidej klíč **Application is agent (UIElement)** = `YES` (`LSUIElement`).
5. Target → *Signing & Capabilities*: App Sandbox může zůstat zapnutý, aplikace nic dalšího nepotřebuje.
6. ⌘R.

## Architektura

```
Sources/FocusGlass/
├── App/           vstupní bod, AppModel (propojuje všechny funkce)
├── Core/          nastavení, citáty, spouštění po přihlášení, klávesové zkratky
├── DesignSystem/  sklo, tlačítka, prstenec, linka, prázdné stavy
├── MenuBar/       okno z lišty a nastavení
├── Focus/         časovač, cvičení očí, tmavé overlaye, Nerušit, panel Focus pro notch
├── Notch/         okno notche, tvar, hover, registr panelů (NotchTab)
├── Media/         Apple Music / Spotify + panel Hudba s vizualizérem
├── Shelf/         odkladiště souborů, rychlý náhled, AirDrop + panel Odkladiště
├── Clipboard/     historie schránky + panel Schránka
├── Calendar/      nejbližší schůzka (EventKit)
├── Guard/         hlídač rozptýlení
└── Stats/         denní statistiky, série, hodnocení
```

**Jak přidat novou funkci do notche:**
1. Nová složka, např. `Sources/FocusGlass/Calendar/`, se službou (`@Observable` třída) a view panelu.
2. Službu přidej jako vlastnost do `AppModel`.
3. V `Notch/NotchView.swift` přidej `case` do `NotchTab` (ikona, název, view). Hotovo: tlačítko panelu
   se v notchi objeví samo.

## Výkon

- Když časovač neběží, neexistuje žádný `Timer` a aplikace nic nedělá.
- Za běhu tiká jediný `Timer` 1× za sekundu s tolerancí 0,25 s (macOS může tiky slučovat).
  Zbývající čas se počítá z cílového `Date`, takže tik slouží jen k překreslení.
- Při detekci odchodu kontroluje nečinnost 1× za sekundu jen v době, kdy jsi pryč.
- Overlay okna vznikají až při zobrazení a hned po zavření se uvolní.
- **Notch:** okno má vždy jen velikost aktuálního tvaru (nic dalšího neblokuje), hover hlídá systémová
  „tracking area“ (události, žádné dotazování), hudba se čte ze systémových notifikací Music/Spotify.
  Sbalený a nečinný notch = statická černá plocha, 0 % CPU. Animace běží jen při rozbalení/sbalení.
- Naměřeno (Apple Silicon, macOS 26): **footprint ~15 MB** po startu, ~17–21 MB s notchem, ~26 MB po prvním overlayi
  (SwiftUI si nechá vykreslovací cache), 0 % CPU v klidu. Během minutového cvičení animace
  ve 30 fps zabere ~14 % jednoho jádra.
  RSS v `ps` ukazuje víc, protože započítává sdílené systémové frameworky.
