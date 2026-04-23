# Plan v4 — Memoria Cosciente Proattiva SOTA

**Data**: 2026-04-20
**Versione**: 4.1 (supersede v3 — aggiornato con dataset-readiness, confronti SOTA, analisi fine-tuning)
**Effort stimato**: 19.75h implementazione + 2h spike preliminare (Fase 10 opzionale +2h futura)
**Posizionamento**: State-of-the-art 2026 per agente personale single-user, local-first, **dataset-ready per fine-tuning futuro**

---

## 0. Scopo e filosofia

### 0.1 Visione

Costruire un sistema di memoria che trasformi Telegram in **interfaccia universale a Claude per qualsiasi task**, con l'agente che diventa progressivamente più intelligente, proattivo e utile nel tempo.

Ispirazioni:
- **OpenClaw / secure-openclaw** — agente generalista via MCP
- **Letta Sleep-time Agents** — consolidamento asincrono
- **Hermes Agent (NousResearch)** — skill distillation automatica
- **Zep / Graphiti** — memoria temporale con validità
- **Anthropic SKILL.md + Memory Tool** — primitive native

### 0.2 Quattro principi non negoziabili

1. **Local-first**: dati, embedding, graph, reflection girano localmente. Claude è l'unico servizio cloud, per ragioni di capacità del modello.
2. **Qualità > scorciatoie**: ogni scelta va in direzione della massima qualità sostenibile, non del minimo sforzo.
3. **Auto-miglioramento osservabile**: ogni componente deve produrre metriche che dimostrino l'agente sta migliorando (retrieval precision, skill success rate, acceptance rate proattivo).
4. **Dataset-ready per fine-tuning futuro**: ogni file markdown nasce già tagged e filtrabile per diventare training data di qualsiasi modello open futuro (GLM 5.1, Qwen 3, Llama 4, ecc.). Vantaggio strategico vs Hermes (fine-tuning irreversibile locked) e vs Letta/Mem0 (dati cloud proprietari non esportabili).

### 0.3 Non-goals

- Fine-tuning locale del modello *in-the-loop* (rimane Claude API per il runtime; il fine-tuning offline futuro su altri modelli è invece supportato — vedi §3.5)
- Vector DB distribuito / multi-tenant (single-user)
- Compatibilità Linux/Mac prima di Windows stabile
- Replacement totale del sistema attuale (migrazione incrementale)

---

## 1. Architettura a 7 layer

```
┌─────────────────────────────────────────────────────────┐
│  L7  PROATTIVITÀ        (watcher proactive, briefing)   │
├─────────────────────────────────────────────────────────┤
│  L6  SKILL COMPILATION  (SKILL.md, distillation N≥3)   │
├─────────────────────────────────────────────────────────┤
│  L5  SLEEP-TIME COMPUTE (Letta pattern, Haiku ogni 2h)  │
├─────────────────────────────────────────────────────────┤
│  L4  RETRIEVAL HYBRID   (vector + graph + keyword)      │
├─────────────────────────────────────────────────────────┤
│  L3  GRAPH STORE        (SurrealDB embedded, entity+rel)│
├─────────────────────────────────────────────────────────┤
│  L2  VECTOR STORE       (LanceDB + BGE-M3 locale)       │
├─────────────────────────────────────────────────────────┤
│  L1  MEMORY TOOL        (Anthropic memory_20250818)     │
├─────────────────────────────────────────────────────────┤
│  L0  FILESYSTEM         (markdown, git, provenance)     │
└─────────────────────────────────────────────────────────┘
```

### 1.1 Filesystem layout

```
telegram-bridge/
├── memories/
│   ├── <chatId>/
│   │   ├── identity.md              ← chi è l'utente (semantic)
│   │   ├── tacit.md                 ← preferenze, stile (semantic)
│   │   ├── pinned/                  ← cose fissate manualmente (/remember)
│   │   │   └── <slug>.md
│   │   ├── episodes/                ← cronologia eventi (episodic)
│   │   │   └── YYYY-MM-DD.md
│   │   ├── entities/                ← persone, luoghi, progetti (semantic)
│   │   │   └── <slug>.md
│   │   ├── skills/                  ← procedure testate (procedural)
│   │   │   └── <slug>.md            ← SKILL.md format
│   │   ├── lessons.md               ← errori + correzioni ricorrenti
│   │   └── briefings/               ← digest generati da L7
│   │       └── YYYY-MM-DD.md
│   └── _global/                     ← memoria condivisa tra chat
│       └── skills/                  ← skill promosse da singole chat
├── stores/
│   ├── vector.lance/                ← LanceDB directory
│   └── graph.surreal/               ← SurrealDB RocksDB directory
├── models/
│   └── bge-m3-q8.onnx               ← embedding model scaricato
└── logs/
    ├── retrieval/<chatId>.jsonl     ← trace per turn
    ├── proactive_feedback.jsonl     ← accept/dismiss tracking
    └── sleep_time.jsonl             ← log consolidamento
```

---

## 2. Componenti

### 2.1 L1 — Memory Tool Executor (`memory-executor.js`)

Implementa le 6 operations del Memory Tool di Anthropic:
- `view(path)` — listing directory o lettura file
- `create(path, content)` — crea file nuovo
- `str_replace(path, old, new)` — edit in-place
- `insert(path, line, content)` — insert at line
- `delete(path)` — rimozione (soft, sposta in `.trash/`)
- `rename(old_path, new_path)` — rename

**Path guard**: tutti i path devono matchare `^memories/<chatId>/` o `^memories/_global/` — altrimenti reject. Protezione contro path traversal.

**Locking**: `proper-lockfile` con `retries: {retries: 3, minTimeout: 100, maxTimeout: 500}`, stale detection 30s, lockfilePath in cartella dedicata.

**Beta header**: `anthropic-beta: context-management-2025-06-27`.

### 2.2 L0 — Provenance + Git (`provenance.js`)

Ogni file scritto da agente ha YAML frontmatter **esteso per dataset-readiness** (§3.5):

```yaml
---
# Provenance (base)
source: capture | reflection | distillation | user-pinned
chat_id: <string>
created_at: <ISO>
updated_at: <ISO>
last_validated_at: <ISO>
confidence: 0.0-1.0
tags: [list]

# Dataset-readiness (fine-tuning futuro)
domains: [marketing, coding, personal-finance, ...]   # multi-tag auto-classificato
task_type: instruction | chat | qa | creative | classification
quality_tier: premium | standard | draft
training_use: include | exclude | review
language: it | en | mixed
success_count: <int>   # solo per skills, auto-incrementato
---
```

**Auto-classification** (§2.6 task #6): ogni 2h, sleep-time agent popola `domains`, `task_type`, `quality_tier` via Haiku. **Override manuale**: `/tag <file> <tag1> <tag2>` in Telegram. **Auto-promotion a premium** quando `confidence ≥ 0.9` + `success_count ≥ 5` + zero correzioni user ultimi 30gg.

**Git auto-commit** dopo ogni ciclo Riflettore:
- Branch `main` per stato corrente
- Commit message: `[reflector] <N> files updated (<chatId>)`
- Retention: 30 giorni, poi squash settimanale
- `/memory rollback <N>` per tornare indietro

### 2.3 L2 — Vector Store (`vector-index.js`)

- **LanceDB** su disco, tabella per chat: `vectors_<chatId>`
- **BGE-M3 q8** via `@huggingface/transformers`
- Schema: `{id, path, chunk_idx, text, embedding[1024], updated_at}`
- Chunking: paragrafi markdown, max 512 token
- **Re-index trigger**: on file create/update via watcher, debounce 2s
- **Lazy load**: modello caricato on-demand, keep-alive 10min idle

### 2.4 L3 — Graph Store (`graph-store.js`)

- **SurrealDB embedded** (`@surrealdb/node`, pin version esatta)
- **Thin data-access layer** in `graph-api.js` (astrae SurrealDB per swap futuro)
- **Schema**:
  ```surql
  DEFINE TABLE entity SCHEMAFULL;
  DEFINE FIELD name ON entity TYPE string;
  DEFINE FIELD type ON entity TYPE string; -- person, place, project, concept
  DEFINE FIELD md_path ON entity TYPE string;
  DEFINE FIELD valid_from ON entity TYPE datetime;
  DEFINE FIELD valid_to ON entity TYPE option<datetime>;

  DEFINE TABLE mentions TYPE RELATION FROM episode TO entity;
  DEFINE TABLE knows TYPE RELATION FROM entity TO entity;
  DEFINE FIELD since ON knows TYPE datetime;
  ```
- **Temporal validity** (pattern Zep): mai cancellare fatti, marcare `valid_to`
- **Query esempi**:
  - "chi ha mandato email su progetto X nell'ultimo mese?"
  - "quando ho parlato di Y?"
  - "cosa so di Z connesso a W?"

### 2.5 L4 — Hybrid Retrieval (`retrieve.js`)

Per ogni turno, pre-query:
1. **Keyword search** su markdown (ripgrep-js) → top 5
2. **Vector search** BGE-M3 → top 10
3. **Graph traversal** 1-hop su entità menzionate → top 5
4. **Rerank** via Haiku 4.5 con prompt: "quali di questi snippet sono rilevanti per `<user_query>`?"
5. Output: top 8 chunks con provenance, iniettati nel system prompt

**Logging**: ogni retrieval scrive `logs/retrieval/<chatId>.jsonl`:
```json
{"turn_id", "query", "candidates": [{path, score, source}], "selected": [...], "latency_ms"}
```

**Metriche**: retrieval_precision = `<chunks citati nella risposta> / <chunks iniettati>`.

### 2.6 L5 — Sleep-Time Agent (`sleep-time-worker.js`)

Watcher tipo `sleep-time` in `watchers.json`:
- **Cron**: ogni 2 ore, skip se last_turn < 10min fa
- **Modello**: Haiku 4.5
- **Input**: `episodes/` ultimi 2h + `logs/retrieval/*.jsonl` ultimi 2h
- **Output**: mutazioni markdown via Memory Tool

**6 task del sleep-time agent:**

1. **Consolidate episodic → semantic**: leggi nuovi episodi, estrai fatti, aggiorna `entities/*.md` e `tacit.md`
2. **Graph sync**: parse frontmatter/link in markdown aggiornati → upsert su SurrealDB
3. **Pattern detection**: scansiona `episodes/` ultimi 14 giorni, identifica sequenze ricorrenti (≥3 occorrenze, diverse input), propone skill
4. **Skill promotion**: se procedura ha ≥3 successi distinti senza correzione utente, invoca L6
5. **Lesson harvesting**: leggi turni con "no", "non così", correzioni → aggiorna `lessons.md`
6. **Auto-classification (dataset tagging)**: per file senza `domains`/`task_type`/`quality_tier`, Haiku classifica e popola frontmatter. Prompt: "classifica contenuto — quali domini? task_type? quality tier?". Review umana obbligatoria solo per promozione a `premium`.

**Cost**: ~$0.12/giorno (stimato 12 cicli/giorno × ~9K token Haiku input, include task 6).

### 2.7 L6 — Skill Distillation (`skill-distiller.js`)

Trigger: sleep-time agent detect ≥3 successi distinti di una procedura.

**Formato SKILL.md (Anthropic standard)**:
```markdown
---
name: <verbo-oggetto>
description: <1-line, <200 chars>
allowed-tools: [WebSearch, Read, ...]
created_at: <ISO>
last_validated_at: <ISO>
success_count: <int>
---

# <Nome skill>

## When to use
<trigger conditions>

## Inputs
<expected inputs>

## Steps
1. ...
2. ...

## Output
<expected output>

## Anti-examples
<cosa NON fare>
```

**Distillation prompt (Haiku)**:
"Data questa sequenza di 3+ turni di successo, estrai procedura riutilizzabile in formato SKILL.md. Includi anti-examples dai fallimenti precedenti."

**Injection**: all'inizio di ogni turno, se user query matcha `name` o `description` di una skill (via vector sim > 0.8), inietta skill nel system prompt come contesto.

**Validation**: re-validate skill ogni 30 giorni (Haiku verifica che i tool menzionati esistano ancora).

### 2.8 L7 — Proattività (`proactive-engine.js`)

Estende `watchers.json` con tipo `proactive`. Tre sotto-watcher:

**a) Morning Briefing** (`briefing-morning.js`)
- Cron 08:00 per ogni chat opt-in
- Input: `episodes/` ultimo giorno + `skills/` attive + calendario (se configurato)
- Output: digest Telegram con 3-5 punti: "ieri hai fatto X, oggi potresti Y, ricorda Z"
- Target: <800 caratteri

**b) Pattern Detector** (`pattern-detect.js`)
- Cron settimanale (domenica 22:00)
- Scansiona `episodes/` ultimo mese, cerca pattern temporali via Haiku:
  - "ogni lunedì chiedi X"
  - "dopo Y tipicamente chiedi Z"
- **Threshold**: ≥3 occorrenze in finestre temporali consistenti
- Output: proposta proattiva con confidence score. Se confidence ≥ 0.7 → delivery

**c) External Triggers** (`trigger-external.js`)
- Endpoint `POST /api/proactive/trigger` (porta 7777 panel)
- Accetta eventi: email, calendar, custom webhook
- Flow: event → memory lookup → Haiku decide se rilevante → Opus genera messaggio se sì

**Delivery gates (tutti e 3 i canali)**:
1. **Confidence gate**: score ≥ 0.7 (tunable)
2. **Daily cap**: max 3 messaggi proattivi/giorno/chat
3. **Quiet hours**: no delivery tra 22:00-07:00 (configurabile)
4. **Digest over alert**: se ≥2 candidate nella stessa finestra, raggruppa
5. **Undo/mute**: ogni messaggio ha inline button `/mute <topic>` e `/less`

**Feedback loop**:
- User risponde → log `proactive_feedback.jsonl` con accept/dismiss
- Weekly tuning: se acceptance_rate < 0.3 → alza threshold +0.05, se > 0.7 → abbassa

**Mai autonomo su dati sensibili**: actions che inviano email, pagano, modificano calendar richiedono conferma esplicita tramite inline button.

---

## 3. Telegram commands

| Comando | Azione |
|---|---|
| `/remember <fatto>` | Scrive in `pinned/<slug>.md`, mai sovrascritto da reflection |
| `/forget <topic>` | Cerca e propone rimozione (conferma user) |
| `/memory view <path>` | Lista contenuto (view ricorsivo limitato) |
| `/memory search <query>` | Hybrid retrieval, mostra top 5 |
| `/skill list` | Lista skill compiled |
| `/skill show <name>` | Mostra SKILL.md |
| `/mute <topic>` | Disattiva proattività per topic |
| `/briefing on\|off` | Attiva/disattiva morning briefing |
| `/memory rollback <N>` | Git revert ultimi N commit reflector |
| `/tag <file> <tags...>` | Override manuale classification (domains, tier) |
| `/review premium` | Lista file candidati promozione a `quality_tier: premium` |
| `/export <domain> <tier>` | Genera anteprima dataset esportabile (Fase 10) |

---

## 3.5 Dataset-readiness per fine-tuning futuro

### Perché è strategico

v4 accumula dati **già strutturati** come training data. Ogni file è candidato dataset grazie al frontmatter esteso (§2.2). A differenza di:

- **Hermes Agent**: fa fine-tuning in-the-loop → irreversibile + locked al suo formato + modello base mediocre
- **Letta / Mem0**: dati in DB cloud proprietari → export complicato o impossibile
- **Zep / Cognee**: stessa trappola cloud

v4 tiene dati **puri, portabili, filtrabili** usabili per fine-tunare *qualsiasi modello futuro* (GLM 5.1, Qwen 3, Llama 4, modelli ancora non esistenti).

### Cosa diventa training data

**`episodes/YYYY-MM-DD.md` → dataset conversazionale**
Chat format (OpenAI/ShareGPT/Alpaca). Script ~20 righe per conversione.

**`skills/*.md` → dataset instruction-following (il più prezioso)**
SKILL.md ha struttura già perfetta:
- `When to use` → trigger
- `Inputs` → prompt
- `Steps` → chain-of-thought
- `Output` → expected response
- `Anti-examples` → DPO rejected samples

Raro: la maggior parte dei dataset open non ha anti-examples.

**`entities/` + `identity.md` + `tacit.md` → knowledge base per RAG/contextual fine-tuning**

**`lessons.md` → dataset DPO (Direct Preference Optimization)**
Coppie "risposta sbagliata vs corretta dopo correzione user". Ideale per alignment.

**`logs/retrieval/*.jsonl` → dataset per fine-tuning embedding custom** (opzionale futuro).

### Workflow export (Fase 10 futura)

```bash
node scripts/export-dataset.js \
  --domain marketing \
  --tier premium \
  --format sharegpt \
  --min-confidence 0.8 \
  --exclude-drafts \
  --output datasets/marketing-premium-2026-09.jsonl
```

Output: JSONL pulito, filtrato, pronto per HuggingFace upload o LoRA loading.

### Volumi stimati

Con 6 mesi uso attivo bridge → 1000-2000 turni → dataset solido per:
- **LoRA leggero**: 200-500 esempi premium bastano
- **QLoRA full**: 1000-3000 esempi
- **Full fine-tune**: 5000+ (probabile tra 12 mesi uso)

### Filtro qualità nativo

Non tutti i dati sono uguali. Frontmatter permette filtering aggressivo:
- `confidence >= 0.9` → scarti rumore
- `last_validated_at < 30gg` → scarti skill rot
- `source: user-pinned` → tieni solo cose confermate esplicitamente
- `success_count >= 5` sulle skill → solo procedure testate ripetutamente

**500 esempi premium > 2000 mediocri** per LoRA.

### Classificazione multi-dominio

Un file può appartenere a più domini: `domains: [marketing, writing]`. Lo stesso episodio contribuisce a più dataset senza duplicazione.

### Review umana gate per `premium`

Auto-classification via Haiku è ok per `standard`/`draft`. Promozione a `premium` richiede sempre review utente (comando `/review premium`). Questo protegge il "gold set" da errori di classification.

---

## 4. Modello economico

| Componente | Modello | Frequenza | Costo stimato |
|---|---|---|---|
| Turno primario | Opus 4.7 | per turno | variabile |
| Retrieval rerank | Haiku 4.5 | per turno | ~$0.001 |
| Sleep-time consolidation | Haiku 4.5 | ogni 2h | ~$0.10/giorno |
| Pattern detection | Haiku 4.5 | settimanale | ~$0.05/settimana |
| Skill distillation | Haiku 4.5 | triggered | ~$0.02/skill |
| Morning briefing | Haiku 4.5 | giornaliero | ~$0.02/giorno |

**Totale runtime aggiuntivo**: ~$4-5/mese per utente attivo.

---

## 5. Rollout a fasi

**Fase 0 — Scaffolding (30min)**
Cartelle, config, schema iniziale, dipendenze npm.

**Fase 0.5 — Spike decisionale (2h, OPZIONALE MA RACCOMANDATO)**
Prototipo minimo: Memory Tool + Letta sleep-time pattern su chat di test. Se dopo 2h non convince, fermare e rivedere v3.

**Fase 1 — L0 + L1 (2h)**
Memory Tool executor, path guard, provenance frontmatter, git auto-commit.

**Fase 2 — L2 Vector (2.5h)**
LanceDB setup, BGE-M3 download + quantize q8, chunk+index pipeline, watcher re-index, test 100 queries.

**Fase 3 — L3 Graph (3h)**
SurrealDB embedded setup, schema, thin wrapper `graph-api.js`, parser markdown→triple, query helpers.

**Fase 4 — L4 Hybrid Retrieval (2h)**
`retrieve.js` che combina keyword+vector+graph, rerank Haiku, logging JSONL.

**Fase 5 — L5 Sleep-Time Agent (3.25h)**
Watcher `sleep-time`, 6 task (consolidate/graph-sync/pattern/skill-promote/lesson-harvest/**auto-classification**).

**Fase 6 — L6 Skill Distillation (2h)**
SKILL.md template, distiller Haiku, injection nel system prompt, validation cron.

**Fase 7 — L7 Proattività (3h)**
`proactive-engine.js`, 3 sotto-watcher (briefing/pattern/external), delivery gates, feedback loop.

**Fase 8 — Telegram commands (1h)**
12 comandi nel bridge (9 base + `/tag` + `/review premium` + `/export`), inline buttons, mute logic.

**Fase 9 — Seeding + test (1h)**
Import manuale 5-10 skill iniziali, 10-20 entità, identity/tacit. Test end-to-end.

**Fase 10 — Dataset exporter (2h, OPZIONALE, FUTURA)**
`scripts/export-dataset.js` con filter CLI (domain/tier/format/confidence). Conversione `episodes/*.md` + `skills/*.md` + `lessons.md` in JSONL formati standard (ShareGPT / Alpaca / OpenAI chat / DPO pairs). Da implementare solo quando servirà realmente un fine-tuning.

**Totale**: 19.75h + 2h spike (+ 2h Fase 10 futura).

---

## 6. Metriche di successo

Dopo 2 settimane di uso attivo:

| Metrica | Target |
|---|---|
| Retrieval precision (chunks citati / iniettati) | > 0.4 |
| Skill library size | ≥ 10 attive |
| Proactive acceptance rate | > 0.5 |
| Time to first useful memory recall | < 1 settimana |
| Memory growth rate | +5-10 file/giorno |
| Git reflector commits | stabilmente applicati senza rollback >20% |

Dashboard su panel (porta 7777) che mostra queste metriche in real-time.

---

## 7. Red flag accettati e mitigazioni

| Red flag | Probabilità | Impatto | Mitigazione |
|---|---|---|---|
| SurrealDB Node alpha instabile | Media | Alto | Thin wrapper, pin version, fallback JSON-on-disk se rotto |
| BGE-M3 RAM 2GB + Chromium | Media | Medio | Lazy load modello, keep-alive 10min, monitorare con panel |
| Skill rot (tool obsoleti) | Alta (6 mesi) | Basso | `last_validated_at` + cron 30g |
| Proactive spam | Media | Alto | Confidence gate + daily cap + feedback loop + /mute |
| Sleep-time cost blowup | Bassa | Medio | Hard cap $1/giorno, skip se no turn ultime 6h |
| Graph inconsistency | Media | Medio | Git versioning + rebuild from markdown on startup |
| Letta pattern != nostra scala | Media | Basso | Fase 0.5 spike valida prima di commit |

---

## 8. Differenze v3 → v4

| Aspetto | v3 | v4 |
|---|---|---|
| Storage | Markdown solo | Markdown + Vector + Graph |
| Embedding | Opzionale, cloud | BGE-M3 locale obbligatorio |
| Reflection | Riflettore Haiku singolo task | Sleep-time agent multi-task (5 job) |
| Graph | Assente | SurrealDB embedded con temporal validity |
| Skill | Markdown ad-hoc | SKILL.md format + auto-distillation |
| Proattività | Assente | 3 watcher dedicati + delivery gates |
| Memoria episodic | Non separata | `episodes/YYYY-MM-DD.md` distinto |
| Osservabilità | Retrieval log base | Full trace + dashboard metriche |
| Dataset-ready | No | Sì (frontmatter esteso + auto-classification + export CLI) |
| Effort | 7.5h | 19.75h (+2h spike) |
| Costo | $500-1300/anno | ~$50-60/mese = $600-720/anno |
| Qualità | Pragmatico | SOTA 2026 |

---

## 9. Riferimenti validati

- **Sleep-time Compute** — Lin, Snell et al., arXiv 2504.13171 (Aprile 2025, Letta+Berkeley) — NON Anthropic
- **Anthropic Memory Tool** — `memory_20250818`, beta `context-management-2025-06-27`
- **Anthropic SKILL.md** — github.com/anthropics/skills
- **Hermes Agent** — NousResearch, skill distillation pattern
- **Zep/Graphiti** — temporal validity, bi-temporal model
- **SurrealDB Node** — `@surrealdb/node` (alpha), surrealdb.com/docs/sdk/javascript
- **BGE-M3** — `Xenova/bge-m3` via `@huggingface/transformers` v4+
- **LanceDB** — `vectordb` npm, production-ready Windows

---

## 10. Decisione da prendere prima di iniziare

**Opzione A — Full SOTA**: tutte le fasi, 19.5h + spike. Qualità massima.

**Opzione B — SOTA lean**: salta L3 graph in fase 1, aggiungilo solo se L4 senza graph risulta insufficiente. Riduce a 16.5h.

**Opzione C — Incrementale**: v3 completo prima (7.5h), poi upgrade a v4 layer-per-layer nei mesi successivi.

**Raccomandazione**: Opzione A con Fase 0.5 spike come gate decisionale dopo 2h. Se spike convince, commit full; altrimenti fallback a B o v3.

---

## 11. Confronto SOTA 2026 — perché v4 è la scelta più solida

### 11.1 Tre fondamenta architetturali

**(a) Tre tipi di memoria separati fisicamente** (episodic/semantic/procedural)
Allineato a neuroscienza e ricerca AI. Letta li mescola in memory blocks. Mem0/Cognee li appiattiscono in fact store. Zep ha episodic+semantic ma non procedural strutturato. **v4 li separa fisicamente su filesystem** — raro.

**(b) Tre modalità di retrieval combinate** (keyword + vector + graph + rerank Haiku)
Mem0 solo vector. Zep vector+graph ma cloud. Letta solo vector. **v4 unico hybrid triplo + rerank, tutto locale.**

**(c) Due cicli temporali di auto-miglioramento** (sincrono per turno + asincrono 2h con 6 job distinti)
Hermes solo sincrono (checkpoint ogni 15 tool call). Letta sleep-time ma 1 job. **v4 ha 6 job asincroni distinti.**

### 11.2 Confronto diretto con progetti 2026

**Anthropic Memory Tool da solo**
- Bene: primitive ufficiali, 6 ops, path guard
- Manca vs v4: solo markdown piatto, no graph, no vector, no proattività

**Letta (ex-MemGPT)**
- Bene: sleep-time agent, memory blocks, Sleep-time Compute paper
- Manca vs v4: cloud-hosted, no SKILL.md standard, no graph temporal, no proattività utente, no dataset export

**Hermes Agent (NousResearch)**
- Bene: skill distillation automatica, self-improvement loop
- Manca vs v4: richiede fine-tuning locale (non applicabile con Claude API), no proattività esterna, dati non portabili per fine-tuning di *altri* modelli, modello base mediocre

**Zep / Graphiti**
- Bene: bi-temporal knowledge graph, entity resolution
- Manca vs v4: richiede Neo4j server 6+GB, cloud-oriented, no Memory Tool nativo, no SKILL.md

**Mem0**
- Bene: fact extraction facile
- Manca vs v4: stack Docker 6-8GB, critica HN "non inferisce pattern comportamentali", no procedural memory, dati lockati in DB

**OpenJarvis (Stanford)**
- Bene: local-first, Orchestrator+Operative
- Manca vs v4: no temporal graph, no skill distillation, proattività immatura, no Memory Tool ufficiale

**NeuroLink (juspay)**
- Bene: MCP routing, multi-provider, 64+ tool
- Manca vs v4: è orchestratore, non memoria — complementare, non sovrapposto

**OpenClaw / secure-openclaw**
- Bene: agente generalista via MCP
- Manca vs v4: memoria è filesystem base, no vector, no graph, no auto-distillation

**nanobot (HKUDS)**
- Bene: ultra-leggero, MCP-first
- Manca vs v4: nessuna memoria oltre filesystem — valida solo l'approccio

**Cognee**
- Bene: knowledge graph da conversazioni
- Manca vs v4: cloud-first, setup complesso, no Memory Tool, no SKILL.md

### 11.3 Le 10 caratteristiche uniche di v4 (nessun altro le combina tutte)

1. Memory Tool ufficiale Anthropic (primitive stabili)
2. SKILL.md formato Anthropic standard (portabile)
3. Graph temporal validity stile Zep (mai cancellare fatti)
4. Sleep-time agent multi-task stile Letta (6 job distinti)
5. Skill distillation automatica stile Hermes (N≥3 successi)
6. Hybrid retrieval triplo + rerank Haiku
7. Proattività con delivery gates (confidence + cap + quiet hours + feedback loop)
8. Git versioning della memoria (rollback, audit)
9. Local-first totale (zero cloud oltre Claude)
10. **Dataset-ready per fine-tuning futuro** (frontmatter esteso + export CLI)

**v4 = sintesi del meglio di Letta + Hermes + Zep + Anthropic + OpenClaw.**

---

## 12. Impatto del "no fine-tuning in-the-loop" vs Hermes

### 12.1 Equazione reale

- **Hermes**: modello mediocre (Qwen/Llama open) + fine-tuning stretto su task
- **v4**: modello eccellente (Opus 4.7) + prompt injection dinamico

Fine-tuning batte prompt injection solo con: 1000+ esempi puliti, dominio ristrettissimo, latenza critica (ms), privacy totale. **Nessuno dei criteri si applica al bridge Telegram.**

### 12.2 Dove v4 vince oggettivamente

1. **Qualità base**: Opus 4.7 >> modelli open fine-tuned su task generalisti
2. **Reversibilità**: rimuovi skill dal markdown = sparita. Fine-tuning è distruttivo
3. **Debuggabilità**: vedi esattamente cosa l'AI sa. Fine-tuning è black box
4. **Update istantaneo**: secondi vs ore di retraining
5. **Portabilità**: SKILL.md funziona su Claude Code, altri agenti, altri modelli

### 12.3 Dove Hermes teoricamente vince

1. Costo token runtime (v4 paga injection ogni turno, stimato +$0.50-1.50/mese = trascurabile)
2. Generalizzazione fine (il modello internalizza pattern sottili)
3. Offline totale (no API)

### 12.4 Strategia v4: dati puri oggi, fine-tuning domani su qualsiasi modello

A differenza di Hermes che fa fine-tuning in-the-loop (irreversibile + locked al suo modello), v4 accumula **dati portabili** (§3.5). Significa:

- Oggi: runtime con Opus 4.7 (qualità massima)
- Tra 6-12 mesi: fine-tune GLM 5.1 / Qwen 3 / Llama 4 con dataset premium curato organicamente
- Tra 24 mesi: ripeti fine-tuning su modello nuovo senza ripartire da zero

**Hermes ti blocca a un modello. v4 ti lascia scegliere quando e quale modello fine-tunare, con dati sempre pronti.**

### 12.5 Verdetto finale

Nel caso specifico utente, non avere fine-tuning in-the-loop non è un limite — è una scelta *vincente*:

- Usi oggi il modello migliore del mondo
- Accumuli dati premium per fine-tuning futuro
- Zero lock-in
- Costo extra trascurabile

Il "prezzo" della scelta v4: **~$12-18/anno in token injection extra** (stima conservativa). Trascurabile rispetto ai $500-720/anno totali runtime.
