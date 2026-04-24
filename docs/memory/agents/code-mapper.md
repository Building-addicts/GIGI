# code-mapper session log

## 2026-04-24 — bootstrap + Phase 4 (Tailscale + QR pairing, commit `ca8a599`)

**Status:** COMPLETED
**Trigger:** Orchestrator request after P4.1-P4.8 landed in `ca8a599` (12 files, +1018).
**Scope:** first-time creation of `docs/memory/CODE_MAP.md` and `docs/memory/CHANGELOG.md` + map of Phase 4 surface.

### What I did
- Verified `docs/memory/` existed (ACTIVITY_LOG.md + DOC_STATUS.md + agents/) but `CODE_MAP.md` / `CHANGELOG.md` / `agents/code-mapper.md` did not.
- Read the 4 new files and 5 modified files listed in the task brief.
- Grep-confirmed call sites of `GigiPairingSheet` (2 presenters: `SettingsView` + `MainTabView`) and the `/pair` handler in `panel-routes.js`.
- Confirmed the `handlePair` dispatch happens at `server.js:176`, BEFORE `handleIosRequest` at :177 — matches the brief.
- Wrote `CODE_MAP.md` with: module index, per-function entries for every Phase 4 function (public + private helpers), and a dedicated "Cross-module edges" section.
- Wrote `CHANGELOG.md` with the Phase 4 entry (files modified table, functions added/modified/removed, connection changes, impact on other code).
- Appended entry to `ACTIVITY_LOG.md`.

### Decisions
- **Did not retro-map earlier phases.** The brief was Phase 4 only; retro-mapping Phase 1-3 and harness fasi 10-18 would balloon this pass. Future code-mapper runs can add modules incrementally as tasks touch them. Noted this in CODE_MAP.md's header and CHANGELOG.md's bootstrap note.
- **Did not count `qrcode` dep as a function.** It's an npm package; recorded as a new edge (`api/pair.js → qrcode`) in the CHANGELOG.
- **Flagged no BREAKING changes.** `harnessSection` rewrite kept old TextField path alive under `DisclosureGroup`, and `userFacingError` keeps the same signature.

### Breaking changes surfaced
None.

### Key connections discovered
- `MainTabView.pairingBanner` → `GigiHarnessClient.shared.isConfigured` (new caller) + presents `GigiPairingSheet`.
- `SettingsView.harnessSection` → presents `GigiPairingSheet`; `GigiKeychain.delete` on unpair.
- `GigiPairingSheet.process` → `GigiKeychain.save`/`delete`, `GigiHarnessClient.ensureDeviceId`, `GigiHarnessClient.shared.health()`.
- `server.js` request flow → `handlePair` (loopback) THEN `handleIosRequest` (Bearer).
- `panel-routes.js /pair` → `public/pair.html` → client-side `fetch http://<host>:7779/api/pair[?format=svg]`.

### Open questions / follow-ups for future sessions
- When Phase 1 wire-up (P1.4) lands on main, map `GigiClaudeBridge.run(task:context:)` + `ensureStreamConnected` + `handleStreamEvent` + `translateClaudeEvent` fully (currently only `userFacingError` is in the map).
- Retro-map `GigiHarnessClient` (isConfigured / ensureDeviceId / health / agentRun) — it's a hub function with many callers after Phase 4 and will keep accumulating them.
- Retro-map harness-side `ios-router.js`, `ios-auth.js`, `ios-agent.js`, `ios-stream.js` — they anchor the rest of the backend.
- If/when `/pair` grows behind a proxy (VPS deployment), the CORS origin hardcode `http://localhost:7777` in `api/pair.js` will need to be revisited.
