# `docs/knowledge/` — knowledge base

> Technical and conceptual reference documents that re-contextualize project
> decisions. Unlike **ADRs** (immutable decisions) or **runbooks** (operational
> procedures), Knowledge files are **living studies** updated as the knowledge
> evolves. They capture the "why" behind decisions in depth.
>
> Written in English for the worldwide OSS audience.

## Index

| File | Scope | Last update |
|---|---|---|
| [llm-open-source-research.md](llm-open-source-research.md) | Comprehensive map of open-source LLMs in 2026 — architectural paradigms (dense, MoE, reasoning), quantization, inference engines, 7-tier hardware landscape, **Qwen ecosystem deep-dive (§7)** with community pattern + Qwen 3.5 warning, tier-based shortlist for agent runtimes | 2026-05-10 (v2) |
| [nlu-primer.md](nlu-primer.md) | Natural Language Understanding primer — definitions (NLP/NLU/LLM), the two core tasks (intent classification + slot filling), three implementation approaches (rule-based / ML / LLM-based) with trade-offs, modern hybrid pattern | 2026-05-10 |

## Conventions

- **File naming**: `kebab-case.md`
- **Required header**: `# Title — yyyy-mm-dd` (date of last substantive update)
- **Sources section** at the end, with clickable links to primary sources
  (papers, blogs, official docs)
- **Updates tracked** in `docs/memory/CHANGELOG.md` when content changes
  non-cosmetically
- **Internal cross-links** to `docs/adr/`, `docs/runbooks/`, `docs/rework/`
  where relevant
- **Language**: English. Project documentation in `docs/rework/`, `docs/adr/`
  may be in other languages for historical reasons, but Knowledge files target
  the worldwide audience.

## When to add a new Knowledge file

Create a new `kebab-case.md` when:

- You've investigated a tech alternative (LLM models, frameworks, libraries)
  and want to save the analysis
- You've synthesized a series of benchmarks / live tests and want to track
  the findings
- You've studied a theoretical concept (NLU, embeddings, RAG) to
  re-contextualize future decisions

A Knowledge file does NOT replace an ADR. An ADR is a *decision taken*; a
Knowledge file may lead to one or more ADRs. Convention: write the Knowledge
file first, then derive an ADR from it.

## When NOT to add a new Knowledge file

- Operational repeated procedures → `docs/runbooks/`
- Architectural decision made → `docs/adr/`
- Capability map or inventory snapshot → `docs/rework/`
- Codebase / dependency snapshot → `docs/research/`

## Planned future additions (placeholders)

- `docs/knowledge/embeddings-and-rag.md` — when memory unification work
  begins, deep-dive into embedding models (BGE-M3, E5, Nomic) and RAG
  patterns for local agents
- `docs/knowledge/voice-tts-state-of-the-art.md` — when voice quality
  upgrade work begins, mapping of expressive TTS (Coqui, F5-TTS, Kokoro,
  XTTS, ElevenLabs equivalent OSS)
- `docs/knowledge/computer-use-strategies.md` — comparative analysis of
  computer-use approaches (Anthropic SDK, Claude Code + MCP, local
  vision models with Playwright)
- `docs/knowledge/agent-architecture-patterns.md` — comparison of agent
  patterns (cascade, router-upfront, supervisor multi-agent, ReAct loop)
  with trade-offs
