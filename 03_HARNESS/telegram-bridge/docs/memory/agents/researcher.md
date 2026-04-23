# Researcher Session Log

## 2026-04-21 — Memory backend: LanceDB+BGE-M3 vs sqlite-vec+Voyage

**Question:** For a single-user Windows 11 + Node.js 22 AI memory system, which stack is better: LanceDB + local BGE-M3 (q8, transformers.js) vs sqlite-vec + Voyage 3.5 API?

**Key findings:**
- sqlite-vec latest = v0.1.9 (31 Mar 2026), still brute-force only, no HNSW yet. Performance on M1 Pro: 67ms full-scan on 100K x 384 float32, ~17ms with int8 quant, ~4ms with preload. For <10K vectors trivially fast.
- sqlite-vec practical limit: "hundreds of thousands" of vectors — more than enough for single-user memory.
- LanceDB Node.js has documented Windows native-binding issues (issues #630, #939 — vectordb-win32-x64-msvc loading failures). Not blocker but friction.
- Voyage 3.5: $0.06/1M input tokens, 2000 RPM / 8M TPM tier 1. Anthropic's recommended embedding partner (Anthropic has no own embeddings).
- Anthropic Haiku is NOT an embedding model. Cannot produce vectors.
- BGE-M3 MTEB ~63.0, Voyage-3-large significantly higher on retrieval. BGE-M3 supports dense+sparse+multivector in one model — unique.
- BGE-M3 int8 ONNX: ~2x faster than fp32 on CPU, negligible quality loss. Works in transformers.js (xenova/bge-m3 + gpahal/bge-m3-onnx-int8).
- ChromaDB embedded also an option (Node.js client, SQLite-like embedded mode).

**Recommendation:** sqlite-vec + Voyage 3.5. For vibecoded single-user with <100K memories, cost is ~$0.60-2/year, setup is 1h vs a day, no native binding hell on Windows, better retrieval quality. Keep LanceDB+BGE as fallback only if offline/air-gapped becomes a hard requirement.

**Files referenced:** none (pure research task).
