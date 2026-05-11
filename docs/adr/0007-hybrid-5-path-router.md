# ADR-0007: Hybrid 5-Path request router (Apple FM upfront + cost-aware)

- **Status:** Accepted (scaffold implemented 2026-05-12, Spike A still pending)
- **Date:** 2026-05-12
- **Deciders:** @ArmandoBattaglino
- **Tags:** ios, routing, apple-foundation-models, architecture, phase-2

## Context

Apple Foundation Models was code-present but dormant in the main flow prior
to Phase 2 — every non-NLU query went through the harness Claude bridge,
which was wasteful for native iOS actions ("set timer", "call mum") and
expensive for the rare reasoning task. Phase 2 hands Apple FM the role of
**upfront router**, replacing the 2-gate flat (NLU fast-path → harness
Claude) with a 5-path dispatcher.

The five paths:

1. **native_tool** — an iOS-native action GIGI can run on-device (15 canonical actions: set_timer, set_alarm, set_reminder, send_message, make_call, facetime, navigate, play_music, open_app, weather, read_calendar, find_free_slot, read_email, homekit_on, homekit_off).
2. **delegate_local** — simple-to-medium reasoning sent to harness Ollama (Qwen 3 family) when complexity ≤ 40 and no browser/code/vision is needed.
3. **delegate_cloud** — complex reasoning or browser/code/vision sent to harness Claude Code (subprocess with MCP `harness-browser`).
4. **ask_clarification** — single short disambiguation question.
5. **reject** — polite refusal for illegal / harmful / nonsense queries.

Apple FM `@Generable struct FoundationRouterDecision` constrains decoding so
the model cannot return a `path` value outside this set.

## Decision

We adopt the Apple FM upfront router with the `FoundationRouterDecision`
schema, cost-aware routing rules, and a rule-based fallback router for
devices that cannot run Apple FM. The router is **mode-aware**: the
selected operating mode (Minimal / Local-First / Apple Optimized / Full
Power, see ADR-0009) can disable specific paths and the dispatcher remaps
to the nearest enabled alternative.

Key invariants:

- The NLU fast-path stays **before** the router for the 24 NLU intents
  (saves the ~1-2s Apple FM round-trip for obvious commands).
- The DEBUG `BrainPathOverride` picker bypasses the router entirely — used
  for spike testing each path in isolation.
- The cost-aware threshold is `complexity ≤ 40 && requiredCapabilities ∩ {browser, code, vision} == ∅`.
- When Apple FM is unavailable or fails, `GigiFallbackRouter` (keyword-based) takes over with the same `FoundationRouterDecision` shape.

## Implementation (2026-05-12)

- `02_GIGI_APP/GIGI/GigiFoundationContracts.swift` — `FoundationRouterDecision @Generable` (9 fields) + `ActionSlots @Generable` (11 fields).
- `02_GIGI_APP/GIGI/GigiFoundationSession.swift` — `routeRequest(text:history:)` runs on a dedicated `routerSession` seeded with `routerSystemPrompt`.
- `02_GIGI_APP/GIGI/GigiFoundationAgent.swift` — `routerSystemPrompt` (~3.5k chars, 9 few-shot examples).
- `02_GIGI_APP/GIGI/GigiRequestRouter.swift` — `route(text:history:)` entry point + 5 dispatch funcs + slot-to-params mapping for `GigiActionBridge`.
- `02_GIGI_APP/GIGI/GigiFallbackRouter.swift` — keyword-based router with the same shape, regex slot extraction.
- `02_GIGI_APP/GIGI/GigiAgentEngine.swift` — `process(text:)` rewired: BrainPathOverride → NLU fast-path → `GigiRequestRouter.route()`.
- `02_GIGI_APP/GIGI/GigiMode.swift` — 4 modes with `remap(path, capabilities)` policy.

## Alternatives considered

1. **Rule-based router first-class** (NLU expanded to N intents, Apple FM only for ambiguity). Rejected: NLU expansion is brittle; Apple FM constrained decoding gives `path` + slots in one round-trip with higher accuracy.
2. **Multi-pass router** (round 1 = classify, round 2 = extract slots). Rejected: doubles latency for no quality gain when slots are co-extractable in the same `@Generable` call.
3. **SwiftMCP first-class router** (plan §3.10 Spike D). Rejected for MVP: SwiftMCP feasibility unproven; deferred to Phase 5 post-v0.1.0.

## Consequences

**Pros**

- Single source of truth for routing logic (router decision + dispatch).
- Cost-aware path picking — Ollama for cheap reasoning, Claude Code for hard tasks.
- Mode gating gives the user clear privacy/cost trade-offs.
- Fallback router preserves coverage on ~90% of iPhones without Apple FM hardware.

**Cons / risks**

- Apple FM tool calling on iOS 26.4 may regress (Spike A pending; mitigation in ADR-0011).
- `complexityEstimate` is LLM-generated and may drift — telemetry needed for calibration (deferred to GATE 8).
- Router system prompt + tool defs + history must stay under 4k tokens.

## References

- `docs/plans/frolicking-stargazing-pancake.md` §3, §3.4, §3.5, §3.7
- `docs/taskplans_new_gigi/GATE-2-router-applefm-upfront.md`
- ADR-0006 — UI cleanup MVP trim (D1 Brain Path Override picker preview)
- ADR-0008 — Apple FM Tool calling
- ADR-0009 — Hardware targets + fallback + 4 modes
- ADR-0011 — iOS 26.4 regression mitigation (pending Spike A)
- `docs/research/spike-a-test-set.md` — 50-query test set for empirical validation
