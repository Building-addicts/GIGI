# docs/ — Indice documentazione GIGI

Questa cartella contiene tutta la documentazione **project-level**. I `README.md` dei singoli componenti (`01_SERVER_MDM/`, `02_GIGI_APP/`, `03_HARNESS/`) restano nelle loro cartelle.

## File piatti

| File | Cosa contiene |
|---|---|
| `GETTING_STARTED.md` | Onboarding utente: pairing iPhone↔PC, sideload IPA, troubleshooting |
| `MVP_SCOPE.md` | **Source of truth del lancio 1 maggio 2026** — cosa è in scope, cosa non lo è, acceptance criteria del demo |
| `TASK_PLAN.md` | Piano task corrente (autoritativo, granulare per fase) |
| `Architecture Armando Revision.md` | Paper architettura "True Agent" V3 (aprile 2026, rev. 2 peer-reviewed) |
| `PIANO_INTEGRAZIONE_HARNESS.md` | Piano integrazione backend Node nell'app iOS |
| `TEST_E2E.md` | Scenari test end-to-end |
| `COMPONENTS.md` | Mappa "quale file fa cosa" raggruppata per funzione |

## Sotto-cartelle

| Cartella | Contenuto | Aggiornata da |
|---|---|---|
| `memory/` | Memoria progetto condivisa (PROJECT, CONTEXT, ACTIVITY_LOG). `ACTIVITY_LOG.md` è alimentato automaticamente dall'hook `Stop` — non serve leggerlo. | hook auto + agenti |
| `adr/` | Architecture Decision Records numerate (Stripe-style). Ogni decisione = 1 file immutabile con context/decision/consequences. | dev quando si decide qualcosa |
| `runbooks/` | Procedure operative ripetitive (build IPA, deploy harness, pair iPhone). Checklist, non narrativa. | dev quando cambia una procedura |
| `plans/` | Piani implementativi per fase (cloudflare-tunnel-pairing, tailscale-qr-pairing, claude-bridge-integration, auto-fix-and-difficulty-tiers, panel-observability) | planner / project-manager |
| `research/` | Finding tecnici e ricerche esterne (pairing-landscape-2026) | researcher |
| `archive/` | Doc storiche superate ma conservate per riferimento (TASK_PLAN_V3) | manuale |

## Quale file leggere quando

Vedi tabella "Dove guardare per cosa" nel `CLAUDE.md` alla root del repo.
