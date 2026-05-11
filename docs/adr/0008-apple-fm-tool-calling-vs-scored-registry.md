# ADR-0008: Apple FM Tool calling vs scored tool registry (closes TD-001)

- **Status:** Accepted (scaffold implemented 2026-05-12, runtime opt-in default-on)
- **Date:** 2026-05-12
- **Deciders:** @ArmandoBattaglino
- **Tags:** ios, tool-calling, apple-foundation-models, technical-debt, phase-2

## Context

The legacy `GigiToolRegistry.selectRelevant_DEPRECATED()` (renamed
2026-05-11) ranked 47 tools by keyword overlap with the user utterance,
then handed the top-N to whichever LLM was driving (Groq, Apple FM,
Claude). The scoring was brittle — see TD-001 in plan §6:

- Synonym misses (e.g. "torcia" vs "flashlight").
- Multi-word intents truncated to a single token.
- No way to teach the model new tool names without retraining keywords.

Apple Foundation Models (iOS 26+) ships a `Tool` protocol with constrained
decoding: the framework guarantees the model picks one of the provided
tools and fills its `@Generable Arguments` correctly. No scoring needed.

## Decision

We replace `selectRelevant_DEPRECATED` with **`GigiFoundationToolRegistry`**
— 15 hand-curated `Tool` structs that wrap canonical actions in
`GigiActionBridge`. The router (ADR-0007) decides `path: "native_tool"`
and a `primaryAction`; the dispatcher picks the matching `FM*Tool` from
the registry and hands it to `LanguageModelSession.respond` via
`GigiFoundationSession.respondWithTools(text:tools:history:)`.

The 15 chosen tools (Q2 decided):

```
set_timer, set_alarm, set_reminder, send_message, make_call, facetime,
navigate, play_music, open_app, weather, read_calendar, find_free_slot,
read_email, homekit_on, homekit_off
```

Notes on the cut:

- `delegate_to_claude` excluded — handled by the router's `delegate_cloud`
  path, not surfaced as a tool (cleaner separation).
- HomeKit kept split (on / off) because the bridge handlers are split
  and a single `homekit_toggle(state:)` would just defer the branching
  one level deeper.
- The remaining ~32 actions in `GigiActionBridge` (HomeKit dim/temp/lock/scene,
  media controls, news, food order, restaurant booking, etc.) stay reachable
  via NLU fast-path or via Path 3/4 delegation — they're not lost.

## Implementation (2026-05-12)

- `02_GIGI_APP/GIGI/GigiFoundationToolRegistry.swift` — 15 `FM*Tool` struct + `allTools` static array + `tool(for:)` lookup.
- Each tool: `@available(iOS 26.0, *)`, `Tool` conformance, `@Generable Arguments` with `@Guide` field hints, `@MainActor call(arguments:)` → shared `dispatchAction(label:params:)` → `GigiActionBridge.execute(GigiIntent)`.
- Tools renamed with `FM` prefix (`FMSetTimerTool`, etc.) to avoid collision with the legacy `GigiToolRegistry.swift` `SetTimerTool: GigiTool` (transitional, removed in GATE 8 cleanup).
- `GigiRequestRouter.dispatchNativeTool` — two modes:
  - **(A) Apple FM Tool round-trip** via `respondWithTools` (1-2s, best slot quality). Default-on, gated by `UserDefaults("gigi.feature.path2_apple_fm_tools")`. Settings → Debug toggle exposes the switch.
  - **(B) Slot-extracted bridge** — uses `decision.slots` already populated by the router, maps to `GigiIntent` params, dispatches directly (~80-200ms). Fallback when (A) fails, the tool isn't found, or the feature flag is off.

## Alternatives considered

1. **Keep `selectRelevant` with smarter keyword scoring** (TF-IDF, embeddings). Rejected: incremental gain, doesn't fix the core problem that the downstream LLM is a better picker than a keyword score.
2. **Pass all 15 tools every turn**. Considered: works but the context budget is tight. Currently we pass only the single tool matching `decision.primaryAction` — keeps system prompt + tool defs under 1.5k tokens.
3. **Defer Apple FM tool calling to GATE 8** and use bridge-only path in GATE 3. Rejected: bridge path doesn't exercise the `Tool` protocol, so Spike A wouldn't validate the real flow.

## Consequences

**Pros**

- Constrained decoding eliminates the synonym / scoring problems of `selectRelevant`.
- Tool surface is small (15) and human-curated.
- A/B between (A) Apple FM Tool round-trip and (B) bridge slot path is a UserDefaults toggle — measurable.
- Closes TD-001 cleanly.

**Cons / risks**

- iOS 26.4 may regress tool calling (Spike A pending, ADR-0011).
- 15 may be too small for power users — extension surface is `FM*Tool` struct creation, no registry editing.
- `respondWithTools` signature assumption: `LanguageModelSession(tools: [any Tool], instructions: String).respond(to:)`. Build SUCCEEDED confirms compile-time OK; runtime behavior validated in GATE 1 Spike A.

## References

- `docs/plans/frolicking-stargazing-pancake.md` §3.6, §3.7, §3.8
- `docs/taskplans_new_gigi/GATE-3-path-2-applefm-tool-calling.md`
- `02_GIGI_APP/GIGI/GigiFoundationToolRegistry.swift` — 15 FM Tool struct
- ADR-0007 — Hybrid 5-path router
- ADR-0009 — Hardware targets + fallback router for non-Apple-FM devices
- ADR-0011 — iOS 26.4 regression mitigation
