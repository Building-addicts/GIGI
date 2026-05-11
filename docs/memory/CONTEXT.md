# Current Context
**Updated:** 2026-05-12
**Focus:** Pre-demo settimana MVP. Path 3 Ollama SSE parsing finalmente
fixato con parser byte-buffer manuale (commit `6a74842`, ADR-0013).
Prossimo step: utente reinstalla IPA finale → conferma "Bonjour." → Phase
C router 5-path tests + Phase D mode switch + Phase E killer demo Tesla.

**Path SSE journey (2026-05-12)**:
1. Sintomo: "Ollama returned no answer · chunks=0" su ogni call con Brain Path Override = Ollama.
2. Tentativo 1 `7a3585a`: strip `\r` da ogni `rawLine` di `bytes.lines` — non basta.
3. Tentativo 2 `c72d1a5`: flush su nuovo `event:` header — anche non testato perché build pre-c72d1a5 finita sul device.
4. Tentativo 3 `6a74842` ✅ — abbandonato `bytes.lines` del tutto, parser byte-buffer
   manuale alla mattt/EventSource. Token diagnostico `parser=manual-buffer-v1`
   nei Captured logs per identificare al volo la build installata.

Vedi `docs/adr/0013-sse-manual-byte-buffer-parser.md` per razionale completo
e `docs/plans/sse-ollama-deep-fix-2026-05-12.md` per piano implementativo.

**Lo storico Phase 1/2/3/4 (claude bridge, pairing, etc.)** è completato e
mergiato. Settimana lancio MVP ora ruota su 5-path router + UI Modes + killer
demo Tesla → nota.

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
- **documenter:** `docs/rework/Architecture-Armando-Revision.md` è la fonte canonica V3. `03_HARNESS/docs/api/ios-integration.md` è autoritativo per il contratto iOS↔harness.
