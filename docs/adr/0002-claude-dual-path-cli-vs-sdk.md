# ADR-0002: Doppio path Claude — CLI subprocess + SDK cloud (boundary esplicito)

- **Status:** Accepted
- **Date:** 2026-05-07
- **Deciders:** @ArmandoBattaglino
- **Tags:** harness, claude, llm, billing, computer-use

## Context

Il harness Node ha due implementazioni indipendenti che parlano con Claude, nate in momenti diversi del progetto e mai esplicitamente coordinate:

1. **`server/claude-runner.js`** — spawna `claude` CLI come subprocess. Sfrutta la subscription Claude Code (€20/mese flat) tramite la sessione locale del PM. È il path usato da:
   - `server/api/ios-stream.js` (WebSocket voice)
   - `server/api/ios-agent.js` (HTTP agent run)
   - `server/server.js` (boot)
   - `server/memory-snapshot.js` (memoria)

2. **`server/api/ios-computer-use.js`** — usa `@anthropic-ai/sdk` con API key. Billing per-token. Usato da un solo endpoint dedicato a computer-use (Playwright loop con screenshot).

L'audit di rework (2026-05-07, `docs/rework/CAPABILITY_MAP.md`) ha rilevato:
- I due path NON si toccano nel codice — `@anthropic-ai/sdk` è importato solo da `ios-computer-use.js`; `claude-runner` non è chiamato da `ios-computer-use.js`.
- Il boundary esiste de facto ma non è mai stato formalizzato. Il rischio è che future feature ripeschino l'SDK (o il CLI) per il path "sbagliato", facendo lievitare i costi token o spezzando computer-use.

La decisione si pone ora perché il PM è ora unico developer e sta facendo un rework di sfoltimento: serve un confine chiaro che blinda il futuro contro mix accidentali.

## Decision

Adottiamo entrambi i path, ognuno con uno scope esclusivo e non sovrapponibile:

> **CLI subprocess (`claude-runner.js`)** è l'unico canale per voice/agent/orchestration generale. Sfrutta la subscription Claude Code → costo marginale zero per richiesta vocale dall'iPhone.
>
> **SDK cloud (`@anthropic-ai/sdk` in `ios-computer-use.js`)** è l'unico canale per computer-use server-side (Playwright loop con screenshot tools). Il loop a scatti richiede tool calls strutturati che il CLI non espone con la stessa granularità → giustifica il billing per-token su quel singolo endpoint.

**Nessun altro file del harness può importare `@anthropic-ai/sdk`.** Nessun altro file può chiamare `ios-computer-use.js` direttamente — il consumer è solo l'endpoint HTTP `/api/ios/computer-use` invocato dall'iPhone.

## Alternatives considered

- **A — Tieni solo CLI subprocess**: scartato perché eliminerebbe computer-use server-side. Il loop screenshot/click richiede tool-calling SDK che il CLI non offre con la stessa fluidità.
- **B — Tieni solo SDK cloud**: scartato perché ogni richiesta vocale dall'iPhone (decine al giorno in uso reale) verrebbe fatturata a token, vanificando il vantaggio della subscription Claude Code da €20/mese flat. Stima a spanne: 30 voice turn/giorno × 6k token avg = ~5M token/mese → ben oltre il pacchetto subscription.
- **C — Unifica tutto via Claude Code SDK ufficiale (single-source)**: scartato perché l'SDK ufficiale supporta il path subprocess in modo più verboso del wrapper custom esistente, e la migrazione costa più del valore — i due path attuali funzionano e sono testati live.

## Consequences

### Positive
- Costo voice prevedibile e flat (subscription Claude Code).
- Computer-use mantiene la flessibilità tool-calling SDK.
- Boundary esplicito → nessun overlap accidentale in future feature.
- Nessuna riscrittura: il codice attuale rispetta già il confine, l'ADR lo blinda.

### Negative / Trade-off
- Due dipendenze separate da mantenere (Claude CLI binary + npm `@anthropic-ai/sdk`).
- Se Anthropic cambia API CLI o SDK in modo incompatibile, va patchato in due punti.
- Computer-use non beneficia della subscription Claude Code → ogni session costa.

### Neutral / Note
- Se computer-use server-side viene de-scoped definitivamente (non prima del lancio MVP venerdì 1 maggio 2026, ma post-lancio è plausibile), questo ADR sarà superseded da uno nuovo che rimuove il path SDK. Il file `ios-computer-use.js` + dipendenza npm diventerebbero la kill list di quel rework.
- L'enforcement del boundary è informale (nessun lint rule). Per ora basta la review del PM. Se in futuro torna un altro dev, valutare un ESLint custom rule che vieti `import * from '@anthropic-ai/sdk'` fuori da `ios-computer-use.js`.

## References

- `docs/rework/CAPABILITY_MAP.md` — sezione "Doppio path Claude" e "Chirurgia da fare"
- `docs/rework/CAPABILITIES_harness.md` — entry per `claude-runner.js` e `ios-computer-use.js`
- `03_HARNESS/server/claude-runner.js` — implementazione path A
- `03_HARNESS/server/api/ios-computer-use.js` — implementazione path B
- ADR correlati: ADR-0001 (pairing Cloudflare Tunnel)

---

> Una volta `Accepted`, **non si edita più questo file**. Se la decisione cambia,
> si crea un nuovo ADR che la _supersedes_ e si aggiorna lo Status di questo a
> `Superseded by ADR-XXXX`.
