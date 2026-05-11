# Changelog

All notable changes to GIGI from public-release-onwards. Versioning roughly
follows [SemVer](https://semver.org/) with major bumps gated on demo
quality + breaking-API changes.

## [Unreleased] — v0.1.0-rc — Phase 2-4 scaffold (2026-05-12)

### Added — 5-path router (GATE 2)

- `FoundationRouterDecision` `@Generable` schema with 9 fields drives every
  non-NLU dispatch (path, primaryAction, confidence, complexity,
  capabilities, reason, slots, directSpeech, delegatePrompt). Apple FM
  constrained decoding guarantees `path` is one of:
  `native_tool | delegate_local | delegate_cloud | ask_clarification | reject`.
- `ActionSlots` `@Generable` (11 fields) carried inside every decision.
- `GigiFoundationSession.routeRequest(text:history:)` runs on a dedicated
  router session with the new `routerSystemPrompt` (~3.5k chars, 9 few-shot
  examples).
- `GigiRequestRouter.route(text:history:)` is the new primary dispatcher.
  5 dispatch functions, slot-to-params mapping, mode gating, fallback chain.
- `GigiFallbackRouter` keyword-based for devices without Apple Foundation
  Models. Same `FoundationRouterDecision` shape — dispatch logic is identical.
- `GigiAgentEngine.process` rewired: BrainPathOverride → NLU fast-path →
  `GigiRequestRouter.route()`. The legacy `harness Claude bridge` falls back
  as the cloud catch.

### Added — Apple FM Tool calling (GATE 3)

- 16 `FM*Tool` struct conforming to Apple FM `Tool` protocol (iOS 26+):
  set_timer, set_alarm, set_reminder, send_message, make_call, facetime,
  navigate, play_music, open_app, weather, read_calendar, find_free_slot,
  read_email, homekit_on, homekit_off, **create_note** (added for GATE 6).
- `GigiFoundationToolRegistry.allTools` + `tool(for:)` lookup.
- `GigiFoundationSession.respondWithTools(text:tools:history:)` API.
- `GigiRequestRouter.dispatchNativeTool` has two modes: pure Apple FM
  Tool round-trip (default-on for iOS 26+) and slot-extracted bridge
  fallback. Toggle in Settings → Debug.

### Added — Ollama Path 3 (GATE 4)

- `03_HARNESS/server/local-llm/ollama-client.js` full HTTP client with
  `generate()`, `chat()`, `listModels()`, `pullModel()`, `isReachable()`,
  AbortSignal wired through.
- `03_HARNESS/server/api/ios-local-llm.js` SSE endpoints:
  `POST /generate` (event:chunk + event:done + event:error),
  `GET /status` (reachable + models + RAM-based recommendedTier),
  `POST /cancel` (AbortController registry per runId).
- `GigiHarnessClient.runLocalLLM(prompt:history:)` `AsyncStream` SSE consumer.
- Settings → 🦙 Ollama section with tier picker (lite/standard/default/pro),
  status badge, installed models list.

### Added — Claude Code subprocess + MCP (GATE 5)

- `03_HARNESS/server/api/ios-claude-agent.js` real subprocess wiring via
  `gigiServer.runClaude(cfg, prompt, deviceId, onEvent, onSpawn, { mcpServers })`.
  Claude JSONL events → SSE translation. Cancel via `POST /claude/cancel`
  SIGTERMs the subprocess.
- `GigiHarnessClient.runClaudeCode(prompt:mcpServers:)` `AsyncStream` SSE consumer.
- `GigiHarnessClient.claudeCodeStatus()` probe via `/agent/claude-status`.
- `ConfirmComputerUseSheet` SwiftUI sheet wired client-side. Server-side
  `confirm_required` event emission deferred to follow-up (Claude CLI lacks
  native interrupt hook).
- `unset ANTHROPIC_API_KEY` in `start-harness.sh` (anti-billing for Issue
  claude-code#45572).

### Added — Operating modes + setup wizard (GATE 7)

- `GigiMode` 4-mode enum (Minimal / Local-First / Apple Optimized / Full Power)
  with per-mode `remap(path:capabilities:)` policy.
- `GigiModeDetector` capability probes (Apple FM, Ollama, Claude Code) with
  60s TTL cache and best-available-mode auto-suggest.
- `ModesSelectionView` SwiftUI screen with 4 mode cards (requirements
  checklist ✅/❌, latency hint, privacy hint, Select/Setup button).
- Settings → ⚙️ Modes section.
- `scripts/setup-oss-demo.sh` 10-step idempotent OSS bootstrap wizard.

### Added — Killer demo multi-step (GATE 6)

- `GigiRequestRouter.dispatchDelegateCloud` detects "research + action"
  patterns in the original utterance and auto-chains a 2-turn callback:
  Path 4 returns summary → Path 2 dispatches `create_note` /
  `set_reminder` / `send_message` with the summary as body.
- `FMCreateNoteTool` (16th tool) + `GigiActionBridge.createNote` writes to
  clipboard + opens Notes app (URL scheme limitation).
- `docs/research/gate-6-killer-demo.md` with 5 demo scenarios (Tesla, weather,
  news, recipe, score) + 4 failure-mode tests.

### Added — Empirical validation scaffolds

- `docs/research/spike-a-test-set.md` — 50-query test set for Apple FM iOS
  26.x regression (Spike A).
- `docs/research/spike-a-results.md` — results template (50 × 3 runs = 150).
- `docs/research/gate-2-router-integration-test.md` — 10-query router integration test.
- `docs/research/gate-3-tool-coverage.md` — 15-tool coverage matrix + A/B
  comparison (FM round-trip vs bridge).
- `docs/research/gate-4-ollama-e2e.md` — 8 reasoning queries + 4 failure modes.
- `docs/research/gate-6-killer-demo.md` — 5 multi-step scenarios.

### Changed

- ADR-0007 / 0008 / 0009 / 0010 closed (Proposed → Accepted) with
  implementation details and file pointers.
- `INDEX.md` GATE status table updated (8 GATE statuses).
- `start-harness.sh` unsets `ANTHROPIC_API_KEY` before spawning the harness.
- `BrainPathOverride.helpText` rewritten to reflect post-Phase 2 reality
  (no more Groq, 5-path named).

### Removed

- `@anthropic-ai/sdk` removed from `03_HARNESS/server/package.json`. Only
  importer was `ios-computer-use.js`, now moved to
  `server/examples/ios-computer-use-anthropic-sdk.js.legacy`. Path 4
  uses Claude Code subscription via subprocess instead.
- `GET /api/ios/computer-use/*` + `POST /api/ios/computer-use` routes
  return `410 Gone` with migration hint to `/api/ios/agent/claude`.

### Fixed

- `BUILD FAILED — missing import of defining module 'Combine'` in
  `GigiModeDetector.swift` (added `import Combine`).
- `BUILD FAILED — invalid redeclaration of SetTimerTool` collision between
  legacy `GigiToolRegistry.swift` and new `GigiFoundationToolRegistry.swift`
  resolved by `FM` prefix on all 16 new struct.
- `BUILD FAILED — missing argument for parameter #1` (no-arg `ActionSlots()`
  init on `@Generable` struct) resolved with explicit `emptySlots()` helper.

## [v0.0.x] — Phase 0-1 (pre-2026-05-11)

- Initial scaffold: 01_SERVER_MDM (MDM iOS profiles), 02_GIGI_APP (Swift +
  SwiftUI), 03_HARNESS (Node + Claude CLI + MCP).
- Cloudflare Tunnel pairing (ADR-0001).
- NLU fast-path with 24 intents (on-device).
- Force Claude legacy bridge.
- Apple Intelligence integration via `GigiFoundationAgent` (one-shot intent
  classification).
- HomeKit native actions (on/off, dim, temp, lock, scene).
- WhatsApp Web automation + Google Sign-In (later removed in ADR-0004).
- Wake word soft-kill (ADR-0003) + Day Plan Reasoner soft-kill (ADR-0005).
- UI cleanup MVP trim (ADR-0006): 3 tabs, 6 onboarding steps, brain pill
  consolidated.
- Groq removal (2026-05-11): Path 5 of the legacy 3-Gate flat removed; bridge
  thinned. `GigiPlannerEngine` archived to `_legacy/`.

---

**Notes on what's NOT in v0.1.0-rc:**

- ❌ Apple FM Tool calling validated on iOS 26.4 (Spike A pending)
- ❌ Qwen 3 14B BFCL accuracy validated (Spike B pending)
- ❌ Claude Code subscription burn-rate data (Spike C pending)
- ❌ ConfirmComputerUseSheet wired to a real `confirm_required` event (Claude
  CLI needs interrupt hook upstream)
- ❌ Push notification proactive routine watchers (carried over from Phase 1)
- ❌ Multi-language UI (English only; harness LLM is multilingual)

These are tracked as follow-ups in `docs/HANDOFF_2026-05-12.md`.
