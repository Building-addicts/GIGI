# GIGI — CLAUDE.md (team-shared)

> File committato, letto da ogni Claude/agente che apre il repo. Indice + regole, **non** manuale.
> Contesto dev privato (host SSH personali) → `CLAUDE.local.md` (gitignored).
> Sub-cartelle hanno il proprio CLAUDE.md (es. `03_HARNESS/CLAUDE.md`).

## TL;DR

Assistente vocale "True Agent" su iPhone (Swift/SwiftUI) che delega task a un harness Node.js sul PC. L'harness orchestra Claude (CLI + SDK), tiene memoria, fa push APNS, espone HTTP+WS via Cloudflare Tunnel.

## Dove guardare per cosa

| Devi… | Apri |
|---|---|
| **Scope MVP del lancio (cosa serve venerdì)** | **`docs/MVP_SCOPE.md`** |
| Capire l'architettura V3 | `docs/ARCHITETTURA_V3.md` |
| Piano integrazione harness | `docs/PIANO_INTEGRAZIONE_HARNESS.md` |
| Test E2E | `docs/TEST_E2E.md` |
| Onboarding utente / pairing / sideload | `docs/GETTING_STARTED.md` |
| Stato e task | `docs/TASK_PLAN.md` (autoritativo) |
| Backend Node (run, env, porte, endpoint) | `03_HARNESS/CLAUDE.md` + `03_HARNESS/README.md` |
| Spec API iOS↔harness | `03_HARNESS/docs/api/ios-integration.md` |
| Stack, vincoli, goal | `docs/memory/PROJECT.md` |
| Focus corrente | `docs/memory/CONTEXT.md` |
| Decisioni architetturali | `docs/adr/` (numerate, immutabili) |
| Cronologia attività (auto) | `docs/memory/ACTIVITY_LOG.md` (alimentato dall'hook `Stop`) |
| Procedure ripetitive (build, deploy, pair) | `docs/runbooks/` |
| Ricerche tecniche | `docs/research/`, `docs/plans/` |
| Come contribuire (umano) | `CONTRIBUTING.md` |
| Review automatica per path | `.github/CODEOWNERS` |
| Quale file fa cosa (per funzione) | `docs/COMPONENTS.md` |
| Indice cartella docs | `docs/README.md` |

## Layout monorepo

```
01_SERVER_MDM/  Node — profili MDM iOS
02_GIGI_APP/    Swift/SwiftUI — app iOS + Siri ext
03_HARNESS/     Node — Claude sessions, memoria, computer-use, APNS
docs/           TUTTI i doc project-level (architettura, piano, E2E, components,
                onboarding, task plan, memory/, plans/, research/, archive/)
```

Run rapido harness: `./start-harness.sh` → dettagli in `03_HARNESS/README.md`.

## Memoria progetto — checklist agente

**Session start:**
1. `docs/memory/PROJECT.md`, `CONTEXT.md`
2. `docs/TASK_PLAN.md` per piano dettagliato
3. CLAUDE.md della sub-cartella se applicabile (es. `03_HARNESS/CLAUDE.md`)
4. `ACTIVITY_LOG.md` **NON serve leggerlo** — è alimentato automaticamente dall'hook e serve solo a te per ispezione manuale

**Session end:**
1. Decisione architetturale presa → nuovo file `docs/adr/NNNN-titolo.md` (formato in `docs/adr/0000-template.md`)
2. Cambio focus → aggiorna `CONTEXT.md`
3. Procedura operativa nuova/cambiata → aggiungi/aggiorna `docs/runbooks/<nome>.md`
4. Tutto il resto (cronologia attività, file toccati, riassunto turno) → l'hook `Stop` appende automaticamente a `ACTIVITY_LOG.md` via Haiku 4.5

Niente memorie per-agente: l'utente è solo, agenti paralleli rari, `ACTIVITY_LOG.md` automatico è la sola fonte cronologica.

## Regole operative

- **Bug** → chiama subito **debugger**. Root cause prima del fix. Se rivela un'assunzione sbagliata, aggiorna `DECISIONS.md`.
- **Loop / task ricorrente** → **NON** `ScheduleWakeup`. Crea watcher in `03_HARNESS/server/watchers.json` (chiedi sempre frequenza polling). Dettagli in `03_HARNESS/CLAUDE.md` §"Regola: loop → watcher".
- **iOS build verify** → ogni task che modifica `.swift` DEVE essere seguito da xcodebuild filtrato per errori prima di dichiararsi completo. Workflow di build (host, comandi) personale → `CLAUDE.local.md` di ciascun dev.
- **Mai dichiarare "fix iOS testato"** senza nuovo IPA installato sul device fisico. Simulatore non copre audio/VAD.
- **Convenzioni:** Swift = SwiftUI-first, `@MainActor` su ViewModel, naming `Gigi*`. Node = v20+, ES modules, no TS, route `ios-*`. Lingua: italiano nei doc/commenti, inglese nelle spec API tecniche. Commit: Conventional Commits.

## Stato corrente (2026-04-27)

Phase 1 (Claude bridge MVP) → P1.1–P1.6 ✅ verificati 2026-04-25. Phase 4 (QR pairing) ✅ commit `ca8a599`. Blocker U0: sideload nuovo IPA + Tailscale per test on-device. Granulare → `docs/TASK_PLAN.md`, focus → `docs/memory/CONTEXT.md`.
