# Ritmo, stato dei servizi e finestra Spesa — piano di implementazione

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Aggiungere a LimitBar il ritmo dei limiti, lo stato dei servizi e una finestra Spesa, come descritto nello spec.

**Architecture:** Tre parti indipendenti. Ognuna ha una parte pura e testata (`Pace`, `ServiceStatusReader`, `SpendReport`) e una parte d'interfaccia che la mostra (pannello, icona nella barra dei menu, finestra). I dati di stato passano da `UsageStore`, come quelli dei limiti.

**Tech Stack:** Swift 6.4 (tools 5.10, modalità Swift 5), SwiftUI + AppKit, Swift Charts, Swift Testing; solo Command Line Tools, niente Xcode.

**Spec:** `docs/superpowers/specs/2026-10-31-ritmo-stato-spesa-design.md`

## Global Constraints

- Solo Command Line Tools: niente macro SwiftUI (`@State`, `@Observable`); stato locale con `@StateObject` / `ObservableObject` (vedi `HoverState` in `PanelView.swift`).
- Interfaccia in italiano; commenti nel codice in inglese, nello stile dei file vicini (doc comment `///` sopra ogni tipo e funzione non banale).
- Menu bar: l'immagine base resta sempre template; ciò che ha colore va solo nel livello `colour` di `Icons.StatusLabel`.
- Colori: arancione `NSColor.systemOrange`, rosso `.systemRed`, verde `.systemGreen`; testo neutro `.secondary`.
- Soglie dello spec: ritmo ±5 punti, nascosto sotto il 10% della finestra; stato controllato ogni 5 minuti, all'apertura del pannello se ha più di 2 minuti, tenuto 30 minuti se la pagina non risponde.
- Ogni `./build.sh` incrementa `build-number`: va nel commit della parte.
- Nessun remote, nessun push, nessun invio a Telegram.

## Review Focus

1. Una finestra con `resetsAt` più lontano della sua durata (orologio sballato, dati vecchi): niente ritmo, niente tacca. Test in Task 1.
2. Pagina di stato che risponde HTML o JSON troncato (Wi‑Fi con portale, errore del server): nessuna striscia nuova; l'ultimo stato valido resta fino a 30 minuti, poi sparisce. Test in Task 3 e Task 4.
3. Interruttore dello stato spento: nessuna richiesta, nessun puntino, nessuna striscia, anche se prima c'era un disservizio. Test in Task 4.
4. Periodo di 7 o 30 giorni a cavallo di un cambio di mese o di anno: i giorni giusti, in ordine. Test in Task 6.
5. Nessuna spesa nel periodo (Mac nuovo, registro con 2 giorni): totale 0, quote 0 senza divisioni per zero, un giorno per ogni giorno del periodo. Test in Task 6.

---

### Task 1: Target di test e calcolo del ritmo

**Files:**
- Modify: `Package.swift`
- Create: `Sources/LimitBar/Pace.swift`
- Test: `Tests/LimitBarTests/PaceTests.swift`

**Interfaces:**
- Produces:
  ```swift
  struct Pace: Equatable {
      enum State: Equatable { case onTrack, ahead, behind }
      let expected: Double     // share of the window elapsed, 0...1
      let difference: Double   // used percent − expected percent, in points
      var state: State { get }
      var text: String { get } // "In linea", "12% in anticipo", "12% di margine"
      static let tolerance = 5.0
      static let minimumElapsed = 0.10
      static func of(_ window: UsageWindow, now: Date) -> Pace?
  }
  ```

- [ ] **Step 1: Aggiungi il target di test a `Package.swift`**

```swift
.testTarget(name: "LimitBarTests", dependencies: ["LimitBar"], path: "Tests/LimitBarTests",
            swiftSettings: [.unsafeFlags(["-plugin-path", "/Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing"])]),
```

(Verificato il 31/10/2026: `@testable import LimitBar` di un `executableTarget` compila e gira con i soli CLT.)

- [ ] **Step 2: Scrivi i test che falliscono** — `import Testing`, `@testable import LimitBar`. Finestra di 7 giorni (`windowMinutes: 10080`), `now` fisso, `resetsAt = now + 3,5 giorni` (trascorso 0,5) salvo dove indicato:
  - `usedPercent 50` → `state == .onTrack`, `text == "In linea"`, `expected == 0.5`
  - `70` → `.ahead`, `difference == 20`, `text == "20% in anticipo"`
  - `30` → `.behind`, `text == "20% di margine"`
  - `54.9` → `.onTrack`; `55` → `.ahead`, `"5% in anticipo"`; `45` → `.behind`, `"5% di margine"`
  - `resetsAt = now + 0,95 × 7 giorni` (trascorso 0,05) → `nil`
  - `resetsAt = now + 8 giorni` (più lungo della finestra) → `nil` (Review Focus 1)
  - `resetsAt = now − 1 minuto` → `nil`
  - `usedPercent 99.6` → `nil`
  - `windowMinutes nil` → `nil`; `resetsAt nil` → `nil`

- [ ] **Step 3: Esegui e verifica che fallisca** — `swift test --filter PaceTests` → errore di compilazione «cannot find 'Pace' in scope».

- [ ] **Step 4: Implementa `Pace.of(_:now:)` in `Sources/LimitBar/Pace.swift`** — formule dello spec: `inizio = resetsAt − windowMinutes×60`, `expected = (now − inizio)/durata`; `nil` se `expected < minimumElapsed`, se `resetsAt <= now` o se `effectivePercent(at: now) >= UsageWindow.exhausted`. `difference = effectivePercent − expected×100`; `|difference| < tolerance` → `.onTrack`. Il numero nel testo è `Int(abs(difference).rounded())`.

- [ ] **Step 5: Esegui i test** — `swift test --filter PaceTests` → tutti superati.

### Task 2: Ritmo nel pannello (tacca e riga) — commit della parte 1

**Files:**
- Modify: `Sources/LimitBar/PanelView.swift` (`Gauge` 123–157, `LimitsCard` 300–306, `OpenCodeCard.gauge` ~454–460)

**Interfaces:**
- Consumes: `Pace.of(_:now:)`, `Pace.expected`, `Pace.state`, `Pace.text` (Task 1).
- Produces: `Gauge(title:percent:tint:lines:pace:)` con `pace: Pace? = nil`.

- [ ] **Step 1: `Gauge` riceve `var pace: Pace? = nil`.** Se c'è:
  - tacca: un `Path` radiale dentro lo `ZStack` dell'anello, da raggio `(ring − ringLine)/2 − 1` a `(ring + ringLine)/2 + 1`, all'angolo `expected × 360° − 90°`, tratto 1,5 pt, `Color.secondary`, disegnato dopo l'arco;
  - riga: dopo le `lines`, `Text(pace.text)` a 10,5 pt `.medium`, colore per stato: `.onTrack` → `.secondary`, `.ahead` → `systemOrange`, `.behind` → `systemGreen`;
  - `.help("Dove saresti usando il limite in modo costante fino al reset")` sulla riga.
- [ ] **Step 2: `LimitsCard`** passa `pace: Pace.of(window, now: now)` a ogni limite tranne il primo (5 ore). **`OpenCodeCard.gauge`** lo passa per settimana e mese, non per le 5 ore (aggiungi un parametro `pace: Bool` o confronta `period.label`).
- [ ] **Step 3: Verifica** — `swift build` senza errori; `./build.sh --install`; `~/Applications/LimitBar.app/Contents/MacOS/LimitBar --render <scratchpad>/pace.png` e `--dark`: tacca e riga sotto «Settimana» di Claude e sotto settimana e mese di OpenCode, niente sotto le 5 ore. Per vedere una riga anche a inizio settimana: `LIMITBAR_RENDER_OPENCODE_SAMPLE=1` (mese iniziato 10 giorni prima).
- [ ] **Step 4: Commit**

```bash
git add Package.swift Sources/LimitBar/Pace.swift Sources/LimitBar/PanelView.swift Tests docs build-number
git commit -m "Ritmo dei limiti: tacca sull'anello e «in linea / in anticipo / di margine» (1.0 (<build>))"
```

### Task 3: Lettura delle pagine di stato (pura)

**Files:**
- Create: `Sources/LimitBar/ServiceStatus.swift`
- Test: `Tests/LimitBarTests/ServiceStatusTests.swift` (JSON di esempio come stringhe nel file di test)

**Interfaces:**
- Produces:
  ```swift
  enum ServiceHealth: Int, Comparable { case operational, maintenance, degraded, outage }
  struct ServiceStatus: Equatable {
      let health: ServiceHealth
      let text: String?        // nil when operational
      let page: URL
      let checkedAt: Date
  }
  enum ServiceStatusReader {
      static let claudePage: URL      // https://status.claude.com
      static let claudeSummary: URL   // https://status.claude.com/api/v2/summary.json
      static let openCodePage: URL    // https://status.opencode.ai
      static let openCodeStatus: URL  // https://status.opencode.ai/api/status
      static func parseClaude(_ data: Data, at date: Date) -> ServiceStatus?
      static func parseOpenCode(_ data: Data, model: (id: String, name: String)?, at date: Date) -> ServiceStatus?
      /// Last good status kept up to 30 minutes when the new read failed.
      static func merged(previous: ServiceStatus?, fresh: ServiceStatus?, now: Date) -> ServiceStatus?
  }
  ```
  `nil` = sconosciuto (illeggibile, `stale`, tutti i componenti sconosciuti).

- [ ] **Step 1: Scrivi i test che falliscono**
  - Claude, tutto `operational` → `health == .operational`, `text == nil`.
  - Claude Code `degraded_performance` + incidente aperto «Elevated errors on Opus» che lo elenca → `.degraded`, `text == "Claude Code: prestazioni ridotte · Elevated errors on Opus"`.
  - «Claude API (api.anthropic.com)» `major_outage`, Claude Code `partial_outage` → `.outage`, testo che inizia con `"API di Claude: disservizio grave"`.
  - claude.ai `under_maintenance` → `.maintenance`, `"claude.ai: manutenzione in corso"`.
  - «Claude Cowork» `major_outage`, gli altri `operational`, incidente che elenca solo Cowork → `.operational`, `text == nil`.
  - Incidente senza componenti con Claude Code `degraded_performance` → il titolo compare nel testo.
  - OpenCode `go` operativo, modello `deepseek-v4.1-flash` `degraded`/`latency` in `breakdown`, `model: ("deepseek-v4.1-flash", "DeepSeek V4.1 Flash")` → `.degraded`, `"DeepSeek V4.1 Flash: rallentato"`.
  - OpenCode `go` `outage`/`errors`, modello operativo → `.outage`, `"OpenCode Go: errori"`.
  - OpenCode `go` `degraded`/`none` → `"OpenCode Go: prestazioni ridotte"`; `outage`/`none` → `"OpenCode Go: non disponibile"`.
  - OpenCode `"stale": true` → `nil`.
  - `Data("<html>".utf8)` per entrambe → `nil` (Review Focus 2).
  - `merged(previous: p (checkedAt now−10 min), fresh: nil, now)` → `p`; con `checkedAt now−31 min` → `nil`; con `fresh` non nil → `fresh`.

- [ ] **Step 2: Esegui e verifica che fallisca** — `swift test --filter ServiceStatusTests` → «cannot find 'ServiceStatusReader'».

- [ ] **Step 3: Implementa** con `JSONSerialization`, nello stile di `Parse`. Valori fissati dallo spec:
  - componenti Claude considerati e nome nella frase: `"Claude Code"` → «Claude Code», `"Claude API (api.anthropic.com)"` → «API di Claude», `"claude.ai"` → «claude.ai»;
  - Statuspage: `degraded_performance`, `partial_outage` → degraded; `major_outage` → outage; `under_maintenance` → maintenance; `operational` → operational; altro → ignorato;
  - parole: degraded «prestazioni ridotte», outage «disservizio grave», maintenance «manutenzione in corso»; testo `"<nome>: <parola>"` + `" · <titolo>"` del primo incidente pertinente;
  - OpenCode: `degraded` → degraded, `outage` → outage, `operational` → operational, altro → sconosciuto; a parità vince il modello; motivo `errors` → «errori», `latency` → «rallentato», altrimenti «prestazioni ridotte» (degraded) / «non disponibile» (outage).

- [ ] **Step 4: Esegui i test** — `swift test --filter ServiceStatusTests` → tutti superati.

### Task 4: Controllo periodico in `UsageStore` e interruttore

**Files:**
- Modify: `Sources/LimitBar/ServiceStatus.swift` (lettura di rete), `Sources/LimitBar/UsageStore.swift`, `Sources/LimitBar/Settings.swift`, `Sources/LimitBar/OpenCode.swift` (nome del modello)
- Test: `Tests/LimitBarTests/ServiceStatusTests.swift`

**Interfaces:**
- Consumes: `ServiceStatusReader.parseClaude/parseOpenCode/merged` (Task 3).
- Produces:
  - `ServiceStatusReader.fetch(_ id: ProviderID, model: (id: String, name: String)?) async -> ServiceStatus?` (`URLSession.shared`, timeout 15 s; `.claude` e `.opencode`, `nil` per gli altri);
  - `ServiceStatusReader.checks(_ id: ProviderID) -> Bool` (true per `.claude`, `.opencode`);
  - `UsageStore.serviceStatus: [ProviderID: ServiceStatus]` (`@Published private(set)`);
  - `UsageStore.checkServiceStatus(force: Bool = false) async`;
  - `AppSettings.checkServiceStatus: Bool` (chiave `settings.checkServiceStatus`, predefinito `true`);
  - `OpenCodeProvider.modelName(_ id: String) -> String?` (nome dalla tabella `allowances`).

- [ ] **Step 1: Test che fallisce** — `UsageStore.statusesAfterCheck(previous:fresh:enabled:providers:now:) -> [ProviderID: ServiceStatus]`, funzione statica pura che `checkServiceStatus` usa:
  - `enabled: false` con un disservizio in `previous` → dizionario vuoto (Review Focus 3);
  - `providers: [.claude]` con `fresh` anche per `.opencode` → solo `.claude`;
  - `fresh[.claude] == nil`, `previous[.claude]` di 10 minuti prima → resta `previous[.claude]`.
- [ ] **Step 2: Esegui** — `swift test --filter ServiceStatusTests` → fallisce.
- [ ] **Step 3: Implementa.**
  - `checkServiceStatus(force:)`: esce se è passato meno di `force ? 120 : 300` secondi dall'ultimo controllo. Con l'interruttore spento non fa richieste e svuota `serviceStatus`. Altrimenti legge in parallelo i servizi visibili che `checks`, e assegna `statusesAfterCheck(...)`.
  - Il modello per OpenCode: `id = OpenCodeActivity.currentModel()`, `name = OpenCodeProvider.modelName(id) ?? id`.
  - Chiamata in fondo a `refresh(force:)`, solo se `isOnline`, e da `refreshIfStale()` con `force: true`.
  - Interruttore in `SettingsView`, sezione «Pannello»: «Controlla lo stato dei servizi», con nota «Legge le pagine di stato di Anthropic e OpenCode ogni 5 minuti.» Cambiarlo chiama `settingsChanged()`, già osservato.
- [ ] **Step 4: Esegui** — `swift test` → tutti superati; `swift build` senza errori.

### Task 5: Striscia nel pannello e puntino sull'icona — commit della parte 2

**Files:**
- Modify: `Sources/LimitBar/PanelView.swift`, `Sources/LimitBar/Icons.swift` (`StatusPart` ~308, `statusLabel` ~346), `Sources/LimitBar/UsageStore.swift` (`statusLabel` ~431)

**Interfaces:**
- Consumes: `UsageStore.serviceStatus`, `ServiceStatus.health/text/page` (Task 3–4).
- Produces: `Icons.StatusPart.statusDot: NSColor?` (predefinito `nil`).

- [ ] **Step 1: Pannello.** Vista privata `ServiceStatusStrip(status: ServiceStatus?)`, che non mostra nulla se `nil` o `.operational`:
  - `.degraded` → `Banner(symbol: "exclamationmark.triangle.fill", color: systemOrange)`;
  - `.outage` → `Banner(symbol: "xmark.octagon.fill", color: systemRed)`;
  - `.maintenance` → `Note(symbol: "wrench.and.screwdriver", …)`.

  La striscia è avvolta in un `Button` `.plain` che apre `status.page` (`NSWorkspace.shared.open`), con `.help("Apri la pagina di stato")`. Va subito dopo `CardHeader` in `LimitsCard` e `OpenCodeCard`, che ricevono `status: store.serviceStatus[id]` da `PanelView`.
- [ ] **Step 2: Icona.** `StatusPart` riceve `var statusDot: NSColor? = nil`. Nel livello colore, `statusLabel` disegna un cerchio di 5 pt di diametro in alto a destra del rettangolo del simbolo (`x = rect.maxX − 4`, `y = rect.maxY − 4`), restando dentro l'immagine. Anche `hasColour` deve tenere conto di `statusDot`. `UsageStore.statusLabel` imposta `statusDot`: `.degraded` → `.systemOrange`, `.outage` → `.systemRed`, altrimenti `nil`.
- [ ] **Step 3: Verifica.**
  - `swift build`, poi `swift test`.
  - Con un disservizio finto: variabile d'ambiente `LIMITBAR_FAKE_STATUS=degraded|outage` letta in `checkServiceStatus`, che salta la rete e restituisce uno stato di prova per Claude, sul modello di `LIMITBAR_RENDER_OPENCODE_SAMPLE`. Poi `--render` con la variabile impostata: striscia arancione o rossa sotto l'intestazione di Claude.
  - Puntino: `./build.sh --install`, quindi si avvia il binario installato con `LIMITBAR_FAKE_STATUS=outage` e si guarda la barra dei menu. Se `screencapture` non ha il permesso, chiedi all'utente di guardarla. La variabile `LIMITBAR_FAKE_STATUS` serve solo per le prove e va documentata accanto a `LIMITBAR_RENDER_OPENCODE_SAMPLE`.
  - Infine si riapre l'app normale.
- [ ] **Step 4: Commit**

```bash
git add Sources Tests build-number
git commit -m "Stato dei servizi: striscia nel pannello e puntino sull'icona (1.0 (<build>))"
```

### Task 6: Somme per periodo (pura)

**Files:**
- Create: `Sources/LimitBar/SpendReport.swift`
- Test: `Tests/LimitBarTests/SpendReportTests.swift`

**Interfaces:**
- Consumes: `CostLedger.Summary` (`totals`, `projects`, `completeSince`, `projectFolders`), `CostLedger.dayKey(_:)`, `OpenCodeProvider.modelName(_:)` (Task 4).
- Produces:
  ```swift
  enum SpendPeriod: String, CaseIterable, Identifiable {
      case today, week, thirtyDays, month
      var title: String          // "Oggi", "7 giorni", "30 giorni", "Questo mese"
      func days(now: Date) -> [String]   // yyyy-MM-dd local, oldest first, today included
  }
  struct SpendReport {
      struct Day: Identifiable { let day: String; let date: Date; let costs: [ProviderID: Double]; var id: String { day } }
      struct Model: Identifiable { let key: String; let title: String; let service: ProviderID; let cost: Double; let tokens: Int; let share: Double; var id: String { "\(service.rawValue)/\(key)" } }
      struct Project: Identifiable { let name: String; let folder: String?; let cost: Double; let share: Double; var id: String { name } }
      let total: Double                        // dollars, from Summary.projects
      let input: Int, output: Int, cacheRead: Int, cacheWrite: Int
      let days: [Day]                          // one per day of the period, zeros included
      let models: [Model]                      // by cost, highest first
      let projects: [Project]                  // by cost, ProjectFolder.other last
      let incompleteBefore: String?            // completeSince of a service, when the period starts before it
      static func make(summary: CostLedger.Summary, providers: [ProviderID], period: SpendPeriod, now: Date) -> SpendReport
      static func modelTitle(_ key: String, service: ProviderID) -> String
  }
  ```

- [ ] **Step 1: Scrivi i test che falliscono** (`Summary` costruito a mano, `now` = 3 novembre 2026 alle 12:00 ora locale):
  - `.week.days(now:)` → da `"2026-10-28"` a `"2026-11-03"`, 7 elementi in ordine (Review Focus 4); `.month` → da `"2026-11-01"` a `"2026-11-03"`; `.today` → `["2026-11-03"]`; `.thirtyDays` → 30 elementi, il primo `"2026-10-05"`.
  - `now` = 2 gennaio 2027, `.week` → il primo elemento è `"2026-12-27"`.
  - Totale: `projects` claude `2026-11-02` {A: 3, B: 1} e opencode `2026-11-03` {A: 0,5}, `providers [.claude, .opencode]`, `.week` → `total == 4.5`; con `providers [.claude]` → `4`.
  - Modelli: `totals` claude `2026-11-02` {`claude-opus-5-5`: cost 3, input 100, output 50} e {`claude-haiku-5-5`: cost 1} → `models.first?.title == "Claude Opus 5.5"`, `tokens == 150`, `share == 0.75`.
  - Nome dei modelli: `modelTitle("claude-haiku-4-5-20251001", .claude) == "Claude Haiku 4.5"`; `modelTitle("deepseek-v4.1-flash", .opencode) == "DeepSeek V4.1 Flash"`; una chiave sconosciuta resta com'è.
  - Progetti: `share` = costo / totale; `ProjectFolder.other` per ultimo.
  - `Summary()` vuoto, `.thirtyDays` → `total == 0`, `days.count == 30`, tutte le quote a `0`, `models` e `projects` vuoti (Review Focus 5).
  - `completeSince["claude"] = "2026-10-30"`, `.week` → `incompleteBefore == "2026-10-30"`; `.today` → `nil`.
  - Coerenza col pannello: per `.month` il `total` è uguale a `CostLedger.cost(of:in:days:)` con prefisso `"2026-11"`.

- [ ] **Step 2: Esegui** — `swift test --filter SpendReportTests` → «cannot find 'SpendReport'».
- [ ] **Step 3: Implementa** in `Sources/LimitBar/SpendReport.swift`.
  - Giorni: calendario locale, `CostLedger.dayKey`.
  - Il totale e i progetti vengono da `projects`, i token e i modelli da `totals`. Le quote dei modelli si calcolano sulla somma dei costi dei modelli, quelle dei progetti sul totale; con denominatore 0 sono 0.
  - `modelTitle` per Claude: si toglie un suffisso data di 8 cifre, «claude» e il nome della famiglia vanno con l'iniziale maiuscola, i numeri finali si uniscono con «.». Per OpenCode: `OpenCodeProvider.modelName(key) ?? key`.
- [ ] **Step 4: Esegui** — `swift test --filter SpendReportTests` → tutti superati.

### Task 7: Finestra Spesa e scheda del valore cliccabile — commit della parte 3

**Files:**
- Create: `Sources/LimitBar/SpendWindow.swift`
- Modify: `Sources/LimitBar/PanelView.swift` (`ValueCard`, `Card` 67–83), `Sources/LimitBar/StatusController.swift` (chiusura del pannello)

**Interfaces:**
- Consumes: `SpendReport.make`, `SpendPeriod` (Task 6); `UsageStore.costs`, `monthComparison`, `monthValue`; `Format.euros(fromDollars:)`, `Format.wholeEuros(fromDollars:)`; `ProviderID.tint`, `.title`, `.logo`.
- Produces: `SpendWindow.shared.show(store: UsageStore)` (`@MainActor final class`, come `SettingsWindow`).

- [ ] **Step 1: `SpendWindow`.**
  - Una sola istanza: `NSWindow` con `NSHostingController`, titolo «Spesa», `styleMask [.titled, .closable, .resizable]`, `contentMinSize 560×520`, partenza 560×640, `NSApp.activate()`.
  - Periodo: `Picker` a segmenti nella toolbar (`.toolbar { ToolbarItem(placement: .principal) }`), salvato in `UserDefaults` con la chiave `spend.period` (predefinito `.month`), tramite un `ObservableObject` (niente `@State`).
- [ ] **Step 2: `SpendView` (in `SpendWindow.swift`)**, in uno `ScrollView` con `Form`/`Section` raggruppati, dall'alto:
  1. Riepilogo: `Format.wholeEuros(fromDollars: total)` grande. Per `.month` anche `Format.change(comparison)` e i risparmi come in `ValueCard`. Poi una riga di token: «Input · Output · Cache letta · Cache scritta».
  2. `Chart` di `BarMark(x: .value("Giorno", date, unit: .day), y: .value("Euro", euros))`, con `.foregroundStyle(by: .value("Servizio", id.title))` e `chartForegroundStyleScale` che usa i `tint` dei servizi. Selezione con `chartXSelection` e una `RuleMark` + annotazione «3 nov · Claude 12 € · OpenCode 1 €».
  3. «Modelli»: logo del servizio, `title`, quota (`Int(share×100)%`), token abbreviati, euro.
  4. «Progetti»: le righe come `ProjectLine`, con clic per aprire la cartella nel Finder.
  5. Se `incompleteBefore` non è nil, `Note` «I giorni prima del <data> non sono completi». Se `total == 0`, «Nessuna spesa nel periodo» al posto di grafico e liste.
- [ ] **Step 3: `ValueCard`** passa `Card(action: { SpendWindow.shared.show(store: store) })`, con `.help("Apri la spesa nel dettaglio")`. All'apertura della finestra il pannello si chiude: `StatusController.dismiss()` scatta già quando il pannello perde il focus. Se non succede, `SpendWindow.show` manda una notifica che `StatusController` ascolta.
- [ ] **Step 4: Verifica.**
  - `swift build`, poi `swift test`, poi `./build.sh --install`.
  - Nell'app installata, un clic su «Valore di …» apre «Spesa».
  - I periodi cambiano grafico e liste, e «Questo mese» ha lo stesso totale del pannello.
  - Da controllare anche in modalità scura.
- [ ] **Step 5: Commit**

```bash
git add Sources Tests build-number
git commit -m "Finestra Spesa: periodi, grafico giornaliero, modelli e progetti (1.0 (<build>))"
```

### Task 8: Verifica finale

- [ ] `swift test` → tutti superati; `./build.sh --install` → «Installed»; `--dump` di claude e opencode senza errori.
- [ ] `git status --short` → solo `?? .vscode/`. Se c'è altro, va nel commit giusto o in un commit «Rifiniture (1.0 (<build>))».
