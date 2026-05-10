// Ollama HTTP client (stub — Phase 2)
//
// Wraps the local Ollama HTTP API (default: http://127.0.0.1:11434) so the
// iOS app can stream offline reasoning via Path 3 of the 5-path plan.
//
// Tier-based model selection (read from config.example.json, override via
// Settings → Brain → "Ollama model"):
//   - lite     (RAM 4-8GB):   qwen3:4b
//   - standard (RAM 8-16GB):  qwen3:8b
//   - default  (RAM 16-32GB): qwen3:14b
//   - pro      (RAM 32GB+):   qwen3.6:27b
//
// AVOID qwen3.5:* family (Ollama tool calling broken, Issue ollama#14493).
// Hybrid thinking (Qwen 3 family) togglable runtime via `think: true|false`.
//
// Reference: docs/plans/frolicking-stargazing-pancake.md §3.2 + §7.Q1
//            docs/knowledge/llm-open-source-research.md §7 (Qwen ecosystem)
// ADR-0010 (TBD) — Ollama as first-class Path 3
// Blocker: Spike B (Qwen 3 14B vs 3.6-27B BFCL + loop test on test set)

// TODO Phase 2: implement
//
//   export async function generate({ prompt, model, think = false, signal })
//     -> AsyncIterable<string>  // streams chunks, throws on error/timeout
//
//   export async function chat({ messages, model, think = false, tools = [], signal })
//     -> AsyncIterable<ChatEvent>  // tool_use | text_delta | done
//
//   export async function isReachable({ host = '127.0.0.1', port = 11434 })
//     -> { ok: bool, version: string, models: string[] }
//
// HTTP endpoints used:
//   POST /api/generate   { model, prompt, stream: true, think? }
//   POST /api/chat       { model, messages, tools?, stream: true, think? }
//   GET  /api/tags       (list installed models)
//   GET  /api/version
//
// Retry/timeout policy:
//   - 30s timeout for first byte (cold load)
//   - 5min timeout total per request
//   - 1 retry on network error, NO retry on 4xx
//   - AbortSignal forwarded for cancel (iOS swipe-to-cancel)

export const OLLAMA_PHASE2_STUB = true;
