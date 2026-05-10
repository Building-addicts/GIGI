# ADR-0009: Hardware target iPhone 15 Pro+ + fallback degradation modes

- **Status:** Proposed
- **Date:** TBD
- **Deciders:** @ArmandoBattaglino
- **Tags:** ios, hardware, mvp-scope, fallback, mode-selection, phase-2

## Context

> **Placeholder** — fleshed out during Phase 1 design doc.
>
> Per Statista 2025, ~6-10% degli iPhone installati globalmente ha hardware
> Apple Intelligence-capable. Per OSS demo è target accettabile, per mass
> market sarebbe gating. Il piano definisce **4 modes operativi**
> (Minimal / Privacy Max / Apple Optimized / Full Power) che combinano i
> path disponibili e degradano graceful in base a infra presente +
> hardware capability.

## Decision

TBD. Q11 (iOS 26.3 vs 26.4 pin) bloccante.

> Adottiamo iOS deployment target **26.3** con feature flag che riabilita
> Path 2 quando 26.5+ esce. Fallback rule-based primo-citizen
> (`GigiFallbackRouter`) per device non-Apple-FM-capable. 4 modes
> selezionabili da Settings.

## Alternatives considered

TBD (vedi plan §3.8, §3.9).

## Consequences

TBD.

## References

- `docs/plans/frolicking-stargazing-pancake.md` §3.8, §3.9
- `02_GIGI_APP/GIGI/GigiFallbackRouter.swift` (stub Phase 2)
- ADR-0011 (TBD) — iOS 26.4 regression mitigation
