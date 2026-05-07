# Current Context
**Initialized:** 2026-04-27
**Focus:** Phase 1 (claude bridge integration) in corso — task P1.4 IN PROGRESS, P1.5+ in coda. Phase 4 (pairing) completa lato codice, in attesa test on-device.

Per il piano dettagliato leggi `docs/TASK_PLAN.md`.
Per le ultime attività leggi le ultime 5–10 entry di `docs/memory/ACTIVITY_LOG.md`.

## Active Threads

- **P1.4** — streaming Claude → iOS (frontend-dev / backend-dev).
- **U0** — utente deve installare Tailscale e sideloadare nuovo IPA per test on-device P4.9 + P1.10.

## Open Questions

- Quando arriverà il sign-off utente sul nuovo IPA con P1.4 streaming integrato?
- Decisione finale tra Cloudflare Tunnel (MVP default) e Tailscale (advanced documented path) per onboarding utenti non-tecnici post-1.0?

## Notes for Specific Agents

- **frontend-dev / backend-dev (iOS):** ricorda il ciclo IPA completo dopo ogni `.swift` (vedi `CLAUDE.md` §Pacchettizzazione + memoria utente `feedback_ios_build_deploy.md`). Mai dichiarare "fix testato" senza nuovo IPA.
- **debugger:** se utente dice "il fix non funziona", PRIMA verificare via SSH sul Mac quale versione del file Swift è stata buildata (`grep` nel file sul Mac), POI debuggare il codice.
- **researcher:** `iroh-ffi` archived da Feb 2025 — non riproporre come MVP. Vedi `docs/research/pairing-landscape-2026.md`.
- **code-mapper:** mappare incrementalmente; non retro-mappare le fasi 1–3 / harness 10–18 finché un task non tocca quei moduli.
- **documenter:** `docs/Architecture-Armando-Revision.md` è la fonte canonica V3. `03_HARNESS/docs/api/ios-integration.md` è autoritativo per il contratto iOS↔harness.
