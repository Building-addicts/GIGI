# Memory Upgrade — Ritrovamenti

> Ricerca approfondita (aprile 2026) su sistemi di memoria per agenti AI, con focus su soluzioni applicabili al bridge Telegram→Claude di Harness.

## TL;DR per chi ha fretta

Il 2026 ha consolidato la memoria degli agenti come **categoria ingegneristica autonoma** con benchmark (LOCOMO, LongMemEval), paper dedicati e ~10 progetti production-ready. Nessuna soluzione singola vince: il pattern vincente è uno **stack a 3-4 livelli** (identità statica + episodic buffer + vector + graph temporale) con **consolidazione notturna in background** e **retrieval deterministico zero-LLM** nel path critico.

Per Harness la scelta migliore è **ibrida**: claude-mem (hooks + progressive disclosure) + Cognee (graph locale + vector) + watcher notturno custom (KAIROS-like) che pulisce/consolida.

---

## Tassonomia 2026 — Come categorizzare

La categoria si è frammentata in **sei idee distinte** che i blog chiamano tutte "memoria":

1. **Raw conversational recall** — mirror letterale (JSONL, SQLite FTS). Esempio: i tuoi `logs/transcripts/*.jsonl`.
2. **Profile memory** — fatti sull'utente (`tacit.md`, Mem0 user preferences).
3. **Reflective memory** — il sistema si auto-corregge (Reflection agents, autoDream).
4. **Coding-agent memory** — specifica per lavoro su codebase (claude-mem, claude-memory-compiler).
5. **Context operating systems** — gestione esplicita di tier (MemGPT/Letta).
6. **Enterprise context APIs** — cloud memory-as-a-service (Zep Cloud, Mem0 Cloud).

Ignorare questa tassonomia produce confronti apples-to-oranges. Per il tuo caso ti interessano principalmente **#1, #2, #3, #4**.

---

## Stato dell'arte — Progetti principali

### Graphiti / Zep — Temporal knowledge graph
Paper arXiv 2501.13956. Modello **bi-temporale**:
- Timeline T = ordine cronologico degli eventi
- Timeline T′ = ordine di ingestione in Zep

I fatti hanno **validity windows**. Quando l'informazione cambia, il vecchio fatto viene **invalidato, non cancellato** — permette query "cosa era vero al tempo X".

**Retrieval ibrido**: embedding semantico + keyword + graph traversal in tempo quasi costante indipendente dalla scala del grafo.

**Performance pubbliche**:
- DMR: 94.8% vs 93.4% baseline
- LongMemEval: +18.5% vs baseline
- Token medi in context: da 115.000 → 1.600 (sotto fattore 70×)
- Latenza: da 29-31s → 2.5-3.2s

**Quando usarlo**: workflow enterprise con entità che evolvono nel tempo, query complesse "chi ha detto cosa quando". Pesante, richiede Neo4j o FalkorDB.

### Mem0 — Entity extraction
Paper arXiv 2504.19413 (ECAI 2025). **Cloud-first** (ma SDK open-source).

- Chiami `memory.add(conversation)` → pipeline estrae fatti/preferenze/entità → store in vector DB
- Chiami `memory.search(query)` → recupera top-k rilevanti
- **~7k token per retrieval** vs 25k full-context (>3×)
- **LOCOMO**: Mem0 66.9%, Mem0g (graph variant) 68.4%
- Framework-agnostico: LangChain, CrewAI, AutoGen, custom loop

**Quando usarlo**: drop-in memory per qualsiasi agente, setup 5 minuti, massima adozione community.

### Letta (ex MemGPT) — LLM-managed tiers
Paper arXiv 2310.08560 (MemGPT). **Runtime completo**, non solo libreria — l'agente *vive dentro* Letta.

Memoria a 3 tier ispirati a OS:
- **Core Memory** (RAM) — sempre in context, ~1-2k token. Identity, utente, task attuale.
- **Recall Memory** (disk cache) — storia conversazioni searchable.
- **Archival Memory** (cold storage) — knowledge base a lungo termine, read-write.

L'agente stesso gestisce la memoria via **function calls**: `core_memory_replace`, `archival_memory_insert`, `conversation_search`, etc. Scrive/legge quando durante il suo reasoning decide che serve.

**Quando usarlo**: agenti long-running autonomi che devono imparare dal proprio operato. Overhead: devi adottare il runtime Letta.

### MemMachine — Top LOCOMO 2026
Paper arXiv 2604.04853. **Ground-truth-preserving** — conserva episodi conversazionali raw, minimizza estrazione LLM.

Architettura a 2 tier + profile:
- Short-term episodic
- Long-term episodic (indicizzato a livello sentence)
- Profile memory

**Contextualized retrieval**: espande i match con episodi vicini per recuperare evidenze distribuite su più turni.

**Performance**:
- LOCOMO: **0.9169** con gpt-4.1-mini (state-of-the-art)
- **~80% meno token** di Mem0
- Latenza bassa: zero LLM nel retrieval normale

**Quando usarlo**: quando vuoi massima accuratezza senza pagare LLM calls ripetute. Più recente, community più piccola.

### claude-mem — Per Claude Code
GitHub: thedotmack/claude-mem, **46k star in 48h**.

Hook su 5 lifecycle events Claude Code:
- `SessionStart` — carica memoria rilevante
- `UserPromptSubmit` — arricchisce prompt con context
- `PostToolUse` — registra ogni tool call
- `Stop` — chiude sessione
- `SessionEnd` — compila riassunto

Storage: **SQLite + FTS5 + ChromaDB**, worker HTTP Bun su porta 37777.

**Pattern chiave: progressive disclosure 3-strati** (risparmio ~10× token):
1. `search()` → indice compatto con ID (~50-100 tok/risultato)
2. `timeline()` → contesto cronologico (~500-1000 tok)
3. `get_observations(ids)` → dettaglio completo solo per ID filtrati

**Issue noto**: leak di subprocess ChromaDB (184 processi orfani in 19h, 16 GB RAM) causato da modello ONNX corrotto → infinite retry. Da monitorare.

### claude-memory-compiler — Karpathy-inspired
GitHub: coleam00/claude-memory-compiler. Più elegante di claude-mem per codebase.

- Hook `SessionEnd` + `PreCompact` catturano transcript
- `flush.py` dopo le 18:00 locali → compilazione giornaliera con Agent SDK
- Estrae: decisioni progettuali, lezioni, pattern, gotchas
- Struttura a tre cartelle: `concepts/`, `connections/`, `qa/`
- **Niente RAG/embeddings**: index.md strutturato + LLM read → meglio di vector similarity a scala personale (50-500 articoli)
- Comandi: `compile.py`, `query.py`, `lint.py` (7 check di integrità)

**Intuizione**: per volumi piccoli (decine-centinaia di documenti), un LLM che legge un indice strutturato **batte** il retrieval vettoriale. Vale assolutamente per il tuo caso (chat personali).

### Cognee — Knowledge engine locale
GitHub: topoteretes/cognee. **6 righe di codice** per integrazione.

Stack 100% locale di default:
- **SQLite** (metadata)
- **LanceDB** (vector)
- **Kuzu** (graph, embedded)

Ingestion universale: 30+ connettori (Slack, Notion, Drive, DB). UI web locale da v0.3.3 con notebooks interattivi + graph explorer.

**Differenza da Mem0**: Cognee costruisce un **knowledge graph** collegando entità, Mem0 estrae fatti isolati. Cognee vince su query relazionali ("cosa sa fare Leo con cosa?").

**Quando usarlo**: budget zero, setup locale, vuoi graph + vector insieme. La scelta naturale per watchers su dati continui.

### Basic Memory — Markdown-first via MCP
GitHub: basicmachines-co/basic-memory.

LLM legge/scrive file Markdown locali via MCP. Struttura:
- Observations (fatti atomici con metadata)
- Relations (collegamenti espliciti tra topic)

Compatibile con Obsidian (i file diventano una vault). **Zero DB**, tutto file system. Perfetto se vuoi la memoria versionabile, leggibile, diff-abile.

### Obsidian-mind & Obsidian Skills
GitHub: breferrari/obsidian-mind, kepano/obsidian-skills.

- **obsidian-mind**: tiered loading — non scarica tutta la vault, carica solo i file rilevanti per il prompt corrente.
- **Obsidian Skills** (kepano, CEO Obsidian): skill ufficiali gen 2026 che insegnano a Claude come maneggiare i formati Obsidian (Bases, JSON Canvas, Markdown).

Combinate, trasformano una vault Obsidian in memoria persistente navigabile.

### Altre menzioni
- **Memsearch** (zilliztech) — libreria standalone markdown-first, ispirata OpenClaw.
- **SimpleMem** (aiming-lab/SimpleMem) — lossless compression, multimodale.
- **Memori** (MemoriLabs) — LOCOMO 81.95% con ~1294 tok/query.
- **ReMe** (agentscope-ai) — "remember me, refine me", estrazione preferenze automatica.
- **Supermemory** — memoria cloud, API-first.
- **OMEGA** — memoria enterprise con multi-tenancy.

---

## Il leak di Claude Code (marzo 2026) — 512k righe

Il 31 marzo 2026 Anthropic ha esposto per errore l'intero codice di Claude Code via `.npmignore` misconfigurato. Rivelazioni critiche:

### Architettura memoria a 4 tipi
1. **User memories** — chi è l'utente, ruolo, preferenze durature
2. **Feedback memories** — correzioni e guidance (con "Why:" e "How to apply:")
3. **Project memories** — stato, decisioni, deadline del progetto
4. **Reference memories** — puntatori a sistemi esterni

Ogni tipo in file separato, indice centrale in `MEMORY.md` caricato sempre. *Questo è esattamente il sistema che già usi per la memoria personale.*

### Regola anti-pollution
L'agente aggiorna `MEMORY.md` **solo dopo conferma di file write riuscito**. Evita di registrare tentativi falliti o stato inconsistente. **Regola d'oro trasferibile**: mai salvare un'azione incompleta.

### Hook lifecycle
Pipeline: `SessionStart → UserPromptSubmit → Tool Use → Stop → SessionEnd`. Da Claude Code 2.1.0 i `SessionStart` hook non mostrano messaggi utente-visibili: il context viene iniettato in silenzio via `hookSpecificOutput.additionalContext`.

### KAIROS + autoDream — il sogno di Anthropic
Daemon autonomo **background** non rilasciato. Durante inattività, esegue `autoDream`:
- **Consolidazione notturna**: merge di osservazioni sparse
- **Coerenza logica**: rimuove contraddizioni
- **Verificazione**: trasforma "insight vaghi" in "fatti verificati"
- **Chyros**: cognizione di background generale

È la direzione strategica: la memoria non si aggiorna solo reattivamente, ma **si raffina passivamente** durante la notte. Replicabile localmente con un watcher cron + Haiku.

### Self-healing memory
L'agente è responsabile di **riscrivere** i propri file di memoria quando scopre errori, non solo di annotare correzioni. Questo crea una memoria che converge alla verità invece di accumulare rumore.

### Warning da evitare
- **SessionStart hook ricorsivi**: utente ha creato hook che spawnava 2 istanze Claude → ciascuna triggerava l'hook → crescita esponenziale 2^N → centinaia di istanze la mattina dopo.
- **ChromaDB subprocess leak**: 184 processi orfani in 19h, 16 GB RAM, causa modello ONNX corrotto in infinite retry.

**Lezione per il bridge**: qualsiasi hook deve avere un **circuit breaker** e un limite su processi spawnabili.

---

## Benchmark standard 2026

### LOCOMO (Long Conversational Memory)
snap-research/locomo — dataset di dialoghi multi-sessione con task event-grounded.

Risultati chiave 2026:
| Sistema | Score LOCOMO | Tokens |
|---------|--------------|--------|
| MemMachine (gpt-4.1-mini) | **0.9169** | 80% meno di Mem0 |
| Memori | 0.8195 | ~1294 tok/query |
| Mem0g (graph) | 0.684 | — |
| Mem0 (base) | 0.669 | ~7000 tok/query |
| Letta | non pubblicato | — |
| Cognee | non pubblicato | — |

### LongMemEval
Zep/Graphiti 71.2% (GPT-4o) — miglior score pubblico.

### DMR (Deep Memory Retrieval)
Zep 94.8% vs 93.4% baseline.

---

## Pattern architetturali ricorrenti

### 1. Stack multi-layer (production consensus)
Non un'architettura, ma una **pipeline**:
```
Identity layer (soul.md) → always in context
     ↓
Episodic buffer (ultimi N turni) → coerenza breve
     ↓
Vector store (ChromaDB/LanceDB) → recall fuzzy
     ↓
Graph (Kuzu/Neo4j) → entità + relazioni temporali
     ↓
Consolidation daemon (cron) → autoDream-like
```

### 2. Progressive disclosure
Mai caricare tutto. Pipeline 3 step:
1. Indice compatto (pochi token)
2. Timeline filtrata (medio)
3. Dettaglio su ID espliciti (grande, solo se serve)

### 3. Zero-LLM retrieval
**"Memory as infrastructure, not prompt engineering"**. Pipeline retrieval deterministico:
- Tag Matching (SQLite FTS)
- Graph Expansion (BFS)
- Vector Search (ChromaDB)
- Fusion + Rank (Reciprocal Rank Fusion)
- Diversity (MMR)

LLM arriva solo **dopo** che il context rilevante è stato selezionato.

### 4. Reflection / Self-correction
Loop continuo `plan → execute → reflect → update_memory`. Ogni errore diventa una lezione salvata. Episodic memory tracks (failure → solution) episodes.

### 5. Relevance > Volume
Mantra del 2026: *"More is not better. Relevance is better."* Meglio 500 token mirati che 50k generici.

### 6. Bi-temporal validity
Ogni fatto ha due timestamp:
- Quando è diventato vero nel mondo
- Quando il sistema l'ha appreso

Permette di rispondere "cosa credevi di sapere al tempo X" vs "cosa era vero al tempo X".

### 7. Non-lossy update
Non cancellare mai. Invalidare con `valid_until`. Il passato resta interrogabile.

---

## Trade-off decisionali

| Scelta | Pro | Contro |
|--------|-----|--------|
| Solo markdown files | Versionabile, leggibile, zero-dep | Scala male oltre 500 file |
| Vector DB | Fuzzy search, scale | Non cattura relazioni |
| Graph DB | Relazioni + temporal | Pesante, richiede modeling |
| Hybrid (vector + graph) | Best of both | Complessità ingegneristica |
| LLM extraction | Fatti puliti | Costi ricorrenti, errori cumulativi |
| Raw storage + index | Zero loss, cheap | Retrieval meno "pulito" |
| Cloud memory-as-a-service | Zero infra | Privacy, lock-in, costi |
| Local self-hosted | Privacy, costi zero | Manutenzione |

---

## Applicabilità a Harness — Fit analysis

### Vincoli specifici del progetto
1. **Windows + Node.js bridge** → preferire soluzioni che girino nativamente o via sidecar HTTP
2. **Flusso Telegram** → la "sessione" è il turno Telegram, non una sessione Claude Code desktop → gli hook Claude Code standard sono solo parzialmente applicabili
3. **Multi-chat** → ogni `chatId` è un'entità separata con memoria propria → serve namespace
4. **Memoria personale già esiste** in `~/.claude/projects/.../memory/` con MEMORY.md — la nuova memoria deve **integrarsi**, non duplicare
5. **Watchers autonomi** → già hai infrastruttura per task periodici → il consolidation daemon è quasi gratis
6. **Browser pool** → non rilevante ma non interferisce
7. **Costi** → preferenza forte per locale, zero cloud

### Scelta consigliata (giustificata)
**Cognee (core) + claude-memory-compiler pattern (struttura) + watcher notturno (autoDream)**

Motivazioni:
- **Cognee** perché: 100% locale, SQLite+LanceDB+Kuzu embedded, 6 righe per integrare da Node via HTTP wrapper, include graph nativo
- **Struttura à la claude-memory-compiler** perché: `concepts/connections/qa/` + `daily/` è perfetta per volume Harness, usa index.md leggibile vs embedding black-box, lint integrato
- **Watcher notturno** perché: tu hai già i watcher, Haiku costa $0.0008/turno, e replica autoDream

Scarto claude-mem perché: è pensato per Claude Code desktop, gli hook non mappano bene sul bridge Telegram, ChromaDB subprocess leak è un rischio concreto su Windows.

Scarto Zep/Graphiti perché: troppo pesante, Neo4j/FalkorDB overhead non giustificato per traffico Telegram personale.

Scarto Letta perché: richiede che l'agente viva dentro il runtime Letta — incompatibile con il modello "spawn claude.exe" del bridge.

Scarto Mem0 (cloud) perché: cloud, vendor lock-in. Mem0 OSS è opzione, ma meno features di Cognee.

---

## Checklist di sanity — Cose da NON sbagliare

- [ ] **Circuit breaker** su ogni hook — max N esecuzioni/minuto, kill se overflow
- [ ] **No write on failed action** — mai salvare memoria di tool call falliti
- [ ] **Namespace per chatId** — memoria Telegram segregata per utente
- [ ] **Audit log** di tutte le scritture memoria (chi ha scritto cosa quando)
- [ ] **Dry-run mode** per consolidation daemon (prima volta: solo preview)
- [ ] **Rollback** — ogni scrittura versionata, rollback istantaneo
- [ ] **Privacy** — la memoria contiene dati personali → backup crittografati, non committare su git se pubblico
- [ ] **Bound** sulla crescita — cap su file/entità, compattazione trimestrale
- [ ] **Human-in-the-loop** per consolidation importanti — diff visibile su panel prima di confermare
- [ ] **Benchmark locale** — test regression su un set di 20 chat passate per misurare drift

---

## Fonti consultate

### Papers & Research
- [MemGPT: Towards LLMs as Operating Systems (arXiv 2310.08560)](https://arxiv.org/abs/2310.08560)
- [Zep: A Temporal Knowledge Graph Architecture for Agent Memory (arXiv 2501.13956)](https://arxiv.org/abs/2501.13956)
- [Mem0: Building Production-Ready AI Agents (arXiv 2504.19413)](https://arxiv.org/abs/2504.19413)
- [MemMachine: A Ground-Truth-Preserving Memory System (arXiv 2604.04853)](https://arxiv.org/abs/2604.04853)
- [Evaluating Very Long-Term Conversational Memory — LOCOMO](https://snap-research.github.io/locomo/)
- [Towards Mitigating LLM Hallucination via Self Reflection (ACL)](https://aclanthology.org/2023.findings-emnlp.123/)

### Progetti GitHub
- [claude-mem (thedotmack)](https://github.com/thedotmack/claude-mem)
- [claude-memory-compiler (coleam00)](https://github.com/coleam00/claude-memory-compiler)
- [cognee (topoteretes)](https://github.com/topoteretes/cognee)
- [mem0 (mem0ai)](https://github.com/mem0ai/mem0)
- [graphiti (getzep)](https://github.com/getzep/graphiti)
- [memmachine (MemMachine)](https://github.com/MemMachine/MemMachine)
- [basic-memory (basicmachines-co)](https://github.com/basicmachines-co/basic-memory)
- [memsearch (zilliztech)](https://github.com/zilliztech/memsearch)
- [obsidian-mind (breferrari)](https://github.com/breferrari/obsidian-mind)
- [obsidian-skills (kepano)](https://github.com/kepano/obsidian-skills)
- [letta-obsidian](https://github.com/letta-ai/letta-obsidian)
- [agentic-memory (lhl)](https://github.com/lhl/agentic-memory)
- [Awesome-Agent-Memory (TeleAI)](https://github.com/TeleAI-UAGI/Awesome-Agent-Memory)
- [Awesome-AI-Memory (IAAR-Shanghai)](https://github.com/IAAR-Shanghai/Awesome-AI-Memory)

### Analisi & Blog tecnici
- [State of AI Agent Memory 2026 — Mem0](https://mem0.ai/blog/state-of-ai-agent-memory-2026)
- [Graph-Based Memory Solutions Top 5 — Mem0](https://mem0.ai/blog/graph-memory-solutions-ai-agents)
- [Agent Memory Systems in 2026 — bymar](https://blog.bymar.co/posts/agent-memory-systems-2026/)
- [The 4-Layer Memory Architecture — DEV](https://dev.to/oblivionlabz/the-4-layer-memory-architecture-that-makes-ai-agents-actually-useful-long-term-50ep)
- [Memory Is the Unsolved Problem of AI Agents — DEV](https://dev.to/jihyunsama/memory-is-the-unsolved-problem-of-ai-agents-heres-why-everyones-getting-it-wrong-4066)
- [Agent Memory Architectures: Vector vs Graph vs Episodic](https://www.digitalapplied.com/blog/agent-memory-architectures-vector-graph-episodic)
- [Claude Code Memory System Explained (Milvus)](https://milvus.io/blog/claude-code-memory-memsearch.md)
- [Inside Claude Code Memory Architecture (Medium)](https://medium.com/@zljdanceholic/inside-claude-code-the-database-free-memory-architecture-that-redefines-ai-agents-c61d7cb1f763)
- [Claude Code Source Leak — MindStudio](https://www.mindstudio.ai/blog/claude-code-source-leak-three-layer-memory-architecture)
- [What Claude Code's Source Leak Actually Reveals — Marc Bara](https://medium.com/@marc.bara.iniesta/what-claude-codes-source-leak-actually-reveals-e571188ecb81)
- [The Claude Code Leak Showed Me What I Was Configuring Wrong — Tyler Folkman](https://tylerfolkman.substack.com/p/i-read-the-claude-code-source-leak)
- [Graph Memory for LLM Agents: Relational Blind Spots — TianPan](https://tianpan.co/blog/2026-04-10-graph-memory-llm-agents-relational-reasoning)
- [MemMachine on LOCOMO](https://memmachine.ai/blog/2025/09/memmachine-reaches-new-heights-on-locomo/)
- [Building AI Agents with Graphiti — Saeed Hajebi](https://medium.com/@saeedhajebi/building-ai-agents-with-knowledge-graph-memory-a-comprehensive-guide-to-graphiti-3b77e6084dec)
- [Cognee — File-Based AI Memory](https://www.cognee.ai/blog/deep-dives/file-based-ai-memory)
- [Serenities — Mem0 vs Zep vs Claude-Mem](https://serenitiesai.com/articles/ai-agent-memory-why-2026-is-the-year-of-persistent-context)
- [vectorize.io — 8 Frameworks Compared](https://vectorize.io/articles/best-ai-agent-memory-systems)
- [Letta Forum — Letta vs Mem0 vs Zep vs Cognee](https://forum.letta.com/t/agent-memory-letta-vs-mem0-vs-zep-vs-cognee/88)

### Documentazione & Tutorial
- [Letta Docs — MemGPT concept](https://docs.letta.com/concepts/memgpt/)
- [Neo4j — Graphiti Knowledge Graph Memory](https://neo4j.com/blog/developer/graphiti-knowledge-graph-memory/)
- [claude-mem — Hooks Architecture](https://docs.claude-mem.ai/hooks-architecture)
- [DataCamp — Claude-Mem Guide](https://www.datacamp.com/tutorial/claude-mem-guide)

---

# Parte II — Approfondimento (deep dive aggiuntivo)

> Ricerche supplementari con focus su: memoria ufficiale Anthropic, sleep-time compute, ricerca accademica (Titans, A-MEM, APEX-MEM), fondamenti cognitivi (ACT-R, Ebbinghaus), compressione prompt, multi-agent namespace, RAG vs Memory, e integrazione pratica Cognee su Windows/Node.

## A. Taxonomia cognitiva della memoria (per usarla correttamente)

Il 2026 ha consolidato **cinque tipi** di memoria che ogni sistema serio deve distinguere. Non è teoria: ignorarli produce confusione di scopo.

| Tipo | Analogia umana | Cosa contiene | Dove vive nel tuo sistema |
|------|----------------|---------------|---------------------------|
| **Working** | Attenzione ora | Prompt corrente, ultimi turni | Context window Claude |
| **Episodic** | "Ricordo che la scorsa volta…" | Eventi timestampati, sessioni passate | T2 episodic buffer + daily/ |
| **Semantic** | "So che Roma è in Italia" | Fatti, preferenze, relazioni | T3 vector + T4 graph |
| **Procedural** | "So come fare pasta" | Workflow, skill, how-to | `concepts/` + `qa/` markdown |
| **Organizational context** | Cultura aziendale | Regole, policy, terminologia di dominio | `soul.md` + `tacit.md` |

**Conseguenza pratica**: quando progetti il retrieval, non cercare "memoria rilevante" genericamente — cerca **quale tipo di memoria** serve al turno corrente. "Qual è la preferenza X?" → semantic. "Cosa abbiamo deciso ieri?" → episodic. "Come procedo con Y?" → procedural.

**Trappola nota**: "*memory blindness*". Se archivi troppo aggressivamente, l'agente non sa di sapere. Se pagini il wrong tier, bruci context. L'orchestrazione è il vero Achille della memoria gerarchica.

**Fonti**: [Agent Memory Types (Atlan)](https://atlan.com/know/types-of-ai-agent-memory/) · [Beyond Short-term Memory (MachineLearningMastery)](https://machinelearningmastery.com/beyond-short-term-memory-the-3-types-of-long-term-memory-ai-agents-need/) · [Memory for Autonomous LLM Agents (arXiv 2603.07670)](https://arxiv.org/html/2603.07670v1)

## B. Anthropic ufficiale — Memory Tool + Managed Agents

Anthropic ha lanciato infrastruttura ufficiale per memoria agenti nel 2026:

### Memory Tool (production API)
Tool ufficiale della Claude API per gestire memoria agentica. Si pair con **context editing**: compaction comprime context, memory persiste oltre le compaction boundaries.

Punto chiave: il tool **è** un filesystem dietro un'interfaccia limitata (`view`, `create`, `str_replace`, `insert`, `delete`, `rename`). Esattamente lo stesso modello che abbiamo adottato nella Parte I — filesystem come memory substrate.

### Claude Managed Agents (public beta, 8 aprile 2026)
Endpoint REST `/v1/agents`, `/v1/environments`, `/v1/sessions`:
- Agent loop + tool execution + sandbox container + state persistence
- Memoria persistente gestita da Anthropic
- Beta header: `managed-agents-2026-04-01`
- Pricing: token rates normali **+ $0.08/session-hour**

**Decisione per Harness**: NON usare Managed Agents. Motivi:
1. Cloud — viola il requirement di stay-local
2. $0.08/h × 24 × 30 = **$57.60/mese/chat** se tieni sessione persistente. Inaccettabile.
3. Il bridge esistente è già un "managed agent" locale fatto da noi — non c'è nulla da delegare.

**Decisione tattica**: possiamo però **imitare l'interfaccia** del Memory Tool ufficiale sul nostro memory-service. Se Anthropic lo ha standardizzato, i futuri upgrade del modello beneficeranno di quella forma.

**Fonti**: [Memory Tool Docs](https://platform.claude.com/docs/en/agents-and-tools/tool-use/memory-tool) · [Managed Agents Overview](https://platform.claude.com/docs/en/managed-agents/overview) · [Claude Managed Agents Deep Dive (DEV)](https://dev.to/bean_bean/claude-managed-agents-deep-dive-anthropics-new-ai-agent-infrastructure-2026-3286)

## C. Sleep-time compute — la teoria dietro autoDream

### Paper
Letta + arXiv 2504.13171 (*Sleep-time Compute: Beyond Inference Scaling at Test-time*) — il fondamento accademico dell'approccio "dream durante inattività".

### Architettura a 3 componenti
1. **Sleeper Agent** — gira periodicamente durante downtime, analizza raw context, genera *learned context*
2. **Memory Store** — dove i "learned insights" vengono persisti
3. **Serve Agent** — a query time, pesca dal Memory Store, non ricomputa da zero

### Risultati misurati
- Claude 3.5 Sonnet: **stessa accuratezza con 11k token vs 20k baseline** (45% riduzione)
- Budget compute fisso a inference: **+15% risposte corrette** usando pre-computed insights
- Cost/token: circa **1/5** rispetto a fare tutto a test-time

### Quando vale
- Context long-lived (progetti persistenti)
- Multi-query sullo stesso context (chat ricorrenti ← tuo caso)
- Latency-sensitive (utente che aspetta)

### Applicazione a Harness
Il watcher `memory-consolidate` del piano è esattamente un sleeper agent. La specifica formalizza:
- **Quando**: 03:00 Europe/Rome (notte, zero traffico Telegram)
- **Cosa computa**: diff tra raw turns del giorno e stato memoria attuale
- **Cosa produce**: entità nuove/aggiornate, fatti invalidati, concetti promossi
- **Costo**: ~$0.015/notte Haiku (vs $0.08/h di Anthropic Managed Agents)

**Trade-off honesto**: sleep-time compute è potente solo se lo sleeper agent **non allucina**. La regola del piano "usa solo testo esplicito, niente invenzione" è la mitigazione. Lint post-run la rete di sicurezza.

**Fonti**: [Sleep-time Compute — Letta blog](https://www.letta.com/blog/sleep-time-compute) · [arXiv 2504.13171](https://arxiv.org/html/2504.13171v1) · [Claude Code AutoDream explained](https://www.mindstudio.ai/blog/what-is-claude-code-autodream-memory-consolidation) · [Arize — Sleep-time Compute](https://arize.com/blog/sleep-time-compute-beyond-inference-scaling-at-test-time/)

## D. Frontiera accademica (paper del 2025-2026)

### Titans + MIRAS (Google Research, arXiv 2501.00663)
**Nuova classe di modelli**, non solo software di memoria. Titans augmenta transformer standard con modulo di **long-term memory** che aggiorna i suoi pesi **a test time** — durante l'inference, non in training separato.

Concetto chiave: **surprise metric**. Il modello misura quanto un token è inatteso → più sorpresa = più memorizzabile. Analogo biologico: gli eventi emotivamente salienti sono ricordati meglio.

Performance: context window >2M token con accuratezza maggiore di baseline Transformer.

**MIRAS** è il meta-framework: 4 design choices (memory structure, attentional bias, stability/retention, memory algorithm) per generalizzare questi approcci.

**Rilevanza per Harness**: zero applicazione diretta (sei utente di Claude, non builder di LLM). Ma il principio "**surprise = priorità**" è trasferibile al nostro sleeper agent: quando consolidi, dai peso maggiore ai turni con contenuto inatteso, non al boilerplate routinario.

**Fonti**: [Titans + MIRAS — Google Research](https://research.google/blog/titans-miras-helping-ai-have-long-term-memory/) · [arXiv 2501.00663](https://arxiv.org/abs/2501.00663) · [Hacker News discussion](https://news.ycombinator.com/item?id=46181231)

### A-MEM (NeurIPS 2025, arXiv 2502.12110) — Zettelkasten agentico
Applicazione del **metodo Zettelkasten** (note interconnesse, atomiche) alla memoria LLM. Ogni memoria è un "note" con:
- Raw content
- Timestamp
- LLM-generated keywords
- LLM-generated tags
- Context descriptions
- Dense embedding
- Link set (inizialmente vuoto)

**Memory evolution**: quando arriva una nuova nota, l'agente analizza storia per identificare **link rilevanti**. I link esistenti possono essere aggiornati retroattivamente. La rete di note **evolve**.

**Differenza da claude-memory-compiler**: a-mem ha link dinamici generati dall'agente. Compiler ha `connections/` scritto manualmente/regolarmente. A-mem è più potente ma più costoso.

**Rilevanza**: da aggiungere come **v2 evolution** del piano dopo stabilizzazione. Nel v1 teniamo connections/ statiche. Nel v2 permettiamo al sleeper agent di proporre nuovi link retroattivi.

**Fonti**: [A-MEM arXiv](https://arxiv.org/abs/2502.12110) · [GitHub agiresearch/A-mem](https://github.com/agiresearch/a-mem) · [Zettelkasten for agents (Alpha's Manifesto)](https://blog.alphasmanifesto.com/2026/04/11/a-mem-zettelkasten-for-agents/)

### APEX-MEM (arXiv 2604.14362)
Memoria **semi-structured** con temporal reasoning. Approccio ibrido tra:
- Storage semi-strutturato (tag + schema flessibile)
- Reasoning temporale esplicito su sequenze di eventi

**Rilevanza**: ispirazione per schema frontmatter dei file entità. Proposta per Harness: ogni `entities/*.md` deve avere frontmatter con `first_seen`, `last_updated`, `confidence`, `source_turns[]`.

### Position paper: Episodic memory is missing (arXiv 2502.06975)
**Tesi**: l'episodic memory è il pezzo che manca ai LLM long-term. Semantic (fatti) e procedural (skill) sono coperti da RAG. Episodic (eventi specifici timestampati) no.

**Implicazione**: il piano Harness deve privilegiare T2 episodic buffer come fonte di continuità percepita. Non basta "ricordare fatti": serve "ricordare *quando* il fatto è emerso".

## E. Fondamenti cognitivi — memoria biomimetica

### ACT-R (Adaptive Control of Thought-Rational)
Architettura cognitiva classica (Anderson 1993). Applicata a LLM in paper 2026 (HAI Conference, ACM 3765803).

**Idea**: ogni memoria ha un'**activation** che dipende da:
- Decay temporale (tempo dall'ultimo access)
- Similarità semantica con query corrente
- Noise probabilistico (plausibilità stocastica)

**Formula base** (semplificata):
```
activation(m) = base_level(m) + spreading(m, context) - decay*log(time_since_access)
```

Memorie sotto soglia non vengono recuperate (ma non cancellate). Questo **riproduce il comportamento umano**: dimentichi ciò che non usi.

### Curva di Ebbinghaus
Memoria biologica decade **esponenzialmente** senza rinforzo:
```
R(t) = e^(-t/S)
```
dove `S` è la memory strength. Ogni access la aumenta.

### Applicazione pratica — TTL tiers
Sistema intelligente di forgetting:
- **Immutable** → TTL infinito (identità, preferenze permanenti)
- **Durable** → TTL 90g, rinforzato a ogni access
- **Transient** → TTL 7g, eventi operativi non strategici
- **Ephemeral** → TTL 24h, chatter quotidiano

Applicazione a Harness: ogni fatto nel graph ha `tier` e `last_accessed`. Il cron notturno di consolidation **decrementa** activation e rimuove sotto soglia.

**Attenzione**: "rimuove" nel piano = sposta in `archive/` file, non `DELETE`. Per retrieval storico resta disponibile ma fuori dal retrieval path standard.

### SAGE — Self-evolving Agents
Paper recente che combina reflection loop + memory augmentation + procedural skill accumulation. Agente che **impara a lavorare meglio** via tracce di successo/fallimento pregressi.

**Rilevanza**: future evolution. V1 non lo copre, V3+ può introdurre feedback loop ("questa risposta è stata utile?" → boost activation fatti coinvolti).

**Fonti**: [ACT-R Inspired Memory (ACM)](https://dl.acm.org/doi/10.1145/3765766.3765803) · [Machine Memory Intelligence (ScienceDirect)](https://www.sciencedirect.com/science/article/pii/S2095809925000293) · [Memoria arXiv 2310.03052](https://arxiv.org/html/2310.03052v3) · [SAGE](https://www.sciencedirect.com/science/article/abs/pii/S0925231225011427)

## F. Prompt compression — quando il retrieval non basta

Se nonostante la memoria il context rimane gonfio, compressione è l'ultimo layer.

### Tecniche principali 2026

| Tecnica | Meccanismo | Compression | Note |
|---------|------------|-------------|------|
| **Selective Context** | Rimuove ridondanza informazionale | ~50% token | -36% memoria, -32% latency |
| **CPC (Context-aware Prompt Compression)** | Sentence encoder score → drop low | Variable | Human-readable output |
| **RCC (Recurrent Compression)** | Segmenta + comprime in vettori | **32× compression** | Potenza ma opaca |
| **BEAVER** (arXiv 2603.19635) | Structure-aware page selection | — | **26.4× speedup** su 128k context (1.2s vs 31.7s LongLLMLingua) |
| **Provence** | Post-retrieval pruning sentence-level | — | Head su re-ranker esistente |

### Gerarchia di summary (Claude Code)
Claude Code internamente usa **hierarchical summaries**:
- Context taggato per funzione ("currently edited file", "referenced dependency", "error message")
- Ogni turno: sistema seleziona cosa è rilevante e presenta strutturato
- Separate tracks per reasoning e visible output

### Applicazione Harness
Nel v1 **NON serve compression**. Budget è 3k tok iniettati, dentro la comfort zone. Aggiungere compression solo se:
- Un chat specifico supera 100 turni/giorno
- Il retrieval produce >10k tok di materiale candidato da filtrare

In quel caso: implementare **Selective Context** come post-processing nel memory-service prima di return.

**Fonti**: [State of Context Engineering 2026](https://www.newsletter.swirlai.com/p/state-of-context-engineering-in-2026) · [Prompt Compression Survey NAACL 2025](https://aclanthology.org/2025.naacl-long.368.pdf) · [BEAVER arXiv 2603.19635](https://arxiv.org/html/2603.19635)

## G. Context engineering vs prompt engineering

Il 2026 ha cristallizzato una distinzione:

- **Prompt engineering** (2023-2024): scrivi bene UN prompt
- **Context engineering** (2025-2026): orchestri memoria, tools, retrieval, state dinamicamente

> *"Il centro di gravità dello sviluppo AI si è spostato dallo scrivere prompt migliori all'ingegnerizzare context migliori."*

**Definizione operativa**: selezionare, organizzare e ottimizzare **algoritmicamente** le informazioni di background fornite a un LLM.

Il memory-service del piano è di fatto un **context engineering system**, non "solo memoria". Le 5 responsabilità:
1. Persist (store)
2. Retrieve (query)
3. Compose (assemble prompt)
4. Compress (when over budget)
5. Consolidate (sleep-time)

**Lezione per il naming nel piano**: non più "memory-service" ma **`context-service`** sarebbe più corretto concettualmente. Tuttavia "memory" è comunicativamente più chiaro, quindi lo teniamo nel codice pur sapendo che fa di più.

## H. Multi-agent memory & namespace isolation

### Collaborative Memory (arXiv 2505.18279)
Framework modulare per **permission-aware memory sharing** in sistemi multi-utente/multi-agente. Componenti:
- **Asymmetric access sharing** via dynamic bipartite graphs
- **Two-tier architecture**: private memory + shared memory
- **Read/write policies configurabili** a livello system/user/agent

Tre modi di scoping:
1. **Isolated** — ogni profilo vede solo i propri fatti
2. **Shared with attribution** — tutti vedono tutto, ma con source tag
3. **Hybrid** — profile-scoped di default, con promote esplicito a shared

### Problema "facts pollution"
In setup multi-agente, fatti rilevanti per agente A inquinano context di agente B. La regola di business è rigida: **ogni `memory.add()` e `memory.search()` DEVE includere `user_id` autenticato**.

### Risparmi misurati
Sharing con 50% overlap → **-61% uso risorse** vs memoria isolata. Con 75% overlap → -59%.

### Applicazione Harness
Tu hai **una chat sola** (whitelist di un chat ID). Quindi namespace isolation è *overengineering*.

**MA**: se un giorno aggiungi altri chat whitelisted, il piano deve già prevedere:
- `chats/<chatId>/` → namespace isolato (Isolated mode)
- `shared/` globale → concepts di dominio condivisi (soul.md, glossario)
- **Zero cross-contamination automatica** — ogni accesso filtra per chatId

Questo è già previsto nel piano (§ 4 policy sicurezza). Conferma che l'architettura è corretta.

**Fonti**: [Collaborative Memory arXiv 2505.18279](https://arxiv.org/abs/2505.18279) · [INMS arXiv 2404.09982](https://arxiv.org/html/2404.09982) · [Multi-Agent Memory from Computer Arch Perspective](https://arxiv.org/html/2603.10062v1)

## I. RAG vs Memory — la distinzione che molti sbagliano

Il 2026 ha finalmente chiarito la differenza:

| | **RAG** | **Memory Layer** |
|---|---------|------------------|
| Stato | Stateless | Stateful |
| Cosa serve | Knowledge retrieval da corpora grandi | Continuità sessioni + personalizzazione |
| Direzione | Read-only | Read-write |
| Update | Periodico batch | Incrementale online |
| Scope | Organizational knowledge | Per-user/per-agent |
| Esempi | Docs aziendali, catalogo prodotti | User preferences, past conversations |

**Regola pratica 2026**: produzione agenti matura usa **entrambi**:
- RAG per knowledge (quando serve riferire a docs)
- Memory per personalization (chi è l'utente, cosa ha detto)

**Conseguenza**: il tuo sistema attuale non usa RAG (non hai corpora da interrogare). Il piano Harness è pure-memory-layer. Ma **futura feature**: indicizzare la documentazione Harness (`CLAUDE.md`, `docs/`, README dei watchers) come mini-RAG interno, permettendo a Claude di fare "*cosa c'è in tacit.md di questa chat?*" come RAG query strutturata.

**Fonti**: [RAG vs AI Memory — Mem0](https://mem0.ai/blog/rag-vs-ai-memory) · [AI Memory vs RAG vs KG Enterprise Guide](https://atlan.com/know/ai-memory-vs-rag-vs-knowledge-graph/) · [Vector vs Graph RAG — MachineLearningMastery](https://machinelearningmastery.com/vector-databases-vs-graph-rag-for-agent-memory-when-to-use-which/)

## J. Embedding models — scelta tecnica per CPU locale

Cognee usa embedding. Dobbiamo scegliere quale. Vincolo: **Windows CPU-only** (no CUDA probabile).

| Modello | Size | Max context | Velocità CPU | Quality | Note |
|---------|------|-------------|--------------|---------|------|
| **MiniLM L6** | 22M | 256 | Velocissimo | Bassa | Solo per tag match |
| **BGE-small-en** | 45M | 512 | Veloce | Buona | Entry level RAG |
| **BGE-base-en** | 110M | 512 | Medio | Alta | Sweet spot generale |
| **Nomic Embed v2** | 137M | **8192** | Medio | **Alta+** | Matryoshka (truncabile 768→64), task prefix |
| **GTE-multilingual-base** | ~300M | 8192 | Medio | Alta | Multilingue nativo, 10× più veloce di decode-only |
| **BGE-large-en** | 355M | 512 | Lento | Alta+ | Overhead non giustificato |

### Raccomandazione per Harness
**Nomic Embed v2** come default. Motivi:
1. Context 8192 → gestisce turni lunghi interi senza chunking
2. Matryoshka → puoi partire a 768 dim, troncare a 256 per chat a basso traffico (storage ¼)
3. Italiano nativo accettabile (training multilingue)
4. CPU-friendly (137M)
5. Supporto task prefix (`search_query:` vs `search_document:`) → retrieval più accurato

Alternativa fallback: **GTE-multilingual-base** se l'italiano con nomic produce risultati scarsi nei test.

### Via Cognee
Cognee supporta via config:
```python
cognee.config.set_llm_config({
    "embedding_provider": "huggingface",
    "embedding_model": "nomic-ai/nomic-embed-text-v2-moe",
    "embedding_dimensions": 768
})
```

**Fonti**: [Best Open-Source Embedding Models — Supermemory](https://supermemory.ai/blog/best-open-source-embedding-models-benchmarked-and-ranked/) · [Baseten Embedding Guide](https://www.baseten.co/blog/the-best-open-source-embedding-models/) · [CPU Optimized Embeddings (HF Blog)](https://huggingface.co/blog/intel-fast-embedding) · [Nomic Embed v2 (HF Card)](https://huggingface.co/nomic-ai/nomic-embed-text-v2-moe)

## K. Integrazione Cognee → Node.js → Windows (dettagli pratici)

### Opzione 1 — HTTP transport (scelta del piano)
Cognee espone server HTTP MCP via:
```bash
python src/server.py --transport http --host 127.0.0.1 --port 8000 --path /mcp
```
Node.js chiama via `fetch`. Vantaggi: isolamento processi, restart indipendente.

### Opzione 2 — TypeScript client ufficiale
`@lineai/cognee-api` su npm. Client TS type-safe che wrappa l'HTTP. Suggerito usarlo invece di `fetch` diretto:
```bash
npm install @lineai/cognee-api
```

### Opzione 3 — n8n node (non rilevante)
Cognee-n8n esiste per workflow n8n. Non usiamo n8n, quindi scartato.

### Windows-specific
1. **venv attivazione**: `memory-service\.venv\Scripts\activate` (non `bin/activate`)
2. **Percorsi file**: usare forward slashes in config, Python li normalizza
3. **Long path**: abilitare Long Path Support di Windows (`HKLM\SYSTEM\CurrentControlSet\Control\FileSystem\LongPathsEnabled = 1`) — Kuzu potrebbe creare nested deep
4. **Process management**: usare `node-windows` o un wrapper `service` per auto-restart sidecar Python

### Docker alternative
Per production "seria" si suggerisce Docker container Ubuntu 22.04 con Cognee installato, esposto su `localhost:8000`. Se hai Docker Desktop su Windows, è la via più pulita. **Ma** aggiunge una dipendenza pesante al progetto. Il piano va avanti senza Docker; Docker sarà fase "7 — hardening opzionale".

**Fonti**: [Cognee Docs](https://docs.cognee.ai) · [Cognee Installation Guide](https://github.com/40Thinker/cognee-installation-guide) · [Cognee MCP Guide](https://skywork.ai/skypage/en/ultimate-ai-engineer-guide-cognee-mcp-server/1977912822261551104) · [@lineai/cognee-api npm](https://www.npmjs.com/package/@lineai/cognee-api)

## L. Benchmark riferimenti di Telegram-bot con memoria

Progetti open con pattern simili ad Harness:

### Hermes Agent (NousResearch, v0.7.0 aprile 2026)
- Open-source, model-agnostic
- **Pluggable memory backends** (design che copieremo)
- 40+ built-in tools, MCP server mode
- Sei terminal backends (incluso Telegram)
- **Feature issue aperto** per profile-scoped memory namespaces

### Nanobot (HKUDS)
- Ultra-lightweight personal AI agent
- Token-based memory + shared retries
- Design minimal: "memory or skills pulled in only as context instead of becoming heavy orchestration layer"
- Molto vicino alla filosofia "memory as infrastructure"

### Multibot (Cloudflare Workers + Durable Objects, serverless)
- Multi-bot orchestration con sub-agent spawning
- **LLM-driven two-layer memory**
- $5/month runtime, cross-platform (Telegram, Discord, Slack)
- Serverless — non direttamente applicabile, ma idee di DO-per-chat sono interessanti

### ma2za/telegram-llm-bot
- Stack: OpenAI, Whisper, Beam, LLaMA, Weaviate, MinIO, MongoDB
- Too heavy per Harness. Citato come reference negativo: "don't do this, Weaviate overkill"

### mlloliveira/TelegramBot (Ollama-based)
- Completamente self-hosted con Ollama
- Python, modalità switch, image analysis
- Memoria semplice (no graph), buon riferimento per struttura bot

**Conclusione**: Hermes è il progetto più vicino al nostro target. Vale leggerlo prima di implementare.

**Fonti**: [Hermes Agent (NousResearch)](https://github.com/nousresearch/hermes-agent) · [Hermes Issue #4726 — namespaces](https://github.com/NousResearch/hermes-agent/issues/4726) · [Nanobot](https://github.com/HKUDS/nanobot) · [Multibot launch](https://agent-wars.com/news/2026-03-16-multibot-open-source-serverless-multi-bot-ai-platform-on-cloudflare-workers) · [ma2za telegram-llm-bot](https://github.com/ma2za/telegram-llm-bot)

## M. Ulteriori rischi identificati

Aggiornamento risk matrix con quanto emerso:

| Rischio | Scoperto in | Mitigazione |
|---------|-------------|-------------|
| **Memory blindness** (archivi troppo, agente non sa di sapere) | Atlan types article | Keep index.md rilevante, no over-archiving |
| **Context bloat from over-retrieval** | Context Engineering sources | Hard cap token budget, MMR diversity |
| **Experience-following bias** (arXiv 2505.16067) | Empirical study on memory mgmt | Mix di retrieval semantic + episodic, non solo similarità |
| **Embedding drift** tra modelli | Embedding benchmark | Lock del modello embedding in config, re-embed batch su upgrade |
| **Kuzu data format change** | Cognee release notes | Cognee version pin, test migration path |
| **Surprise-weighted bias** (da Titans) | Google blog | Balance: surprise + repetition (non solo sorpresa pura) |

## N. Pattern emergenti da adottare nel v2/v3 (roadmap)

Dopo stabilizzazione del piano v1, queste sono le evolution naturali:

### v2 — "intelligent memory"
1. **A-MEM-style dynamic linking** — lo sleeper agent propone link retroattivi tra note esistenti
2. **Activation decay** (ACT-R) — ogni memoria ha activation che decresce, sotto soglia → archive/
3. **Surprise scoring** — al capture, tagga turni "surprising" con priority alta nel consolidation
4. **Episodic emphasis** — quando retrieve, weight extra a memorie con timestamp recente

### v3 — "reflective memory"
5. **Self-correction loop** — quando il retrieve porta fatti contraddittori, l'agente chiede all'utente quale è vero, aggiorna
6. **Skill accumulation** (procedural) — workflow ripetuti 3+ volte diventano skill file in `procedures/`
7. **Feedback loop** — `/mem_good` e `/mem_bad` Telegram commands → reward signal per activation
8. **Cross-chat knowledge promotion** — concetti che emergono in 2+ chat diventano shared/

### v4 — "integrated"
9. **Mini-RAG interno** — indicizza la documentazione Harness come RAG layer
10. **Obsidian vault sync** — export memory a Obsidian per review human-readable + skills kepano/obsidian-skills
11. **Voice memory** — chat vocali Telegram → whisper → trascritto + memorized come episodic audio

## O. Sintesi finale aggiornata

Il piano Parte I resta corretto. Le conferme dall'approfondimento:

1. ✅ **Sleep-time compute** formalizza il watcher notturno — approccio confermato dalla ricerca
2. ✅ **Memory tiers (T0-T4)** allineati con working/episodic/semantic/procedural/org standard 2026
3. ✅ **Zero-LLM retrieval path** è il consensus di produzione
4. ✅ **Namespace per chatId** è già best practice per multi-user futuro
5. ✅ **Filesystem-first** allineato con Memory Tool ufficiale Anthropic e claude-memory-compiler
6. ✅ **Cognee** resta la scelta migliore per graph+vector locali su Windows
7. ✅ **Circuit breaker** è critico (leak Claude Code + collaborative memory access control)

**Novità da integrare nel plan.md**:
- Specificare **Nomic Embed v2** come embedding default
- Aggiungere **TTL tiers** (immutable/durable/transient/ephemeral) al modello dati entità
- Documentare **surprise weighting** nel consolidation prompt (non solo "dedupe")
- Adottare interfaccia **Memory Tool-compatible** per forward compatibility
- Usare **@lineai/cognee-api** invece di `fetch` raw
- Pianificare **v2/v3/v4 roadmap** post-stabilizzazione

**Costo operativo stimato annuale (ricalcolato)**:
- Haiku sleeper: ~$7/anno
- Elettricità Python sidecar + Kuzu/LanceDB: trascurabile
- Storage: <5 GB dopo anno di uso intenso
- Zero cloud fees
- **Totale: <$10/anno**

Rispetto a Anthropic Managed Agents ($57.60/mese/chat = $691/anno per chat), un sistema locale equivalente è **70× più economico** e privacy-preserving.

## P. Altre fonti consultate nel deep dive

- [Memory Tool — Anthropic](https://platform.claude.com/docs/en/agents-and-tools/tool-use/memory-tool)
- [Managed Agents — Anthropic](https://platform.claude.com/docs/en/managed-agents/overview)
- [Sleep-time Compute — Letta](https://www.letta.com/blog/sleep-time-compute)
- [Sleep-time Compute — Arize](https://arize.com/blog/sleep-time-compute-beyond-inference-scaling-at-test-time/)
- [Titans arXiv 2501.00663](https://arxiv.org/abs/2501.00663)
- [Titans + MIRAS — Google Research](https://research.google/blog/titans-miras-helping-ai-have-long-term-memory/)
- [A-MEM arXiv 2502.12110](https://arxiv.org/abs/2502.12110)
- [Position: Episodic Memory is Missing (arXiv 2502.06975)](https://arxiv.org/pdf/2502.06975)
- [APEX-MEM arXiv 2604.14362](https://arxiv.org/html/2604.14362)
- [Human-Like Remembering — ACM](https://dl.acm.org/doi/10.1145/3765766.3765803)
- [Machine Memory Intelligence](https://www.engineering.org.cn/engi/EN/10.1016/j.eng.2025.01.012)
- [Memoria arXiv 2310.03052](https://arxiv.org/html/2310.03052v3)
- [Collaborative Memory arXiv 2505.18279](https://arxiv.org/abs/2505.18279)
- [INMS arXiv 2404.09982](https://arxiv.org/html/2404.09982)
- [Multi-Agent Memory Computer Architecture Perspective](https://arxiv.org/html/2603.10062v1)
- [Experience-Following Behavior (arXiv 2505.16067)](https://arxiv.org/html/2505.16067v2)
- [RAG vs AI Memory — Mem0](https://mem0.ai/blog/rag-vs-ai-memory)
- [AI Memory vs RAG vs KG — Atlan](https://atlan.com/know/ai-memory-vs-rag-vs-knowledge-graph/)
- [Memory Layer vs Context Window — Atlan](https://atlan.com/know/memory-layer-vs-context-window/)
- [State of Context Engineering 2026](https://www.newsletter.swirlai.com/p/state-of-context-engineering-in-2026)
- [Prompt Compression Survey NAACL 2025](https://aclanthology.org/2025.naacl-long.368.pdf)
- [BEAVER arXiv 2603.19635](https://arxiv.org/html/2603.19635)
- [Cognee Docs](https://docs.cognee.ai)
- [@lineai/cognee-api (npm)](https://www.npmjs.com/package/@lineai/cognee-api)
- [Hermes Agent](https://github.com/nousresearch/hermes-agent)
- [Nanobot](https://github.com/HKUDS/nanobot)
- [Agent-Memory-Paper-List (TsinghuaC3I)](https://github.com/TsinghuaC3I/Awesome-Memory-for-Agents)
- [Agent Memory Paper List (Shichun-Liu)](https://github.com/Shichun-Liu/Agent-Memory-Paper-List)
- [Awesome-Efficient-Agents (yxf203)](https://github.com/yxf203/Awesome-Efficient-Agents)
- [Nomic Embed v2 MoE (HF)](https://huggingface.co/nomic-ai/nomic-embed-text-v2-moe)
- [ICLR 2026 MemAgents Workshop](https://openreview.net/pdf?id=U51WxL382H)
- [Beyond Short-term Memory — MachineLearningMastery](https://machinelearningmastery.com/beyond-short-term-memory-the-3-types-of-long-term-memory-ai-agents-need/)
- [7 Steps to Mastering Memory — MachineLearningMastery](https://machinelearningmastery.com/7-steps-to-mastering-memory-in-agentic-ai-systems/)
- [Agent Memory Architecture Deep Dive — AI Magicx](https://www.aimagicx.com/blog/ai-agent-memory-architecture-developer-guide-2026)
- [Analytics Vidhya — Memory Systems Orchestration](https://www.analyticsvidhya.com/blog/2026/04/memory-systems-in-ai-agents/)
- [Cofounder — General Intelligence Co](https://www.generalintelligencecompany.com/writing/introducing-cofounder-our-state-of-the-art-memory-system-in-an-agent)
- [Auto-Dream Level Up Coding](https://levelup.gitconnected.com/your-ai-coding-agent-now-needs-sleep-heres-what-dream-actually-does-81d32977ec25)
- [Claude Code AutoDream — DMarketer](https://dmarketertayeeb.com/blog/claude-code-auto-dream-memory-feature/)

