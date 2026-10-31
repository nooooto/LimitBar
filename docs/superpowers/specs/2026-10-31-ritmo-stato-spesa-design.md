# Ritmo, stato dei servizi e finestra Spesa

Data: 31 ottobre 2026 · Stato: approvato a voce, in revisione scritta

## Perché

Studiando CodexBar (codexbar.app) sono emerse tre cose che LimitBar non fa e che servono a chi la usa ogni giorno:

1. sapere, prima che sia troppo tardi, se si sta consumando un limite più in fretta del tempo che passa;
2. capire se un rallentamento dipende da un disservizio di Anthropic o di OpenCode;
3. vedere la spesa più nel dettaglio di quanto stia nel pannello: giorno per giorno, per modello, per periodi diversi dal mese.

Di CodexBar si prende l'idea delle funzioni, non l'aspetto né il codice. LimitBar resta un'app nativa macOS 27 con Liquid Glass, interfaccia in italiano, compilata con i soli Command Line Tools.

Fuori da questo lavoro (scartati): widget WidgetKit (servono Xcode e un'estensione; c'è già il widget Scriptable), lettura dei cookie del browser, altri provider, avvisi sui reset non sfruttati.

## Struttura del lavoro

Tre parti indipendenti, in quest'ordine, ognuna con la sua build e il suo commit:

1. Ritmo (solo pannello);
2. Stato dei servizi (modulo nuovo, pannello, icona nella barra dei menu, impostazioni);
3. Finestra Spesa (finestra nuova, scheda del valore cliccabile).

Si aggiunge un target di test (`LimitBarTests`, Swift Testing) per le parti pure: calcolo del ritmo, lettura delle pagine di stato, somme per periodo. Con i soli Command Line Tools il target ha bisogno di `swiftSettings: [.unsafeFlags(["-plugin-path", "/Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing"])]`. I test raggiungono il codice con `@testable import LimitBar`: SwiftPM permette di testare un `executableTarget` (dalla 5.5). Solo se questo non compila con i Command Line Tools, le funzioni pure si spostano in un target libreria `LimitBarCore` importato da app e test.

## Parte 1 — Ritmo

### Calcolo

Per una finestra con `resetsAt` e `windowMinutes` noti:

- `durata = windowMinutes × 60`
- `inizio = resetsAt − durata`
- `trascorso = (adesso − inizio) / durata`, limitato a 0…1
- `atteso = trascorso × 100`
- `scarto = uso reale (effectivePercent) − atteso`

Il ritmo non c'è (nil) quando: manca `resetsAt` o `windowMinutes`; la finestra è già ripartita; `trascorso < 0,10`; il limite è esaurito (≥ 99,5%, c'è già la striscia rossa).

Esito:

| scarto | stato | riga | colore |
|---|---|---|---|
| −5 < scarto < 5 | in linea | «In linea» | secondario |
| ≥ 5 | in anticipo | «12% in anticipo» | arancione di sistema |
| ≤ −5 | margine | «12% di margine» | verde di sistema |

Il numero è `scarto` arrotondato all'intero, senza segno.

Si applica a: settimana di Claude, settimane per modello di Claude (extra con `windowMinutes`), settimana e mese di OpenCode, settimana di Codex se riattivato. Non alle 5 ore: lì resta la previsione «A questo ritmo: …» di `UsageHistory.forecast`, che resta anche per la settimana. Il mese di OpenCode usa `windowMinutes` (30 giorni): lo scarto rispetto ai mesi di 31 o 28 giorni è trascurabile.

### Interfaccia

- `Gauge` riceve un parametro opzionale `pace` (posizione attesa 0…1 e riga colorata).
- Tacca: un segmento radiale sottile (1,5 pt) che attraversa lo spessore dell'anello all'angolo di `atteso`, colore `.secondary`, sopra l'arco.
- Riga: sotto le righe esistenti del ring (countdown, ed eventuali «$ rimasti»), nel colore della tabella; tooltip «Dove saresti usando il limite in modo costante fino al reset».

### Codice

Funzione pura `Pace.of(window:now:) -> Pace?` in un file nuovo `Pace.swift`. `PanelView` (`LimitsCard`, `OpenCodeCard`) la chiama per ogni limite tranne le 5 ore.

### Test

Inizio finestra (nil sotto il 10%), a metà settimana con uso 50 (in linea), 70 (20% in anticipo), 30 (20% di margine), confini ±5, finestra ripartita, limite esaurito, dati mancanti.

## Parte 2 — Stato dei servizi

### Fonti

- Anthropic: `GET https://status.claude.com/api/v2/summary.json` (Atlassian Statuspage). Componenti considerati: «Claude Code», «Claude API (api.anthropic.com)», «claude.ai». Stati Statuspage: `operational`, `degraded_performance`, `partial_outage`, `major_outage`, `under_maintenance`. Incidenti: `incidents[]` non risolti che toccano uno dei componenti considerati (`components[].name`), oppure, se l'incidente non elenca componenti, tutti gli incidenti aperti.
- OpenCode: `GET https://status.opencode.ai/api/status`. Componente `service == "go"`, con `status` (`operational`, `degraded`, `outage`, `unknown`) e `reason` (`none`, `errors`, `latency`); dentro `breakdown[]` lo stato e il motivo del modello in uso (`OpenCodeActivity.currentModel()`). Se il JSON ha `stale: true`, lo stato è sconosciuto. Gli incidenti (`incidents[]`, aperti se `resolvedAt` è nullo) non hanno un titolo: la frase si costruisce dal motivo.

### Modello

```
enum ServiceHealth { case operational, degraded, outage, maintenance, unknown }
struct ServiceStatus { health, title: String?, page: URL, checkedAt: Date }
```

Corrispondenze Anthropic: `degraded_performance` e `partial_outage` → degraded; `major_outage` → outage; `under_maintenance` → maintenance; un valore mai visto → unknown. OpenCode: `degraded` → degraded, `outage` → outage, `unknown` e valori mai visti → unknown. Si tiene lo stato peggiore fra i componenti considerati (per OpenCode, fra Go e il modello in uso; a parità vince il modello, più preciso).

Testo della striscia (il componente è quello peggiore):
- Claude: «Claude Code: prestazioni ridotte · <titolo del primo incidente aperto>», «API di Claude: disservizio grave · …», «claude.ai: manutenzione in corso».
- OpenCode, dal motivo: `errors` → «errori», `latency` → «rallentato», altrimenti «prestazioni ridotte» / «non disponibile». Esempi: «OpenCode Go: errori», «DeepSeek V4.1 Flash: rallentato».

### Frequenza ed errori

Controllo ogni 5 minuti nello stesso timer di `UsageStore`, e all'apertura del pannello se l'ultimo ha più di 2 minuti. Un errore di rete o una risposta illeggibile non si mostra: resta l'ultimo stato valido per 30 minuti, poi diventa `unknown` (nessuna segnalazione). Con l'interruttore spento non si fanno richieste e lo stato è `unknown`.

### Interfaccia

- Pannello: nella scheda del servizio, subito dopo l'intestazione, un `Banner` arancione (degraded), rosso (outage) o una `Note` (maintenance), cliccabile: apre la pagina di stato (`status.claude.com`, `status.opencode.ai`).
- Barra dei menu: un puntino (circa 4 pt) arancione o rosso in alto a destra del simbolo del servizio, disegnato nel livello colorato (`colourLayer`, vedi `Icons.StatusLabel`), mai nell'immagine template. Niente puntino per maintenance e unknown.
- Impostazioni: interruttore «Controlla lo stato dei servizi» nella sezione Pannello, acceso di serie (`settings.checkServiceStatus`).

### Codice

File nuovo `ServiceStatus.swift`: le due letture di rete e le due funzioni pure di interpretazione (`Data` → `ServiceStatus`). `UsageStore` tiene `@Published var serviceStatus: [ProviderID: ServiceStatus]`. `PanelView` e `StatusController` lo leggono.

### Test

Con JSON di esempio salvati nei test: tutto operativo; Claude Code degradato con incidente; disservizio grave sull'API; manutenzione; incidente su un componente non considerato (ignorato); OpenCode Go operativo con modello in uso degradato; `stale: true`; JSON illeggibile.

## Parte 3 — Finestra Spesa

### Apertura

Clic sulla scheda «Valore di <mese>» del pannello (oggi senza azione): diventa cliccabile come le altre schede, con il tooltip «Apri la spesa nel dettaglio». Si apre una finestra standard «Spesa», circa 560 × 640 pt, ridimensionabile in altezza, costruita come `SettingsWindow` (singola istanza, `NSApp.activate()`). Il pannello si chiude.

### Contenuto

1. Barra degli strumenti: selettore a segmenti Oggi · 7 giorni · 30 giorni · Questo mese (predefinito Questo mese, ricordato).
2. Riepilogo: valore in euro ai prezzi API del periodo; per Questo mese il confronto con il mese scorso e il risparmio sugli abbonamenti come nel pannello; token totali di input, output, cache in lettura e in scrittura.
3. Grafico (Swift Charts): una barra per giorno, impilata per servizio con il colore del servizio; asse in euro. Per Oggi, una sola barra per servizio. Al passaggio del puntatore: giorno e importo per servizio.
4. Modelli: nome, valore, quota del periodo, token (input + output). In ordine di valore; il primo è il più usato.
5. Progetti: tutti, con valore e quota, come le righe del pannello (clic per aprire la cartella nel Finder).

### Dati

`CostLedger.Summary.totals` (servizio → giorno → modello → `Totals`) per valore, token e modelli; `Summary.projects` (servizio → giorno → progetto → dollari) per i progetti. I giorni del periodo si scelgono con le chiavi `yyyy-MM-dd` locali (`CostLedger.dayKey`). Il dettaglio per modello copre i giorni che i log conservano (30 per Claude Code): bastano, perché il periodo più lungo è 30 giorni. Se nel periodo ci sono giorni prima di `completeSince`, una nota lo dice («I giorni prima del … non sono completi»).

Il totale della finestra per Questo mese deve coincidere con quello del pannello (stessa fonte, `projects`).

### Codice

File nuovo `SpendWindow.swift` (finestra e vista SwiftUI). Le somme per periodo sono una funzione pura `SpendReport.make(summary:providers:period:now:)` in un file nuovo `SpendReport.swift`, che restituisce totale, token, serie giornaliera per servizio, modelli e progetti.

### Test

Somme di un periodo su dati finti: confini dei giorni (Oggi, 7 giorni che includono oggi), servizi esclusi, ordinamento dei modelli, coerenza del totale di Questo mese con `UsageStore.monthValue`.

## Verifica

Per ogni parte: `swift build`, test verdi, `./build.sh --install`, controllo del layout con `--render` (chiaro e scuro) e, dove serve, `--dump`. La finestra Spesa si controlla aprendola dall'app installata. Nessun invio a Telegram senza chiedere.

## Commit

Un commit locale per parte, nello stile del repository («<descrizione> (1.0 (<build>))»); questo documento e il piano entrano nel commit della parte 1. Alla fine di tutto il lavoro non resta nulla di non committato (salvo `.vscode/`, che era già fuori). Nessun remote, nessun push.
