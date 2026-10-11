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

**Všechny příkazy:** `make` (nápověda), `make install`, `make dev`, `make run`, `make stop`, `make restart`, `make clean`, `make uninstall`, `make icon`, `make preview` (hned ukáže cvičení očí), `make notch` (hned rozbalí notch).


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
- **Notch:** černý výřez kamery s jemným obrysem (na Macu bez výřezu malá kapsle nahoře uprostřed).
  - *Klid:* jen výřez, nic nepřekrývá lištu (ani u aplikací na celou obrazovku).
  - *Najetí myší:* po stranách ikona a čas focusu; když do 30 min začíná schůzka, vlevo minuty do ní.
  - *Kliknutí* (nebo **⌃⌥ mezerník**): panely **Focus**, **Hudba**, **Odkladiště**, **Schránka**. Esc zavře.
  - *Hudba:* Apple Music / Spotify, ovládání a animovaný vizualizér (syntetický – skutečná analýza
    zvuku by vyžadovala oprávnění k nahrávání obrazovky).
  - *Odkladiště:* přetáhni soubory na notch, odtud je vytáhneš kamkoli (kopie). Mezerník = rychlý náhled,
    pravé tlačítko = otevřít / AirDrop / Finder / odebrat. Volitelně se soubor po vytažení sám odebere.
  - *Schránka:* posledních 10 zkopírovaných textů (jen v paměti, hesla ze správců hesel se ignorují).
    Kliknutí zkopíruje zpět. **⌃⌥ V** otevře rovnou schránku.
- **Hlídač rozptýlení:** během focusu sleduje aplikace (Discord, Telegram…) a weby (YouTube, Instagram…)
  v Safari, Chrome, Arc, Brave a Edge. Když tam odskočíš, notch tě tvrdě upozorní a ztracený čas se
  započítá do statistik. Seznamy upravíš v nastavení.
- **Nabídka focusu:** když 3 minuty aktivně pracuješ v pracovní aplikaci (VS Code, Cursor, Xcode,
  ClickUp, Figma, Notion – upravitelné) a focus neběží, notch se zeptá, jestli ho spustit.
- **Statistiky:** čistý čas práce dnes, denní cíl, série dní se splněným cílem, graf týdne, ztracený čas
  a tvrdé hodnocení dne. V okně z lišty i v panelu Focus.
- **Klávesové zkratky:** ⌃⌥ mezerník notch · ⌃⌥ ↩ start/pauza · ⌃⌥ V schránka.
- **Nerušit během focusu:** v aplikaci Zkratky vytvoř dvě zkratky s akcí *Nastavit režim soustředění*:
  „FocusGlass On“ (Nerušit zapnout) a „FocusGlass Off“ (vypnout). FocusGlass je spouští sám.
- **Schůzky:** po zapnutí v nastavení se zeptá na přístup ke Kalendáři.
- **Spustit po přihlášení** přes `SMAppService.mainApp`.
- Při uspání Macu, vypnutí displeje nebo přepnutí uživatele se časovač pozastaví.

## Šedý iPhone během focusu

Mac iPhone přímo ovládat nesmí, ale jde to řetězem přes režimy soustředění:

1. **Mac → Nastavení systému → Soustředění:** vytvoř režim „Deep Work“ (nebo použij Nerušit)
   a zapni **Sdílet mezi zařízeními**.
2. **Mac → Zkratky:** zkratky „FocusGlass On“ / „FocusGlass Off“ s akcí *Nastavit režim soustředění*
   → Deep Work zapnout / vypnout. Ve FocusGlass zapni *Nerušit během focusu*.
3. **iPhone → Nastavení → Zpřístupnění → Displej a velikost textu → Barevné filtry:** filtr nastav
   na *Odstíny šedé* (samotný přepínač nech vypnutý).
4. **iPhone → Zkratky → Automatizace → Nová:** *Soustředění* → Deep Work → *Při zapnutí* →
   *Spustit okamžitě* → akce **Nastavit barevné filtry: Zapnout**. Druhá automatizace
   *Při vypnutí* → **Vypnout**.

Start focusu na Macu → Deep Work se zapne i na iPhonu → iPhone zešedne. Konec focusu → barvy zpět.

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

## Autor a licence

**Autor:** Jiří Posavád · [LinkedIn](https://linkedin.com/jiří-posavád)

Licence: jen **osobní, nekomerční použití**, viz [LICENSE](LICENSE). Bez písemného svolení autora je zakázáno:
- aplikaci nebo její části prodávat, přeprodávat a jakkoli komerčně využívat,
- ji šířit, ať v původní, nebo upravené podobě,
- odstranit jméno a profil autora z aplikace, kódu nebo dokumentace.
