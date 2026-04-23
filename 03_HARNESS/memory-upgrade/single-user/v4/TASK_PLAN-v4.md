# Task Plan v4 — Breakdown operativo

Riferimento: [plan-v4.md](plan-v4.md)
Effort totale: 19.75h + 2h spike (+ Fase 10 futura 2h)
Versione: 4.1 (aggiornato con auto-classification + dataset exporter)
Aggiornato: 2026-04-20

---

## Fase 0 — Scaffolding (30min)

### T0.1 — Creare struttura cartelle (10min)
- [ ] `mkdir telegram-bridge/memories`
- [ ] `mkdir telegram-bridge/memories/_global/skills`
- [ ] `mkdir telegram-bridge/stores` (gitignore: contenuto binario)
- [ ] `mkdir telegram-bridge/models` (gitignore: modelli ONNX)
- [ ] `mkdir telegram-bridge/logs/retrieval`
- [ ] Aggiungere `.gitignore` per `stores/`, `models/`, `memories/_test/`

### T0.2 — Installare dipendenze npm (15min)
- [ ] `npm i proper-lockfile` (file locking Windows)
- [ ] `npm i @huggingface/transformers` (v4+ per BGE-M3)
- [ ] `npm i vectordb` (LanceDB client Node)
- [ ] `npm i @surrealdb/node` (graph, pin exact version)
- [ ] `npm i simple-git` (auto-commit reflector)
- [ ] `npm i chokidar` (file watching per re-index)
- [ ] `npm i gray-matter` (YAML frontmatter parser)
- [ ] Test `node -e "require('@huggingface/transformers')"` su Windows

### T0.3 — Config base (5min)
- [ ] Aggiungere sezione `memory-v4` in `config.json`: `{enabled: false, chats_opted_in: [], proactive: {enabled: false, quiet_hours: [22, 7], daily_cap: 3, confidence_threshold: 0.7}}`
- [ ] Feature flag globale per rollback rapido

---

## Fase 0.5 — Spike decisionale (2h, OPZIONALE)

### T0.5.1 — Prototipo Memory Tool su chat test (60min)
- [ ] Creare chat Telegram dedicata `test-memory`
- [ ] Implementare executor minimale (solo `view`, `create`, `str_replace`)
- [ ] 10 turni di conversazione reale con memoria attiva
- [ ] Verificare: Claude usa Memory Tool come atteso? Path guard funziona?

### T0.5.2 — Sleep-time prototipo (60min)
- [ ] Watcher manuale che ogni 30min invoca Haiku su episodi
- [ ] Output: aggiorna `identity.md` basato sui turni
- [ ] Verificare: dopo 10 turni, `identity.md` è accurato?

**GATE**: Se spike non convince → STOP, rivedere scope. Altrimenti procedi con Fase 1.

---

## Fase 1 — L0 + L1 Memory Tool (2h)

### T1.1 — `memory-executor.js` (60min)
- [ ] File: `telegram-bridge/memory/memory-executor.js`
- [ ] Classe `MemoryExecutor` con 6 ops
- [ ] Path guard: regex `^memories/(<chatId>|_global)/` — throw se fail
- [ ] `proper-lockfile` per ogni write op (retries 3, stale 30s)
- [ ] `.trash/` soft-delete (7gg retention)
- [ ] Unit test con 20 casi: happy path + edge (path traversal, lock timeout, missing file)

### T1.2 — `provenance.js` (30min)
- [ ] File: `telegram-bridge/memory/provenance.js`
- [ ] `parseFrontmatter(content)`, `writeWithFrontmatter(path, content, meta)`
- [ ] Auto-populate `created_at`, `updated_at`, `source`, `chat_id`
- [ ] `confidence` default 0.8 per agent-written, 1.0 per user-pinned
- [ ] **Campi dataset-readiness** (anche se vuoti inizialmente): `domains[]`, `task_type`, `quality_tier`, `training_use`, `language`, `success_count`
- [ ] Default `quality_tier: draft`, `training_use: review` (auto-classification Fase 5.7 popolerà)

### T1.3 — Git auto-commit (30min)
- [ ] File: `telegram-bridge/memory/git-versioning.js`
- [ ] Init repo dedicato in `memories/.git` (non contamina repo principale)
- [ ] `commitReflectorCycle(chatId, files)` dopo ogni ciclo
- [ ] Squash settimanale (cron domenica 03:00)
- [ ] `rollback(N)` helper

### T1.4 — Integrazione con bridge (30min)
- [ ] In `bridge.js`: pass `memory` tool in tools array
- [ ] Beta header `context-management-2025-06-27`
- [ ] Log ogni memory op in `logs/memory-ops.jsonl`

---

## Fase 2 — L2 Vector Store (2.5h)

### T2.1 — Setup BGE-M3 locale (45min)
- [ ] Script `scripts/download-model.js`
- [ ] Download `Xenova/bge-m3` q8 ONNX da HuggingFace
- [ ] Cache in `models/bge-m3-q8/`
- [ ] Warm-up test: embed 10 testi, misura latenza CPU
- [ ] **Gate**: se latenza > 800ms/query → fallback Nomic-embed-v2

### T2.2 — `vector-index.js` (60min)
- [ ] File: `telegram-bridge/memory/vector-index.js`
- [ ] LanceDB table-per-chat: `vectors_<chatId>`
- [ ] Schema: `{id, path, chunk_idx, text, embedding[1024], updated_at}`
- [ ] Chunking markdown: paragrafi, max 512 tok, overlap 50
- [ ] `indexFile(path)` — chunk + embed + upsert
- [ ] `search(chatId, query, topK)` — embed query + cosine sim

### T2.3 — Re-index watcher (30min)
- [ ] `chokidar` su `memories/<chatId>/**/*.md`
- [ ] Debounce 2s
- [ ] Re-index solo file modificati
- [ ] Lazy-load modello, unload dopo 10min idle

### T2.4 — Test 100 query (15min)
- [ ] Seeding 20 file fake
- [ ] 100 query test, calcolare retrieval precision@5
- [ ] Baseline: target > 0.3

---

## Fase 3 — L3 Graph Store (3h)

### T3.1 — SurrealDB setup (45min)
- [ ] Install `@surrealdb/node@<pinned-version>`
- [ ] File: `telegram-bridge/memory/graph-store.js` (thin data-access layer)
- [ ] Init RocksDB in `stores/graph.surreal/`
- [ ] Define schema (entity, episode, mentions, knows, valid_from/to)
- [ ] Unit test: CRUD 50 entità, 100 relazioni

### T3.2 — `graph-api.js` astrazione (45min)
- [ ] API neutrale: `createEntity, linkEntities, findByName, traverse`
- [ ] Implementazione corrente: SurrealDB
- [ ] Fallback stub: JSON-on-disk (in caso SurrealDB alpha rompa)

### T3.3 — Parser markdown → graph (60min)
- [ ] `parseEntitiesFromMarkdown(path)` — estrae `[[wiki-link]]`, menzioni `@nome`
- [ ] `syncFileToGraph(path)` — upsert entities + mentions
- [ ] Trigger: chiamato da sleep-time agent (Fase 5)

### T3.4 — Graph queries utili (30min)
- [ ] `entityBiography(slug)` — tutto ciò che conosce del concetto
- [ ] `recentMentions(slug, days)` — temporal window
- [ ] `connectedTo(slug, hops)` — 1-2 hop traversal

---

## Fase 4 — L4 Hybrid Retrieval (2h)

### T4.1 — `retrieve.js` orchestratore (60min)
- [ ] File: `telegram-bridge/memory/retrieve.js`
- [ ] Function `hybridRetrieve(chatId, userQuery) → {chunks, trace}`
- [ ] Step 1: keyword (ripgrep-js) top 5
- [ ] Step 2: vector BGE-M3 top 10
- [ ] Step 3: graph 1-hop su entità menzionate top 5
- [ ] Step 4: rerank Haiku con prompt dedicato
- [ ] Output: top 8 chunks con path, score, provenance

### T4.2 — Injection nel system prompt (30min)
- [ ] Modifica `bridge.js`: prima di invio turno, chiama `retrieve.js`
- [ ] Inietta chunks come blocco `<memory-context>` nel system
- [ ] Token budget: max 4K token iniettati

### T4.3 — Logging + metriche (30min)
- [ ] Scrivi `logs/retrieval/<chatId>.jsonl` per ogni turno
- [ ] Post-response: parse assistant output, calcola `citations` (quali chunks referenziati)
- [ ] Calcola `retrieval_precision` rolling 100 turni

---

## Fase 5 — L5 Sleep-Time Agent (3h)

### T5.1 — Watcher `sleep-time` registration (30min)
- [ ] Aggiungi tipo `sleep-time` in `watchers.json` schema
- [ ] Cron ogni 2h, skip condition: `last_turn_ts < now - 10min`
- [ ] Hot-reload via panel (già supportato)

### T5.2 — Task 1: Consolidate episodic → semantic (45min)
- [ ] File: `telegram-bridge/memory/jobs/consolidate.js`
- [ ] Input: episodi ultime 2h
- [ ] Haiku prompt: "estrai fatti durevoli, aggiorna entities/tacit"
- [ ] Output: memory ops via executor

### T5.3 — Task 2: Graph sync (30min)
- [ ] File: `jobs/graph-sync.js`
- [ ] Per ogni file modificato ultime 2h: `syncFileToGraph(path)`
- [ ] Rimuove edges obsoleti (non più presenti nel markdown)

### T5.4 — Task 3: Pattern detection (45min)
- [ ] File: `jobs/pattern-detect.js`
- [ ] Input: episodes ultimi 14gg
- [ ] Haiku prompt: "trova sequenze ricorrenti ≥3 occorrenze, diversi input"
- [ ] Output: `patterns/<slug>.md` candidate (non auto-deliver, solo proposal)

### T5.5 — Task 4: Skill promotion trigger (15min)
- [ ] Scan `patterns/` con `success_count ≥ 3`
- [ ] Invoca L6 skill-distiller (Fase 6)

### T5.6 — Task 5: Lesson harvesting (15min)
- [ ] Scan episodes per marker: "no", "non così", "sbagli"
- [ ] Aggiungi voce a `lessons.md` con contesto

### T5.7 — Task 6: Auto-classification (dataset tagging) (15min)
- [ ] File: `telegram-bridge/memory/jobs/auto-classify.js`
- [ ] Scan file con `domains: []` vuoto OR `quality_tier: null`
- [ ] Haiku prompt: "classifica questo contenuto. Output JSON: {domains: [...], task_type: '...', quality_tier: 'standard|draft', language: '...'}"
- [ ] **Safety**: mai auto-promuovere a `premium` (richiede `/review premium` manuale)
- [ ] Aggiorna frontmatter via `provenance.writeWithFrontmatter`
- [ ] Log: `logs/auto-classify.jsonl` con {path, before, after, confidence}

---

## Fase 6 — L6 Skill Distillation (2h)

### T6.1 — SKILL.md template + validator (30min)
- [ ] File: `telegram-bridge/memory/skill-schema.js`
- [ ] Validazione YAML frontmatter obbligatorio
- [ ] Validazione sezioni: When to use, Inputs, Steps, Output, Anti-examples

### T6.2 — `skill-distiller.js` (45min)
- [ ] File: `telegram-bridge/memory/skill-distiller.js`
- [ ] Input: `patterns/<slug>.md` con ≥3 successi
- [ ] Haiku prompt: "compila SKILL.md da queste 3+ sequenze"
- [ ] Output: scrive `skills/<slug>.md` via executor

### T6.3 — Skill injection nel turn (30min)
- [ ] In `retrieve.js`: oltre a chunks, matcha skill via vector sim query↔description
- [ ] Se match > 0.8 → inietta SKILL.md completa nel system
- [ ] Limita 1 skill/turno (evita context bloat)

### T6.4 — Skill validation cron (15min)
- [ ] Cron 30gg: per ogni skill, Haiku verifica tool/path validi
- [ ] Se invalida: marca `stale: true` in frontmatter, escludi da injection

---

## Fase 7 — L7 Proattività (3h)

### T7.1 — `proactive-engine.js` core (30min)
- [ ] File: `telegram-bridge/memory/proactive-engine.js`
- [ ] Delivery gates: confidence, daily_cap, quiet_hours
- [ ] Feedback logger: `logs/proactive_feedback.jsonl`

### T7.2 — Morning briefing watcher (45min)
- [ ] Watcher tipo `briefing-morning`, cron 08:00
- [ ] Input: episodi ieri + skills attive + pending proposals
- [ ] Haiku prompt: "genera digest 3-5 punti <800 chars"
- [ ] Delivery via bridge Telegram send API

### T7.3 — Pattern detector delivery (45min)
- [ ] Legge `patterns/` con `confidence ≥ 0.7` non ancora notificati
- [ ] Costruisce messaggio proattivo con inline buttons `/accept` `/dismiss` `/mute`
- [ ] Log feedback

### T7.4 — External triggers endpoint (30min)
- [ ] Nuovo endpoint `POST /api/proactive/trigger` in `panel.js`
- [ ] Body: `{chat_id, event_type, payload}`
- [ ] Haiku classify: rilevante? urgente? digest-able?
- [ ] Se yes+urgent → delivery immediato; yes+non-urgent → coda digest

### T7.5 — Feedback-driven tuning (30min)
- [ ] Cron settimanale: calcola acceptance_rate ultima settimana
- [ ] < 0.3 → threshold += 0.05
- [ ] > 0.7 → threshold -= 0.05
- [ ] Clamp [0.5, 0.95]

---

## Fase 8 — Telegram commands (1h)

### T8.1 — Command router (15min)
- [ ] In `bridge.js`, aggiungi case per i 12 comandi
- [ ] `/help memory` con lista completa

### T8.2 — Comandi implementation base (30min)
- [ ] `/remember <fatto>` → scrive `pinned/<slug>.md`, slug autogenerato
- [ ] `/forget <topic>` → grep markdown, mostra match, conferma user
- [ ] `/memory view <path>` → listing sicuro (path guard)
- [ ] `/memory search <query>` → invoca hybrid retrieval, mostra top 5
- [ ] `/skill list` — lista skill da `skills/*.md`
- [ ] `/skill show <name>` — pretty-print SKILL.md
- [ ] `/mute <topic>` — append a `config.json:muted_topics`
- [ ] `/briefing on|off` — toggle in config per chat
- [ ] `/memory rollback <N>` — git revert ultimi N commit

### T8.3 — Comandi dataset-management (15min)
- [ ] `/tag <file> <tag1> <tag2>...` → override manuale `domains` o `quality_tier`
- [ ] `/review premium` → lista file con alto confidence+success_count candidati per promozione; inline button "Promote" su ciascuno
- [ ] `/export <domain> <tier>` → preview (solo conteggio + 3 sample); implementazione reale in Fase 10

---

## Fase 9 — Seeding + test end-to-end (1h)

### T9.1 — Seeding iniziale (30min)
- [ ] Intervista breve utente (o import da `context.md` + `memory.md` esistenti)
- [ ] Popolare `identity.md`, `tacit.md` manualmente
- [ ] Aggiungere 10-20 entità chiave (progetti, persone, luoghi)
- [ ] Aggiungere 5 skill seed manuali dalle tue procedure frequenti
- [ ] Re-index vector + graph sync completo

### T9.2 — Test end-to-end (20min)
- [ ] 20 turni di conversazione reale
- [ ] Verificare: retrieval inietta chunks giusti, skill attivate su match, sleep-time consolida
- [ ] Controllare log per errori

### T9.3 — Dashboard metriche (10min)
- [ ] Aggiungi sezione `/api/memory/metrics` nel panel
- [ ] Render retrieval_precision, skill_count, acceptance_rate, storage_size

---

## Fase 10 — Dataset exporter (2h, FUTURA/OPZIONALE)

**Quando implementare**: solo quando servirà realmente fine-tunare un modello open (GLM 5.1, Qwen 3, Llama 4). Tipicamente dopo 3-6 mesi di uso attivo quando dati sono sufficienti.

### T10.1 — `scripts/export-dataset.js` CLI (45min)
- [ ] Parsing argomenti: `--domain`, `--tier`, `--format`, `--min-confidence`, `--exclude-drafts`, `--output`
- [ ] Scan `memories/<chatId>/**/*.md` + `memories/_global/**/*.md`
- [ ] Filter frontmatter secondo argomenti
- [ ] Report pre-export: quanti file match + stima token output

### T10.2 — Converter episodes → chat format (30min)
- [ ] Parser episodi (ruoli user/assistant)
- [ ] Output formati: OpenAI chat, ShareGPT, Alpaca
- [ ] Deduplica turni identici

### T10.3 — Converter skills → instruction-following (30min)
- [ ] Parse SKILL.md (When to use / Inputs / Steps / Output / Anti-examples)
- [ ] Generate esempi instruction: input prompt ← Inputs, output ← Steps+Output
- [ ] Generate DPO pairs: chosen ← Steps, rejected ← Anti-examples (se presenti)

### T10.4 — Converter lessons.md → DPO dataset (15min)
- [ ] Parse lessons: coppie "wrong answer" / "correction"
- [ ] Output DPO format: `{prompt, chosen, rejected}`

### T10.5 — Validator + stats (15min)
- [ ] Verifica schema output, no campi null obbligatori
- [ ] Stats finali: N esempi, media token input/output, distribuzione task_type
- [ ] Warning se dataset < 100 esempi (troppo piccolo per LoRA)

**Effort**: 2h. Non incluso in stima base perché futuro/opzionale.

---

## Dipendenze tra fasi

```
Fase 0 → Fase 0.5 (opzionale) → Fase 1 (Memory Tool)
                                    ↓
                                 Fase 2 (Vector) ──┐
                                    ↓              │
                                 Fase 3 (Graph) ───┤
                                    ↓              ↓
                                 Fase 4 (Hybrid Retrieval)
                                    ↓
                                 Fase 5 (Sleep-Time)
                                    ↓
                                 Fase 6 (Skill Distillation)
                                    ↓
                                 Fase 7 (Proattività)
                                    ↓
                                 Fase 8 (Commands)
                                    ↓
                                 Fase 9 (Seeding + test)
```

**Parallelizzabili**: Fase 2 e Fase 3 possono andare in parallelo se hai due sessioni. Fase 8 può iniziare in parallelo con Fase 7.

---

## Checkpoint di decisione

**Dopo Fase 0.5 (spike)**: commit full v4 o fallback v3?
**Dopo Fase 2**: BGE-M3 latenza accettabile? Se no, Nomic-embed-v2.
**Dopo Fase 3**: SurrealDB alpha stabile nelle operazioni reali? Se no, JSON-on-disk fallback.
**Dopo Fase 4**: retrieval_precision@5 > 0.3 dopo 100 query? Se no, rivedere chunking/reranking.
**Dopo Fase 9**: proseguire con chat reali o ancora tuning?

---

## Stima calendario

Full-time dedicato: 3 giorni lavorativi (6-7h/giorno)
Part-time serale: 2 settimane (1.5h/sera)
Weekend sprint: 1 weekend lungo (10h sabato + 10h domenica)

**Raccomandazione personale**: 2 weekend sprint consecutivi, così ogni layer ha tempo di essere testato in uso reale tra le sessioni.
