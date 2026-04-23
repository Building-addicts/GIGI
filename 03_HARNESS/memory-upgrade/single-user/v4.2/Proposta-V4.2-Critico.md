# Proposta V4.2 Critico

**Data:** 2026-04-21
**Stato:** Proposta post-critica, in discussione
**Base:** plan-v4.md (v4.1) + feedback critico + agenti ricerca SQLite/Gap/Auto-Dream
**Autore:** sessione critica v4.1 → v4.2

---

## 0 · Scopo del documento

Questo file preserva il set completo di modifiche proposte dal **critico** al plan-v4.1, insieme alle **decisioni prese dall'utente** punto per punto e agli **approfondimenti tecnici** richiesti. Serve da:

1. Riferimento storico: se in futuro vogliamo confrontare v4.2 con plan v1/v2/v3/v4 per capire l'evoluzione del ragionamento.
2. Fonte di verità: se tra 6 mesi qualcuno chiederà "perché NON abbiamo fatto X?", questa risposta è qui.
3. Archeologia: include il confronto con tutti i progetti analizzati (Letta, Mem0, Zep, Hermes, Auto-Dream, Agent Kernel, MemPalace, QwenPaw, ecc.).

---

## 1 · Le 5 debolezze del critico (con decisione utente)

### 1.1 Punto 1 — Stack tecnico troppo ambizioso

**Critica:** v4.1 sceglieva SurrealDB embedded (alpha binding Node.js) + BGE-M3 locale via Transformers.js + sqlite-vec come fallback. Tre sistemi, ognuno con friction Windows, setup realistico 1-2 giorni, native binding hell.

**Opzioni proposte:**
- A. SurrealDB + BGE-M3 locale (fedele a local-first, setup lento)
- B. sqlite-vec + Voyage 3.5 API (setup 1h, $0.60/anno, MTEB +9%)
- C. Ibrido con migrazione futura a locale

**DECISIONE UTENTE:** approfondimento richiesto. Spiegazione fornita:
- vector search = ricerca per significato (embedding trasforma testo→vettore, due testi simili hanno vettori simili)
- graph DB = ricerca per relazioni tra entità
- sqlite-vec v0.1.9 (31 Mar 2026): pure C, brute-force, limite pratico ~hundred thousands vectors, nessuna native binding
- Voyage 3.5: $0.06/1M input tokens, Anthropic recommended partner, no-training/no-retention per policy
- BGE-M3: supporta dense+sparse+multivector, MTEB ~63.0, va bene ma 9% sotto Voyage per retrieval

**Raccomandazione finale:** Opzione B (sqlite-vec + Voyage 3.5). Local-first filosofia mantenuta: logic, memoria, dati sono locali. Solo embedding generation via API. Migrazione a locale sempre possibile in futuro.

**Stato:** In attesa voto finale utente dopo approfondimento.

---

### 1.2 Punto 2 — Effort stimato fake

**Critica:** v4.1 stimava 19.75h + 2h spike. Stima finta: esclude debug, Windows friction, test, rewrites. Solo i 3 gap (correzione, replay, doctor) sono 22-28h reali. Stima realistica totale 50-70h.

**Opzioni proposte:**
- Scenario MINIMO: solo Gap 1 critico, 22-27h totali
- Scenario MEDIO: Gap 1 + doctor ridotto, 24-30h totali
- Scenario COMPLETO: tutti e 3 i gap, 34-43h totali

**DECISIONE UTENTE:** "Se dividiamo il piano in modo corretto e riusciamo ad andare in profondità e approfondire tutto nella roadmap da seguire e le task dettagliate per ogni pezzo della roadmap, allora possiamo fare in modo di elaborare tutto quando vogliamo, quindi non andiamo a preoccuparci dell'effort necessario."

**Implementazione:** plan-v4.2 userà tempi onesti (no underestimation), organizzato in fasi indipendenti deployabili, ciascuna deliverable value-delivering da sola. Nessun budget rigido.

**Stato:** APPROVATO.

---

### 1.3 Punto 3 — Classificazione dataset troppo complessa

**Critica:** frontmatter esteso con `domains[]`, `task_type`, `quality_tier`, `training_use`, `language`, `success_count` + T5.7 auto-classification via Haiku = over-engineering preventivo. Classifichi ogni ricordo PRIMA di sapere se farai mai fine-tuning. Overhead Haiku per ogni episodio.

**Opzioni proposte:**
- A. Tieni tutto come ora
- B. Frontmatter minimale + classifier on-demand all'export
- C. Skip totale, accumula raw, classifica una-tantum se/quando fine-tuning
- D. Tag automatico leggero (lingua, top-3 domini, success_bool)

**DECISIONE UTENTE:** "Son d'accordo totalmente con il critico, skippiamo totalmente e poi faremo export se mai servirà, quindi eliminiamo totalmente l'over engineering."

**Implementazione:** eliminata T5.7, rimosso frontmatter esteso. Tenuto solo: `tags`, `lang`. Se fine-tuning servirà in futuro, un classifier Opus one-shot in 20 min farà l'export classificato.

**Stato:** DECISO — skip totale.

---

### 1.4 Punto 4 — Sleep-time agent con 6 job simultanei

**Critica:** 6 job (consolidate, graph-sync, pattern-detect, skill-promote, lesson-harvest, auto-classification) che modificano stessi file .md su Windows = race condition garantite. Debug incubo. Ridurre scope o aggiungere lock stringente.

**Opzioni proposte:**
- A. Tieni 6 con lock file + sequenziali
- B. Riduci a 3 core (consolidate, pattern-detect, skill-promote)
- C. Riduci a 2 core + tutto il resto on-demand
- D. 1 solo job "think" con fasi adattive (Auto-Dream style)

**DECISIONE UTENTE:** Punto 3 eliminato automaticamente → restano 4 job. Utente ha espresso **preferenza iniziale** per opzione A ("mi interessa molto... mi sembra la più solida") MA ha esplicitamente chiesto approfondimento prima di decidere. Domanda esplicita: "C'entra qualcosa Auto-Dream di Anthropic?" + "La nostra soluzione è più interessante e robusta di Auto-Dream oppure no?"

**Risposta fornita:**
- Auto-Dream = sleep-time agent nativo Anthropic (feature flag `tengu_onyx_plover`), 1 job con 4 fasi interne sequenziali (Orient/Gather/Consolidate/Prune&Index)
- Auto-Dream più robusto su affidabilità grezza (no race, manutenzione Anthropic)
- Nostra opzione A più robusta su specializzazione (pattern-detect sa il nostro dominio Telegram+watchers)
- Auto-Dream è quiet rollout senza API pubblica → non integrabile direttamente
- **Soluzione raccomandata:** opzione A con `proper-lockfile` npm + pattern Auto-Dream come linea guida interna (ogni job completa in transazione atomica, no stato intermedio leggibile)

**Stato:** IN ATTESA VOTO FINALE UTENTE. Preferenza iniziale verso A, raccomandazione mia A con safeguard, ma utente non ha ancora confermato definitivamente dopo l'approfondimento.

---

### 1.5 Punto 5 — Proattività fase 7 con confidence gate arbitrario

**Critica:** threshold 0.7 arbitrario, nessun calibration loop, rischio alert fatigue, nessun feedback.

**Opzioni proposte:**
- A. Confidence gate + quiet hours + cap (v4.1 attuale)
- B. Feedback tracker con auto-calibrazione threshold
- C. Shadow mode 2 settimane + attivazione
- D. Skip proattività in v1, aggiungi in v2

**DECISIONE UTENTE:** "Non so scegliere, vorrei ragionare insieme a te."

**Trade-off analizzati:**
- A = subito visibile ma thresholds arbitrari, rischio alert fatigue primi giorni
- B = si auto-regola nel tempo, costo +2-3h codice
- C = calibrazione su dati reali, ma periodo senza proattività
- D = massima solidità v1, proattività rimandata

**Raccomandazione mia (coerente con messaggio originale):** Opzione C — shadow mode. Unica che calibra su dati reali senza rischio alert fatigue iniziale. Semplice, no combinazioni artefatte.

**Stato:** IN ATTESA VOTO UTENTE.

---

## 2 · I 3 GAP (approfonditi con decisioni)

### 2.1 Gap 1 — Correzione inline "no, sbagliato, è X"

**Cosa fa:** rileva correzioni in real-time, localizza ricordo errato, UPDATE + append a `lessons.md`.

**Novità tecnica:** nessun sistema esistente (Letta, Mem0, Zep, Cognee) ha correction detector esplicito. Tutti fanno consolidation passiva o importance scoring.

**Design:**
- Hybrid detector: regex gate (pattern "no, sbagliato, in realtà") + Haiku classifier
- Soglie: <0.6 ignora, 0.6-0.85 conferma esplicita, >0.85 auto-apply
- Locator: ultimo assistant message + retrieval log
- Ops: UPDATE/DELETE/ADD sempre + append lessons.md
- Safeguard anti miss-spelling (domanda utente esplicita):
  1. Doppia soglia confidence
  2. Embedding similarity check (cosine >0.8 = stesso concetto)
  3. Undo window 24h con tombstone
  4. Change log trasparente Telegram ("ho aggiornato X da Y a Z")
  5. Required acknowledgment pattern (solo trigger espliciti)
  6. Rationale logging (Haiku spiega perché ha pensato sia correzione)

**Effort:** 10-12h.

**DECISIONE UTENTE:** "Super interessante, approvo." + richiesta safeguard anti-miss-spelling soddisfatta.

**Stato:** APPROVATO con tutti e 6 i safeguard.

---

### 2.2 Gap 2 — Replay-retrieval harness

**Cosa fa:** tool per rilanciare log storici di query con config nuova vs vecchia, misurare A/B su retrieval. "Ottimizzare retrieval" = cambiare top_k, embedding model, reranker, hybrid weights, temporal window per vedere quale trova ricordi più rilevanti.

**Utilità senza fine-tuning:** calibrare retrieval dopo 2 mesi di uso quando sospetti degrado. Evita "mi sembra che..." a vantaggio di numeri.

**Design:**
- Schema JSONL con `memory_snapshot_hash` + tarball zstd in `logs/snapshots/` per fairness temporale
- Metriche no-GT: Jaccard overlap, Haiku-as-judge pairwise, citation faithfulness, self-consistency
- Reference: RAG-evaluation-harnesses GitHub

**Effort:** 6-8h.

**DECISIONE UTENTE:** "molto interessante questo, è utile anche all'inizio se non uso fine tuning?" + "cosa si intende per ottimizzare il retrieval?" → richiesta di chiarimenti, NON approvazione esplicita. Spiegazione fornita: sì utile anche senza fine-tuning (per calibrare retrieval — top_k, embedding model, reranker, window temporale).

**Raccomandazione mia (coerente con messaggio originale):** skip in v1. Utile ma non essenziale. Aggiunto dopo quando ci saranno 2 mesi di dati reali da calibrare.

**Stato:** IN ATTESA VOTO UTENTE dopo approfondimento.

---

### 2.3 Gap 3 — /memory doctor health check

**Cosa fa:** comando che restituisce report severity-ranked di problemi memoria con auto-fix.

**12 check deterministici:**
1. Frontmatter valido
2. Link interni non rotti
3. File orfani >60 giorni
4. Skill con tool mancanti
5. Supersede cycles
6. Type coerente con contenuto
7. MEMORY.md entry-point validi
8. Duplicazioni path
9. File >500 righe
10. Tombstone scaduti non puliti
11. Lock file orfani
12. Snapshot hash mismatch

**3 check semantici (Haiku):**
1. Contraddizioni cross-file
2. Duplicati semantici (cosine)
3. Fatti stantii

**Effort:** 6-8h.

**DECISIONE UTENTE:** "Approvo."

**Stato:** APPROVATO.

---

## 3 · Auto-Dream + Agent Kernel (Parte 3)

### 3.1 Auto-Dream di Anthropic

**Cosa è:** feature quiet-rollout Claude Code v2.1.59+ (Marzo 2026). Feature flag server-side `tengu_onyx_plover`. 4 fasi: Orient / Gather Signal / Consolidate / Prune&Index. Trigger: 24h + 5 sessioni. Limite MEMORY.md <200 righe (indice, non storage). Files in `~/.claude/projects/<project>/memory/`. Read-only su codice, lockfile anti-concorrenza. No GA timeline. Replica open-source: `grandamenium/dream-skill` via Stop hook.

### 3.2 Agent Kernel di oguzbilgic

**Cosa è:** repo GitHub 319 stars, **NO LICENSE file** (verified via `gh api`). Struttura: AGENTS.md + IDENTITY.md + KNOWLEDGE.md + `notes/` (append-only, storia immutabile) + `knowledge/` (mutable, stato corrente con header `Updated: YYYY-MM-DD`).

**Pattern chiave:** contraddizioni risolte per autorità temporale — knowledge=verità corrente, notes=storia. Se contraddizione, knowledge vince, notes resta tracciabile.

### 3.3 Trade-off adozione (Option D ibrido)

**In MEGLIO:**
1. Semantica esplicita contraddizioni (notes vs knowledge)
2. Pattern 4 fasi più pulito di 4 job paralleli
3. Compatibilità futura con Claude Code nativo quando Auto-Dream → GA
4. MEMORY.md come index rigoroso <200 righe

**In PEGGIO:**
1. Rigidità nello schema note/knowledge
2. Migration 2-3h di refactoring piano
3. NO LICENSE = solo pattern copiabili, non codice
4. Auto-Dream quiet rollout = no API pubblica

**DECISIONE UTENTE:** richiesta approfondimento. Spiegazione fornita. In attesa voto finale.

**Raccomandazione agente ricerca:** adottare Option D ibrido (struttura Kernel + processo Auto-Dream). Costo 2-3h refactoring piano (no codice). Guadagno semantico reale.

---

## 4 · Archeologia del codice — sistemi confrontati

Tutti i sistemi seguenti sono stati analizzati da agenti di ricerca nelle round 1-4 per validare approcci, rubare pattern, verificare claims.

### 4.1 Letta (ex-MemGPT) — arXiv 2504.13171

**Stato:** production, Apache-2.0, docs.letta.com
**Cosa fa:** sleep-time agents nativi con `enable_sleeptime: true`. Gira ogni N step durante idle, consolida memoria, anticipa query.
**Cosa abbiamo rubato:** pattern canonico sleep-time agent, concetto di memoria consolidation durante idle.
**Correzione attribuzione:** inizialmente Claude aveva attribuito il paper ad Anthropic Marzo 2026. Verificato via ricerca: è Letta+Berkeley Aprile 2025. Corretto nel plan.
**Differenza da v4:** Letta è cloud-first (server centralizzato). Noi local-first single-user.

### 4.2 Mem0 — Apache-2.0

**Cosa fa:** memoria personale con 4 operatori ADD/UPDATE/DELETE/NONE tramite prompt LLM.
**Cosa abbiamo rubato:** pattern 4 operatori semantici per gestione ricordi. Applicato in Gap 1 correction detector.
**Limite noto (HN thread Feb 2026):** Mem0 NON infers behavioral patterns, solo store fatti espliciti. v4 fa entrambi.

### 4.3 Zep / Graphiti — Apache-2.0

**Cosa fa:** temporal reasoning con bi-temporal knowledge graph (valid_at / invalid_at). Prompt `extract_edges` e `dedupe_edges`.
**Cosa abbiamo rubato:** concetto di validity windows per fatti (when-true vs when-recorded). Usato per gestione storia contradictions in plan v4.2.
**Differenza:** Zep cloud-based, noi embedded SQLite.

### 4.4 Hermes Agent v0.8.0 (NousResearch, Apr 2026)

**Cosa pensavamo facesse:** self-evaluation checkpoint ogni 15 tool calls con skill distillation pattern N≥5.
**Verifica code-archaeology (agent):** repo analizzato, **NESSUNA skill distillation documentata nel codice**. Self-evaluation esiste ma è introspective, non genera skills riutilizzabili automaticamente.
**Correzione:** claim hallucinato iniziale corretto. v4 ha skill-promote vero, Hermes no.
**Cosa abbiamo rubato:** concetto di self-evaluation checkpoint periodico (usato in sleep-time lesson-harvest).

### 4.5 QwenPaw Mission Mode v1.1.2 (Apr 17 2026)

**Cosa fa:** `/mission` comando autonomous multi-phase con `/mission status/list`. Scheduled memory consolidation.
**Cosa abbiamo rubato:** pattern comando multi-phase con visibilità di stato (applicato a comandi Telegram v4).

### 4.6 Google CC "Your Day Ahead" (Dec 2025)

**Cosa fa:** briefing mattutino senza prompt, integra Gmail/Calendar/Drive.
**Cosa abbiamo rubato:** concetto di briefing mattutino (`briefings/` folder in v4).
**Differenza:** prodotto commerciale multi-integration, noi single-file briefing Telegram.

### 4.7 InterruptBench — arXiv 2604.00892 (Apr 2026)

**Cosa fa:** benchmark interruzioni mid-task (addition/revision/retraction) su web navigation.
**Rilevanza:** inspira il design del proactive interruption etiquette (quando interrompere utente).
**Cosa abbiamo rubato:** 3 tipi di interruzione categorization per proactive system.

### 4.8 OpenJarvis (Stanford, Mar 2026)

**Cosa fa:** Orchestrator+Operative architecture per recurring personal workflows. Contextual reminders su schedule/location/patterns. Local-first.
**Rilevanza:** validation che pattern "agente proattivo personale local-first" è già fattibile. Stanford-grade.
**Cosa abbiamo rubato:** contextual reminder triggers basati su pattern temporali (v4 pattern-detect job).

### 4.9 MemPalace (5 Apr 2026)

**Cosa fa:** method-of-loci per organizzare memoria LLM. Compressione AAAK 30x.
**Rilevanza:** pattern simile al nostro ma con metafora spaziale. Validazione del fatto che "organizzare memoria in strutture semantiche aiuta retrieval".
**Cosa NON abbiamo rubato:** la metafora spaziale è over-engineered per single-user.

### 4.10 SSGM (arXiv 2603.11768)

**Cosa fa:** governance concettuale memoria, 3-4/7 caratteristiche plan-v2.
**Stato:** solo teorico, no implementation.
**Rilevanza:** taxonomy 3 failure points applicata in /memory doctor design.

### 4.11 Hindsight (arXiv 2512.12818, Dec 2025)

**Cosa fa:** 4 reti ortogonali (World/Experience/Opinion/Observation). Opinion ≈ Attitude Ledger. Abstention testato.
**Match più forte:** 4/7 caratteristiche plan-v2.
**Cosa abbiamo rubato:** pattern 4-networks ortogonali (mappato a notes/knowledge/identity/tacit).

### 4.12 Auto-Dream (Anthropic, quiet rollout v2.1.59+ Mar 2026)

**Cosa fa:** 4 fasi Orient/Gather/Consolidate/Prune. Feature flag `tengu_onyx_plover`. MEMORY.md <200 righe.
**Rilevanza:** Anthropic sta costruendo nativamente ciò che pianifichiamo.
**Cosa abbiamo rubato/stiamo rubando (Option D):** pattern 4 fasi, MEMORY.md come indice, read-only su codice, lockfile.

### 4.13 Agent Kernel (oguzbilgic, 319 stars NO LICENSE)

**Cosa fa:** notes/ append-only + knowledge/ mutable con header Updated.
**Rilevanza:** schema filesystem ideale per contraddizioni temporali.
**Cosa abbiamo rubato (Option D):** struttura notes vs knowledge. NO codice per licenza assente.

### 4.14 MemMA, ReasoningBank, EVOLVE-MEM, GAM, Dual-Trace Encoding, MR-Search

**Match parziali:** 2-3 caratteristiche plan-v2 ciascuno.
**Cosa abbiamo rubato:** MemMA probe QA pairs (per /memory doctor semantic check). ReasoningBank failure-weighting (per lesson-harvest). GAM topic-shift trigger (per conversation-boundary detection).

### 4.15 Cognee

**Cosa fa:** graph + vector memoria LLM.
**Rilevanza:** verificato durante analisi, anch'esso senza correction detector esplicito.

### 4.16 SurrealDB (DB multi-modello)

**Stato:** Node.js binding @surrealdb/node ALPHA.
**Verdetto:** scartato per v4.2 a favore di sqlite-vec + Voyage.

### 4.17 CozoDB

**Stato:** DEPRECATO (come Kuzu).
**Verdetto:** scartato.

### 4.18 LanceDB

**Stato:** Node binding con issues #630, #939 su Windows.
**Verdetto:** scartato come primary.

### 4.19 ChromaDB embedded

**Stato:** Node.js client, SQLite-like embedded mode disponibile.
**Verdetto:** alternativa valida a sqlite-vec ma sqlite-vec è più leggero e zero-dep.

### 4.20 sqlite-vec

**Stato:** v0.1.9 (31 Mar 2026). Pure C extension. Brute-force only (no HNSW ancora). Performance: 67ms full-scan su 100K×384 float32, ~17ms con int8 quant, ~4ms con preload. Limite pratico: "hundreds of thousands" vectors.
**Verdetto:** scelto come backend primary per v4.2.

### 4.21 BGE-M3

**Cosa fa:** embedding model 1024-dim. Dense + sparse + multi-vector in un modello. MTEB ~63.0.
**Int8 ONNX:** 2x speed vs fp32, quality loss trascurabile. Works in @huggingface/transformers v4.
**Verdetto:** scelto come fallback offline. Voyage 3.5 primary.

### 4.22 Voyage 3.5

**Cosa fa:** embedding API $0.06/1M input tokens. 2000 RPM / 8M TPM tier 1. Anthropic recommended partner (Anthropic non ha embeddings propri).
**Verdetto:** scelto come primary per v4.2.

### 4.23 grandamenium/dream-skill

**Cosa fa:** replica open-source di Auto-Dream via Stop hook Claude Code.
**Rilevanza:** riferimento implementativo se volessimo replicare Auto-Dream in modo indipendente.

---

## 5 · Librerie runtime scelte

- **proper-lockfile** (npm): 1.7M download/settimana, gestisce Windows file locking correttamente. `flock` non nativo su Windows.
- **@huggingface/transformers** v4: se si volesse embedding locale fallback.
- **sqlite-vec** v0.1.9 extension.
- **Voyage AI Node SDK** per embedding API.
- **zstd** (via node-zstd o tar + zstd CLI): compressione snapshot replay harness.

---

## 6 · Confronto v4.2 vs piani precedenti

### v1 (plan.md)
- Approccio naive: un solo file memory.md con riassunto AI
- Decision: insufficiente, no retrieval semantico, no strutturazione

### v2 (plan-v2.md)
- 7 caratteristiche distintive (dual sleeper, Attitude Ledger, pushback conflict_score, provenance API-level, LRS omeostatico, self-scope, recall-probe)
- Decision: troppo ambizioso, nessun sistema esistente lo fa tutto, ma singoli pattern ottimi

### v3 (plan-v3.md)
- Pragmatic sopra v2: Anthropic Memory Tool + SKILL.md format + sleep-time
- Decision: buono ma cloud-first framing, trending GitHub non valutati

### v4 / v4.1 (plan-v4.md)
- 7-layer architecture (L0→L7), SurrealDB + BGE-M3 locale, 6 job sleep-time, dataset readiness
- Decision: local-first corretto, ma stack troppo ambizioso, effort sottostimato, over-engineering dataset

### v4.2 (proposta corrente)
- sqlite-vec + Voyage 3.5 (B), 4 job sleep-time con lockfile (A), dataset skip, Gap 1 approvato con safeguard, Gap 2 split logging+tool, Gap 3 approvato, Option D Kernel+Auto-Dream
- Effort onesto, fasi indipendenti, scenarios selezionabili

---

## 7 · Prossimi passi post-voto

Una volta che l'utente avrà dato i voti finali su:
- Punto 1 stack (raccomandazione mia: B)
- Punto 4 sleep-time (preferenza iniziale utente: A, da confermare dopo approfondimento)
- Punto 5 proattività (raccomandazione mia: C shadow mode)
- Gap 2 replay (raccomandazione mia: skip in v1)
- Option D Auto-Dream+Kernel adozione (raccomandazione mia: sì)

Scriveremo **plan-v4.2.md** definitivo con:
1. Architettura aggiornata (stack, filesystem notes/knowledge)
2. Roadmap fasi indipendenti con effort onesti
3. Task dettagliate per ogni fase
4. Acceptance criteria per ogni task
5. Safeguard Gap 1 integrati
6. Schema logging Gap 2 (tool replay rimandato)
7. Doctor Gap 3 design completo

---

## 8 · Cose salvate per memoria futura

- **Mai attribuire paper senza verifica**: incidente Letta→Anthropic. Sempre verificare autori/istituzione.
- **Local-first non significa "zero API"**: significa "dati e logica local, API solo come trasformazione stateless"
- **Formato Telegram**: niente tabelle markdown, utente non le legge. Usare liste indentate con frecce.
- **NO LICENSE repo**: copia solo pattern/struttura, mai codice letterale.
- **Windows file locking**: sempre `proper-lockfile`, mai `flock`.
- **Critic role utile**: v4.1 stava per andare in esecuzione con effort fake. Critic ha salvato 30h di lavoro sprecato.

---

**Fine documento.**
