# ADR-0010: Ollama as first-class Path 3 (Qwen 3 tier-based)

- **Status:** Proposed
- **Date:** TBD
- **Deciders:** @ArmandoBattaglino
- **Tags:** harness, ollama, qwen, offline-reasoning, phase-2

## Context

> **Placeholder** — fleshed out during Phase 1 design doc.
>
> Path 3 del piano 5-path = reasoning offline + privacy senza burn del cap
> Claude Code subscription. Standardizziamo su **Qwen 3 ecosystem**
> (Apache 2.0, hybrid thinking, 119 lingue) con tier-based selection
> (4B / 8B / 14B / 27B) in base al RAM detectato dal setup wizard.
>
> AVOID Qwen 3.5 family — Ollama tool calling broken (Issue
> ollama#14493). Reference Knowledge file: `docs/knowledge/llm-open-source-research.md` §7.

## Decision

TBD. Spike B (Qwen 3 14B vs 3.6-27B BFCL + loop test) bloccante.

> Adottiamo Ollama come Path 3 first-class. Default model =
> `qwen3:14b` (tier "default" 16-32GB RAM). Tier alternativi: lite (4B),
> standard (8B), pro (27B). Hybrid thinking togglable runtime.

## Alternatives considered

TBD (vedi plan §3.5).

## Consequences

TBD.

## References

- `docs/plans/frolicking-stargazing-pancake.md` §3.2, §7.Q1
- `docs/knowledge/llm-open-source-research.md` §7 (Qwen deep dive)
- `03_HARNESS/server/local-llm/ollama-client.js` (stub Phase 2)
- `03_HARNESS/server/local-llm/config.example.json` (template)
- `docs/research/phase-1-1-empirical-validation.md` Spike B
