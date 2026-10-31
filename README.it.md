# LimitBar

I limiti di Claude e di OpenCode Go nella barra dei menu del Mac.

*[Read in English](README.md)*

LimitBar è una piccola app nativa per macOS. Mostra quanto hai usato di ogni limite e tra quanto si azzera. Ti dice anche se al ritmo attuale arrivi al reset, quanto varrebbe a prezzi API il lavoro fatto e se i servizi hanno problemi. L'app è in italiano e in inglese e segue la lingua del Mac.

> LimitBar è un progetto indipendente: non è fatta da Anthropic né da OpenCode, non è collegata a loro e non è approvata da loro.

## Cosa mostra

- **Limiti.** Un anello per ogni limite (5 ore e settimana, più il mese per OpenCode Go), con il tempo che manca all'azzeramento. Il numero nella barra dei menu diventa arancione dall'80% e rosso dal 90%. Quando un limite è esaurito, la barra mostra tra quanto torna disponibile.
- **Ritmo.** Su settimana e mese, una tacca segna dove saresti usando il limite in modo costante fino al reset. Sotto l'anello una riga dice *In linea*, *12% in anticipo* o *12% di margine*. Per le 5 ore c'è invece una previsione, che avvisa se al ritmo attuale finisci il limite prima del reset.
- **Stato dei servizi.** LimitBar legge ogni 5 minuti le pagine di stato di Anthropic e OpenCode. Se Claude Code, l'API, claude.ai, OpenCode Go o il modello che usi hanno problemi, nel pannello compare una striscia arancione o rossa e sull'icona nella barra dei menu un puntino.
- **Valore a prezzi API.** Quanto costerebbe a prezzi API pubblici il lavoro fatto questo mese con Claude Code e OpenCode, a confronto con il tuo piano e con il mese scorso, diviso per progetto.
- **Finestra Spesa.** Si apre con un clic sulla scheda del valore. Copre Oggi, 7 giorni, 30 giorni o Questo mese, con un grafico giorno per giorno diviso per servizio, i token, i modelli e i progetti. Gli importi sono in dollari o in euro (al cambio BCE del giorno), a scelta nelle impostazioni.
- **Attività.** L'icona di un servizio si colora mentre il suo agente lavora. Una notifica ti avvisa quando Claude o OpenCode finiscono un lavoro lungo o ti aspettano. Ogni lunedì arriva il riepilogo della settimana prima.
- **Widget per iPhone** (facoltativo). LimitBar copia i limiti su iCloud Drive per un widget di [Scriptable](https://scriptable.app), che installa da sola nella cartella di Scriptable.

## Requisiti

- Un Mac con processore Apple e macOS 14 o successivo. È pensata per macOS 26 e 27, con Liquid Glass.
- Claude: un piano Pro o Max, usato con Claude Code o con l'accesso dal pannello.
- OpenCode Go: l'app OpenCode, con Go collegato.

## Installazione

1. Scarica `LimitBar.zip` dalle [Release](../../releases) e scompattalo.
2. Trascina LimitBar in Applicazioni e aprila. LimitBar non è autenticata da Apple, quindi la prima volta il Mac dice che non può verificare lo sviluppatore. Vai in **Impostazioni di Sistema › Privacy e sicurezza**, scorri in basso e premi **Apri comunque**. In alternativa, dal Terminale:
   ```bash
   xattr -dr com.apple.quarantine /Applications/LimitBar.app
   ```
3. Clicca l'icona nella barra dei menu per aprire il pannello. Quando il Mac lo chiede, consenti le notifiche.

### Compilarla dal codice

Bastano i Command Line Tools, non serve Xcode:

```bash
xcode-select --install
./build.sh --install
```

`./build.sh --install` crea `build/LimitBar.app`, la copia in `~/Applications` e la apre. Installa anche gli script della status line e degli hook di Claude Code, con cui LimitBar legge limiti e attività da Claude Code. Per usarli, aggiungili a `~/.claude/settings.json` (vedi [scripts/](scripts)).

I test si eseguono con `swift test`.

## Collegare i servizi

- **Claude.** Se usi Claude Code con il tuo account, LimitBar trova il suo accesso e non devi fare niente. Altrimenti, nel pannello premi **Accedi a Claude…**, approva nel browser, copia il codice che compare e premi **Incolla codice**. Per disconnetterti: Impostazioni › Account.
- **OpenCode Go.** OpenCode non rende leggibili i suoi limiti, quindi LimitBar li stima dall'uso registrato su questo Mac nel database di OpenCode. Collega Go nell'app OpenCode e scegli il tuo piano (Go o Go Plus) nelle impostazioni. L'uso da altri dispositivi non viene contato.

## Privacy

LimitBar non ha un suo server e non raccoglie nulla. Si collega solo a:

- l'endpoint di utilizzo di Anthropic, per leggere i tuoi limiti di Claude con il tuo accesso;
- le pagine di stato `status.claude.com` e `status.opencode.ai` (si può disattivare nelle impostazioni);
- il cambio giornaliero della Banca Centrale Europea, quando gli importi sono in euro.

Tutto il resto lo legge dai file sul Mac: i registri di Claude Code e Codex e il database di OpenCode. Se usi iCloud Drive, una copia dei limiti va nella sua cartella LimitBar, per il widget.

**Sull'accesso a Claude.** Claude non offre un'API pubblica per i limiti del piano. LimitBar usa lo stesso accesso e lo stesso endpoint di utilizzo di Claude Code. Anthropic può cambiarli in qualsiasi momento.

## Licenza

[MIT](LICENSE)
