# ADR-0012: Path 2-fast — Apple FM + SwiftMCP bridge (opt-in, Phase 5)

- **Status:** Proposed
- **Date:** TBD
- **Deciders:** @ArmandoBattaglino
- **Tags:** ios, apple-foundation-models, mcp, latency-optimization, phase-5

## Context

> **Placeholder** — gate-dipendente da Spike D.
>
> SwiftMCP (sutheesh/SwiftMCP, MIT, ~300 righe glue code) + Apple
> `DynamicGenerationSchema` API permettono ad Apple FM iOS-side di
> chiamare MCP server harness-side **direttamente** via HTTP/SSE — niente
> spawn Claude Code subprocess per single-tool query (es. "che tempo fa",
> "che dice Wikipedia su X"). Risparmio latency stimato 50-70% sui casi
> coperti + alleggerimento Claude Code subscription weekly cap.
>
> **Non collassa Path 4**: per deep reasoning multi-step e browser
> automation Claude Code resta necessario (context 4096 tok Apple FM
> satura su 3-4 chiamate MCP grosse).

## Decision

TBD. Decisione gate-dipendente da Spike D risultati.

> Schedulato per Phase 5 se Spike D conferma feasibility (≥5 turni
> sustainable con 3 tool MCP attivi, latency ≥50% migliore di Path 4).
> Per il MVP 1 maggio: **NON inserire** — è enhancement post-launch.

## Alternatives considered

TBD (vedi plan §3.10 + validation deep dive 2026-05-10).

## Consequences

TBD.

## References

- `docs/plans/frolicking-stargazing-pancake.md` §3.10
- `docs/research/phase-1-1-empirical-validation.md` Spike D
- Swift Forums — SwiftMCP announcement
- ADR-0007 — Hybrid 5-path router
