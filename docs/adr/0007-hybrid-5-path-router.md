# ADR-0007: Hybrid 5-Path request router (Apple FM upfront + cost-aware)

- **Status:** Proposed
- **Date:** TBD
- **Deciders:** @ArmandoBattaglino
- **Tags:** ios, routing, apple-foundation-models, architecture, phase-2

## Context

> **Placeholder** — fleshed out during Phase 1 design doc.
>
> Drift architetturale documentato: Apple FM è codice presente ma dormant
> nel main flow (vedi `docs/plans/frolicking-stargazing-pancake.md` §3 +
> conversation transcript "Perché Apple FM è dormant"). Il piano 5-path
> riconsegna ad Apple FM il ruolo di **router upfront**, sostituendo il
> 3-Gate flat attuale (Force Claude → NLU → Groq planner + agent loop).

## Decision

TBD.

> Adottiamo router Apple FM upfront con `FoundationRouterDecision` schema,
> cost-aware routing (Path 3 Ollama / Path 4 Claude Code), e fallback
> rule-based per device non-Apple-FM-capable.

## Alternatives considered

TBD (vedi plan §3.5 + §3.10 SwiftMCP).

## Consequences

TBD.

## References

- `docs/plans/frolicking-stargazing-pancake.md` §3, §3.4, §3.5
- ADR-0006 — UI cleanup MVP trim (D1 Brain Path Override picker preview)
- ADR-0008 (TBD) — Apple FM Tool calling
- ADR-0009 (TBD) — Hardware targets + fallback
- ADR-0011 (TBD) — iOS 26.4 regression mitigation
- `docs/research/phase-1-1-empirical-validation.md` — Spike A gate
