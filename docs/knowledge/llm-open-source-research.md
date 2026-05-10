# Open-Source LLM Research — 2026-05-10 (v2)

> Reference document for selecting the local LLM that powers the agent's
> reasoning runtime. Covers architectural paradigms (dense vs MoE vs reasoning),
> quantization techniques, inference engines, and the open-source model landscape
> across hardware tiers, with a deep-dive on the **Qwen ecosystem** (§7) which
> emerged as the community-default 2026 OSS family.
>
> **Audience**: contributors evaluating LLM choices for a worldwide open-source
> agent project. Language and locale-neutral.
>
> **Maintenance**: re-evaluate every 3–6 months. The open-source LLM landscape
> moves extremely fast.
>
> **v2 changelog (2026-05-10)**:
> - Added §7 The Qwen Ecosystem deep dive (timeline, all variants, Max vs
>   open-weight, community pattern)
> - Updated Tier C–F lineup with Qwen 3 (May 2025) and Qwen 3.6 (Apr 2026)
> - Added critical warning §7.4 — Qwen 3.5 family broken on Ollama, avoid
> - Replaced shortlist with tier-based Qwen-only candidates (was 4-vendor mix)
> - Added anti-shortlist section explaining why other candidates excluded

---

## 1. Why this document exists

The agent project needs a local LLM for its mid-tier reasoning path (Path 3:
short/medium reasoning, summarization, rephrasing, simple tool calling). The
choice has long-term consequences:

- Setup friction for contributors (model download size, hardware requirements)
- Per-turn latency on consumer hardware
- Function-calling reliability (the agent depends on it)
- License compatibility for commercial / open-source distribution

The model decision is deferred to a hands-on test phase. This document is the
shortlist input: it maps the landscape, classifies models by hardware tier,
explains the architectural paradigms behind their trade-offs, and proposes a
test methodology.

---

## 2. Benchmark literacy — what to measure for agentic use

For an agent that performs **routing, tool calling, intent classification, and
slot filling**, the standard knowledge benchmark (MMLU) is saturated and not
discriminative. The following benchmarks matter:

| Benchmark | Measures | Relevance for agent runtime |
|---|---|---|
| **BFCL v4** (Berkeley Function Calling Leaderboard) | Tool/function call correctness, multi-turn agentic flows, web search + memory tasks | Critical |
| **IFEval** | Instruction-following precision, format compliance | Critical |
| **MMLU-Pro** | Reasoning beyond saturated MMLU | High (replaces vanilla MMLU) |
| **SWE-bench Verified** | Real-world coding tasks | Medium (matters mostly for code-specialized path) |
| **Arena Elo (LMSYS)** | Human preference, pairwise comparison | Medium |
| **GPQA Diamond** | Scientific reasoning under uncertainty | Low |
| **AIME 2025** | Competition math | Low (unless math-heavy use case) |
| **HumanEval / MBPP** | Code generation basics | Saturated — ignore |
| **Vanilla MMLU** | General knowledge factoid recall | Saturated — ignore |

**Practical rule**: when comparing two candidate models, the deciding metrics
are **BFCL v4 + IFEval**. Knowledge breadth is a tiebreaker, not the primary
criterion.

**BFCL v4 caveat** (from the official leaderboard, 2026 update): models excel
at one-shot function calls but still struggle with multi-turn memory, dynamic
decision-making, and long-horizon reasoning. Don't take single-call BFCL scores
as a guarantee of agentic robustness — test with your own multi-turn task set.

---

## 3. Architectural paradigms

Open-source models in 2026 fall into three architectural categories, each with
distinct trade-offs.

### 3.1 Dense Transformers

The classic decoder-only Transformer: all parameters are activated for every
token. Examples: Llama 3.x, Qwen 2.5 (dense variants), Phi-4, Gemma 4, Mistral.

**Properties**:
- Predictable VRAM footprint (params × bytes-per-weight)
- Stable behavior on tool-calling chains
- Per-token compute scales linearly with parameter count
- Well-supported by every inference engine

**When dense wins**: agentic workflows with tool calling, long
multi-turn conversations, anything requiring consistent latency. The community
consensus on Reddit r/LocalLLaMA (2026) is: **for agents, prefer dense over MoE
at the same size**.

### 3.2 Mixture of Experts (MoE) — deep dive

MoE architectures decouple **total parameters** from **active parameters**.
Each layer contains many "expert" feedforward sublayers, but a routing
mechanism selects only a small subset per token.

**Why MoE exists**: scaling laws say "bigger model = better quality." But
serving a 671B dense model is prohibitively expensive. MoE keeps the quality
benefits of a huge parameter count while paying compute only for the active
subset (typically 5–10% of total).

#### Anatomy of DeepSeek V3 (the canonical 2026 MoE design)

DeepSeek V3 has **671B total parameters with 37B activated per token**. Each
MoE layer contains:

- **256 routed experts** (specialized, activated by router)
- **1 shared expert** (always activated, learns common knowledge)
- Router selects **top-K experts** per token (typically 8 out of 256)

The architecture is replicated across many layers; per forward pass roughly
**1354 activated experts in total** across all MoE layers.

#### Fine-grained experts (DeepSeekMoE innovation)

Earlier MoE designs (e.g., Switch Transformer, Mixtral 8×7B) used few large
experts. DeepSeekMoE goes the opposite direction: many small experts. Formal
trade-off:

- Standard MoE: N experts, hidden dimension D, activate K per token
- DeepSeekMoE: mN experts, hidden dimension D/m, activate mK per token

Computational cost stays identical, but knowledge is decomposed more finely
across experts. Combined with the always-on shared expert, this lets routed
experts specialize more aggressively while shared knowledge stays accessible.

#### Auxiliary-loss-free load balancing

The classic MoE problem: without intervention, routers tend to send everything
to a few favorite experts, leaving most experts under-trained ("dead expert"
problem).

Older solution: auxiliary load-balancing loss added to the training objective.
But this loss competes with the main task loss and degrades quality.

DeepSeek V3 solution: **bias terms on expert affinity scores**, adjusted
heuristically during training. If an expert is overloaded, its bias decreases
by a small constant per step; if underloaded, it increases. The bias is *not*
backpropagated — it's a separate balancing mechanism. Result: balance without
quality cost.

#### Routing mechanisms

**Top-K routing**: each token computes affinity with all experts, picks top-K.
Simple but expensive at scale.

**Node-limited routing** (DeepSeek V3): in multi-node training/inference, each
token is constrained to at most M nodes, chosen by the top M node-affinity
scores. Reduces cross-node communication dramatically. Each token averages
3.2 experts per node without NVLink overhead.

#### MoE vs Dense — practical trade-offs

| Aspect | Dense (e.g., Qwen 2.5 32B) | MoE (e.g., Qwen 3.6-35B-A3B) |
|---|---|---|
| **Total params** | 32B | 35B |
| **Active params per token** | 32B | 3B |
| **VRAM (Q4)** | ~18 GB | ~20 GB (loads all experts) |
| **Per-token compute** | High | Low (~10× less FLOPs) |
| **Throughput (tokens/sec)** | Lower | Higher |
| **First-token latency** | Higher | Lower |
| **Quality at same active params** | Worse | Better |
| **Tool-calling reliability** | Good | **Mixed — can loop** |
| **Inference engine support** | Universal | Patchy |

**The agentic warning**: r/LocalLLaMA community reports (verified across
multiple threads) that **Qwen3-Coder-30B MoE loops endlessly on tool-calling
chains**, despite running at 49 tok/s on Apple Silicon. The hypothesis is that
expert routing causes inconsistent behavior across turns of a multi-step
chain. For an agent runtime, this is a **dealbreaker** unless the specific MoE
variant has been validated on multi-turn function calling.

**Default recommendation for agents**: prefer dense models at the same VRAM
budget. Pick MoE only after validating on your own multi-turn test set.

### 3.3 Reasoning Models

A third architectural pattern (popularized by OpenAI o1 in 2024 and
democratized by DeepSeek R1 in early 2025): models trained to produce
**explicit chain-of-thought** before answering, using reinforcement learning
to optimize for reasoning correctness.

#### Key innovations from DeepSeek R1

DeepSeek R1 introduced **Group Relative Policy Optimization (GRPO)** — instead
of scoring outputs as right/wrong, it compares each new answer to previous
attempts on the same problem and reinforces relative improvement. Combined
with reward signals for:

- **Accuracy** (verifiable math, code, logic outputs)
- **Format** (structured `<think>...</think>` tags around reasoning, then
  final answer)

This produces models that genuinely "think" before answering. Self-reflection,
verification, and dynamic strategy adaptation emerge from the training without
being explicitly programmed.

#### Two training paths

DeepSeek published two variants:

1. **R1-Zero**: pure RL from a base model, no supervised fine-tuning. Proves
   reasoning can emerge from RL alone, but outputs are sometimes unreadable
   or mix languages.
2. **R1**: multi-stage pipeline — cold-start SFT data + two RL stages + two
   SFT stages. Produces human-readable reasoning aligned with preferences.

The R1 paper also distilled reasoning capability into smaller dense models
(Qwen 1.5B, 7B, 14B, 32B and Llama 8B, 70B). **Distilled R1 outperforms
same-size models trained from scratch with RL** — a key practical finding:
small reasoning models work best when distilled from large teachers.

#### Practical implications for agents

**Pros**:
- Significantly better on multi-step tasks, planning, debugging logic
- The `<think>` block is inspectable for debugging the agent's reasoning

**Cons**:
- **Latency 2–3× higher** (model emits hundreds of "thinking" tokens before
  the answer)
- Token cost (on subscription models) is higher because thinking tokens count
- For simple tool calls, reasoning models over-think — they're overkill for
  "what time is it"

**When to use reasoning models in an agent runtime**:
- As a specialized path for complex multi-step queries
- NOT as the default model for the orchestrator (latency hurts UX)
- Distilled small variants (DeepSeek-R1-Distill-Qwen-14B) are a sweet spot
  for consumer hardware

---

## 4. Quantization techniques

Open-source models are released as FP16/BF16 weights. To run a 70B model on
24 GB VRAM you must quantize. The technique you pick affects accuracy,
inference speed, and which engines you can use.

### 4.1 The precision spectrum

| Format | Bits | Size (vs FP16) | Quality retention |
|---|---|---|---|
| FP16 / BF16 | 16 | 100% baseline | 100% |
| FP8 | 8 | 50% | ~99% |
| INT8 | 8 | 50% | ~98% |
| **4-bit (INT4, Q4)** | **4** | **25%** | **92–95%** |
| 3-bit (Q3) | 3 | 18.75% | 85–90% |
| 2-bit (Q2) | 2 | 12.5% | 70–80% (often unusable) |

**The 4-bit sweet spot**: 3–4× memory reduction with negligible quality loss
on most tasks. This is the production standard for consumer/prosumer inference.

### 4.2 Major quantization methods

#### GGUF (Q4_K_M and K-quants)

The format used by **llama.cpp** and **Ollama**. The "K-quants" (Q4_K_M,
Q5_K_M, etc.) use **mixed precision per tensor**: salient tensors get more
bits, less important ones get fewer. This is why Q4_K_M outperforms naive INT4
in accuracy.

- **Strengths**: best CPU support, runs on literally any hardware (CUDA,
  Metal, ROCm, Vulkan, plain CPU). Easiest deployment.
- **Weaknesses**: lower GPU throughput than AWQ/GPTQ on dedicated inference
  engines like vLLM (93 tok/s vs 700+ tok/s on Marlin-AWQ).
- **Accuracy**: 6.74 perplexity vs FP16's 6.56 baseline (JarvisLabs benchmark).
- **When to use**: local single-user runtime, Ollama, Mac inference, anything
  CPU-fallback-required.

#### GPTQ

Calibration-based post-training quantization. Uses second-order information
(Hessian) to minimize quantization error per layer.

- **Strengths**: mature, widely supported, good accuracy.
- **Weaknesses**: slower than AWQ at inference, calibration takes hours.
- **With Marlin kernel**: 712 tok/s (faster than FP16 baseline).
- **When to use**: when AWQ isn't available for your model.

#### AWQ (Activation-aware Weight Quantization)

Developed at MIT. Key insight: **less than 1% of weights are "salient"** —
they contribute disproportionately to model output. AWQ identifies them via
calibration activation observation and protects them from quantization.

- **Strengths**: best accuracy at 4-bit among GPTQ/AWQ/Marlin family.
  HumanEval 51.83% vs Marlin-GPTQ same score, but better latency.
- **With Marlin kernel**: **741 tok/s output throughput** — the fastest 4-bit
  option in 2026, **faster than FP16 baseline**.
- **When to use**: production inference on NVIDIA GPUs with vLLM/SGLang.

#### BitsAndBytes

NF4 / FP4 quantization, originally designed for QLoRA fine-tuning.

- **Strengths**: smallest quality drop (6.66 vs FP16's 6.56 perplexity).
  Easy to use with HuggingFace Transformers. Best for training adapters on a
  4-bit base.
- **Weaknesses**: slower inference than AWQ/GPTQ for serving.
- **When to use**: research, QLoRA fine-tuning, low-traffic serving.

#### Marlin kernels — the throughput unlock

Marlin is a CUDA kernel optimization layer that dramatically speeds up 4-bit
inference on NVIDIA GPUs:

- **2.6× speedup for GPTQ**
- **10.9× speedup for AWQ**

Marlin requires Ampere or newer (RTX 30/40/50 series, A100, H100). It's the
reason 4-bit can be *faster* than FP16 in 2026.

### 4.3 Practical comparison (vLLM benchmarks, 2026)

| Method | Throughput | Perplexity (lower = better) | HumanEval | Notes |
|---|---|---|---|---|
| FP16 baseline | ~400 tok/s | 6.56 | 56% | Reference |
| **Marlin-AWQ** | **741 tok/s** | 6.84 | 51.83% | Best speed × quality |
| Marlin-GPTQ | 712 tok/s | similar | 51.83% | Close second |
| GGUF Q4_K_M (vLLM) | 93 tok/s | 6.74 | 51.83% | Slow in vLLM, fast in llama.cpp |
| BitsAndBytes NF4 | ~300 tok/s | 6.66 | 51.83% | Best quality, worst speed |

### 4.4 Practical recommendation

- **Production serving on GPU**: Marlin-AWQ via vLLM or SGLang
- **Local single-user (Mac, CPU, simple deployment)**: GGUF Q4_K_M via Ollama
  or llama.cpp
- **Fine-tuning or QLoRA**: BitsAndBytes NF4
- **Last resort if no AWQ available**: GPTQ + Marlin

For an open-source agent project distributed via `ollama pull`, the practical
choice is **GGUF Q4_K_M** — it's what Ollama ships natively.

---

## 5. Inference engines

The engine determines throughput, latency, memory efficiency, and which
features you can use (continuous batching, prefix caching, structured output,
speculative decoding).

### 5.1 vLLM — production default

**Core innovation**: PagedAttention — manages KV cache like virtual memory
pages, eliminating fragmentation. Result: massively more concurrent users on
the same GPU.

- **Throughput at peak load**: **35× more requests/sec than llama.cpp**,
  **44× more output tokens/sec**.
- TTFT p50 at 10 concurrent: 120 ms.
- Cold start: ~62 seconds.
- Supports continuous batching, structured output (JSON schema), speculative
  decoding, tensor parallelism.

**When to use**: server-grade deployment, multi-user serving, ≥1 GPU available.

### 5.2 SGLang — the agent specialist

Developed at UC Berkeley. **Core innovation**: RadixAttention — treats the KV
cache as a tree, enabling prefix caching across requests that share context.

- **Beats vLLM by 29% throughput when requests share context** (chatbots,
  agents, RAG — where system prompt + history are reused across turns).
- TTFT p50 at 10 concurrent: 112 ms.
- Cold start: ~58 seconds.
- Structured output, function calling, multi-LM workflows.

**When to use**: agentic workloads (heavy prefix reuse), chat systems,
multi-turn applications. **For an agent runtime with stable system prompt,
this is the better choice than vLLM at scale.**

### 5.3 llama.cpp — the universal runtime

Ggerganov's C/C++ implementation. Runs on **CUDA, ROCm, Metal, Vulkan, SYCL,
plain CPU, even WebAssembly**.

- **80–100 tok/s for a 7B model on Apple M2 Ultra via Metal**.
- Single-file deploy. No Python.
- Native GGUF support.
- Speculative decoding, grammar-constrained sampling.

**When to use**: edge deployment, single-user local inference, any platform
where vLLM/SGLang don't fit. The backbone of Ollama and LM Studio.

### 5.4 MLX — Apple Silicon specialist

Apple's ML framework, optimized for unified memory architecture (M1/M2/M3/M4
chips). Inference engines built on MLX (e.g., `mlx-lm`, `oMLX`) leverage
Metal Performance Shaders and a **"hot-cold dual-layer KV cache"**.

- Crushes other frameworks on Apple Silicon for **multi-turn dialogue and
  agentic code workflows**.
- Better than llama.cpp Metal backend on M3/M4 for some workloads.
- Native Swift/Python bindings.

**When to use**: agent harness running on Mac Studio / Mac Mini Pro. If your
backend is on Apple Silicon, evaluate MLX before defaulting to llama.cpp.

### 5.5 Ollama — developer experience champion

Built on top of llama.cpp. Adds a daemon, REST API, model registry,
one-command pulls.

- `ollama pull <model>:<tag>` and done.
- Auto memory management, hot-swap models (with reload latency).
- **Doesn't scale past single-user workloads** — for that, switch to vLLM/SGLang.
- Native tool-calling API since v0.5.0 (model-dependent quality).

**When to use**: local development, single-user agent harness, OSS projects
where contributors need 5-minute setup. **The default choice for a worldwide
open-source agent project.**

### 5.6 TensorRT-LLM — NVIDIA enterprise peak

NVIDIA's proprietary engine, compiled-graph approach.

- **30–50% higher throughput than vLLM** at high concurrency.
- TTFT p50: 105 ms.
- **Cold start: 28 minutes** (compile step).
- NVIDIA-only.

**When to use**: ultra-high-volume production. Not for OSS distribution
(NVIDIA lock-in, compilation overhead).

### 5.7 Recommendation matrix

| Use case | Engine | Reason |
|---|---|---|
| Local dev, OSS contributor onboarding | **Ollama** | 5-min setup, REST API |
| Agent harness on Mac Studio/Mini Pro | **MLX** (or Ollama for simplicity) | Apple Silicon optimized |
| Single-user local on PC | **llama.cpp** or **Ollama** | Universal hardware support |
| Multi-user agent serving (≥10 concurrent) | **SGLang** | Prefix caching wins for agents |
| General multi-user serving | **vLLM** | Production default, mature |
| Enterprise ultra-low-latency | **TensorRT-LLM** | NVIDIA-only, compile cost |

---

## 6. Open-source model landscape by hardware tier

Each tier assumes 4-bit quantization (Q4_K_M for GGUF, AWQ/GPTQ for vLLM). FP16
deployment doubles VRAM requirements.

### Tier A — Frontier (multi-GPU enterprise)

For datacenter deployment or cloud GPU clusters.

| Model | Total params | Active params | Architecture | License | Specialty |
|---|---|---|---|---|---|
| **DeepSeek V3** | 671B | 37B (MoE 256 + 1) | MoE + MLA | DeepSeek License | Strong general reasoning |
| **DeepSeek R1** | 671B | 37B (MoE) | MoE + reasoning | MIT | Chain-of-thought reasoning leader |
| **Llama 4 Maverick** | ~400B | ~70B (MoE) | MoE | Llama License | Meta's flagship |
| **Qwen 3.5-397B** | 397B | (varies) | MoE | Apache 2.0 | Frontier OS overall |
| **Mistral Large 3** | 123B | 123B | Dense | MRL | 128k context, 80+ languages |
| **MiniMax M2.7** | ~150B | (MoE) | MoE | Apache 2.0 | SWE-bench leader |
| **Kimi K2.6** | ~100B+ | (MoE) | MoE | Modified | Coding specialist |
| **Cohere Command R+** | 104B | 104B | Dense | CC-BY-NC | RAG / enterprise, 10 lang business |

**Hardware**: 8× H100/H200/B200, or rent on demand ($10–25/h cloud).

### Tier B — Mid (single 80GB GPU)

For a single A100 80GB or H100. Cloud cost: $1–1.50/h.

| Model | Params | Architecture | License | Specialty |
|---|---|---|---|---|
| Llama 3.3 70B | 70B | Dense | Llama License | General purpose, agentic-ready |
| Llama 4 70B | 70B | Dense | Llama License | Meta 2026 default |
| Qwen 2.5 72B | 72B | Dense | Apache 2.0 | Multilingual + reliable tool calls |
| Qwen 3.6 Plus | ~70B | Dense | Apache 2.0 | Agentic coding leader, 1M context |
| DeepSeek-R1-Distill-Llama-70B | 70B | Dense + R1 distillation | MIT | Reasoning distilled into dense |

### Tier C — Prosumer (24–32 GB VRAM, single high-end card)

RTX 4090 24GB, RTX 5090 32GB, or Mac Studio M4 Max 64GB unified.

| Model | Params | Architecture | License | VRAM Q4 | Specialty |
|---|---|---|---|---|---|
| **Qwen 3.6-27B** ⭐⭐ | 27B | Dense | Apache 2.0 | ~14–16 GB | **Latest agentic-tuned (Apr 2026), "corrects overthinking", community-recommended for agents** |
| **Qwen 3 32B** | 32B | Dense hybrid | Apache 2.0 | ~18 GB | May 2025, single hybrid thinking, mature |
| Qwen 3 30B-A3B Instruct-2507 | 30B (3B active) | MoE | Apache 2.0 | ~18–20 GB | 256K context, fast inference, ⚠️ MoE agentic risk |
| Qwen 3.6-35B-A3B | 35B (3B active) | MoE | Apache 2.0 | ~20 GB | Fast multimodal MoE, ⚠️ test for agentic chains |
| Qwen 2.5 32B | 32B | Dense | Apache 2.0 | ~18 GB | Legacy mature, ecosystem-stable |
| Gemma 3 27B / Gemma 4 26B | 26–27B | Dense | Gemma License | 14–16 GB | Apache alternative |
| DeepSeek-R1-Distill-Qwen-32B | 32B | Dense + R1 distillation | MIT | ~18 GB | Best small reasoning model |
| Command R 35B | 35B | Dense | CC-BY-NC | ~20 GB | RAG community variant |

### Tier D — Consumer mid (16 GB VRAM or unified) — agent-default target

Mac Mini M4 Pro 32–64GB, RTX 4070 Ti Super, RTX 4070 with offloading.

| Model | Params | Architecture | License | VRAM Q4 | Specialty |
|---|---|---|---|---|---|
| **Qwen 3 14B** ⭐⭐ | 14B | Dense hybrid | Apache 2.0 | 9–10 GB | **DEFAULT — May 2025, hybrid thinking toggle, BFCL excellent, 12+ months production** |
| Qwen 2.5 14B | 14B | Dense | Apache 2.0 | 9–10 GB | Legacy mature, ecosystem-proven, fallback if Qwen 3 unavailable |
| Phi-4 14B | 14B | Dense | MIT | ~9 GB | Higher MMLU-Pro but English-first only |
| DeepSeek-R1-Distill-Qwen-14B | 14B | Dense + R1 distill | MIT | ~9 GB | Best reasoning at 14B (latency 2–3× higher) |
| Llama 3.1 / 3.3 8B | 8B | Dense | Llama License | ~5 GB | General-purpose multilingual |
| Gemma 4 12B | 12B | Dense | Gemma License | ~8 GB | Apache-friendly alternative |

> ⚠️ **AVOID Qwen 3.5 family on Ollama**: tool calling broken (Issue
> [ollama#14493](https://github.com/ollama/ollama/issues/14493)), GGUF
> compatibility issues with mmproj vision files, thinking mode "egregious"
> per community feedback. Wait for community fixes (mid-2026 estimate) or
> stay on Qwen 3 (May 2025) / Qwen 3.6 (Apr 2026).

### Tier E — Consumer small (8 GB VRAM/RAM)

| Model | Params | Architecture | License | VRAM Q4 |
|---|---|---|---|---|
| **Qwen 3 8B** ⭐ | 8B | Dense hybrid | Apache 2.0 | ~5 GB |
| Qwen 2.5 7B | 7B | Dense | Apache 2.0 | ~5 GB (legacy) |
| Mistral Small 3 7B | 7B | Dense | Apache 2.0 | ~4 GB |
| Llama 3.1 8B | 8B | Dense | Llama License | ~5 GB |
| Yi 9B | 9B | Dense | Apache 2.0 | ~6 GB |
| Falcon H1R 7B | 7B | Dense | Apache 2.0 | ~4 GB |
| DeepSeek-R1-Distill-Qwen-7B | 7B | Dense + R1 distill | MIT | ~5 GB |

### Tier F — Very small (3–4 B parameters, edge/mobile/fallback)

| Model | Params | License | VRAM Q4 | BFCL v4 | Notes |
|---|---|---|---|---|---|
| **Qwen 3 4B** ⭐ | 4B | Apache 2.0 | ~2.5 GB | high | **Hybrid thinking even at 4B, recommended for OSS lite tier** |
| Qwen 3-2507 4B Instruct | 4B | Apache 2.0 | ~2.5 GB | high | Dedicated non-thinking, fast, 256K context |
| Llama 3.2 3B | 3B | Llama License | ~2 GB | **67.0** | Best-in-class BFCL at 3B but Llama License |
| Phi-4 mini | 3.8B | MIT | ~2.3 GB | medium | MMLU 68.5%, English-first |
| Ministral 3B | 3B | MRL | ~2 GB | high | MRL license — research only |
| Gemma 4 4B | 4B | Gemma License | ~2.5 GB | low | Mobile-first |
| Qwen 2.5 3B | 3B | Apache 2.0 | ~2 GB | medium | Legacy general-purpose tiny |
| Qwen 3 1.7B | 1.7B | Apache 2.0 | ~1.2 GB | low | Edge devices, hybrid thinking |
| DeepSeek-R1-Distill-Qwen-1.5B | 1.5B | MIT | ~1 GB | n/a | Smallest reasoning |

### Tier G — Specialized

#### Vision-language (multimodal)
| Model | Params | License | Use case |
|---|---|---|---|
| Qwen3 VL 235B | 235B | Apache 2.0 | Frontier vision + OCR 32 languages + GUI automation |
| Qwen 2.5 VL 7B | 7B | Apache 2.0 | Consumer vision on RTX 4090 |
| Llama 3.2 Vision 11B / 90B | 11B / 90B | Llama License | Image reasoning |
| Pixtral 12B | 12B | Apache 2.0 | Mistral vision model |

#### Coding-specialized
| Model | Params | License | Use case |
|---|---|---|---|
| DeepSeek Coder V2 | MoE | DeepSeek License | Code generation, completion |
| Qwen3-Coder-Next | MoE | Apache 2.0 | Agentic coding workflows |
| Qwen 2.5-Coder 32B / 7B | Dense | Apache 2.0 | Stable coding family |
| CodeLlama 70B | Dense | Llama License | Legacy but stable |

#### Embeddings (for RAG / memory retrieval)
| Model | Dimensions | License | Use case |
|---|---|---|---|
| BGE-M3 (BAAI) | 1024 | MIT | Multilingual, multi-granularity. 2026 standard |
| E5-Large (Microsoft) | 1024 | MIT | Solid baseline |
| Nomic Embed | 768 | Apache 2.0 | Consumer-friendly |

---

## 7. The Qwen Ecosystem — deep dive (recommended for agent runtime)

The Qwen family (Alibaba Cloud) has emerged as the **community-default OSS
choice** for agent runtimes in 2026. r/LocalLLaMA quote: *"For the time being,
the default is Qwen"*. This section maps the entire Qwen ecosystem so
contributors can pick the right model for their hardware **and** stay clear
of known issues.

### 7.1 Generation timeline (open-weight releases only)

| Date | Generation | Status 2026-05 | Production-ready? |
|---|---|---|---|
| Sep 2024 | **Qwen 2.5** | Stable, mature | ✅ Yes — legacy gold standard |
| Nov 2024 | QwQ-32B-Preview | Reasoning precursor (pre-R1) | ⚠️ Superseded by Qwen 3-2507 Thinking |
| Jan 2025 | Qwen 2.5-VL family | Vision-language stable | ✅ Yes |
| Mar 2025 | Qwen 2.5-Omni-7B | First open multimodal | ✅ Yes |
| **Apr/May 2025** | **Qwen 3** | Hybrid thinking in-model | ✅ **Yes — RECOMMENDED stable baseline** |
| Jul 2025 | Qwen 3-2507 (Instruct + Thinking split) | Dedicated 4B / 30B-A3B / 235B-A22B | ✅ Yes — best dedicated quality |
| Sep 2025 | Qwen3-Next-80B-A3B | Ultra-sparse hybrid attention | ✅ Yes — Tier 5 prosumer |
| **Feb 2026** | **Qwen 3.5** | Multimodal-native (Omni in Mar) | ❌ **AVOID on Ollama** — see §7.4 |
| Mar 2026 | Qwen 3.5-Omni | Full multimodal voice/audio/video | ⚠️ Use llama.cpp, not Ollama |
| **Apr 2026** | **Qwen 3.6** | Text-first agentic-tuned | ✅ **Yes — RECOMMENDED quality upgrade** |

### 7.2 Cloud-only "Max" variants (NOT downloadable)

These exist but are **not open-weight**. Listed so contributors don't get
confused when they see them in benchmarks:

- **Qwen 2.5-Max** (Jan 2025) — Alibaba Cloud API only
- **Qwen 3.6-Max-Preview** (Apr 2026) — flagship, top 6 coding benchmarks

If your project is OSS or cost-sensitive, ignore these — they violate the
"no API metering" constraint for self-hosted agents.

### 7.3 Open-weight family map (every size, every variant)

#### Base + Instruct (general-purpose)

| Generation | Sizes available | Notes |
|---|---|---|
| Qwen 2.5 | 0.5B / 1.5B / 3B / 7B / 14B / 32B / 72B | All Apache 2.0 |
| Qwen 3 | 0.6B / 1.7B / 4B / 8B / 14B / 32B + 30B-A3B (MoE) + 235B-A22B (MoE) | Hybrid thinking in-model |
| Qwen 3-2507 | 4B / 30B-A3B / 235B-A22B (each in Instruct + Thinking variants) | 256K context, dedicated split |
| Qwen 3-Next | 80B-A3B | Ultra-sparse hybrid attention |
| Qwen 3.5 | 0.8B / 2B / 4B / 9B (Small) + 27B / 35B-A3B / 122B-A10B (Medium) + 397B-A17B (Plus) | ⚠️ Ollama bugs, see §7.4 |
| Qwen 3.6 | 27B (dense) + 35B-A3B (MoE) + Plus (~70B dense) | Latest stable, agentic-tuned |

#### Coder (code-specialized)

| Model | Sizes | Notes |
|---|---|---|
| Qwen 2.5-Coder | 0.5B / 1.5B / 3B / 7B / 14B / 32B | "Best balance" still used in production per community |
| Qwen 3-Coder | 30B-A3B | Code-heavy agentic |
| **Qwen 3-Coder-Next** | 3B active MoE | SWE-Bench-Pro comparable to 10–20× larger |
| Qwen 3.6-Coder Plus | ~70B | Agentic coding leader 2026, 1M context |

#### Vision-Language (multimodal image input)

| Model | Sizes | Notes |
|---|---|---|
| Qwen 2-VL | 2B / 7B / 72B | Aug 2024, original multimodal |
| Qwen 2.5-VL | 3B / 7B / 32B / 72B | Document parsing HTML, video analysis |
| **Qwen 3-VL** | 2B / 4B / 8B / 32B (dense) + 30B-A3B / 235B-A22B (MoE) | Visual agent (operate UI), 256K → 1M context, code-from-image |

#### Math (math-specialized reasoning)

| Model | Sizes | Notes |
|---|---|---|
| Qwen 2-Math | 1.5B / 7B / 72B | CoT + PoT + Tool-Integrated Reasoning |
| Qwen 2.5-Math | 1.5B / 7B / 72B | Bilingual EN/ZH, multi-method |

#### Audio / Omni (multimodal audio + video)

| Model | Notes |
|---|---|
| Qwen 2-Audio | Audio understanding, English/Chinese |
| Qwen 2.5-Omni-7B | First open Omni (Mar 2025), Apache 2.0 |
| Qwen 3.5-Omni | Latest full multimodal (voice + audio + video + text) |

#### Reasoning-specialized

| Model | Notes |
|---|---|
| QwQ-32B-Preview | Nov 2024 precursor, superseded |
| Qwen 3-2507 Thinking variants | 4B / 30B-A3B / 235B-A22B |
| DeepSeek-R1-Distill-Qwen-* | 1.5B / 7B / 14B / 32B (Qwen base + R1 reasoning distillation) |

### 7.4 Critical warning — Qwen 3.5 known issues on Ollama

**Status as of 2026-05**: Qwen 3.5 has multiple production blockers when
deployed via Ollama. Documented issues:

1. **Tool calling broken**: GitHub Issue
   [ollama#14493](https://github.com/ollama/ollama/issues/14493) documents
   six concrete chat template mismatches between what Ollama sends and what
   Qwen 3.5 was trained on. Tool calls rendered inside unclosed `<think>`
   blocks corrupt all subsequent turns.
2. **Thinking mode "egregious"**: enabled by default, "burns tokens in
   circles without any benefit over Qwen 3 non-thinking" (community
   testimony).
3. **GGUF compatibility broken**: "Currently no Qwen 3.5 GGUF works in
   Ollama" — separate `mmproj` vision files cause loading failures.
   Workaround: use llama.cpp directly.
4. **No `/think` `/nothink` soft switch**: present in Qwen 3 but removed
   in Qwen 3.5. Must configure via API parameters
   `"chat_template_kwargs": {"enable_thinking": False}`.

**Recommendation**: skip Qwen 3.5 entirely until community fixes land.
Stay on Qwen 3 (May 2025) for stability or upgrade to Qwen 3.6 (Apr 2026)
for latest quality.

### 7.5 Community pattern — which Qwen people actually run

Synthesized from r/LocalLLaMA threads, HuggingFace download trends, and
GitHub issue traffic (Apr–May 2026):

| Use case | Community pick | Why |
|---|---|---|
| **Stable agent runtime** | Qwen 3 14B (May 2025) | 12 months production, hybrid thinking works, tool calling reliable |
| **Latest quality, single-GPU** | Qwen 3.6-27B | Apr 2026, "fixes overthinking", agentic-tuned, dense |
| **Fast chat / RAG** | Qwen 3.6-35B-A3B (MoE) | 3-4× speed, slight quality trade-off |
| **Production code in dev tools** | Qwen 2.5-Coder-14B | "Best balance" still — maturity beats marginal gains |
| **Reasoning-heavy specific tasks** | Qwen 3-2507 30B-A3B Thinking | Dedicated split, 256K context |
| **Edge / mobile** | Qwen 3 1.7B / 4B | Hybrid thinking even at small size |
| **Avoid** | Qwen 3.5 family on Ollama | See §7.4 |

### 7.6 GIGI Path 3 lineup — final tier-based shortlist

After community research, the lineup that maximizes user reach while
avoiding known issues:

```
Setup wizard auto-detects hardware and proposes:

  📱 Lite (4–8 GB unified RAM)
     ollama pull qwen3:4b
     → Qwen 3 4B (May 2025), hybrid thinking, ~2.5 GB Q4

  💻 Standard (8–16 GB unified RAM)
     ollama pull qwen3:8b
     → Qwen 3 8B (May 2025), proven stable, ~5 GB Q4

  🚀 Recommended (16–32 GB unified RAM) ⭐⭐ DEFAULT
     ollama pull qwen3:14b
     → Qwen 3 14B (May 2025), the safe baseline, ~10 GB Q4
     → 12+ months production, BFCL excellent, hybrid thinking toggle

  ⚡ Pro (32+ GB unified RAM) ⭐ QUALITY UPGRADE
     ollama pull qwen3.6:27b
     → Qwen 3.6-27B (Apr 2026), agentic-tuned, ~14–16 GB Q4
     → "Corrects overthinking", dense, community-recommended for agents

  🔬 Power user / advanced (32+ GB)
     ollama pull qwen3:32b              # mature single hybrid
     ollama pull qwen3.6:35b-a3b        # MoE fast, ⚠️ verify tool calling
     ollama pull qwen3-coder:30b-a3b    # if code-heavy use case

  🚫 AVOID until fixes land:
     qwen3.5:* family — Ollama tool calling broken
     Cloud-only "Max" variants — not downloadable
```

### 7.7 License consistency

**All open-weight Qwen models are Apache 2.0** — the most permissive license
for OSS distribution (commercial use, modification, sub-licensing all
allowed). No fragmentation across the ecosystem (unlike Llama license clauses
or Gemma restrictions). This is a major strategic reason to standardize on
Qwen for an OSS agent project.

---

## 8. Hardware tiers and reference setups

### Reference consumer setups (community-validated, 2026)

- **Mac Mini M4 Pro 64 GB unified** ($1999–2499) — "best value local AI 2026"
  per r/LocalLLaMA. 273 GB/s memory bandwidth. Runs 30B-class comfortably.
- **RTX 4090 24GB + 64 GB RAM** ($1500–2000 GPU) — handles up to Qwen 32B Q4
  with offloading.
- **RTX 5090 32GB** — unlocks 70B Q4 single-GPU (with offloading).
- **Dual RTX 4090** — clean 70B Q4 dual-GPU split.
- **Mac Studio M4 Max 64–128GB** — ARM alternative, excellent for MLX-based
  inference, prosumer Tier B–C workloads.

### Cloud GPU rental (2026 pricing)

For users without local hardware or who want elastic capacity:

| Provider | GPU | $/hour | Class supported |
|---|---|---|---|
| **Vast.ai** (marketplace, spot) | RTX 4090 24GB | $0.30–0.50 | Tier C/D |
| Vast.ai | A100 80GB | $0.80–1.20 | Tier B (70B Q4) |
| **RunPod** (flat-rate) | RTX 4090 24GB | $0.49 | Tier C/D |
| RunPod | A100 80GB | ~$1.00 | Tier B |
| RunPod | H100 80GB | $1.50 | Tier B (production speed) |
| RunPod | B200 180GB | premium | Tier A entry-level |
| **Lambda Labs** | A100 80GB | $1.10–1.30 | Tier B, stable |

### Cloud Mac (always-on alternative)

- **MacInCloud / MacStadium**: $30–60/month for a dedicated Mac Mini M2/M3
  16–24GB. Runs Tier D models with MLX. Zero-maintenance, always-on.

### Cost reality check

A 24/7 cloud GPU running 7B–14B models for a personal agent: roughly
**$30–45/month** on Vast.ai RTX 4090 spot pricing. This is comparable to
mid-tier LLM API subscriptions ($20/mo for an entry plan up to
$100–200/mo for higher tiers). **Self-hosting wins on privacy and customization,
not on cost.**

---

## 9. Decision framework for an agent runtime

When selecting a local LLM for an agent middle tier (between trivial
rule-based logic and heavy cloud reasoning):

### 8.1 Hard constraints

1. **License compatibility**: must allow commercial / OSS redistribution.
   Apache 2.0 and MIT are unambiguous. Llama License is OK for most uses but
   has the 700M MAU clause. Gemma License has use restrictions. MRL (Mistral
   Research License) is research-only — not viable for OSS shipping.
2. **Tool calling reliability**: must support native function calling via
   inference engine. BFCL score >65 at the chosen size class is a reasonable
   floor.
3. **VRAM budget**: must fit the target contributor's machine. For broad
   reach, 8GB VRAM is the safety floor; 16GB is the comfortable middle.
4. **Inference engine compatibility**: must run on Ollama (lowest-friction
   contributor onboarding) — this rules out research-only formats.

### 8.2 Soft preferences

1. **Architecture**: prefer dense over MoE for agentic stability (unless the
   specific MoE has been validated for tool-calling chains).
2. **Reasoning vs general**: for routing/intent classification, prefer general
   instruction-tuned. For multi-step task decomposition, distilled reasoning
   models (DeepSeek-R1-Distill-Qwen-14B) are excellent.
3. **Multilingual**: depends on target audience. Qwen 2.5 is multilingual-first;
   Phi-4 is English-first. **For a worldwide audience, prefer multilingual
   models even if single-language benchmarks are slightly lower.**
4. **Community validation**: prefer models with 6+ months of community use in
   production agent contexts. Reddit r/LocalLLaMA and HuggingFace download
   trends are signals.

### 8.3 Anti-patterns

- ❌ Picking based on MMLU score
- ❌ Picking the largest model that "barely fits" (leaves no VRAM for KV cache
  growth, OOMs mid-task)
- ❌ Defaulting to MoE without multi-turn validation
- ❌ Optimizing for single-call BFCL without testing multi-turn workflows
- ❌ Locking to one provider's tool-calling API format (different engines
  serialize tools differently)

---

## 10. Proposed test methodology

To choose between candidates, run all of them through the same task set on the
target hardware. Following the Qwen ecosystem deep dive (§7), the shortlist
is **tier-based across the Qwen family** to maximize user reach while
avoiding known issues:

### 10.1 Tier-based candidate shortlist

| Tier | Hardware target | Candidate | Why shortlisted |
|---|---|---|---|
| Lite | 4–8 GB unified | **Qwen 3 4B** | Hybrid thinking even at 4B, Apache 2.0, mature |
| Standard | 8–16 GB unified | **Qwen 3 8B** | Mature, stable, hybrid thinking, broad compat |
| **Recommended** ⭐⭐ | 16–32 GB unified | **Qwen 3 14B** | DEFAULT — 12+ months production, BFCL excellent, hybrid in-model |
| **Pro Quality** ⭐ | 32+ GB unified | **Qwen 3.6-27B** | Latest agentic-tuned (Apr 2026), "corrects overthinking", dense |
| Power user (opt-in) | 32+ GB unified | Qwen 3 32B / Qwen 3.6-35B-A3B | Mature dense vs latest MoE comparison |

### Anti-shortlist (excluded after research)

| Candidate | Why excluded |
|---|---|
| Qwen 2.5 14B | Superseded by Qwen 3 14B (Qwen Team confirms one-tier-larger equivalence) |
| Qwen 3.5 family | Tool calling broken on Ollama (§7.4), wait for fixes |
| Phi-4 14B | English-first only — fails multilingual reach goal |
| DeepSeek-R1-Distill-Qwen-14B | Latency 2–3× higher, overkill for routing/tools |
| Llama 3.2 3B | Llama License has 700M MAU clause; Apache alternatives preferred |

### 10.2 Test set composition

**40 queries split**:

- **20 intent classification** queries spanning the agent's action set
  (timers, messaging, navigation, calendar, music, smart home, etc.) in the
  target deployment languages.
- **10 reasoning** queries (summarization, explanation, rephrasing,
  translation) of varying length (50 to 500 input tokens).
- **5 multi-arg slot filling** queries with 3–5 named slots each (contact
  name + date + time + reason, address + appointment + reminder, etc.).
- **5 ambiguous routing** queries that test whether the model correctly
  estimates complexity and routes to local vs cloud vs clarification.

### 10.3 Metrics

| Metric | What it captures |
|---|---|
| **BFCL accuracy %** | Tool-calling correctness on the 20 intent + 5 slot-filling subset |
| **IFEval-style format compliance** | Structured output respects JSON schema |
| **Latency P50 / P95** | On target hardware (e.g., Mac Mini M4 Pro), end-to-end |
| **VRAM peak** | During inference with realistic context |
| **Routing accuracy** | % of ambiguous queries routed to the correct downstream path |
| **Multilingual quality** | Coverage in the target deployment languages |
| **Setup friction** | Download time, first-response cold-start time |

### 10.4 Decision procedure

1. Pull all candidates: `ollama pull <model>:<tag>`
2. Implement a test runner that sends the test set to each model via Ollama
   REST API (`/api/chat` with `tools` array).
3. Aggregate metrics across all candidates.
4. Apply hard constraints (license, BFCL floor, VRAM) — drop disqualified.
5. Among survivors, pick by routing accuracy × latency P95 (the joint metric
   that matters most for agent UX).
6. Write the decision into an ADR with full data tables.

---

## 11. Operational notes for Ollama deployments

- **Quantization tag**: always specify explicit Q-level. `qwen2.5:14b-instruct-q4_K_M`
  is reproducible; `qwen2.5:14b` is not (default may change across Ollama
  versions).
- **Tool calling**: use Ollama `/api/chat` with `tools` array (Ollama ≥ 0.5.0).
  Validate per-model — schema adherence varies even within the same engine.
- **Streaming**: `stream: true` returns JSON line stream. Useful for forwarding
  to WebSocket clients with low latency perceived response.
- **Hot-swap**: Ollama keeps one model in VRAM at a time. Switching models
  triggers unload + load (~5–15 seconds). For an agent that uses multiple
  models (small router + large reasoner), evaluate whether the swap cost
  beats unifying on a single model.
- **Concurrency**: Ollama is single-user. For multi-user agent serving, switch
  to vLLM or SGLang behind a simple HTTP proxy.
- **Binding**: default `localhost:11434`. Bind to `0.0.0.0` only if you
  intentionally want LAN access — and add network ACLs.

---

## 12. What this document does NOT cover

- **Proprietary LLM APIs** (GPT, Claude, Gemini) — out of scope for the local
  runtime tier. Relevant only if your project also has a cloud path that
  delegates to a subscription CLI.
- **Voice models** (Whisper, Coqui, F5-TTS, Kokoro) — separate document.
- **Computer-use strategies** (vision agents, browser automation specifics)
  — separate document, briefly touched in Tier G.
- **Embeddings + RAG architectures** — separate document, briefly touched
  in Tier G.
- **Training / fine-tuning** — this document is about *selecting* and
  *running* models, not training them.

---

## 13. Sources

### MoE architecture
- [DeepSeek-V3 Technical Report (arXiv)](https://arxiv.org/abs/2412.19437)
- [How DeepSeek improved the Transformer architecture — Epoch AI](https://epoch.ai/gradient-updates/how-has-deepseek-improved-the-transformer-architecture)
- [DeepSeekMoE: Towards Ultimate Expert Specialization (ACL)](https://aclanthology.org/2024.acl-long.70.pdf)
- [Mixture-of-Experts LLMs — Cameron Wolfe](https://cameronrwolfe.substack.com/p/moe-llms)

### Reasoning models
- [DeepSeek-R1: Incentivizing Reasoning via RL (Nature)](https://www.nature.com/articles/s41586-025-09422-z)
- [DeepSeek-R1 arXiv paper](https://arxiv.org/abs/2501.12948)
- [Understanding DeepSeek R1 — Kili Technology](https://kili-technology.com/blog/understanding-deepseek-r1)
- [DeepSeek R1 explained: CoT, RL, Distillation — HuggingFace blog](https://huggingface.co/blog/NormalUhr/deepseek-r1-explained)

### Quantization
- [LLM Quantization Guide 2026 — Prem AI](https://blog.premai.io/llm-quantization-guide-gguf-vs-awq-vs-gptq-vs-bitsandbytes-compared-2026/)
- [vLLM Quantization Benchmarks — JarvisLabs](https://jarvislabs.ai/blog/vllm-quantization-complete-guide-benchmarks)
- [LLM Quantization Explained 2026 — VRLA Tech](https://vrlatech.com/llm-quantization-explained-int4-int8-fp8-awq-and-gptq-in-2026/)
- [Quantization for 70B Models 2026 — Meta Intelligence](https://www.meta-intelligence.tech/en/insight-quantization)

### Inference engines
- [LLM Inference Engine Showdown — Buttondown](https://buttondown.com/ultradune/archive/eval-001-the-great-llm-inference-engine-showdown/)
- [Inference Engine Comparison 2026 — n1n.ai](https://explore.n1n.ai/blog/llm-inference-engine-comparison-vllm-tgi-tensorrt-sglang-2026-03-13)
- [vLLM vs llama.cpp — Red Hat Developer](https://developers.redhat.com/articles/2025/09/30/vllm-or-llamacpp-choosing-right-llm-inference-engine-your-use-case)
- [Apple Silicon Inference 2026 — Contra Collective](https://contracollective.com/blog/llama-cpp-vs-mlx-ollama-vllm-apple-silicon-2026)
- [Local LLM Inference 2026 — Starmorph](https://blog.starmorph.com/blog/local-llm-inference-tools-guide)

### Benchmarks
- [Berkeley Function Calling Leaderboard V4 — Official](https://gorilla.cs.berkeley.edu/leaderboard.html)
- [BFCL Paper (OpenReview)](https://openreview.net/forum?id=2GmDdhBdDk)
- [Function Calling Benchmarks 2026 — Awesome Agents](https://awesomeagents.ai/leaderboards/function-calling-benchmarks-leaderboard/)
- [Beyond the Leaderboard: Function Calling Eval — Databricks](https://www.databricks.com/blog/unpacking-function-calling-eval)

### Model landscape
- [Open-Source LLM Landscape 2026 — Codersera](https://codersera.com/blog/open-source-llms-landscape-2026/)
- [Open Source LLM Releases 2026 — Fazm](https://fazm.ai/blog/open-source-llm-releases-2026)
- [Self-Hosted LLM Leaderboard 2026 — Onyx](https://onyx.app/self-hosted-llm-leaderboard)
- [Best Open Source LLM 2026 — WhatLLM](https://whatllm.org/best-open-source-llm)
- [Home GPU LLM Leaderboard — Awesome Agents](https://awesomeagents.ai/leaderboards/home-gpu-llm-leaderboard/)

### Hardware
- [Best Local LLMs Apple Silicon 2026 — apxml](https://apxml.com/posts/best-local-llms-apple-silicon-mac)
- [Mac Mini Local AI 2026 — modelfit.io](https://modelfit.io/blog/mac-mini-local-ai-2026/)
- [Cloud GPU Pricing Comparison 2026 — Spheron](https://www.spheron.network/blog/gpu-cloud-pricing-comparison-2026/)
- [Vast.ai vs RunPod 2026](https://medium.com/@velinxs/vast-ai-vs-runpod-pricing-in-2026-which-gpu-cloud-is-cheaper-bd4104aa591b)
