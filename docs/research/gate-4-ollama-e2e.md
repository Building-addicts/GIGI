# GATE 4 — Ollama Path 3 end-to-end test

> **Status**: template (to be filled on device with harness + Ollama running)
> **Purpose**: verify the full Path 3 chain: iOS → harness `/api/ios/local-llm/generate` → `OllamaClient.generate` → Qwen 3 model → SSE chunks → iOS TTS.
> **Pre-req**: GATE 0 build verified, IPA installed, harness paired, **`ollama serve` running on harness host with `qwen3:14b` (or matching tier model) pulled**, Brain Path Override = `auto` or `ollama`.

## Setup

```bash
# On harness host
brew install ollama       # or https://ollama.com/download
ollama pull qwen3:14b     # ~9GB; pick lower tier if RAM-constrained
ollama serve              # background daemon on :11434

# In repo
cp 03_HARNESS/server/local-llm/config.example.json 03_HARNESS/server/local-llm/config.json
# Edit config.json if needed (default tier "default" → qwen3:14b)
./start-harness.sh
```

In the app: Settings → 🦙 Ollama → confirm "Reachable · N models installed". If unreachable, fix harness setup before running tests.

## Test set

| # | Query | Expected behavior | Latency target |
|---|---|---|---|
| 1 | "Explain Bayes theorem in three sentences" | router → delegate_local → Ollama streams response → TTS speaks 3 sentences | 7-15s |
| 2 | "Summarize this: <paste 200-word email>" | summary in 3-4 sentences | 7-15s |
| 3 | "Rephrase 'I'm running late' more professionally" | response like "I apologize for the delay..." | 5-10s |
| 4 | "What is the capital of France" | response "Paris" or "The capital of France is Paris" | 3-7s |
| 5 | "Translate 'good morning' to French" | response "bonjour" | 3-7s |
| 6 | "Tell me a joke" | one short joke | 5-10s |
| 7 | "Compare Llama 3 and Qwen 3 briefly" | 2-3 sentence comparison | 7-15s |
| 8 | "Search Wikipedia for Tesla" | router → delegate_cloud (cost-aware capability check: browser required) → Path 4, NOT Ollama | n/a |

## Run table

| # | Latency (s) | First-chunk latency | Tokens approx | Response quality (1-5) | PASS / FAIL | Notes |
|---|---|---|---|---|---|---|
| 1 |  |  |  |  |  |  |
| 2 |  |  |  |  |  |  |
| 3 |  |  |  |  |  |  |
| 4 |  |  |  |  |  |  |
| 5 |  |  |  |  |  |  |
| 6 |  |  |  |  |  |  |
| 7 |  |  |  |  |  |  |
| 8 |  |  |  |  |  |  |

## Failure-mode tests

| Scenario | Action | Expected behavior |
|---|---|---|
| Ollama daemon stopped | `pkill ollama` mid-query | router catches error, falls back to delegate_cloud if mode allows; otherwise speaks "Local AI failed" |
| Wrong model name in config.json | edit config to `model: "doesnotexist:1b"` | `ollama_http_404` error → fallback |
| Cancel mid-stream | start a long query, hit cancel | stream aborts, `ollama logs` shows generation cancelled |
| Cold start (first call after harness restart) | first query | latency 15-30s (first-byte timer 30s safe), subsequent calls 5-15s |

## Pass criteria

- **6/8** Ollama queries succeed (queries 1-7) with reasonable quality (>=3/5)
- Query #8 correctly remapped to delegate_cloud (cost-aware capability check works)
- At least 1 failure-mode test passes (the fallback chain is exercised)
- Settings → 🦙 Ollama shows correct tier + installed models list

## Decision

After running: `PASS / FAIL`:

> ___________________________________

If Qwen 3 14B quality is below 3/5 on >50% of queries, consider Spike B downgrade to `qwen3:8b` and re-test. Document in ADR-0010 verdict section.
