# Researcher Session Log

## 2026-04-22 — Paper memoria LLM/agent ultimi 30-45 giorni (Mar-Apr 2026)

**Task**: ricerca accademica papers usciti dopo 1 Marzo 2026 su memoria LLM/agent, federated memory, benchmark, privacy, skill distillation, consolidation. Output 8-15 findings ordinati per impatto su piano Harness multi-user.

**Key findings (16 paper + pattern)**:
- **HIGH impact**:
  - **HorizonBench** (2604.17283): benchmark 6-mesi / 360 utenti / mental-state-graph typed-edges + provenance → adottare come test obbligatorio, schema direttamente mappabile su Attitude Ledger.
  - **MemEvoBench** (2604.15774): primo bench mis-evolution memoria (adversarial injection + noisy tools + biased feedback) → metriche per `/memory doctor`.
  - **Survey Mnemonic Sovereignty** (2604.16548): 4-phase threat chain (Write/Store/Retrieve/Execute) + concetto user-sovereign memory → cornice teorica threat model federato.
  - **Experience Compression Spectrum** (2604.15877): unifica memory/skills/rules su asse compressione quantitativa (5-20× / 50-500× / 1000×+); identifica gap "missing diagonal" (no adaptive cross-level) → metrica per validare Auto-Dream phase-3.
  - **HeLa-Mem** (2604.16839): Hebbian plasticity su memory graph, emerging associative pathways → pattern reinforcement edges runtime senza training.
  - **SleepGate** (2603.14517): conflict-aware temporal tagger + forgetting gate + consolidation; base per Auto-Dream "Prune & Index" + correction detector.
  - **MAGE** (2604.13777): corpus-free unlearning via memory-graph probing, no forget-set utente → pattern GDPR "right to be forgotten" per modello federato Qwen.
- **MEDIUM-HIGH**:
  - **StageMem** (2604.16774): 3-stage lifecycle (transient/working/durable) + confidence/strength dual-metric → upgrade frontmatter docs/memory/ low-effort.
  - **MemMachine** (2604.04853): SOTA open LoCoMo 0.9169 gpt-4.1-mini, filosofia "ground-truth preserving" (raw episodi, no LLM extraction) → candidato backend alternativo a Letta.
- **MEDIUM**:
  - **MAGMA** / **GAAMA** (2603.27910): 4 grafi ortogonali semantic/temporal/causal/entity + dual-stream write → aggiungere dim "causal" mancante nel nostro design.
  - **Nano-Memory** (2604.11628): baseline nonparametric TIR+QDP che batte sistemi complessi → sanity-check anti-overengineering.
  - **eTAMP** (2604.02623) + **Visual Inception** (2604.16966) + CognitiveGuard: attacchi environment-injected cross-session + images-as-sleepers → sanitization layer su browser watchers e immagini Telegram.
  - **CLEAR** (2604.07487): contrastive reflection (positive vs negative trajectories) invece di summary → upgrade Hermes self-eval checkpoint.
  - **RUMS** (2604.14473): memory selection via mutual information invece di cosine → alternativa leggera a cross-encoder rerank.
- **LOW-MEDIUM**:
  - **ChainFed** (2604.06819): federated fine-tuning sequenziale layer-by-layer per edge memory-constrained → fallback se server federato scende di scala.

**Gap identificati (no prior art 2604)**:
- Federated learning memory-specific agent (paper 2604 federati sono LLM generico, non memoria) → opportunità/rischio per piano Harness.
- TEE + memory agent, SMPC + memory: nessun paper Mar-Apr 2026, gap accademico reale.
- Embedding fine-tuning retrieval custom: nulla di nuovo oltre CLP (2412); BGE-M3/Voyage 3.5 restano baseline.

**3 azioni raccomandate**:
1. Aggiungere HorizonBench + MemEvoBench alla test suite piano memoria.
2. Adottare schema StageMem (confidence + strength + lifecycle stage) nel frontmatter docs/memory/.
3. Leggere Survey Mnemonic Sovereignty (2604.16548) prima di finalizzare threat model server federato.

**Output**: risposta diretta al parent (no file .md creati — solo aggiornamento memoria agent).

**Status**: COMPLETED.

## 2026-04-20 — Round 4 prior-art for plan-v2 memory upgrade

**Task**: verificare se esiste un sistema agentico con 3+ delle 7 caratteristiche distintive del plan-v2 (dual sleeper, Attitude Ledger, pushback conflict_score, provenance API-level, LRS omeostatico, self-scope meta-memoria, recall-probe).

**Output**: `C:\Users\arman\Desktop\Harness\memory-upgrade\prior-art.md` (~2.5k parole, 5 sezioni + fonti).

**Key findings**:
- **Hindsight** (arXiv 2512.12818, Dec 2025) è il match più forte trovato: 4/7 caratteristiche. Ha 4 reti ortogonali (World/Experience/Opinion/Observation) con Opinion ≈ Attitude Ledger e Abstention testato.
- **SSGM** (arXiv 2603.11768) copre governance concettuale, 3-4/7 ma solo teorico.
- **MemMA, ReasoningBank, EVOLVE-MEM, GAM, Dual-Trace Encoding, MR-Search** sono match parziali (2-3 caratteristiche ciascuno).
- La **gestalt** dei 7 elementi combinati è inedita. CQRS applicato a memoria LLM, provenance API-level HTTP 400, authority-gated pushback state-based, user-sampled LRS calibration loop sembrano originali come combinazione.
- Pattern da rubare: Hindsight 4-networks ortogonali, MemMA probe QA pairs, ReasoningBank failure-weighting, GAM topic-shift trigger, SSGM 3 failure point taxonomy.

**Status**: COMPLETED.

## 2026-04-21 — 3 memory gaps: correzione inline, replay retrieval, /memory doctor

**Task**: design concreto+operativo per 3 gap identificati da un critico sul plan memoria: (1) rilevamento correzione inline "no sbagliato è X" con update immediato + lessons.md; (2) tool replay-retrieval.js per A/B config nuove su log storici; (3) `/memory doctor` health check con checklist esaustiva.

**Key findings**:
- **Nessun sistema (Letta, Mem0, Zep, Cognee) offre correction detector esplicito** — tutti fanno consolidation passiva o importance scoring. Pattern novel da costruire.
- **Gap 1 design**: hybrid regex gate + Haiku classifier (soglie 0.6/0.85), locator via last assistant + retrieval log, ops UPDATE/DELETE/ADD + sempre append lessons.md, auto-apply con undo, lock file + tombstone TTL 24h per race con sleep-time.
- **Gap 2 design**: schema JSONL con `memory_snapshot_hash` + tarball zstd in `logs/snapshots/` per fairness temporale A/B. Metriche no-GT: Jaccard overlap, Haiku-as-judge pairwise, citation faithfulness (chunk effettivamente citati), self-consistency. RAG-evaluation-harnesses GitHub come reference.
- **Gap 3 design**: 12 check deterministic Node (frontmatter, link, orphan >60d, skill tool mancanti, supersede cycles, ecc.) + 3 Haiku semantic (contraddizioni cross-file, dupe entità via embedding cosine, fatti stantii). Output severity-ranked md + `/memory fix <id>` auto-fix su kinds safe.
- **Effort totale**: 22-28h (Gap1: 10-12h, Gap2: 6-8h, Gap3: 6-8h). Ordine consigliato: 1→3→2.
- **Edge case critico**: su Windows `flock` non nativo — usare `proper-lockfile` npm.

**Output**: risposta diretta al parent agent (no file separato).

**Status**: COMPLETED.

## 2026-04-20 — Proactive agent pattern validation (Telegram bridge)

**Task**: validare pattern di proattività per agente personale Telegram 2026. Top 3 progetti, pattern canonico, MVP minimale, red flag.

**Key findings**:
- **Letta sleep-time agents** (docs.letta.com/guides/agents/architectures/sleeptime): pattern canonico di background agent che gira ogni N step durante idle, consolida memoria, anticipa query. `enable_sleeptime: true`. Papers: arXiv 2504.13171.
- **Hermes Agent v0.8.0** (Nous Research, Apr 2026): self-evaluation checkpoint ogni 15 tool calls — "what worked/failed/is this worth capturing as a skill?" — closed learning loop, NON notifica utente, scrive su memoria.
- **QwenPaw Mission Mode v1.1.2** (Apr 17 2026): /mission comando autonomous multi-phase con /mission status/list per visibilità. Scheduled memory consolidation.
- **Google CC "Your Day Ahead"** (Dec 2025): briefing mattutino senza prompt, integra Gmail/Calendar/Drive. Reference di prodotto per briefing.
- **InterruptBench** (arXiv 2604.00892, Apr 2026): 3 tipi interruzione (addition/revision/retraction), primo benchmark interruzioni mid-task su web nav. Rilevante per "quando interrompere utente".
- **OpenJarvis** (Stanford, Mar 2026): Orchestrator+Operative per recurring personal workflows, contextual reminders su schedule/location/patterns. Local-first.
- **Zep**: temporal reasoning con validity windows (fatti con when-true/when-recorded). Mem0 NON infers behavioral patterns (limite noto, HN thread Feb 2026).
- **Alert fatigue** (IBM/Darktrace 2026): "human-in-the-loop fallisce per approval fatigue" → YOLO mode emergenti. Necessario confidence gating + quiet hours.

**Pattern canonico proactive loop**: sensori (trigger esterno o cron) → memory lookup → candidate generation → confidence gate → interruption etiquette (urgency × user state) → delivery (silent log vs push) → feedback loop (accept/dismiss rate).

**MVP consigliato**: estendere watchers.json esistenti con tipo `proactive`: (1) morning-briefing cron 8am, (2) pattern-detection weekly su memory.md (Claude-based, non regex), (3) external-event hook webhook→bridge. Primitive minime: digest-not-alert, confidence threshold 0.7+, acceptance tracker in logs/proactive_feedback.json, quiet hours, daily cap (max 3 messaggi spontanei).

**Red flag**: false pattern (N<3 campioni), notifiche senza undo/silence, azioni autonome su dati privati senza allowlist, "YOLO auto-approve" per skippare human-in-the-loop.

**Status**: COMPLETED.

## 2026-04-21 — Auto-Dream + Agent Kernel deep-dive per sistema memoria personale

**Task**: approfondire 2 pattern Aprile 2026 (Claude Code Auto-Dream con flag `tengu_onyx_plover`, Agent Kernel di oguzbilgic) e decidere se adottare per Telegram-bridge memory system.

**Key findings**:
- **Auto-Dream**: quiet rollout da v2.1.59+ Marzo 2026. Flag server-side `tengu_onyx_plover`. 4 fasi (Orient/Gather Signal/Consolidate/Prune&Index). Trigger auto: 24h+5sessioni. Limite <200 righe su MEMORY.md (è un indice, non storage). Files in `~/.claude/projects/<project>/memory/`. Read-only su codice, lockfile anti-concorrenza. No GA timeline annunciata. Replica open-source: `grandamenium/dream-skill` via Stop hook.
- **Agent Kernel** (319 stars, NO LICENSE file — verified via `gh api`): struttura AGENTS.md + IDENTITY.md + KNOWLEDGE.md + notes/ (append-only narrative) + knowledge/ (mutable state con header `Updated: YYYY-MM-DD`). Regola promozione implicita (pattern ricorrenti → knowledge). Contraddizioni risolte per autorità temporale (knowledge=verità attuale, notes=storia immutabile).
- **Decisione raccomandata: D (ibrido)** — struttura da Kernel + processo da Auto-Dream. Migration path a step incrementali su `docs/memory/`, watcher `/dream` schedulato 24h via watchers.json.
- **v4 mapping**: episodes↔notes/, entities↔knowledge/, identity↔IDENTITY/CLAUDE.md, tacit↔Auto-Dream phase-3, indice↔MEMORY.md<200.

**Status**: COMPLETED. Output consegnato direttamente al parent (no .md file creati).

## 2026-04-22 — Scouting memory/agent repos ultimi 30gg per plan Harness multi-user

**Task**: scouting GitHub per repo memoria LLM/agent (a) rilasciati/aggiornati ultimi 30gg, (b) con release significative, (c) trending. Focus: multi-tenant, federated, MCP, PII, local-first ONNX, skill distillation, graph-only.

**Top candidati trovati** (ordinati per rilevanza a Harness):
1. **MemPalace/mempalace** — 49k stars, viral Apr 5 2026, MIT, v3.3.2 21/4. Temporal KG + 29 MCP tools + 96.6% LongMemEval R@5. BUT: benchmark contestati (community code review → numeri vengono dal vector store, non architettura Palace). PII Guard issue #118 in progress.
2. **rohitg00/agentmemory** — 1.9k stars, v0.9.1 20/4, Apache, TS. 107 REST endpoints + 51 MCP tools + 12 auto-capture hooks. 95.2% R@5 LongMemEval, namespaced team memory (multi-user built-in).
3. **NevaMind-AI/memU** — 13.4k stars, v1.5.1 23/3, Apache, Python. Esplicitamente per "24/7 proactive agents like moltbot/clawdbot". Hierarchical Resources→Items→Categories, dual-mode retrieval RAG+LLM.
4. **MemoriLabs/Memori** — agent-native memory infrastructure LLM-agnostic (già in lista Arman ma con aggiornamenti recenti).
5. **EverMind-AI/EverOS** — 4.2k stars, Apache. Engram-inspired MemCells/MemScenes. 93% LoCoMo. Single-user focus.
6. **CaviraOSS/OpenMemory** — 4k stars, Apache, TS/Python. "Not RAG not Vector DB". Episodic+semantic+procedural+emotional+reflective sectors + MCP server + multi-user org-wide.
7. **JordanMcCann/agentmemory** (separato da rohitg00) — solo 16gg build, $1k, 96.2% LongMemEval.
8. **supermemoryai/supermemory** — claim #1 su LongMemEval+LoCoMo+ConvoMem.
9. **aiming-lab/SkillRL** — skill distillation via RL, checkpoints Feb 2026.
10. **kylezantos/skill-distillery** — "skill che crea skill" bottom-up synthesis, 35+ agent compat, solo 11 stars ma concept promettente.
11. **yangyihe0305-droid/memgraph-agent** — NER+co-occurrence+PPR, 82% faster than vector, CPU-only, zero LLM cost. 6 stars ma pattern nuovo (SPRIG-inspired).
12. **lsdefine/GenericAgent** — 5.9k stars, MIT. Self-evolving skill crystallization, 6x meno token (<30K ctx), L4 session archive memory 11/4.
13. **EvoMap/evolver** — Genome Evolution Protocol, open Feb 2026 switched GPL-3 Apr 9.
14. **raaihank/llm-sentinel** — PII scrubbing 80+ tipi sensibili.

**NON trovati relevance critica**: progetti puramente federated LLM ultimi 30gg (solo Flower Summit London Apr 15-16 e papers, nessuna nuova release open-source significativa FlexLoRA/FedLLM lato memory).

**Impatto per Harness**:
- HIGH: MemPalace (pattern wings/rooms/drawers interessante per multi-user scoping; temporal KG con validity windows), rohitg00/agentmemory (multi-user namespaced + team memory + hook-based capture = pattern quasi pronto per Harness), memU (proactive 24/7 match perfetto per watchers).
- MEDIUM: EverOS (engram per long-horizon consolidation), OpenMemory (memory typing esplicito), SkillRL+skill-distillery (per skill extraction layer).
- LOW: memgraph-agent (troppo piccolo), EvoMap (GPL può contaminare).

**Caveat importante**:
- Claim di benchmark MemPalace contestati (LongMemEval headline = vector store, non Palace). Non fidarsi delle metriche senza verificare.
- Federated fine-tuning ultimi 30gg = vuoto relativo. Piano Harness federated richiede build interno.

**Status**: COMPLETED. Output diretto al parent.

## 2026-04-22 — Scan community X/YouTube ultimi 30gg su memoria LLM/agent

**Task**: contenuto community pubblicato dopo 22 Marzo 2026 che NON sia nei paper/repos già noti. Complementare al giro scouting GitHub fatto prima stesso giorno — qui focus su annunci cloud/managed + thought-leadership.

**Limitazione metodologica**: X.com/YouTube richiedono auth — nessun accesso diretto. 11 WebSearch triangolati su press + blog terzi che citano tweet/video. Thread X specifici di Alex Albert/Turley/swyx/karpathy non verificati one-by-one, solo via aggregatori.

**8 segnali forti (ordinati per rilevanza piano Harness multi-user)**:

1. **Anthropic — Claude Managed Agents** (blog 2026-04-08, public beta). Memoria in research preview, memory stores workspace-scoped, immutable versioning con audit+rollback, max 8 store/session, research preview gate separato. Clienti: Notion/Rakuten/Sentry. NOVEL vs Memory Tool: primo runtime managed Anthropic con memoria+checkpoint+credenziali unificati. HIGH impact (competitor diretto a Harness; pattern immutable versioning da replicare).

2. **Cloudflare — Agent Memory private beta** (Agents Week 2026-04-13/17, blog 04-17). Managed extract/dedupe/recall via Worker binding + REST. Operazioni ingest/recall/forget/list. Commitment esplicito data-portability ("every memory exportable"). NOVEL: primo hyperscaler generalista con memoria agent-first. HIGH impact (Harness può posizionarsi come "local-first, stessa API surface").

3. **Memori Labs — Memori Cloud + OpenClaw plugin** (press 2026-03-02, OpenClaw 2026-03-13). SQL-native (NON vettoriale) LLM-agnostic. 81.95% LoCoMo con 1294 tok/query (~5% full-context). OpenClaw plugin per multi-agent gateways. NOVEL: validazione forte del "no-vector" su benchmark ufficiale. HIGH impact (Harness è già file-based, Memori conferma che SQL-only può battere vector/graph su conversation scale).

4. **Letta — Letta Code app** (blog 2026-04-06). Harness locale memory-first, model-agnostic, import memoria da Claude Code/Codex via `/init`, memory subagents periodici, remote env da mobile→laptop. NOVEL: "memoria scorporata dal modello" venduta come feature. HIGH impact (feature parity check; UX remote-from-phone è da studiare per bridge Telegram).

5. **Memvid v2** (GitHub releases Q1 2026). Riscrittura Rust, formato `.mv2` single-file (header+WAL+data segments+indici) ispirato a video encoding (Smart Frames append-only immutabili). <1ms search, <5ms access. NOVEL: format di persistence simile ad Agent Kernel notes/ ma con WAL nativo. MEDIUM impact (pattern per `logs/transcripts/` mirror — formato binario compatto con WAL).

6. **mem0 — "State of AI Agent Memory 2026"** (blog ~aprile 2026). Tassonomia community in 6 classi: conversational recall / profile / reflective / coding-agent / context OS / enterprise context API. LOCOMO ormai standard. Mercato $6.27B 2026 → $28.45B 2030 CAGR 35%. NOVEL come framework di posizionamento condiviso. MEDIUM impact (Harness = ibrido "context OS + profile", utile vocabolario per docs).

7. **Karpathy su RAG personal-scale** (citato in AkitaOnRails 2026-04-06 "Is RAG Dead?"). Quote: per knowledge personale curato "full RAG stack introduce più latenza/rumore di quanto ne rimuova". Favorisce long-context + grep puro. NOVEL: autorità esplicita contro vector-DB-per-default. MEDIUM impact (ammunition per difendere approccio Harness file+grep contro proposte future di Pinecone/Weaviate/Qdrant).

8. **DeepLearning.AI — "LLMs as Operating Systems: Agent Memory"** (Letta + Ng, ripubblicizzato aprile 2026). 1.5h short course con Packer/Wooders, basato su paper MemGPT. INSIGHT didattico, zero pattern tecnici nuovi rispetto a MemGPT. LOW impact (onboarding only).

**HYPE vs INSIGHT**: tutti 1-7 sono INSIGHT (release verificabili, API docs, numeri benchmark, citazioni con attribuzione). 8 è didattico. Nessun puro hype trovato — ciclo annunci aprile 2026 è stato concreto.

**Raccomandazione strategica**: i due eventi HIGH che cambiano il landscape sono Anthropic Managed Agents (04-08) e Cloudflare Agent Memory (04-17). Harness deve definire positioning nei prossimi 30 giorni: "owned data, Windows-native, file-based, multi-Telegram-chat multi-tenant" vs nuovo baseline managed cloud. L'evidenza Memori (81.95% LoCoMo SQL-native) rafforza la tesi no-vector.

**Status**: COMPLETED. Output diretto al parent.
