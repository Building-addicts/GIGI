# ADR-0014: AI Shortcut Authoring Pipeline (Cherri + Mac signing + harness bridge)

- **Status:** Accepted (MVP shipped 2026-05-13, commit 9b66cfa)
- **Date:** 2026-05-13
- **Deciders:** @ArmandoBattaglino
- **Tags:** ios, shortcuts, apple-fm, cherri, ai-authoring, harness

## Context

GATE 14.B.2 lite (ADR-0011) shipped a Shortcut Alias Registry + tier 1/2
pattern (addToNote, setAlarm fallbacks) but stopped short of letting GIGI
**author** new Shortcuts from natural language. The user explicitly asked
for the AI-generated path: *"facciamolo or noi abbiamo il Mac"* — i.e.
build the pipeline that produces signed `.shortcut` files from a user's
voice request.

Research findings (ADR-0012 § cont.) confirmed:
1. iOS 16+ requires `.shortcut` files to be Apple Encrypted Archive
   (AEA1) signed by Apple's iCloud crypto chain. **Unsigned files are
   rejected** at install with "Invalid Shortcut format".
2. The signing operation is exposed ONLY via the macOS `shortcuts sign`
   CLI subcommand. No public client-side API.
3. **[Cherri](https://github.com/electrikmilk/cherri) v2.2.0** (April
   2026, actively maintained, 1.5k stars) is a DSL → `.shortcut`
   compiler that calls `shortcuts sign` under the hood, with HubSign as
   a community-server fallback.
4. The user (Armando) had SSH access to a Mac (MacInCloud) — sufficient
   for an MVP signing server.

## Decision

Build a 3-tier pipeline:

1. **iOS — Apple FM @Generable spec generation** (on-device, ~200-400 ms)
   - New tool `FMBuildShortcutTool` in `GigiFoundationToolRegistry`
   - Apple FM produces `(title, actionsJSON)` constrained by a curated
     vocabulary of 17 Cherri actions (no free-form code generation,
     model can't hallucinate non-existent actions)
   - `GigiCherriDSL.translate(title:actions:)` materializes the Cherri
     source from the structured spec

2. **Harness — POST endpoint + Mac SSH/SCP** (~2-8 s)
   - `03_HARNESS/server/api/ios-build-shortcut.js` — handler with two
     routes: `POST /api/ios/build-shortcut` and
     `GET /api/ios/build-shortcut/<id>.shortcut`
   - Pipeline per request:
     1. Write DSL to local `<tmp>/gigi-shortcuts/<id>.cherri`
     2. `scp` to Mac (`HARNESS_MAC_SIGN_HOST` env)
     3. `ssh` Mac: `${HARNESS_MAC_CHERRI_BIN} <path> -s anyone`
     4. Cherri compiles + (local `shortcuts sign` OR HubSign fallback)
     5. `scp` signed `.shortcut` back
     6. Host with TTL 5 min, prune on every GET
     7. Return JSON `{ url, id, title }` with public URL
   - File serve: `Content-Type: application/x-apple-aspen-config` so
     iOS triggers Shortcuts.app preview

3. **iOS — Install flow** (~1 s)
   - `GigiHarnessClient.postBuildShortcut(payload:)` async-throws wrapper
   - `GigiActionBridge.buildShortcut(title:actionsJSON:)` handler
   - On success: `UIApplication.open(url)` → Shortcuts preview → user
     1-tap "Add Shortcut" (Apple-mandated, non-bypassable)

## Drivers

1. **AI-native UX** — users invent Shortcuts conversationally instead
   of clicking 5-20 actions in Shortcuts.app
2. **No Gallery review** — bypass Apple's 1-2 week Gallery submission
3. **Reusable architecture** — same pipeline supports future tools
   (Apple FM generates spec for any Cherri-vocabulary action, harness
   just compiles + signs)
4. **Constrained vocabulary** — Apple FM picks from a static action list,
   making outputs reliable and easy to grow

## Alternatives considered

### A. Generate `.shortcut` programmatically without Mac

Rejected. Apple cryptographic signing wall on iOS 16+ blocks any
self-signed/server-generated file. No public Apple API to sign without
the macOS `shortcuts` CLI. Reverse-engineering the AEA signature is
infeasible (requires Apple's private key).

### B. iCloud Shortcuts gallery submission per request

Rejected for runtime. Apple Gallery is for curated official Shortcuts
with 1-2 week review per submission. Cannot scale for per-user AI
generation.

### C. AI guides user through manual creation in Shortcuts.app

This is the GATE 14.B.2 lite "conversational builder" fallback path.
Acceptable but requires the user to click each action manually — not
true "AI-generated programmatic Shortcuts" as the user requested.

### D. Free-form Apple FM code generation (no vocabulary constraint)

Considered. Apple FM @Generable with a single `cherriSource: String`
field. Rejected because the model would hallucinate non-existent Cherri
actions on novel requests, leading to compile failures. Constrained
vocabulary is more robust for MVP.

## Consequences

### ✅ Positive

- Users can author Shortcuts via voice or chat, no Shortcuts.app
  expertise required
- 1-tap install preserves Apple security model (no bypass)
- Vocabulary is a Swift dictionary — easy to extend without harness
  changes
- HubSign fallback works on the user's MacInCloud setup without
  needing local `shortcuts sign` to be perfectly stable
- Latency budget: 200-400ms (Apple FM) + 2-8s (Mac sign) + 100ms
  (network) = ~3-9s total. Acceptable for "build a Shortcut" UX with a
  visible "🔧 Building..." banner

### ⚠️ Trade-offs

- **Mac dependency**: harness needs SSH access to a Mac running Cherri.
  Without `HARNESS_MAC_SIGN_HOST` env configured, build_shortcut
  errors out cleanly. MVP uses MacInCloud (~$30/mo); production would
  benefit from owner's Mac mini.
- **HubSign instability**: when local `shortcuts sign` fails on Mac
  (we observed an NSException at startup), Cherri falls back to
  HubSign community server. HubSign outages were reported May 2026.
  Self-hosted `shortcut-signing-server` is the production-grade
  replacement (deferred).
- **Vocabulary limit**: 17 actions out of Cherri's ~200+. Users
  requesting actions outside the vocabulary get a clear chat error
  asking to rephrase. Expansion is straightforward (add entry to
  `CHERRI_VOCABULARY`).
- **5-min TTL on hosted files**: if user delays install, the URL
  returns 410 Gone. Acceptable for an interactive flow.
- **SSH credentials**: harness Node needs SSH key access to the Mac.
  Setup is a one-time SSH-agent or `~/.ssh/config` task. Documented in
  `docs/runbooks/phase2-shortcut-pipeline-setup.md`.
- **Bandwidth**: each request ships ~200 bytes DSL + ~25 KB signed
  file across SSH/SCP. Negligible.

## Follow-ups

- **GATE 16** — replace HubSign with self-hosted
  `shortcut-signing-server` on the Mac mini for production reliability
- **Vocabulary expansion** — add Cherri actions for: HomeKit fine
  control, Calendar events, Reminders, Contact calls, Music playlist
  selection
- **Cherri syntax validation** — pre-flight check the generated DSL
  against Cherri's grammar before SSH to fail fast
- **Per-user signing identity** — currently all generated Shortcuts
  are signed by whatever account the Mac uses. For multi-user OSS, a
  signing proxy that uses user's own Apple ID is the long-term plan
- **Phase 3** — RuntimeAlias: register the just-installed Shortcut
  in `GigiShortcutRegistry` automatically via URL roundtrip detection

## Validation criteria

- [ ] User says *"build me a quick torch shortcut"* → Apple FM
  selects `build_shortcut` → DSL generated → Mac compiles → iOS opens
  preview → tap Add → installed. End-to-end < 10s.
- [ ] Vocabulary errors (e.g. *"build a shortcut that plays the
  flute"*) surface in chat with *"one of the actions isn't in my
  vocabulary yet"*, no crash, no silent fail.
- [ ] Harness without `HARNESS_MAC_SIGN_HOST` set → chat shows clear
  config error.
- [ ] Signed file TTL: install within 5 min works; after expiry GET
  returns 410.
- [ ] Language audit clean (English everywhere user-facing).

## Code locations

| File | Role |
|---|---|
| `02_GIGI_APP/GIGI/GigiCherriDSL.swift` | Vocabulary + translation |
| `02_GIGI_APP/GIGI/GigiFoundationToolRegistry.swift` | `FMBuildShortcutTool` registered |
| `02_GIGI_APP/GIGI/GigiActionBridge.swift` | `buildShortcut()` handler |
| `02_GIGI_APP/GIGI/GigiHarnessClient+Streams.swift` | `postBuildShortcut()` POST wrapper |
| `03_HARNESS/server/api/ios-build-shortcut.js` | POST + GET handlers |
| `03_HARNESS/server/api/ios-router.js` | Route wiring |
| `docs/runbooks/phase2-shortcut-pipeline-setup.md` | Setup steps for user |
