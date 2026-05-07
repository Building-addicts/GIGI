# `docs/rework/` — artefatti del rework `armando-rework`

Cartella creata 2026-05-07 per raggruppare i documenti generati dal rework solitario del PM (@ArmandoBattaglino, ora unico dev del progetto). Sono il riferimento canonico per capire **cosa è stato fatto, perché, e cosa resta da fare**.

## Index

### Documento architetturale principale

- **[Architecture-Armando-Revision.md](Architecture-Armando-Revision.md)** — paper architetturale "True Agent" V3 (rev. Armando, 2026-05-07). Contiene §1-20 design originale + **§21 Rework log (living)** che traccia ogni commit del rework con razionale, ADR linkati, e 4 sub-indici vivi:
  - **Phase log** — cronologia commit del rework
  - **Codice congelato** — pezzi soft-killed riattivabili via flag flip (Wake Word + Day Plan Reasoner)
  - **Debiti architetturali (TODO)** — TD-001 tool selection inefficiente, TD-002 memoria 3-layer da unificare
  - **Decisioni di non-kill** — pezzi considerati per kill ma tenuti consciamente (debug endpoints, health-check)

### Mappa capability di partenza

Generata 2026-05-07 da `main @ 7ec7e94` come audit di partenza, **prima** di iniziare a tagliare. Snapshot del codebase pre-rework con classificazione kill/chirurgia/non-toccare.

- **[CAPABILITY_MAP.md](CAPABILITY_MAP.md)** — cruscotto decisionale: TL;DR delle 14 domande del rework + sorprese architetturali + MVP-critical list + roadmap 6 fasi
- **[CAPABILITIES_iOS.md](CAPABILITIES_iOS.md)** — inventario 56 capability lato app Swift (`02_GIGI_APP/`)
- **[CAPABILITIES_harness.md](CAPABILITIES_harness.md)** — inventario 38 capability lato Node (`03_HARNESS/`)
- **[CAPABILITIES_infra.md](CAPABILITIES_infra.md)** — inventario MDM, GitHub Actions, hooks, scripts, runbooks
- **[CAPABILITIES_crosscut.md](CAPABILITIES_crosscut.md)** — vista trasversale: 30 capability user-facing end-to-end iOS↔harness

### Recap visivo

- **[recap.html](recap.html)** — pagina HTML colorata, dark/light auto, con:
  - Stats (~1900 righe rimosse, file killed, soft-killed, kept, debiti architetturali, ADR scritti)
  - 6 sezioni color-coded (Killed / Frozen / Kept / Added / Deferred / Open)
  - Ogni capability con file path, ADR di riferimento, SHA del commit
  - Lista di tutti i 18 commit del rework con descrizione

Aprila con un browser per leggere il recap a colori. Funziona sia in repo locale (`open recap.html`) sia su GitHub (raw view).

## ADR correlati al rework

Gli ADR vivono in `docs/adr/` (convenzione standard del progetto, ADR-0001 esisteva pre-rework). Quelli generati durante il rework `armando-rework`:

- **[ADR-0002](../adr/0002-claude-dual-path-cli-vs-sdk.md)** — Doppio path Claude (CLI subprocess + SDK cloud) con boundary esplicito
- **[ADR-0003](../adr/0003-wake-word-soft-kill-mvp.md)** — Wake Word soft-kill MVP, riattivazione via flag
- **[ADR-0004](../adr/0004-uproot-gemini-and-google-signin.md)** — Sradicamento totale Gemini + Google Sign-In
- **[ADR-0005](../adr/0005-day-plan-reasoner-soft-kill-mvp.md)** — GigiDayPlanReasoner soft-kill, riattivazione legata a sub #59

## Come usare questi file

**Se vuoi capire lo stato corrente** del codebase post-rework:
→ Apri `recap.html` (visivo) oppure il §21 di `Architecture-Armando-Revision.md`

**Se vuoi vedere il piano originale e cosa era stato proposto**:
→ Apri `CAPABILITY_MAP.md` (snapshot di partenza)

**Se devi affrontare una capability specifica**:
→ Apri il file `CAPABILITIES_<scope>.md` corrispondente (iOS / harness / infra / crosscut)

**Se devi prendere una decisione architetturale**:
→ Leggi gli ADR (`../adr/`) per vedere come sono state blindate le decisioni passate. Se ne aggiungi una nuova, copia da `../adr/0000-template.md`.

## Convenzione

Ogni futuro rework / phase di sfoltimento dovrebbe seguire questo pattern:

1. **Audit di partenza** — capability map dettagliata via subagent paralleli
2. **Cruscotto decisionale** — TL;DR delle decisioni da prendere
3. **Esecuzione iterativa** — domanda alla volta, ADR per ogni decisione strutturale
4. **Rework log vivo** — sezione §21 in architettura aggiornata a ogni commit
5. **Recap visivo** — HTML finale per consultazione veloce

Il pattern è codificato in **§21 → "Convenzione per future modifiche"** del documento architetturale.
