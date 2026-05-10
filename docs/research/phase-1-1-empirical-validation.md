# Phase 1.1 — Empirical Validation Spikes

> **Status**: stub — pre-Phase 1 work. Document is filled during Spike A/B/C/D
> execution. Plan reference: `docs/plans/frolicking-stargazing-pancake.md` §5.

## Why this document exists

The 5-path plan rests on assumptions about Apple Foundation Models reliability,
Qwen tool calling stability on Ollama, Claude Code subscription burn rate, and
SwiftMCP feasibility. Each is documented but **not validated** with first-party
test data. Phase 1.1 is the **go/no-go gate** for Phase 2 implementation:

- If Spike A fails (Apple FM 26.4 regression >15%), pin to 26.3 (ADR-0011)
- If Spike B fails (Qwen 3 14B tool calling loops >5%), demote to 3.6-27B
  dense or accept Path 3 as reasoning-only
- If Spike C confirms Pro plan exhaustion <2h, force Max 5x in README
- If Spike D (SwiftMCP) is green, schedule Path 2-fast for Phase 5

## Spike A — Apple FM iOS 26.4 regression test

**Goal**: measure tool-calling accuracy regression in iOS 26.4 vs 26.3
(Apple Dev Forums report active production regression as of 2026-05).

**Test setup**:
- iPhone 15 Pro physical device on iOS 26.3 (stable)
- Same device on iOS 26.4 (after OTA)
- 50-query test set: 20 native_tool intents + 20 ambiguous + 10 reject cases
- Each query run 3× to measure variance

**Metrics**:
- Tool selection accuracy (BFCL-style — correct tool chosen?)
- Slot extraction accuracy (correct args?)
- False reject rate (model refuses valid query)
- Latency P50 / P95

**Pass criteria**:
- 26.4 accuracy drop ≤15% vs 26.3
- False reject rate ≤10%
- Latency P50 ≤2s

**Status**: TBD

**Results**: TBD

---

## Spike B — Qwen tier-based Ollama validation

**Goal**: validate that the Qwen tier shortlist holds up empirically on the
target hardware (Mac M4 Pro 64GB ~ harness reference) for BFCL tool calling
and loop-free multi-turn behavior.

**Test setup**:
- Mac Studio M4 Max 64GB (or rented equivalent via Vast.ai)
- Pull 4 models: qwen3:4b, qwen3:8b, qwen3:14b, qwen3.6:27b
- 40-query GIGI test set:
  - 20 intent classification (timer / call / message / navigate / weather …)
  - 10 reasoning ("explain X in 3 sentences", "summarize this email")
  - 5 tool calling multi-arg
  - 5 ambiguous (router decision borderline)
- 200+ multi-turn tool calls per model to detect loop emergence

**Metrics**:
- BFCL accuracy %
- Latency P50 / P95
- RAM peak per model
- Loop rate (% of chains where model repeats same tool call >3×)
- Routing accuracy (% query routed correctly local vs cloud delegation)

**Pass criteria**:
- Default tier (qwen3:14b) BFCL ≥75%, loop rate <5%
- Pro tier (qwen3.6:27b) BFCL ≥85%, loop rate <5%
- Anti-shortlist confirmed: qwen3.5:* still has tool calling broken
  (verify Issue ollama#14493 status before testing)

**Status**: TBD

**Results**: TBD

---

## Spike C — Claude Code subscription burn rate

**Goal**: measure how many turns a real GIGI session consumes from Pro / Max
5x / Max 20x weekly caps to validate the recommendation in README setup.

**Test setup**:
- One Pro plan account ($20/mo)
- 100-query GIGI simulation across 1 day:
  - 70 single-tool / fast actions (cap-bypass via NLU expected — but verify)
  - 20 Path 4 reasoning ("write an email", "summarize document")
  - 10 Path 4 browser ("search Wikipedia + create note")
- Track 5h rolling window message count

**Metrics**:
- Messages consumed per 5h
- Time to plan exhaustion
- Cap reset behavior

**Pass criteria**:
- Pro plan: <30 messages / 5h on demo-like usage (leaves headroom)
- Max 5x: comfortable buffer for "always-on agent" daily usage

**Status**: TBD

**Results**: TBD

---

## Spike D — SwiftMCP feasibility (1 day, opt-in)

**Goal**: validate that `Apple FM + DynamicGenerationSchema + MCP swift-sdk`
holds up as a real fast-path for single-tool harness MCP queries.

**Test setup**:
- Fork sutheesh/SwiftMCP into `02_GIGI_APP/GIGI/Vendor/SwiftMCP/` (MIT, ~300 lines)
- Implement `GigiMCPBridge.swift` (~150 lines): MCPToolBridge.connect(to:)
- Expose 1 tool `gigi.web_search` from harness MCP server
- 10 demo queries: "search X on Wikipedia", "what's the weather in Y", …

**Metrics**:
- Latency vs current Path 4 (Claude Code subprocess)
- Context budget consumed (Apple FM 4096 tok) with 3 tool MCP active
- Tool selection accuracy
- Number of turns sustainable before context overflow

**Pass criteria**:
- Latency ≥50% faster than Path 4
- ≥5 turns sustainable with 3 MCP tools loaded
- Tool selection ≥90% on the 10-query set

**Status**: TBD (optional — only if Phase 5 feasibility validation is
prioritized post-MVP)

**Results**: TBD

---

## Go/No-Go decision matrix

| Spike | Pass → action | Fail → action |
|---|---|---|
| A | Phase 2 proceeds on iOS 26.3 pin | ADR-0011 mitigation: defer Path 2, expand FallbackRouter |
| B | qwen3:14b default tier confirmed | Demote 32GB tier to dense; document Path 3 reasoning-only mode |
| C | Pro plan acceptable for casual demo | README setup: Max 5x minimum, cost-aware warning UI |
| D | Schedule ADR-0012 + Phase 5 integration | SwiftMCP deferred indefinitely |

## Timeline

Estimated 5-7 days parallel execution (Spike D opt-in). Output: this doc filled
with results + go/no-go for each gate, before §22 Architecture-V4 design doc
starts.
