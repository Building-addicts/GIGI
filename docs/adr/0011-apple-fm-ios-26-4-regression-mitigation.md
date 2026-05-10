# ADR-0011: Mitigation for Apple FM iOS 26.4 tool-calling regression

- **Status:** Proposed
- **Date:** TBD
- **Deciders:** @ArmandoBattaglino
- **Tags:** ios, apple-foundation-models, risk-mitigation, phase-2

## Context

> **Placeholder** — fleshed out after Spike A results.
>
> Apple Developer Forums (multiple thread maggio 2026) riportano una
> regressione in iOS 26.4 nelle capacità di tool calling + instruction
> following di Apple Foundation Models:
> > "After installing iOS 26.4 the Foundation Models instruction following
> > and tool calling capabilities have been degraded significantly. The
> > model is not usable anymore."
>
> Il piano 5-path costruisce sopra `Tool` protocol Apple FM (Path 2 +
> router Gate 2). Una regressione del 15%+ collassa l'intera proposta.

## Decision

TBD. Decisione gate-dipendente da Spike A.

> Adottiamo: (1) pin `IPHONEOS_DEPLOYMENT_TARGET=26.3`, (2) feature flag
> `enablePath2NativeTools` che si disabilita automaticamente su 26.4 +
> regression detected, (3) `GigiFallbackRouter` primo-citizen quando
> Path 2 è gated.

## Alternatives considered

TBD (vedi plan §9 Risks).

## Consequences

TBD.

## References

- `docs/plans/frolicking-stargazing-pancake.md` §9 Risks (rischio alto #1)
- `docs/research/phase-1-1-empirical-validation.md` Spike A
- Apple Developer Forums — Foundation Models topic
- ADR-0007 — Hybrid 5-path router
- ADR-0009 — Hardware targets + modes
