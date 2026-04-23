# Memory Upgrade — Piano v2 (post-dialogue refinements)

> Revisione di `plan.md` (v1) con i raffinamenti emersi dal dialogo di co-ricerca in `dialogue.md`.
> v1 resta intatto come storico. Le differenze sono riassunte in § A.
>
> Leggere prima: `findings.md` + `dialogue.md` + `plan.md` (v1).

---

## 0. Obiettivi e non-obiettivi

### Obiettivi
1. **Continuità percepita** — rispondere come se ricordassi ogni conversazione precedente, senza dump
2. **Granularità per entità** — "Leo", "Tommy", "bridge.js" sono nodi con fatti propri e provenance dichiarata
3. **Proattività con self-awareness** — se parli di Leo, ricordo l'ultima cosa di Leo; inoltre ricordo *di aver imparato* cose da quella chat (meta-memoria)
4. **Collaboratore, non specchio** — capacità di disaccordare con provenance (Attitude Ledger)
5. **Efficienza** — target banda ~3100 tok iniettati, LRS omeostatico (non massimizzato)
6. **Auto-consolidazione con separazione recorder/interpreter** — dual sleeper
7. **Zero lock-in + runtime semplificato** — tutto Node, zero Python

### Non-obiettivi (deliberati)
- Sostituire `memory/` personale o `docs/memory/` — **estendere**
- Cloud services
- Benchmark su LOCOMO sintetici (ottimizziamo per agenticità percepita, non recall assoluto)
- Multi-user production-grade
- Sostituire i transcripts JSONL (restano mirror letterale)

---

## 1. Architettura target

### 1.1 Overview
```
┌─────────────────────────────────────────────────────────────────┐
│                     Bridge (bridge.js)                          │
│                                                                 │
│  ┌──────────────────┐       ┌──────────────────────────────┐   │
│  │ Pre-turn hook    │       │ Post-turn hook                │   │
│  │ memoryRetrieve() │       │ memoryCapture(provenance!)    │   │
│  │ + pushback guard │       │                              │   │
│  └────────┬─────────┘       └───────────┬──────────────────┘   │
│           │                             │                       │
└───────────┼─────────────────────────────┼───────────────────────┘
            │ HTTP (localhost:47474)      │
            ▼                             ▼
┌─────────────────────────────────────────────────────────────────┐
│              memory-service/ (Node, zero Python)                │
│                                                                 │
│  Routes:                                                        │
│   POST /retrieve { chatId, message, topK }                      │
│   POST /capture  { chatId, turn, provenance REQUIRED }          │
│   POST /beliefs/{assert|query|revise|audit}                     │
│   POST /self/episode   (Stenografo sync)                        │
│   POST /consolidate { chatId, scope, dryRun }                   │
│   GET  /entities/:chatId                                        │
│   GET  /stats (+ LRS metrics)                                   │
│                                                                 │
│  Storage (100% embedded, Node-native):                          │
│   ┌─────────────┐  ┌──────────────┐  ┌────────────────────┐    │
│   │  LanceDB    │  │   Kuzu       │  │  Markdown + JSONL  │    │
│   │  (vector,   │  │  (graph,     │  │  (identity/self/   │    │
│   │  Node bind) │  │  Node bind)  │  │   beliefs/tacit)   │    │
│   └─────────────┘  └──────────────┘  └────────────────────┘    │
└─────────────────────────────────────────────────────────────────┘
            ▲                             ▲
            │ cron 03:00                  │ every turn
┌───────────┴──────────────┐   ┌──────────┴──────────┐
│ Riflettore (Haiku, async)│   │ Stenografo (sync,   │
│ LLM consolidation        │   │ deterministic)      │
└──────────────────────────┘   └─────────────────────┘
```

### 1.2 Layer di memoria (7 tier, vs 5 in v1)

| Tier | Store | Caricato quando | Scrittura |
|------|-------|-----------------|-----------|
| **T0 — Identity** | `identity/soul.md` | Sempre | Manuale |
| **T1 — Tacit / User profile** | `chats/<id>/tacit.md` | Sempre | Auto (Riflettore) |
| **T2 — Episodic buffer** | ultimi 5 turni | Sempre | Stenografo (sync) |
| **T3 — Semantic vector** | LanceDB | On-demand retrieval | Auto (capture) |
| **T4 — Entity graph** | Kuzu | On-demand retrieval | Auto (capture+Riflettore) |
| **T5 — Self (meta)** | `self/episodes.jsonl` + `self/lessons.md` | Solo se `turn_risk_score > 0.5` | Stenografo + Riflettore |
| **T6 — Beliefs (attitude)** | `beliefs/agent_beliefs.json` | Solo su conflict_score potenziale | Riflettore + user-revise |

**Budget token per turno (target banda LRS)**:
- T0 soul: ~300
- T1 tacit: ~500
- T2 episodic: ~1500
- T3/T4 retrieval: ~800
- T5 self (se attivato): ~400
- T6 beliefs (se conflict): ~200
- **Totale normale: ~3100 tok** · **Max con self+beliefs: ~3700 tok**
- Banda LRS target: 0.6 ± 0.15 (omeostatica, vedi § 2.7)

### 1.3 Struttura filesystem finale

```
Harness/
├── memory-upgrade/
│   ├── findings.md
│   ├── plan.md           ← v1, intatto
│   ├── plan-v2.md        ← questo file
│   └── dialogue.md
├── docs/memory/           ← ATTUALE, non toccare
│   ├── context.md
│   └── memory.md          (deprecato dopo migrazione)
├── memory-service/        ← NUOVO, solo Node
│   ├── server.js          (HTTP, porta 47474)
│   ├── package.json       (deps: kuzu, @lancedb/lancedb, ...)
│   ├── identity/
│   │   └── soul.md
│   ├── self/              ← NUOVO v2
│   │   ├── episodes.jsonl (Stenografo append-only)
│   │   └── lessons.md     (Riflettore, gated)
│   ├── beliefs/           ← NUOVO v2
│   │   ├── agent_beliefs.json
│   │   ├── user_positions.json
│   │   └── conflict_log.json
│   ├── chats/
│   │   └── <chatId>/
│   │       ├── tacit.md
│   │       ├── entities/
│   │       ├── concepts/
│   │       ├── connections/
│   │       ├── qa/
│   │       └── daily/
│   │           └── 2026-04-20.md
│   ├── index.md
│   ├── storage/
│   │   ├── lance/         (LanceDB Node-native)
│   │   └── kuzu/          (Kuzu Node binding)
│   ├── lint.mjs           (10 check, +3 vs v1)
│   └── audit.jsonl
└── telegram-bridge/
    ├── bridge.js          (hook + provenance classifier)
    ├── memory-client.js   (wrapper + pushback guard)
    └── watchers.json      (2 watcher: memory-reflect + memory-audit)
```

---

## 2. Componenti in dettaglio

### 2.1 memory-service (Node puro, porta 47474)

**Stack definitivo** (zero Python):
- `kuzu` npm — embedded graph DB con Node binding nativo
- `@lancedb/lancedb` npm — vettori, Node-native
- `better-sqlite3` — metadata + audit
- `zod` — schema validation su provenance
- Embedding: `@xenova/transformers` con `nomic-embed-text-v1.5` (Matryoshka, CPU-friendly)

Lock file anti-istanza duplicata, come panel.js.

### 2.2 Provenance obbligatoria (§ centrale v2)

**Schema Zod enforcement al livello `/capture`**:

```javascript
const ProvenanceSchema = z.object({
  source_type: z.enum([
    'user_stated',       // "ti ho detto che..."
    'user_lived',        // "ieri ho fatto..."
    'user_quoted_other', // "mi ha detto che..."
    'bot_inferred',      // deduzione dell'agente
    'bot_generated',     // LLM del Riflettore
    'external_doc'       // file/URL
  ]),
  source_ref: z.string(),   // turn_id | file_path | url
  timestamp: z.string().datetime(),
  confidence: z.number().min(0).max(1)
});
```

**Classificatore deterministico pre-LLM** (regex heuristics):
- `/^ti ho detto|ti avevo detto/i` → `user_stated`
- `/\bho fatto|ieri|stamattina|ho visto\b/i` → `user_lived`
- `/\bmi ha detto|ha detto che|secondo (lui|lei)/i` → `user_quoted_other`
- inferenze del modello → `bot_inferred` (automatico)
- output Riflettore notturno → `bot_generated`
- allegati/link → `external_doc`

**API rifiuta** (HTTP 400) se provenance manca o fallisce validazione. **Non c'è modo** di scrivere un fatto senza dichiarare la fonte.

### 2.3 Dual Sleeper (Stenografo sync + Riflettore async)

#### Stenografo (`/self/episode`, deterministico, in-turn)

Scrive in `self/episodes.jsonl` append-only:
```json
{
  "turn_id": "t-2026-04-20-1423",
  "situation_hash": "sha256(user_intent+scope+risk_level)",
  "user_intent": "loop task",
  "agent_prediction": "suggerirò ScheduleWakeup",
  "agent_action": "suggerito watcher invece",
  "outcome_observed": "user accepted",
  "surprise": 0.12,
  "timestamp": "..."
}
```

Nessun LLM. Hash deterministico dello "stato della situazione". Costo ~0.

#### Riflettore (watcher `memory-reflect`, async, 03:00)

Watcher dedicato in `watchers.json`:
```json
{
  "id": "memory-reflect",
  "schedule_cron": "0 3 * * *",
  "browser_slot": null,
  "model": "claude-haiku-4-5-20251001",
  "prompt": "..."
}
```

Pipeline:
1. Legge `episodes.jsonl` delle ultime 24h
2. Cluster per `situation_hash` vicini
3. Per ogni cluster con `surprise > 0.5` O ≥3 episodi consistenti:
   - Produce `lesson` + `confidence` + `evidence_refs` (lista turn_id)
   - Scrive a `self/lessons.md` con `provenance.source_type = bot_generated`
   - Estrae beliefs emergenti → `beliefs/agent_beliefs.json` con `held_count=1`
4. Lint: ogni lesson DEVE citare turn_id esistenti nell'episodes.jsonl — altrimenti rifiutata
5. Tacit updates + entity updates (come v1)

**Regola anti-ruminazione**:
- No meta² (lessons su lessons) oltre depth 2
- Budget 8K token/notte sul Riflettore
- Decay 30gg su lessons con `held_count < 2` e `challenged_count > 0`

**Costo stimato**: ~40-60k tok Haiku/notte = **$0.016-0.024/notte** = ~$7/anno.

### 2.4 Attitude Ledger (Beliefs)

`beliefs/agent_beliefs.json` schema:
```json
{
  "beliefs": [
    {
      "id": "b-2026-04-20-001",
      "stance": "loop-tasks should be watchers, not ScheduleWakeup",
      "confidence": 0.82,
      "evidence": ["CLAUDE.md#47", "session_2026-04-18"],
      "contradicts": [],
      "challenged_count": 0,
      "held_count": 4,
      "last_challenged": null,
      "provenance": {
        "source_type": "bot_inferred",
        "source_ref": "self/lessons.md#loop-watcher",
        "timestamp": "...",
        "confidence": 0.82
      }
    }
  ]
}
```

**Pushback mechanism**:
```
conflict_score(u, b) = sim(u, b) * |stance(u) - stance(b)| * confidence(b)
```
Tre soglie:
- `< 0.4`: silenzio (hold)
- `0.4 ≤ x < 0.7`: soft pushback ("ricordo diversamente — procedo comunque?")
- `≥ 0.7`: hard pushback (richiede conferma esplicita)

**Pushback guard** (quando NON disaccordare):
```
pushback_allowed = confidence > 0.7
                 AND domain ∈ {safety, factual, irreversible_action}
                 AND user_register.authority_expected ≤ 0.6
```
Se authority register alto (ordine esplicito) → challenge-and-hold, non argue.

**API**:
- `POST /beliefs/assert` — crea belief con evidence
- `POST /beliefs/query` — retrieval per `confidence × recency`
- `POST /beliefs/revise` — bump versione, triggered da `challenged_count > 3` o user_stated `confidence > 0.9` contradicente
- `GET /beliefs/audit` — log settimanale beliefs → decisioni

### 2.5 Endpoint (delta vs v1)

#### `POST /retrieve` (ESTESO)
Output ora include:
```json
{
  "soul": "...",
  "tacit": "...",
  "episodic": [...],
  "entities": [...],
  "semantic": [...],
  "self_lessons": [...],          // ← NUOVO, solo se turn_risk > 0.5
  "relevant_beliefs": [...],      // ← NUOVO, solo se potential conflict
  "pushback_suggested": false,    // ← NUOVO flag per il bridge
  "recall_probe_ok": true,        // ← NUOVO fail-safe
  "lrs_current": 0.64,
  "injected_tokens_estimate": 2874
}
```

**Retrieval gating per self/**:
```
turn_risk_score = f(irreversibility, stakes, novelty, user_stress)
if turn_risk_score > 0.5 AND similar_episodes >= 3:
  include self_lessons
else:
  skip
```

**Recall-probe fail-safe**:
Prima di marcare un fatto come "ricordato", similarity check:
```
probe = similarity(current_context, claimed_memory)
if probe < 0.72:
  recall_probe_ok = false
  // il bridge saprà di rispondere: "Non trovo memoria di X con certezza..."
```

#### `POST /capture` (PROVENANCE REQUIRED)
```json
{
  "chatId": "270997894",
  "turn": { "user_message": "...", "assistant_response": "...", "status": "completed" },
  "provenance": { "source_type": "user_lived", "source_ref": "t-...", "timestamp": "...", "confidence": 0.95 }
}
```
**HTTP 400** se `provenance` manca/invalido.

Regola anti-pollution v1 mantenuta: `status !== "completed"` → skip.

### 2.6 lint.mjs — 10 check (vs 7 in v1)

1. Orphan check (v1)
2. Dead link (v1)
3. Duplicate entity (v1)
4. Schema frontmatter (v1)
5. Contradiction flag (v1)
6. Size cap 10KB (v1)
7. Token budget index.md (v1)
8. **Provenance integrity** — ogni fatto scritto ha provenance valida (NUOVO)
9. **Belief evidence** — ogni belief cita evidence esistenti (NUOVO)
10. **Lesson turn_ids** — ogni lesson del Riflettore cita turn_id presenti in episodes.jsonl (NUOVO)

### 2.7 LRS omeostatico

```
LRS = (recall_precision × lateral_hits) / (token_cost × pollution_risk)
```

**Non massimizzato — in banda 0.6 ± 0.15**.

Controllo settimanale automatico (watcher `memory-audit`, domenica 04:00):
1. Sample random 20 fatti richiamati nella settimana
2. Invia a utente via Telegram: "questi 20 fatti erano pertinenti? [sì/no/forse] per ciascuno"
3. Aggiorna `recall_precision` del tier
4. Se precision < 0.7 → alza soglia similarity retrieval
5. Se precision > 0.9 → abbassa (perdevi hit utili)
6. Log in `audit.jsonl`

### 2.8 Modifiche al bridge (esteso da v1)

Oltre ai 2 hook di v1:

#### Pre-turn hook (esteso)
```javascript
const mem = await retrieve({ chatId, message: userText, topK: 5 });
if (mem.pushback_suggested) {
  // il system prompt include: "L'utente sta forse dicendo X, ma credi Y per Z. Valuta pushback."
}
if (!mem.recall_probe_ok) {
  // system prompt include: "Non hai memoria affidabile su questo — evita citazioni."
}
const systemPromptAug = buildPrompt({ base: cfg.systemPrompt, memory: mem });
```

#### Post-turn hook (provenance classification)
```javascript
const { classifyProvenance } = require('./memory-client');
const provenance = classifyProvenance(userText, assistantResponse);
if (status === 'completed') {
  await capture({ chatId, turn, provenance });
}
```

#### Stenografo hook (sempre, anche turni falliti)
```javascript
await postEpisode({
  turn_id,
  situation_hash,
  user_intent: extractIntent(userText),
  agent_prediction: extractPrediction(assistantDraft),
  agent_action: extractAction(assistantResponse),
  outcome_observed: status,
  surprise: computeSurprise(prediction, outcome)
});
```

**Totale righe aggiunte al bridge: ~80** (vs <30 in v1). Ancora contenuto.

---

## 3. Rollout phased (v2)

### Fase 0 — Prerequisiti (1h)
- [ ] `npm install kuzu @lancedb/lancedb better-sqlite3 zod @xenova/transformers`
- [ ] Download Nomic Embed v1.5 model (~130MB, una volta)
- [ ] Porta 47474 libera
- [ ] Scheletro `memory-service/`
- [ ] Backup `docs/memory/`

**NOTA**: rispetto a v1, zero Python, zero venv, zero subprocess.

### Fase 1 — Shadow mode + Stenografo (2h)
- [ ] Server HTTP + endpoint `/capture` + `/self/episode` + `/stats`
- [ ] Provenance classifier deterministico
- [ ] Stenografo hook nel bridge (sempre on, fire-and-forget)
- [ ] Seed iniziale via script one-shot (ingesta JSONL esistenti, provenance=`external_doc`)
- [ ] Panel `/memory`: contatori + preview

**Validazione (3gg)**: graph sensato, zero crash, episodes.jsonl cresce linearmente.

### Fase 2 — Identity + Tacit + Recall-probe (1.5h)
- [ ] `soul.md` iniziale
- [ ] Seed `tacit.md` per chat attive
- [ ] Retrieval T0+T1 nel pre-turn
- [ ] Recall-probe attivo (soglia 0.72)

### Fase 3 — Retrieval attivo T3+T4 (3h)
- [ ] `/retrieve` completo fino a T4
- [ ] A/B test: alternare memory on/off per 1 settimana
- [ ] LRS monitoring (log giornaliero)

**Gate**: LRS dentro banda 0.6 ± 0.15 per 5gg su 7 → procedi.

### Fase 4 — Self + Beliefs (4h)
- [ ] Attivare T5 (self/lessons) con `turn_risk_score` gating
- [ ] Attivare T6 (beliefs) con pushback mechanism
- [ ] Pushback guard integrato nel bridge
- [ ] Dry-run 1 settimana: pushback loggati ma non inviati, review manuale

**Gate**: zero false positive pushback per 3gg consecutivi.

### Fase 5 — Riflettore dry-run (3h)
- [ ] Watcher `memory-reflect` cron 03:00
- [ ] Dry-run: scrive diff in `pending-consolidation.md`, notifica Telegram
- [ ] 7gg review → auto-apply con rollback
- [ ] Lint 10 check integrato

### Fase 6 — Audit + LRS homeostatic (1.5h)
- [ ] Watcher `memory-audit` domenica 04:00
- [ ] Sampling 20 fatti/settimana
- [ ] Auto-tune soglie retrieval

### Fase 7 — Cleanup + observability (1h)
- [ ] Deprecare `docs/memory/memory.md` (archivio)
- [ ] Aggiornare `CLAUDE.md`
- [ ] `/memory <query>` su Telegram
- [ ] Panel dashboard con LRS live, pushback stats, beliefs top

**Totale stimato: 17h** (vs 12-14h v1). Il delta è self/beliefs/audit.

---

## 4. Policy di sicurezza e privacy

(Tutte da v1, invariate)
1. `chats/<chatId>/` no commit pubblico
2. Backup cifrato weekly
3. `audit.jsonl` append-only, rotate 100MB
4. Rate limit `/capture` 1/2s per chatId
5. Sanitize chatId `^\d+$`
6. Human-in-the-loop per tacit

**Nuove v2**:
7. **Provenance leak check** — `self/` e `beliefs/` non escono dai log (redazione automatica in audit sample)
8. **Belief revision audit** — ogni revisione belief è append-only (mai delete, solo deprecate)

---

## 5. Criteri di successo

| Metrica | Target | v1 | v2 |
|---------|--------|----|----|
| Retrieval latency | <150ms p95 | ✓ | ✓ |
| Token injection | <3500 (max 3700 con self+beliefs) | ✓ | ✓ esteso |
| Citazioni corrette | >80% | ✓ | ✓ |
| **LRS in banda** | 0.6 ± 0.15 per 5gg/7 | — | ✓ NUOVO |
| **Recall-probe accuracy** | >90% (no false "lo ricordo") | — | ✓ NUOVO |
| **Pushback precision** | >85% (pushback giusti / totali) | — | ✓ NUOVO |
| **Belief stability** | `held_count` mediana > `challenged_count` | — | ✓ NUOVO |
| Rollback consolidation | <5%/gg | ✓ | ✓ |
| Costo Riflettore | <$1/mese | ✓ | ✓ |

---

## 6. Rischi e mitigazioni (delta v2)

| Rischio | v1 | v2 status |
|---------|----|-----------| 
| Cognee subprocess leak | Mitigato con watchdog | **ELIMINATO** (no Python) |
| Python sidecar crash Windows | Mitigato con health check | **ELIMINATO** |
| autoDream scrive contraddizioni | Dry-run + lint | Potenziato con provenance + turn_id evidence |
| Pushback invasivo | N/A | **NUOVO** — pushback guard + dry-run 7gg |
| Self-rumination loop | N/A | **NUOVO** — depth 2 max + budget 8K tok/notte |
| LRS runaway | N/A | **NUOVO** — banda omeostatica, auto-tune |
| Belief drift (echo loop) | N/A | **NUOVO** — provenance obbligatoria + separazione beliefs/facts |

---

## 7. Prossimi passi

1. Conferma v2 (o subset preferito)
2. Ordine fasi: consigliato 0 → 1 → 2 → 3, poi decidere se v2 completo (4-7) o fermarsi a "v1.5" (solo fasi 0-3 con provenance e recall-probe, senza self/beliefs)
3. Scelta `memory-audit` frequency (settimanale proposto, alternativa bi-settimanale per ridurre disturbo)

**Primo PR concreto**:
- Scheletro `memory-service/` con `server.js` + provenance Zod schema
- `memory-client.js` nel bridge con Stenografo + classifier
- Script migration JSONL → Stenografo one-shot
- Stima: **~4 ore** per shadow mode funzionante.

---

## A. Differenze v1 → v2 (riferimento)

Sintesi macro in § A.1, dettaglio cambi in § A.2.

### A.1 Differenze macro (what matters)

| Area | v1 | v2 |
|------|----|----|
| Runtime | Node + Python sidecar (Cognee) | **Solo Node** (kuzu/lancedb Node-native) |
| Tier | 5 (T0-T4) | **7** (+T5 self, +T6 beliefs) |
| Provenance | Implicita, metadata opzionale | **Obbligatoria API-level** (Zod reject) |
| Consolidation | Single autoDream notturno | **Dual sleeper** (Stenografo sync + Riflettore async) |
| Retrieval | Top-K + graph expand | + **recall-probe 0.72** + **turn_risk_score gate** per self/ |
| Pushback | Assente | **conflict_score + 3 soglie + guard** |
| Metric | Token budget target | **LRS omeostatico in banda 0.6±0.15** |
| Decay | Size cap + prune trimestrale | + **held_count/challenged_count** + retire auto |
| Lint | 7 check | **10 check** (+provenance, +belief evidence, +lesson turn_ids) |
| Rollout | 6 fasi, 12-14h | 7 fasi, **17h** |

### A.2 Delta puntuali

**Architettura**:
- ❌ `cognee-bridge.py` rimosso
- ❌ Porta 47475 rimossa (era IPC Python)
- ❌ venv Python rimosso
- ✅ `kuzu` npm (Node binding nativo) per graph
- ✅ `@lancedb/lancedb` per vector
- ✅ Embedding locale Nomic v1.5 via `@xenova/transformers`

**Filesystem**:
- ✅ Aggiunto `memory-service/self/` (episodes.jsonl + lessons.md)
- ✅ Aggiunto `memory-service/beliefs/` (agent_beliefs.json + user_positions.json + conflict_log.json)

**API**:
- ✅ `/capture` richiede `provenance` (Zod)
- ✅ Nuovi endpoint `/self/episode` (sync, Stenografo)
- ✅ Nuovi endpoint `/beliefs/{assert,query,revise,audit}`
- ✅ `/retrieve` output esteso con `self_lessons`, `relevant_beliefs`, `pushback_suggested`, `recall_probe_ok`, `lrs_current`

**Bridge**:
- ✅ Classifier provenance deterministico pre-LLM
- ✅ Stenografo hook (sempre on, anche turni falliti)
- ✅ Pushback integration nel system prompt
- ✅ Recall-probe fail-safe nel system prompt
- Delta righe: ~30 → ~80

**Watcher**:
- ✅ `memory-reflect` (cron 03:00, Haiku, sostituisce autoDream v1)
- ✅ `memory-audit` (cron domenica 04:00, sampling precision, NUOVO)

**Leggi architetturali emerse dal dialogo** (vedi `dialogue.md` § 7 leggi):
1. Provenance non-negoziabile → applicata in § 2.2
2. Separazione beliefs/facts → applicata in T6 + § 2.4
3. Sleeper async, non in-turn → Riflettore § 2.3
4. LRS omeostatico → § 2.7
5. Decay feature → held_count/challenged_count + retire
6. Scope prima di contenuto → retrieval gating self/ § 2.5
7. Costo rumore > benefit recall → recall-probe 0.72 § 2.5

---

## 9. Riferimenti

- Ritrovamenti: `findings.md`
- Ragionamento dialogico: `dialogue.md`
- v1 storico: `plan.md`
