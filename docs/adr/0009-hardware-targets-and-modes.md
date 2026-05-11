# ADR-0009: Hardware targets + fallback router + 4 operating modes

- **Status:** Accepted (scaffold implemented 2026-05-12, Q11 pending Spike A)
- **Date:** 2026-05-12
- **Deciders:** @ArmandoBattaglino
- **Tags:** ios, hardware, mvp-scope, fallback, mode-selection, phase-2

## Context

Per Statista 2025, ~6-10% of installed iPhones globally have hardware
that supports Apple Intelligence (iPhone 15 Pro/Pro Max, iPhone 16
series, iPhone 17 series, iPad with M-series). For an OSS demo this is
acceptable, but the demo collapses to Path 1 (NLU rules) + Path 4 (Claude
Code) only on legacy hardware — losing Path 3 (Ollama) entirely, which
is the cheapest reasoning path.

The plan §3.9 defines **4 operating modes** that combine available paths
and degrade gracefully based on infrastructure presence:

| Mode | Paths active | Requirements |
|---|---|---|
| **Minimal**         | 1 + 4 (NLU + Claude Code) | Claude Code subscription |
| **Local-First**     | 1 + 2 + 3 (NLU + Apple FM + Ollama) | Apple Intelligence + Ollama on harness |
| **Apple Optimized** | 1 + 2 + 4 (NLU + Apple FM + Claude Code) | Apple Intelligence + Claude Code subscription |
| **Full Power**      | 1 + 2 + 3 + 4 (all paths) | All three above |

## Decision

We adopt:

1. **iOS deployment target 26.2** (current). Q11 (pin 26.3 vs accept 26.4 vs feature flag) **deferred until Spike A results** — see ADR-0011.
2. **`GigiFallbackRouter` keyword-based** as a first-class router for devices that cannot run Apple FM (iPhone <15 Pro, iOS <26, Apple Intelligence disabled, or model assets not yet downloaded). Same `FoundationRouterDecision` output shape as Apple FM router — dispatch logic is identical.
3. **4-mode `GigiMode` enum** selectable from Settings → Modes. Mode is read by `GigiRequestRouter` at every route to gate paths and remap denied paths to the nearest enabled alternative.
4. **`GigiModeDetector`** capability probe runs at boot (and on app foreground) to auto-suggest the best available mode in the onboarding card and to show ✅/❌ requirement badges per mode in `ModesSelectionView`.

## Implementation (2026-05-12)

- `02_GIGI_APP/GIGI/GigiMode.swift` — `GigiMode` enum (4 cases) + per-mode `displayName`, `summary`, `requirements`, `privacyHint`, `latencyHint`, `allowsAppleFMRouter`, `allowsLocal`, `allowsCloud`, `remap(path:capabilities:)`.
- `02_GIGI_APP/GIGI/GigiFallbackRouter.swift` — keyword tables for 15 native actions + reasoning / browser / code / reject keywords. Regex slot extraction for duration / time / contact / destination / appName / accessory / weather location.
- `02_GIGI_APP/GIGI/GigiModeDetector.swift` — async probes: Apple FM (via `GigiFoundationSession.isAvailable`), Ollama (via `GigiHarnessClient.localLLMStatus()`), Claude Code (via `GigiHarnessClient.pingHealth()` proxy until GATE 5 `/api/ios/agent/claude-status` ships). 60s TTL cache; manual invalidate after re-pair.
- `02_GIGI_APP/GIGI/ModesSelectionView.swift` — SwiftUI selection screen with 4 mode cards, requirement checklist, "Re-check availability" button.
- `02_GIGI_APP/GIGI/SettingsView.swift` — `modesSection` with `NavigationLink` to `ModesSelectionView` and current active mode badge.
- `02_GIGI_APP/GIGI/GigiRequestRouter.swift` — reads `UserDefaults("gigi.user.mode")` at every route, applies `GigiMode.remap` before dispatch.

## Alternatives considered

1. **Hard-cut to iPhone 15 Pro+ only**. Rejected: kills the OSS demo for 90% of users.
2. **Single "auto" mode with no user choice**. Rejected: users want to opt into Local-First for privacy or Minimal for setup simplicity. Surfacing the trade-off is good UX.
3. **Mode set via Onboarding only, no Settings entry**. Rejected: needs to be revisitable when the user adds Ollama or Claude Code later.

## Consequences

**Pros**

- Coverage for legacy iPhones — Ollama still reachable via fallback router + Local-First mode.
- Clear user choice between privacy, cost, and capability.
- Auto-detection avoids confusing users who don't know what they have installed.

**Cons / risks**

- `GigiModeDetector` probes hit the harness twice per refresh (60s TTL cap usually masks this). Cancel-aware in future.
- "Privacy Max" renamed to "Local-First" because Apple Private Cloud Compute (PCC) opacity means we can't claim 100% on-device. Recorded in `docs/HOW_GIGI_WILL_WORK.md` §5.

## References

- `docs/plans/frolicking-stargazing-pancake.md` §3.8, §3.9
- `docs/taskplans_new_gigi/GATE-7-modes-setup-wizard.md`
- `02_GIGI_APP/GIGI/GigiMode.swift`
- `02_GIGI_APP/GIGI/GigiFallbackRouter.swift`
- `02_GIGI_APP/GIGI/GigiModeDetector.swift`
- `02_GIGI_APP/GIGI/ModesSelectionView.swift`
- ADR-0007 — Hybrid 5-path router
- ADR-0011 — iOS 26.4 regression mitigation (Q11 closure)
