# Prior Art Analysis — Memory Upgrade v2

> Round 4 di ricerca. Obiettivo: verificare quanto delle 7 caratteristiche distintive di `plan-v2.md` sia già stato fatto altrove, cosa è inedito, cosa conviene "rubare". Evita di ripetere sistemi già coperti in `findings.md` (Graphiti/Zep, Mem0, Letta/MemGPT, MemMachine, claude-mem, Cognee, A-MEM, Titans/MIRAS, MemoryOS, KAIROS/autoDream).

## 0. Le 7 caratteristiche di riferimento (reminder)

1. **Dual sleeper** — recorder sync deterministico + interpreter async LLM
2. **Attitude Ledger** — belief store dell'agente, separato dai fatti sull'utente
3. **Pushback mechanism** — conflict_score con soglie + guard in contesto di authority
4. **Provenance obbligatoria API-level** — `source_type` non negoziabile
5. **LRS omeostatico** — metrica tenuta in banda, tuning settimanale via feedback
6. **Self-scope / meta-memoria** — episodes predizione/outcome + lessons con surprise
7. **Recall-probe fail-safe** — soglia similarity pre-citazione, abstention esplicita

---

## Sezione 1 — Match diretti (4+ caratteristiche)

### 1.1 Hindsight (arXiv 2512.12818, Vectorize.io + Virginia Tech, dic 2025)
**Link**: https://arxiv.org/abs/2512.12818 · https://vectorize.io/blog/introducing-hindsight-agent-memory-that-works-like-human-memory · repo open-source.

**Score: 4 su 7** — è il **match più forte mai trovato**, rilasciato 4 mesi fa. Paper che VentureBeat ha ripreso con titolo "91% accuracy, 20/20 vision for agents stuck on failing RAG".

Architettura a **4 reti di memoria separate**:
- **World (W)**: fatti oggettivi sul mondo esterno (== i nostri "facts")
- **Experience (B)**: biografia prima persona delle azioni dell'agente (== nostri "episodes" del Stenografo)
- **Opinion (O)**: giudizi soggettivi dell'agente con `confidence ∈ [0,1]` e timestamp (== Attitude Ledger)
- **Observation (S)**: summary di entità preference-neutral

Copre:
1. **Dual sleeper parziale (Y)** — synthesis delle Observations gira "asynchronously to maintain low-latency writes". Ma non c'è una separazione esplicita recorder/interpreter; è un singolo async pipeline.
2. **Attitude Ledger (Y, forte)** — la rete Opinion *è esattamente* quello. Schema: stance + confidence + timestamp. Pipeline `Assess(o, f) -> {reinforce, weaken, contradict, neutral}` con `c' = max(c - 2α, 0)` su contraddizione.
3. **Pushback mechanism (N)** — non c'è un meccanismo user-facing di dissenso calibrato. L'opinion update è interno: quando nuovi fatti contraddicono, l'agente aggiorna silenziosamente. Manca `conflict_score`, soglie silenzio/soft/hard, authority guard.
4. **Provenance (N)** — nessun `source_type`. I fatti sono classificati per *tipo di rete* (world/experience/opinion), non per *origine*. È una distinzione ontologica, non di provenance.
5. **LRS omeostatico (N)** — nessuna metrica in banda con feedback loop.
6. **Self-scope / meta-memoria (N)** — c'è un `behavioral profile Θ=(S,L,E,β)` per disposizioni, ma non episodes con `prediction vs outcome + surprise`.
7. **Recall-probe fail-safe (Y, parziale)** — testano esplicitamente **"Abstention"**: l'agente dovrebbe "correctly decline to answer when information is missing, rather than guessing". Non è però implementato come similarity probe pre-retrieval.

**Performance**: 20B open-source model da 39% a 83.6% su LongMemEval/LoCoMo, batte GPT-4o full context.

**Cosa ruberei**:
- La separazione a **4 reti ortogonali** è più pulita del mio T3/T4/T5/T6. Varrebbe riorganizzare come: `facts/` (world), `episodes/` (experience/Stenografo), `beliefs/` (opinion), `summaries/` (observation).
- La formula `Assess -> {reinforce, weaken, contradict, neutral}` è meglio del mio `sim × |stance_diff| × confidence` per la parte *update*: è discreta, meno rumorosa. Posso usare entrambe: `conflict_score` per decidere il pushback (user-facing), `Assess` per l'update interno.
- Il test di **Abstention** è un benchmark concreto per validare il mio recall-probe.

**Cosa manca rispetto a plan-v2**: provenance API-level, pushback user-facing, LRS omeostatico, episodes con surprise predittivo, dual sleeper vero. Questi sono genuinamente tuoi.

---

### 1.2 SSGM — Stability & Safety Governed Memory (arXiv 2603.11768, Jinan Univ, mar 2026)
**Link**: https://arxiv.org/abs/2603.11768

**Score: 3-4 su 7** — framework concettuale, non codice. Molto vicino al tuo "governance thinking".

Tre failure point identificati:
1. Memory Poisoning (input ingestion)
2. Semantic Drift (consolidation)
3. Conflict/Hallucination (retrieval)

Mitigazioni:
- **Consistency verification** pre-consolidation → sovrappone con le tue provenance + lint check
- **Temporal decay modeling** → sovrappone con held_count/challenged_count + decay 30gg
- **Dynamic access control** → sovrappone con namespace per chatId
- Decouple memory evolution from execution → sovrappone con dual sleeper

Copre:
1. Dual sleeper: **parziale (Y)** — "decouples memory evolution from execution"
2. Attitude Ledger: N
3. Pushback: N
4. Provenance: **parziale (Y)** — "consistency verification prior to any memory consolidation" implica tracking di origine
5. LRS omeostatico: N
6. Self-scope: N
7. Recall-probe: **parziale (Y)** — "Conflict/Hallucination during retrieval" è la classe di rischio trattata

**Differenza sostanziale**: SSGM è un paper di governance/rischio. Non è un'implementazione. Il plan-v2 è un'implementazione concreta con Zod schema, cron watcher, API. SSGM formalizza i rischi che tu hai già mitigato.

**Cosa ruberei**: la tassonomia dei 3 failure point è utile come schema di validazione. Aggiungerei al tuo § 6 Rischi una mappatura esplicita delle mitigazioni a quei tre punti, per "legittimare" architetturalmente il design.

---

## Sezione 2 — Match parziali (2-3 caratteristiche)

### 2.1 MemMA (arXiv 2603.18718, Penn State + Amazon, mar 2026)
**Link**: https://arxiv.org/abs/2603.18718 · https://github.com/ventr1c/memma

**Score: 3 su 7**

Multi-agent framework per coordinare il ciclo di memoria.
- **Meta-Thinker** (async) guida Memory Manager (construction) e Query Reasoner (retrieval)
- **In-situ self-evolving**: sintetizza "probe QA pairs" per verificare memoria corrente, converte failure in repair
- Plug-and-play su storage backend esistenti

Copre:
1. Dual sleeper: **parziale (Y)** — Meta-Thinker vs Memory Manager è una separazione simile
6. Self-scope: **parziale (Y)** — probe QA + repair = self-monitoring della memoria
7. Recall-probe: **parziale (Y)** — le probe QA sono fail-safe interni

**Idea interessante per te**: le **probe QA pairs** come meccanismo di audit automatico. Potresti usarlo al posto (o oltre) del sampling settimanale: generare periodicamente domande-test dalla memoria stessa e vedere se il retrieval risponde correttamente. È audit *endogeno* (no user in the loop). Complementa il tuo `memory-audit` watcher.

### 2.2 ReasoningBank (arXiv 2509.25140, Google + UIUC, set 2025)
**Link**: https://arxiv.org/abs/2509.25140

**Score: 2 su 7**

Memoria di *strategie di ragionamento* distillate da esperienze self-judged successful/failed. Con memory-aware test-time scaling (MaTTS): +34.2% success, -16% step.

Copre:
6. Self-scope: **Y (forte)** — literalmente memoria di lesson da successi E fallimenti. Con reflection self-judged.

**Cosa ruberei**: il pattern "**failure-derived heuristics substantially outperform success-derived ones**" è controintuitivo e utile. Nel tuo Riflettore, dovresti *dare peso maggiore ai cluster con surprise alta* (già previsto) **e** ai cluster di turni falliti (agent_action che non ha prodotto outcome atteso). Plan-v2 § 2.3 menziona `surprise > 0.5 O ≥3 episodi consistenti` — varrebbe aggiungere `OR failed_outcomes ≥ 2` come trigger esplicito.

### 2.3 EVOLVE-MEM (OpenReview 2026)
**Link**: https://openreview.net/pdf?id=dfPQrg1WA5

**Score: 2 su 7**

Self-adaptive hierarchical memory. Closed-loop con **homeostatic latent regulator** — l'unico paper che ho trovato che usa letteralmente il termine "homeostatic" per il LLM agent memory management.

Copre:
5. LRS omeostatico: **Y (forte, semanticamente)** — "homeostatic latent regulator ensures stable and informative latent regime throughout lifecycle" + "structurally aware checkpoint-retention rule"
6. Self-scope: parziale

**Nota importante**: l'omeostasi qui è sulla *latent representation* del modello (livello pesi), non sul retrieval precision. Ma il pattern concettuale è lo stesso: **tenere una metrica in banda, non massimizzarla**. Se cito un paper per giustificare l'approccio LRS nel plan-v2, questo è il più vicino.

### 2.4 EVE / Variational Language Model — "homeostatic latent regulator"
Menzionato nella ricerca, stesso autore/gruppo di EVOLVE-MEM. Principio trasferibile.

### 2.5 GAM — Hierarchical Graph-based Agentic Memory (arXiv 2604.12285)
**Link**: https://arxiv.org/html/2604.12285v1

**Score: 2 su 7** (tangenziale)

Switching tra **buffering e consolidation** basato su topic boundaries. Decoupling storage in Topic Associative Network (globale) + Event Progression Graphs (locali).

Copre:
1. Dual sleeper: **parziale (Y)** — buffering ≠ consolidation, switch esplicito
4. Provenance: N (ma la struttura graph permetterebbe tag)

**Idea da rubare**: i **topic boundaries** come trigger di consolidation invece di (o in aggiunta a) cron 03:00. Se un chat cambia topic bruscamente, fare consolidation *subito*. Nel tuo caso tradurrebbe in: topic-shift detection → flush del buffer episodic T2 → mini-Riflettore su quel segmento. Aggiunge granularità al dual sleeper.

### 2.6 Collaborative Memory (arXiv 2505.18279) — già in findings
Menzionato per completezza: permission-aware + attribution-aware → copre parzialmente provenance. Non aggiunge su pushback/beliefs/recall-probe.

---

## Sezione 3 — Elementi singoli innovativi

### 3.1 Pushback / anti-sycophancy — nessun match architetturale completo
Ricerca specifica su "conflict_score" + "calibrated dissent" + "authority register" non ha prodotto implementazioni simili alla tua.

Ciò che ESISTE:
- **SYCOPHANCY.md** (sycophancy.md) — protocollo anti-sycophancy a livello prompt (citation requirements, challenge thresholds, disagreement protocols). **Nessun state store, solo regole di prompting**.
- **Stanford study mar 2026** — quantifica sycophancy: AI agree 49% più degli umani. Dimostra il problema, non lo risolve.
- **Paper Springer "Programmed to please"** (aprile 2026) — analisi etica, non tecnica.
- **WikiContradict / ConflictBank** — benchmark su knowledge conflicts *dentro i passaggi* forniti (source A vs source B nei RAG chunks). Diverso: tu gestisci conflitti tra *memoria interna* e *utente live*.

**Verdetto**: la tua combinazione `Attitude Ledger + conflict_score con 3 soglie + authority guard` sembra **inedita** come architettura integrata. Esistono le parti (store di opinioni con confidence, detection di sycophancy, knowledge conflicts), ma non l'orchestrazione deterministica pre-LLM con guard contestuale.

Da **USF study 2026**: "agents assigned lower confidence levels were more open to revising their beliefs, while those starting with higher confidence tended to be more persuasive". → Conferma empirica della tua formula: `confidence(b)` come fattore moltiplicativo del conflict_score è giusto.

### 3.2 Provenance obbligatoria API-level
- **guardrails-ai/provenance_llm** (GitHub) — validatore che verifica che il testo generato sia "supported by provided contexts". Output-side, non input-side. Diverso scope.
- **arXiv 2509.13978** (Oak Ridge Lab, "LLM Agents for Interactive Workflow Provenance") — architettura di riferimento per provenance di workflow scientifici. Tratta provenance come *dato persistito*, non come *precondizione di scrittura memoria*.
- **arXiv 2502.00706** (Model Provenance Testing) — verificare lineage di un modello, non di un fatto.

**Verdetto**: l'idea di un Zod schema che **rifiuta HTTP 400** se manca `source_type` non l'ho trovata scritta esplicitamente in nessun paper/progetto. È un'applicazione di principi di database (NOT NULL, check constraint) alla memoria agentica. **Originale nel dominio memoria LLM**, mutuato da engineering db tradizionale. Rivendicalo.

La tassonomia a 6 valori (`user_stated | user_lived | user_quoted_other | bot_inferred | bot_generated | external_doc`) è più granulare di tutto quello che ho visto. Mem0 ha tag generici. Graphiti ha `source_description` libero. Hindsight distingue solo per *tipo di rete*.

### 3.3 Dual sleeper puro (Stenografo + Riflettore)
Il match più vicino è **Dual-Trace Encoding** (arXiv 2604.12948, "Drawing on Memory: Dual-Trace Encoding Improves Cross-Session Recall in LLM Agents"). Ispirato al "drawing effect" cognitivo.
- Due tracce complementari per la stessa memoria: traccia testuale (verbale) + traccia strutturale (forma).
- **Diverso dal tuo**: sono due *rappresentazioni* della stessa memoria, non due *processi* (sync recorder vs async interpreter).

**AutoMemoryToolsAdvisor** (Spring AI, aprile 2026) — "dual-condition consolidation trigger" + "memoryConsolidationTrigger predicate". Tratta il "quando consolidare", non il "chi consolida". Un solo processo.

**Letta sleep-time compute** — un singolo sleeper async (coperto in findings).

**Verdetto**: la separazione **deterministico-append-only (zero LLM) + generativo-notturno (LLM)** come due canali distinti non l'ho trovata come pattern esplicito. Hindsight la ha *parzialmente* (observation async). La tua è più chirurgica:
- Stenografo = event sourcing / write-ahead log
- Riflettore = stream processing / materialized view

Questo è il pattern **"CQRS per la memoria agentica"** (Command Query Responsibility Segregation, classico pattern DB). Applicato al dominio memoria LLM: non l'ho trovato articolato.

### 3.4 Self-scope con surprise metric + prediction vs outcome
Match parziale:
- **Titans** (già in findings) ha surprise metric come gradient update signal, non come memory trigger.
- **ReasoningBank** ha success/failure judging, non `agent_prediction vs outcome_observed` turn-level con `surprise = |pred - outcome|`.
- **MR-Search** (arXiv 2603.11327) — meta-RL con self-reflection tra episodes. Gold.
- **MemMA** probe QA pairs.

**Verdetto parzialmente inedito**: la specifica formulazione "ogni turno l'agente registra (prediction, action, outcome, surprise) deterministicamente senza LLM, e un notturno cluster per situation_hash" è tua. I pezzi esistono (RL classico, MR-Search, Titans), ma l'applicazione **zero-LLM in-turn + LLM only nightly on clusters** è originale.

### 3.5 Recall-probe fail-safe (similarity < threshold → "non ricordo")
- **Semantic entropy** (Nature 2024, Farquhar et al.) — detection hallucination via entropia di significati.
- **Deepchecks / Maxim** — "Contextual Verification Cascade", multi-stage validation post-generation.
- **Hindsight Abstention** — tested as benchmark, non implementato come pre-retrieval gate.

**Verdetto**: la tua implementazione (`probe = similarity(current_context, claimed_memory); if probe < 0.72: recall_probe_ok = false`) è **standard similarity thresholding applicato come input-side gate**. Non ho trovato la stessa applicazione esatta (pre-citazione di memoria, non post-generazione). Semplice ma non banale.

### 3.6 LRS omeostatico con sampling utente
- **EVOLVE-MEM / EVE** hanno "homeostatic regulator" a livello latent.
- **Memory observability** (Braintrust, Patronus) traccia precision/recall come metriche, ma non c'è un closed-loop auto-tuning con user feedback.
- **Databricks blog "Memory Scaling for AI Agents"** discute retrieval_precision / retrieval_recall / context_utilization / memory_staleness come metriche da monitorare. Non propone auto-tune.

**Verdetto**: la combinazione `LRS formula esplicita + banda target (non max) + sampling settimanale user-in-loop + auto-tune soglie retrieval` **non l'ho trovata**. Il principio omeostatico esiste (EVE). Il sampling user-in-loop come calibration esiste (RLHF classico). La specifica applicazione a retrieval similarity threshold come control loop chiuso con utente è originale. 

---

## Sezione 4 — Verdetto originalità

### Cosa plan-v2 **ha già inventato altrove** (da non rivendicare come nuovo)
1. **Belief store separato con confidence** → Hindsight Opinion network, uscito dicembre 2025. **Non sei primo.** Cita Hindsight.
2. **Async consolidation durante idle** → Letta sleep-time compute, KAIROS leak, AutoMemoryTools. **Consolidato.**
3. **Memory tiers gerarchici con budget token** → MemGPT, Letta, claude-mem progressive disclosure. **Consolidato.**
4. **Entity graph + vector ibrido** → Cognee, Graphiti, MemMachine. **Consolidato.**
5. **Reflection / self-correction loop** → A-MEM, MemMA, ReasoningBank. **Consolidato.**

### Cosa sembra **genuinamente originale** nella combinazione di plan-v2
1. **Dual sleeper con separazione hard Stenografo/Riflettore** (CQRS applicato alla memoria LLM) — Hindsight è il più vicino ma ha un singolo pipeline async, non una write-path deterministic sync + read-model generative async. *Originale come pattern architetturale.*
2. **Provenance API-level enforcement con Zod + 6 source_types** — nessuno ha un reject HTTP 400 su memoria senza `source_type`. *Originale come rigore operativo.*
3. **Pushback user-facing con 3 soglie + authority guard** — Hindsight aggiorna beliefs silenziosamente. Protocolli anti-sycophancy esistono solo a livello prompt. *Originale come architettura state-based.*
4. **Self-scope episodes con (prediction, action, outcome, surprise) zero-LLM in-turn + clustering notturno** — ReasoningBank e MR-Search fanno judge post-hoc LLM-based. Tuo è deterministico sync. *Originale per efficienza.*
5. **LRS omeostatico con user-sampling calibration loop** — EVE ha omeostasi latent, nessuno ha user-in-loop su retrieval threshold. *Originale come control system.*
6. **Recall-probe come pre-gate input-side** — Hindsight Abstention lo testa come benchmark, non lo implementa come gate pre-retrieval. *Originale come collocazione.*

### La **gestalt** è l'elemento davvero nuovo
Nessun sistema combina **tutti e 7 gli elementi**. Hindsight ha 4/7 (ed è il più vicino). Il valore di plan-v2 non è nei singoli componenti (molti sono derivati), ma nella **composizione coerente**: provenance obbligatoria → alimenta beliefs con evidence → alimenta pushback → guardato da authority register → con self-scope che previene overconfidence → con recall-probe che previene hallucination → con LRS che previene rumore → con dual sleeper che previene drift.

Questa catena di dipendenze logiche, dove ogni componente chiude un failure mode dell'altro, non l'ho vista articolata altrove. Il plan-v2.md **come documento architetturale** è originale indipendentemente dall'implementazione.

### Pattern da rubare/adattare (concrete actions)
1. **Da Hindsight**: riorganizzare in 4 reti ortogonali (facts/experience/opinion/observation) invece dei T0-T6 lineari. Più pulito semanticamente.
2. **Da Hindsight**: adottare la formula `Assess -> {reinforce, weaken, contradict, neutral}` per gli update interni dei beliefs (accanto al conflict_score user-facing).
3. **Da MemMA**: aggiungere **probe QA pairs** generate endogenamente come audit aggiuntivo (oltre al sampling settimanale utente).
4. **Da ReasoningBank**: dare peso esplicito ai **failure-derived lessons** nel Riflettore (non solo surprise-driven).
5. **Da GAM**: aggiungere **topic-shift detection** come trigger aggiuntivo di consolidation (oltre al cron 03:00).
6. **Da SSGM**: mappare le mitigazioni di plan-v2 ai 3 failure point canonici (poisoning, drift, conflict) per giustificazione teorica.
7. **Da Stanford/USF sycophancy studies 2026**: cita empirica sugli effetti reali della sycophancy come *motivazione* del pushback mechanism nel plan.

### Rivendicazioni legittime da fare nel plan-v2
- "Primo sistema memoria agentica che applica **CQRS pattern** alla separazione scrittura/interpretazione"
- "Primo sistema con **provenance obbligatoria API-level** (HTTP 400 reject) nel dominio memoria LLM"
- "Primo sistema con **user-feedback closed-loop calibration** del retrieval threshold"
- "Primo sistema con **authority-gated pushback** state-based (non solo prompt-based)"

Queste frasi reggono il peso di un README o paper.

### Cosa **NON** rivendicare
- Belief store con confidence (Hindsight Dec 2025)
- Sleep-time compute (Letta, Anthropic)
- Entity graph + vector (Cognee, Graphiti)
- Self-reflection (A-MEM, ReasoningBank, MR-Search)

---

## Sezione 5 — Fonti

### Papers (cronologico)
- [Hindsight is 20/20 — arXiv 2512.12818](https://arxiv.org/abs/2512.12818) · dic 2025 · Vectorize.io + Virginia Tech
- [ReasoningBank — arXiv 2509.25140](https://arxiv.org/abs/2509.25140) · set 2025 · Google + UIUC
- [Memory for Autonomous LLM Agents Survey — arXiv 2603.07670](https://arxiv.org/html/2603.07670v1) · 2026
- [SSGM — arXiv 2603.11768](https://arxiv.org/abs/2603.11768) · mar 2026 · Jinan University
- [MemMA — arXiv 2603.18718](https://arxiv.org/abs/2603.18718) · mar 2026 · Penn State + Amazon
- [MR-Search — arXiv 2603.11327](https://arxiv.org/abs/2603.11327) · 2026
- [GAM — arXiv 2604.12285](https://arxiv.org/html/2604.12285v1) · 2026
- [Dual-Trace Encoding — arXiv 2604.12948](https://arxiv.org/abs/2604.12948) · 2026
- [EVOLVE-MEM — OpenReview](https://openreview.net/pdf?id=dfPQrg1WA5) · 2026 ICLR workshop
- [Multi-Layered Memory Architectures — arXiv 2603.29194](https://arxiv.org/abs/2603.29194) · 2026
- [WikiContradict — arXiv 2406.13805](https://arxiv.org/html/2406.13805v1) · NeurIPS 2024
- [Knowledge Conflicts Survey — arXiv 2403.08319](https://arxiv.org/html/2403.08319v1) · EMNLP 2024
- [Semantic Entropy Hallucination Detection — Nature 2024](https://www.nature.com/articles/s41586-024-07421-0)
- [Memory in the Age of AI Agents Survey — arXiv 2512.13564](https://arxiv.org/abs/2512.13564) · dic 2025
- [LLM Agents for Workflow Provenance — arXiv 2509.13978](https://arxiv.org/html/2509.13978v2) · SC'25
- [Metacognition Review for Safety — s-rsa.com 15271](https://s-rsa.com/index.php/agi/article/download/15271/11131)

### Progetti & Tooling
- [guardrails-ai/provenance_llm](https://github.com/guardrails-ai/provenance_llm) — validator output-side
- [ventr1c/memma](https://github.com/ventr1c/memma) — MemMA implementation
- [Agent Memory Paper List — Shichun-Liu](https://github.com/Shichun-Liu/Agent-Memory-Paper-List)
- [Spring AI AutoMemoryTools](https://spring.io/blog/2026/04/07/spring-ai-agentic-patterns-6-memory-tools/) · apr 2026
- [agentscope-ai/ReMe](https://github.com/agentscope-ai/ReMe)
- [aiming-lab/SimpleMem](https://github.com/aiming-lab/SimpleMem)

### Articoli / Coverage / Blog
- [VentureBeat — Hindsight 91% accuracy](https://venturebeat.com/data/with-91-accuracy-open-source-hindsight-agentic-memory-provides-20-20-vision)
- [Vectorize.io — Hindsight intro](https://vectorize.io/blog/introducing-hindsight-agent-memory-that-works-like-human-memory)
- [Stanford AI sycophancy study](https://www.techbuzz.ai/articles/stanford-study-exposes-ai-chatbot-sycophancy-risk) · mar 2026
- [Fortune — AI sycophancy 49%](https://fortune.com/2026/03/31/ai-tech-sycophantic-regulations-openai-chatgpt-gemini-claude-anthropic-american-politics/) · mar 2026
- [USF researchers mirror human reasoning](https://www.usf.edu/news/2026/usf-researchers-training-ai-to-mirror-human-reasoning.aspx) · 2026
- [SYCOPHANCY.md protocol](https://sycophancy.md/)
- [Mem0 State of AI Agent Memory 2026](https://mem0.ai/blog/state-of-ai-agent-memory-2026)
- [Braintrust — Agent Observability](https://www.braintrust.dev/articles/agent-observability-tracing-tool-calls-memory)
- [Databricks — Memory Scaling for AI Agents](https://www.databricks.com/blog/memory-scaling-ai-agents)
- [MarkTechPost — ReasoningBank](https://www.marktechpost.com/2025/10/01/google-ai-proposes-reasoningbank-a-strategy-level-i-agent-memory-framework-that-makes-llm-agents-self-evolve-at-test-time/)
- [Coding Nexus — Hindsight review](https://medium.com/coding-nexus/a-new-agent-memory-system-just-dropped-and-it-finally-fixes-what-weve-been-getting-wrong-fc84589f75ca)

---

## Caveats
- La ricerca ha coperto arXiv fino a aprile 2026, GitHub fino a marzo 2026, Medium/Substack. Non ho ispezionato Discord closed-source o paper dietro paywall non-open.
- Hindsight è appena uscito (Dec 2025): la community potrebbe produrre derivati/critiche nei prossimi mesi. Monitorare.
- Alcuni paper 2026 sono ancora in single-review / non formalmente pubblicati — trattarli come indicazioni di direzione, non di consolidamento.
- Non ho trovato una critica formale a Hindsight; il paper sembra pulito ma non ho verificato repro dei benchmark.
- Il termine "homeostatic" in LLM memory è raro: potrebbe esserci letteratura in neuroscienze computazionali (ACT-R, SAGE) che ho solo sfiorato in findings.md.

---

## Sezione 6 — Round v4/v4.2 (aprile 2026)

> Archeologia progetti emersa durante la stesura di plan-v4 e della critica Proposta-V4.2. Integrata qui per avere un'unica fonte di prior art. Alcuni progetti erano già citati in findings.md; qui sono riassunti con il taglio specifico di *cosa ci ha insegnato sul design v4*.

### 6.1 Pattern agent-kernel / filesystem-as-memory

#### Auto-Dream (Anthropic, interno)
- **Source**: feature flag `tengu_onyx_plover`, quiet rollout Claude Code v2.1.59+. Nessuna API pubblica, nessun paper.
- **Pattern**: 4 fasi sequenziali in un singolo job notturno — **Orient → Gather → Consolidate → Prune**.
- **Convenzione**: `MEMORY.md` come indice <200 righe + file di memoria atomici in cartelle semantiche (`notes/` append-only, `knowledge/` mutable).
- **Perché rileva per v4**: valida il pattern "single sleeper sequenziale" come alternativa al dual sleeper di v2. Trade-off: meno specializzato ma più robusto. Se copiamo il flag model di Anthropic guadagniamo compatibilità futura con Claude Code nativo.
- **Cosa rubato in v4.2**: la convenzione `MEMORY.md <200 righe` come indice e la separazione `notes/` vs `knowledge/` (adottata come Option D).

#### Agent Kernel (oguzbilgic, GitHub)
- **Link**: github.com/oguzbilgic/agent-kernel · 319 stars · **NO LICENSE → copiamo solo pattern, non codice**.
- **Pattern**: filesystem-as-memory minimal. `notes/` (append-only, cronologico, storia delle decisioni) + `knowledge/` (mutable, stato corrente dei fatti) + `MEMORY.md` come indice.
- **Perché rileva**: semantica esplicita delle contraddizioni — una nota vecchia in `notes/` può essere superseded da un fatto nuovo in `knowledge/` senza dover riscrivere la storia. È l'equivalente git-style della distinzione event-sourcing vs materialized view del dual sleeper.
- **Status legale**: no license ⇒ no copia di codice, pattern design libero da riutilizzare.

### 6.2 Pattern proattività / mission mode

#### QwenPaw Mission Mode v1.1.2
- **Pattern**: comando `/mission` multi-phase con stato persistente. L'agente entra in un modo operativo dove sa che sta eseguendo un task lungo, traccia stato, e può essere ripreso.
- **Perché rileva**: template concreto per la proattività *task-oriented* (non "reminder"). Se Harness deve proporre proattivamente "continuiamo quel task" deve avere un concetto analogo di mission state.

#### Google CC "Your Day Ahead"
- **Pattern**: briefing mattutino generato automaticamente con priorità del giorno, context dal giorno precedente, suggerimenti di focus.
- **Perché rileva**: UX model per la proattività temporale (non reattiva). Validazione che utenti accettano bene i briefing se consegnati a orari prevedibili e con formato stabile.
- **Trade-off**: trigger time-based è meno intrusivo che trigger event-based ma rischia di essere rumore se il modello del giorno è troppo generico.

#### InterruptBench (arXiv 2604.00892)
- **Pattern**: benchmark su 3 classi di interruzione durante task long-running:
  - **Addition** (utente aggiunge un requisito nuovo)
  - **Revision** (utente cambia un requisito esistente)
  - **Retraction** (utente ritira un requisito precedente)
- **Perché rileva per v4.2**: la proattività di Harness emette messaggi *mentre* l'utente potrebbe essere in mezzo ad altro. La tassonomia interruption serve a pensare come Harness *riceve* interruzioni (utente cambia idea mid-task) e come Harness *emette* interruzioni proattive senza essere tossico.
- **Applicazione**: se il classifier Haiku del Gap 1 rileva una retraction (pattern "no, in realtà non quello"), il comportamento corretto è tombstone immediato, non confirm. La tassonomia dà un linguaggio preciso per le 3 soglie del correction detector.

### 6.3 Architetture agent multi-ruolo

#### OpenJarvis (Stanford)
- **Pattern**: Orchestrator + Operative, local-first. L'Orchestrator pianifica e coordina, l'Operative esegue con tool narrow. Entrambi girano locali.
- **Perché rileva**: precedente accademico della filosofia local-first di Harness. Valida l'idea che la separazione di ruoli può essere *fisica* (processi distinti) e non solo logica (prompt diversi).
- **Differenza con v4**: Harness è single-agent con sleeper notturno, non multi-agent online. Ma se un giorno si scalasse a "Claude risponde su Telegram + watcher autonomi", il modello Orchestrator/Operative sarebbe il riferimento.

#### Hermes Agent v0.8.0 (NousResearch)
- **Claim iniziale**: "ha skill distillation".
- **Verifica**: ispezione repo → **NO skill distillation** nel codice pubblico. Claim era una hallucination.
- **Perché rileva**: memento operativo. Prima di citare feature di un progetto in un piano, ispezionare il repo. Nel contesto v4 la skill distillation è tua (da progettare), non ereditata.

### 6.4 Compression / memory-of-loci

#### MemPalace (5 aprile 2026)
- **Pattern**: method-of-loci applicato alla memoria LLM. Gli episodi sono ancorati a "stanze" virtuali con associazioni spaziali, non a timestamp puri.
- **Claim benchmark**: compressione **AAAK 30×** (Average Answer Accuracy per Kilobyte) rispetto a baseline flat summary.
- **Perché rileva per v4**: suggerisce che l'embedding da solo non è sufficiente per compressione aggressiva — associazioni strutturate (spaziali, causali, sociali) migliorano il recall a parità di token.
- **Adozione in v4**: nessuna diretta (overhead troppo alto per single-user), ma idea in reserve per un eventuale `T5.5 associative_anchors` futuro.

### 6.5 Correction / update operators

#### Mem0 (Apache-2.0)
- **Pattern**: 4 operatori espliciti ADD / UPDATE / DELETE / NONE decisi via prompt LLM prima di toccare lo store.
- **Perché rileva per v4.2 Gap 1**: template standard per la *correzione inline*. Il classifier Haiku del Gap 1 emette fondamentalmente uno di questi 4 verdetti. Mem0 però delega *tutto* all'LLM (più costoso, più rumoroso), mentre v4.2 introduce le doppie soglie confidence + embedding similarity come filtro pre-LLM.
- **Trade-off**: Mem0 è più semplice, v4.2 è più difensivo. Il prezzo della semplicità Mem0 è che un LLM sbaglia talvolta a distinguere "aggiorna quel fatto" da "crea un nuovo fatto".

#### Cognee
- **Claim**: entity graph + correction loop.
- **Verifica**: **no correction detector esplicito**. Come quasi tutti gli altri (Letta, Mem0, Zep) non ha un meccanismo che *riconosce* quando l'utente sta correggendo un fatto memorizzato vs aggiungendone uno nuovo. La correzione è implicita nell'update LLM.
- **Perché rileva**: conferma che il **correction detector del Gap 1** (classifier dedicato con trigger pattern-match) **è originale nel panorama open**. Nessuno lo ha come componente isolato.

### 6.6 Stack storage — scartati e adottati

| Tecnologia | Status | Motivo |
|------------|--------|--------|
| **sqlite-vec v0.1.9** (31 mar 2026) | ✅ adottato per opzione B | Pure C, brute-force, limite realistico ~hundred thousands vectors — sufficiente single-user. Zero dipendenze native, no binding hell su Windows. |
| **SurrealDB** (@surrealdb/node) | ❌ scartato | Node binding ancora **ALPHA**. Troppo rischioso per Windows single-user. |
| **CozoDB** | ❌ scartato | Progetto **borderline morto**, ultima release inattiva. |
| **LanceDB** | ❌ scartato | **Windows binding issues** persistenti (GH #630, #939). Pain noto. |
| **ChromaDB** | ⚠️ valido ma oversized | Funziona su Windows, ma richiede server separato. Per single-user `sqlite-vec` è più leggero. |

### 6.7 Stack embedding — evaluated

| Tecnologia | Status | Note |
|------------|--------|------|
| **BGE-M3** (locale) | ✅ opzione A | int8 ONNX ~2× speed, MTEB ~63.0. Zero API cost, zero dati in uscita. |
| **Voyage 3.5** (API) | ✅ opzione B (raccomandata) | $0.06/1M token (~$0.60/anno realistico), **Anthropic recommended partner**, politica **no-training / no-retention**. MTEB +9% su BGE-M3. |
| **@huggingface/transformers v4** | ⚠️ fallback | Se Voyage irraggiungibile, fallback locale BGE-M3 via transformers.js. |

### 6.8 Library utility

- **proper-lockfile** (1.7M download/settimana) — scelto per file locking cross-platform. Windows non ha `flock` nativo, Node `fs.promises` non copre il caso multi-process. Richiesto dall'opzione A del Punto 4 (4-job sleeper con lockfile) per transazioni atomiche tra job.

---

## Sezione 7 — Sintesi prior art rilevante per v4.2

Per ciascuna scelta di design v4.2 aperta, il precedente più prossimo:

- **Stack storage** → sqlite-vec (Voyage API) = opzione pragmatica. No prior art che contesti questa scelta single-user.
- **Filesystem memory** → Auto-Dream + Agent Kernel convergono sulla stessa convenzione `MEMORY.md <200 righe` + `notes/` / `knowledge/`. Adozione consigliata.
- **Sleep-time jobs** → Letta (singolo sleeper), Auto-Dream (4 fasi sequenziali un job), v4.2 opzione A (4 job paralleli con lockfile). Nessun precedente esatto per 4 job paralleli isolati.
- **Correction inline (Gap 1)** → Mem0 4 operatori via LLM puro. v4.2 aggiunge doppie soglie + embedding check pre-LLM. Nessun precedente per correction detector *isolato*.
- **Replay harness (Gap 2)** → nessun prior art stringente. Decisione ortogonale a tutti i progetti citati.
- **/memory doctor (Gap 3)** → ispirazione generica da lint tools (markdownlint) e da MemMA probe-QA. Nessun precedente per audit semantico cross-file su filesystem memory LLM.
- **Proattività** → Google "Your Day Ahead" (time-based) + InterruptBench (emission-side sensibilità). v4.2 opzione C (shadow mode 7gg) non ha prior art diretto — è un metodo di calibrazione empirica prima dell'attivazione.
