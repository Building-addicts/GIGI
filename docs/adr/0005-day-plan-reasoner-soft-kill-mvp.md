# ADR-0005: GigiDayPlanReasoner — soft-kill MVP, riattivazione legata alla sub 4/4 (#59)

- **Status:** Accepted
- **Date:** 2026-05-07
- **Deciders:** @ArmandoBattaglino
- **Tags:** ios, day-plan, planner, mvp, kill-switch

## Context

`GigiDayPlanReasoner.swift` è un engine isolato che, dato un input di eventi calendario + preferenze utente + task estratti dalla session, produce un piano giornata vocale-friendly via Groq LLM. È stato implementato nella **sub-issue #56** (1/4 della parent #15 "Day Plan capability"), con le sub successive che dovevano completarlo:

- **Sub #57 (2/4)**: wirearlo al calendario reale via tool `read_week_calendar` / `read_calendar` ✅ completata
- **Sub #58 (3/4)**: wirearlo a Live Preferences + Live Tasks (UserDefaults stop-gap in attesa che #13 + #14 mergiassero) ✅ completata
- **Sub #59 (4/4)**: registrare il tool `propose_day_plan` in `GigiToolRegistry` così che il loop agent possa chiamarlo quando l'utente dice "che giornata ho?" ❌ **non completata**

Conseguenza: l'engine **funziona perfettamente** come unità isolata, ma **nessun tool registrato lo invoca in produzione**. L'unica cosa che lo esercita oggi sono **3 smoke test in DEBUG** dentro `GIGIApp.swift` `.task` block:

```swift
await GigiDayPlanReasoner.debugRunWithMockData()
await GigiDayPlanReasoner.debugRunWithRealCalendar()
await GigiDayPlanReasoner.debugRunWithLiveSources()
```

Queste chiamate al cold start dell'app partono ma non producono nulla di user-facing — solo log su `GigiDebugLogger`. Costo trascurabile in DEBUG, ma rumore nei log e 3 round trip Groq ad ogni avvio in DEBUG (latency + costo token).

Audit di rework ha rilevato:
- Naming clash con `GigiPlannerEngine` (task decomposer del flow agent — vivo e centrale). I due fanno cose diverse ma il PM li confondeva ricorrentemente nei review.
- L'MVP è stato lanciato il 1 maggio 2026 (oggi: 2026-05-07). La feature "Day Plan capability" è di fatto **post-MVP** — non era nel scope finale del lancio.
- Il PM (@ArmandoBattaglino, ora unico dev) ha richiesto un meccanismo per "vedere a colpo d'occhio cosa è stato congelato" così da poterlo recuperare in v1.1+.

## Decision

Adottiamo il **soft-kill** per `GigiDayPlanReasoner`, allineato al pattern già usato per il Wake Word (ADR-0003):

> Il file `GigiDayPlanReasoner.swift` resta nel codebase **intatto strutturalmente**. Aggiunto in cima alla classe il flag `static let isDisabledForMVP = true`. I tre public entry point (`reason(input:)`, `reasonForToday(preferences:tasks:)`, `reasonForTodayLive`) hanno ora un guard `Self.isDisabledForMVP` early-return su `nil`.
>
> I tre smoke test DEBUG in `GIGIApp.swift` sono commentati con riferimento a questo ADR.

In Architecture Armando Revision.md §21 viene introdotta una nuova sotto-sezione **"Codice congelato — index"** che lista TUTTI i pezzi soft-killed (oggi: Wake Word + Day Plan Reasoner). Diventa la mappa di riattivazione: chi torna a guardare il repo in 6 mesi vede subito cosa parcheggiare e cosa riprendere.

## Alternatives considered

- **A — Kill totale**: cancellare il file. Scartato perché l'engine è sostanzialmente completo (~300 righe, prompt LLM + parsing + 2 source provider + 3 debug runner). Re-implementare in v1.1 costerebbe più del 5 KB di codice dormiente. Git history conservata sì, ma riportare 300 righe da revert è più rumoroso che flippare un flag.
- **B — Completare sub 4/4 ora (registrare il tool)**: scartato come scope creep. La capability "Day Plan" non è MVP-critical (l'MVP è stato lanciato senza), e registrare il tool richiede design del trigger ("quando GIGI propone proattivamente vs solo on-demand") che non è una decisione da prendere durante un rework di sfoltimento.
- **C — Status quo (lasciare smoke test attivi)**: scartato per rumore. 3 round-trip Groq in DEBUG ad ogni cold start sono ~1.5s di latenza inutile + ~3k token bruciati per nulla.

## Consequences

### Positive
- **~300 righe di codice dormienti ma git-blame-recoverable** per v1.1 (basta un flag flip + chiusura sub 4/4 #59).
- **Cold start DEBUG più pulito** — zero round trip Groq inutili, log meno rumorosi.
- **Naming clash più tollerabile** — chi fa grep su "Planner" trova entrambi i file ma il `isDisabledForMVP = true` nel Reasoner segnala subito che è dormiente.
- **Pattern uniforme con Wake Word (ADR-0003)** — il flag `isDisabledForMVP` diventa una convenzione consistente per discoverable parking.
- **Indice "Codice congelato"** in ARCHITETTURA §21 — il PM ha una mappa unica dei pezzi parcheggiati.

### Negative / Trade-off
- ~300 righe di "morto" nel binary. Trascurabile su un app Swift di queste dimensioni.
- Future modifiche a `GigiCloudService.callWithFunctions` o ai tool `read_week_calendar`/`read_calendar` devono ricordarsi di NON rompere l'API che il Reasoner usa internamente — altrimenti la riattivazione v1.1 sarà più costosa. Mitigato dal fatto che `callWithFunctions` è API stabile (usata da Planner, Action Bridge, Task Extractor).
- Il flag `isDisabledForMVP` è duplicato tra Wake Word e Reasoner — se domani vogliamo riattivare entrambi indipendentemente, serve qualche logica più sofisticata (feature flag dict). Per ora è due booleani separati nelle classi, basta.

### Neutral / Note
- L'azione di v1.1 è chirurgica: 1) flip `isDisabledForMVP` a `false`, 2) registra tool `propose_day_plan` in `GigiToolRegistry` (sub 4/4 #59), 3) decommenta i debug runner in `GIGIApp.swift` se servono per ri-validare. Diventa un mini-PR di ~30 righe.
- Se il piano cambia e Day Plan viene de-scoped definitivamente (post-rework approfondito che decide che il flow non è la priorità), questo ADR sarà superseded da uno nuovo che cancella tutto.

## References

- Issue parent [#15](https://github.com/Building-addicts/GIGI/issues/15) — Day Plan capability
- Sub-issue [#56](https://github.com/Building-addicts/GIGI/issues/56) — engine + tipi + system prompt + debug runner (mergiata)
- Sub-issue [#57](https://github.com/Building-addicts/GIGI/issues/57) — wiring calendar reale (mergiata)
- Sub-issue [#58](https://github.com/Building-addicts/GIGI/issues/58) — wiring Live Pref + Task sources (mergiata)
- Sub-issue [#59](https://github.com/Building-addicts/GIGI/issues/59) — voice delivery + tool registration `propose_day_plan` ❌ **non chiusa**, riattivazione v1.1
- `02_GIGI_APP/GIGI/GigiDayPlanReasoner.swift:67-75` — flag `isDisabledForMVP` con commento ricorda-tutto
- `02_GIGI_APP/GIGI/GIGIApp.swift` — sezione `.task` `#if DEBUG` con i 3 smoke test commentati
- `docs/rework/CAPABILITY_MAP.md` § "Chirurgia da fare — GigiPlanner vs GigiDayPlanReasoner"
- `docs/Architecture Armando Revision.md §21` — sotto-sezione "Codice congelato — index"
- ADR correlati: ADR-0003 (Wake Word soft-kill, stesso pattern)

---

> Una volta `Accepted`, **non si edita più questo file**. Se la decisione cambia,
> si crea un nuovo ADR che la _supersedes_ e si aggiorna lo Status di questo a
> `Superseded by ADR-XXXX`.
