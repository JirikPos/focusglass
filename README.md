# FocusGlass

Ultra-lehká macOS aplikace v liště: **Pomodoro pro hlubokou práci** + **péče o oči 20-20-1**.
Nativní Swift + SwiftUI, macOS 14 Sonoma a novější, bez ikony v Docku.

## Jak to zapnout (rychlý start)

1. Otevři Terminál ve složce projektu a spusť:
   ```bash
   make install
   ```
2. V horní liště vpravo (u hodin) se objeví ikona oka v kruhu. Klikni na ni.
3. Vyber profil (90/15, 60/10 nebo 45/5) a stiskni ▶ (nebo mezerník).
4. Ozubené kolo → zapni **Spustit po přihlášení**. Od té doby se aplikace spouští sama.

Ruční spuštění: Spotlight (⌘ mezerník) → „FocusGlass“, nebo `open /Applications/FocusGlass.app`.
Ukončení: ikona v liště → *Ukončit FocusGlass* (nebo ⌘Q v otevřeném okně).
Aplikace nemá ikonu v Docku. To je záměr.

**Po úpravě kódu** stačí znovu spustit `make install`. Skript starou verzi ukončí a nahradí.

**Odinstalace:** v nastavení vypni *Spustit po přihlášení*, aplikaci ukonči a smaž `/Applications/FocusGlass.app`.

**Všechny příkazy:** `make` (nápověda), `make install`, `make dev`, `make run`, `make stop`, `make restart`, `make clean`, `make uninstall`, `make icon`, `make preview` (hned ukáže cvičení očí).


## Funkce

- **Vzhled:** monochromatické matně černé sklo, žádné barvy. Aplikace je vždy v tmavém režimu.
- **Profily:** 90/15 (výchozí), 60/10, 45/5 minut. Play / Pause (mezerník), Skip, Reset.
- **Péče o oči 20-20-1:** po každých 20 minutách práce ztmavne celá obrazovka (všechny monitory)
  a na 1 minutu proběhne cvičení „Rest your eyes“:
  1. *Look far away*: kruhy se stahují do dálky, zaostři na vzdálený bod.
  2. *Follow the dot*: sleduj tečku putující po osmičce, hlava zůstává v klidu.
  3. *Close your eyes*: dýchající kruh, konec ohlásí zvuk.

  Dole se zkracuje tenká linka a ukazuje zbývající čas. Pomodoro se během cvičení zastaví a pak samo pokračuje.
  Přeskočíš ho klávesou **Esc** nebo tlačítkem *Skip*. Poslední 2 minuty před pauzou se nezobrazí.
- **Pauza teď:** tlačítko v okně z lišty spustí cvičení hned a časovač mezitím pozastaví.
- **Velká pauza:** po skončení bloku se ukáže tmavá obrazovka „Take a break“ s odpočtem přes celou obrazovku.
  *Skip break* pauzu ukončí, *Hide* / **Esc** jen skryje obrazovku a pauza běží dál v liště.
  Další blok začne ručně, nebo automaticky s *Po pauze pokračovat*.
- **Detekce odchodu:** když se 1, 2 nebo 5 minut (nastavitelné) nedotkneš myši ani klávesnice, časovač se zastaví
  a čas strávený mimo počítač se do práce nezapočítá. Po návratu se sám rozběhne
  a další připomínka pro oči přijde až za 20 minut. Detekce nepotřebuje žádná oprávnění.
- **Spustit po přihlášení** přes `SMAppService.mainApp`.
- Při uspání Macu, vypnutí displeje nebo přepnutí uživatele se časovač pozastaví.

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

## Struktura

| Soubor | Obsah |
|---|---|
| `FocusGlassApp.swift` | `@main`, `MenuBarExtra` a štítek v liště |
| `AppModel.swift` | propojení časovače, nastavení, overlaye a zvuků |
| `FocusTimer.swift` | stavový automat práce/pauzy, plánování 20-20-1, detekce odchodu |
| `Overlay.swift` | tmavé overlaye přes všechny obrazovky, Esc, auto-zavření |
| `EyeExercise.swift` | kroky a animace cvičení očí (`Canvas`) |
| `ContentView.swift` | okno z lišty: profily, odpočet, ovládání, oči, citát |
| `SettingsView.swift` | nastavení včetně spouštění po přihlášení |
| `GlassStyle.swift` | skleněný panel, tlačítka, prstenec, zkracující se linka |
| `Quotes.swift` | 32 tvrdých anglických citátů (Goggins, Tate, podnikatelé, disciplína) |
| `LaunchAtLogin.swift` | obal nad `SMAppService.mainApp` |

## Výkon

- Když časovač neběží, neexistuje žádný `Timer` a aplikace nic nedělá.
- Za běhu tiká jediný `Timer` 1× za sekundu s tolerancí 0,25 s (macOS může tiky slučovat).
  Zbývající čas se počítá z cílového `Date`, takže tik slouží jen k překreslení.
- Při detekci odchodu kontroluje nečinnost 1× za sekundu jen v době, kdy jsi pryč.
- Overlay okna vznikají až při zobrazení a hned po zavření se uvolní.
- Naměřeno (Apple Silicon, macOS 26): **footprint ~15 MB** po startu, ~26 MB po prvním overlayi
  (SwiftUI si nechá vykreslovací cache), 0 % CPU v klidu. Během minutového cvičení animace
  ve 30 fps zabere ~14 % jednoho jádra.
  RSS v `ps` ukazuje víc, protože započítává sdílené systémové frameworky.
