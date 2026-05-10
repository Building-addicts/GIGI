# ADR-0008: Apple FM Tool calling vs scored tool registry (closes TD-001)

- **Status:** Proposed
- **Date:** TBD
- **Deciders:** @ArmandoBattaglino
- **Tags:** ios, tool-calling, apple-foundation-models, technical-debt, phase-2

## Context

> **Placeholder** — fleshed out during Phase 1 design doc.
>
> TD-001: `GigiToolRegistry.selectRelevant_DEPRECATED()` (renamed
> 2026-05-11) usa keyword scoring brittle per scegliere ~10 tool su 47 da
> esporre al Groq agent loop. Apple FM `Tool` protocol (iOS 26+) fa
> internal selection via constrained decoding — niente più keyword
> heuristics, ma serve un **subset curato di 15 tool** (4096-token
> context limit).

## Decision

TBD. Q2 (lista esatta 15 tool) bloccante per Phase 2.

> Adottiamo 15-tool Apple FM Tool registry (`GigiFoundationToolRegistry`),
> deprechiamo `selectRelevant_DEPRECATED`, deferiamo i restanti 32 tool al
> dispatcher generale (raggiungibili solo via Path 3/4 delegation).

## Alternatives considered

TBD (vedi plan §3.6).

## Consequences

TBD.

## References

- `docs/plans/frolicking-stargazing-pancake.md` §3.6
- `02_GIGI_APP/GIGI/GigiFoundationToolRegistry.swift` (stub Phase 2)
- ADR-0007 — Hybrid 5-path router
