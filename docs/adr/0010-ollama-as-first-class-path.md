# ADR-0010: Ollama as first-class Path 3 (Qwen 3 tier-based)

- **Status:** Accepted (scaffold implemented 2026-05-12, Spike B pending)
- **Date:** 2026-05-12
- **Deciders:** @ArmandoBattaglino
- **Tags:** harness, ollama, qwen, offline-reasoning, phase-2

## Context

Path 3 of the 5-path plan handles **offline reasoning + privacy** without
burning the Claude Code subscription cap. For an OSS demo this is critical
— users without a Claude Code Pro subscription still get medium-quality
reasoning. We standardize on the **Qwen 3 ecosystem** (Apache 2.0, hybrid
thinking, 119 languages) with tier-based model selection (4B / 8B / 14B /
27B) driven by harness RAM detected by the setup wizard.

**AVOID** Qwen 3.5 family — Ollama tool calling is broken (Issue
ollama#14493). Reference: `docs/knowledge/llm-open-source-research.md` §7.

## Decision

We adopt Ollama as Path 3 first-class via a dedicated harness wrapper
(`ollama-client.js`) and an iOS SSE consumer (`GigiHarnessClient.runLocalLLM`).
Tier-based model selection from `03_HARNESS/server/local-llm/config.json`:

| Tier      | Model       | Min RAM | Use case |
|-----------|-------------|---------|----------|
| lite      | qwen3:4b    | 4-8GB   | Older Macs, basic reasoning |
| standard  | qwen3:8b    | 8-16GB  | Mac mini M1/M2 8GB+, decent quality |
| **default** | **qwen3:14b** | **16-32GB** | **Mac M-series 16GB+, recommended** |
| pro       | qwen3.6:27b | 32GB+   | Mac Studio, max quality |

Hybrid thinking is togglable runtime (`think: true|false` in request body).

## Implementation (2026-05-12)

- `03_HARNESS/server/local-llm/ollama-client.js` — `OllamaClient` class with `generate()`, `chat()`, `listModels()`, `pullModel()`, `isReachable()`. AbortSignal wired through, 30s first-byte timeout + 5min hard cap.
- `03_HARNESS/server/api/ios-local-llm.js` — `POST /api/ios/local-llm/generate` SSE endpoint (event:chunk + event:done + event:error), `GET /status` (reachable + models + currentTier + recommendedTier via RAM probe), `POST /cancel` (AbortController registry per runId).
- `03_HARNESS/server/api/ios-router.js` — mount the 3 new endpoints.
- `02_GIGI_APP/GIGI/GigiHarnessClient+Streams.swift` — `runLocalLLM(prompt:history:)` returns `AsyncStream<LocalLLMEvent>` consuming SSE; `localLLMStatus()` probes `/status`.
- `02_GIGI_APP/GIGI/GigiRequestRouter.swift` — `dispatchDelegateLocal` invokes `runLocalLLM`, falls back to `dispatchDelegateCloud` on Ollama error if mode allows cloud.
- `02_GIGI_APP/GIGI/SettingsView.swift` — `ollamaSection` with tier picker (4 options), status badge (✅ reachable / ⚠️ unreachable / probing), installed models disclosure.
- `scripts/setup-oss-demo.sh` — detects Ollama install + probes RAM + suggests tier in step 5.

## Alternatives considered

1. **Llama 3.2 (Meta)**. Rejected: weaker tool calling than Qwen 3, smaller multilingual coverage.
2. **Phi-3 (Microsoft)**. Rejected: smaller context window, weaker on the BFCL benchmark.
3. **OpenAI API as Path 3**. Rejected: violates the OSS demo guarantee of "zero API to pay".
4. **Don't include Path 3 at all**. Rejected: would burn Claude Code subscription on cheap reasoning tasks.

## Consequences

**Pros**

- 100% on-LAN reasoning, no cloud egress.
- Cost-aware routing (router's `complexity ≤ 40 + non-browser` rule) keeps Claude Code reserved for hard tasks.
- Tier system means the demo works on a wide range of hardware.

**Cons / risks**

- 30 GB disk needed for all 4 model tiers — setup wizard pulls only the recommended tier.
- Qwen 3 14B BFCL accuracy + loop rate not yet validated empirically (Spike B pending, GATE 4).
- Cold-load latency 5-15s on first invocation after harness restart.
- If user reorders / disables Ollama daemon mid-session, fallback chain catches gracefully but the first failing turn is degraded.

## References

- `docs/plans/frolicking-stargazing-pancake.md` §3.2, §7.Q1
- `docs/knowledge/llm-open-source-research.md` §7 (Qwen deep dive)
- `docs/taskplans_new_gigi/GATE-4-path-3-ollama-harness.md`
- `03_HARNESS/server/local-llm/ollama-client.js`
- `03_HARNESS/server/local-llm/config.example.json`
- `03_HARNESS/server/api/ios-local-llm.js`
- `02_GIGI_APP/GIGI/GigiHarnessClient+Streams.swift`
- `docs/research/phase-1-1-empirical-validation.md` Spike B
- ADR-0007 — Hybrid 5-path router
