# Memory Upgrade — Piano di Implementazione

> Piano operativo per portare Harness a una memoria multi-layer stile KAIROS (Claude Code leak) usando Cognee + pattern claude-memory-compiler + watcher notturno di consolidazione.
>
> Basato sui ritrovamenti in `findings.md`. Leggere prima quello.

---

## 0. Obiettivi e non-obiettivi

### Obiettivi
1. **Continuità percepita** — quando scrivo su Telegram, rispondo come se ricordassi ogni conversazione precedente, senza dump completo in context
2. **Granularità per entità** — "Leo", "Tommy", "bridge.js", "browser pool" sono nodi con fatti propri, non frammenti sparsi
3. **Proattività** — se parli di Leo, ricordo automaticamente l'ultima cosa di Leo. Senza che tu chieda
4. **Efficienza** — <2000 token iniettati per turno, indipendentemente da quante settimane di storia
5. **Auto-consolidazione** — la memoria si pulisce da sola di notte (autoDream locale)
6. **Zero lock-in** — tutto locale, filesystem-first, markdown dove possibile

### Non-obiettivi (deliberati)
- Sostituire il sistema attuale `memory/` personale o `docs/memory/` — **estendere**, non rimpiazzare
- Cloud services — rimane tutto sul PC
- Benchmark su LOCOMO — è memoria personale, non serve tunare per dataset pubblici
- Multi-user production-grade — solo il chat whitelist attuale
- Sostituire i transcripts JSONL — restano mirror letterale di backup

---

## 1. Architettura target

### 1.1 Overview
```
┌─────────────────────────────────────────────────────────────────┐
│                     Bridge (bridge.js)                          │
│                                                                 │
│  ┌──────────────────┐       ┌──────────────────────────────┐   │
│  │ Pre-turn hook    │       │ Post-turn hook                │   │
│  │ memoryRetrieve() │       │ memoryCapture()              │   │
│  └────────┬─────────┘       └───────────┬──────────────────┘   │
│           │                             │                       │
└───────────┼─────────────────────────────┼───────────────────────┘
            │                             │
            │ HTTP (localhost:47474)      │
            ▼                             ▼
┌─────────────────────────────────────────────────────────────────┐
│              memory-service/ (nuovo, Node worker)               │
│                                                                 │
│  Routes:                                                        │
│   POST /retrieve { chatId, message, topK }                      │
│   POST /capture  { chatId, turn }                               │
│   POST /consolidate { chatId, scope, dryRun }                   │
│   GET  /entities/:chatId                                        │
│   GET  /stats                                                   │
│                                                                 │
│  Storage (locale, embedded):                                    │
│   ┌─────────────┐  ┌──────────────┐  ┌────────────────────┐    │
│   │  LanceDB    │  │    Kuzu      │  │  Markdown files    │    │
│   │  (vector)   │  │   (graph)    │  │  (identity/tacit)  │    │
│   └─────────────┘  └──────────────┘  └────────────────────┘    │
│         via Cognee                                              │
└─────────────────────────────────────────────────────────────────┘
            ▲
            │ cron
┌───────────┴────────────┐
│ watchers (consolidate) │  ← autoDream, 03:00 Europe/Rome
└────────────────────────┘
```

### 1.2 Layer di memoria (5 tier)

| Tier | File/Store | Caricato quando | Scrittura |
|------|-----------|-----------------|-----------|
| **T0 — Identity** | `soul.md` | Sempre, ogni turno | Manuale |
| **T1 — Tacit / User profile** | `tacit.md` per chatId | Sempre, ogni turno | Auto (consolidate) |
| **T2 — Episodic buffer** | ultimi 5 turni raw | Sempre | Auto (append) |
| **T3 — Semantic vector** | LanceDB (via Cognee) | Retrieval on-demand | Auto (capture) |
| **T4 — Entity graph** | Kuzu (via Cognee) | Retrieval on-demand | Auto (capture + consolidate) |

**Budget token per turno (stima)**:
- T0 soul: ~300 tok
- T1 tacit: ~500 tok
- T2 episodic: ~1500 tok
- T3/T4 retrieval mirato: ~800 tok
- **Totale: ~3100 tok injected** vs context window 200k → <2%

### 1.3 Struttura filesystem finale

```
Harness/
├── memory-upgrade/                   ← questa cartella (ritrovamenti + piano)
│   ├── findings.md
│   └── plan.md
├── docs/memory/                      ← ATTUALE, non toccare
│   ├── context.md                    (statico manuale)
│   └── memory.md                     (legacy dump — deprecato dopo migrazione)
├── memory-service/                   ← NUOVO
│   ├── server.js                     (HTTP, porta 47474)
│   ├── cognee-bridge.py              (sidecar Python, chiamato via spawn)
│   ├── identity/
│   │   └── soul.md                   (identità globale dell'agente)
│   ├── chats/
│   │   └── <chatId>/
│   │       ├── tacit.md              (profilo user per questa chat)
│   │       ├── entities/             (entità estratte)
│   │       │   ├── leo-corte.md
│   │       │   ├── tommy.md
│   │       │   └── ...
│   │       ├── concepts/             (concetti del dominio)
│   │       ├── connections/          (relazioni cross-ref)
│   │       ├── qa/                   (q/a ricorrenti)
│   │       └── daily/
│   │           └── 2026-04-20.md     (log turni giornalieri, pre-compilazione)
│   ├── index.md                      (indice globale, sempre caricato)
│   ├── storage/
│   │   ├── lance/                    (LanceDB data)
│   │   └── kuzu/                     (Kuzu graph data)
│   ├── lint.mjs                      (7 check integrità)
│   └── audit.jsonl                   (ogni write loggato)
└── telegram-bridge/
    ├── bridge.js                     (modificato: 2 punti di hook)
    ├── memory-client.js              (NUOVO: wrapper HTTP del service)
    └── watchers.json                 (nuovo watcher: memory-consolidate)
```

---

## 2. Componenti in dettaglio

### 2.1 memory-service (Node, porta 47474)

Server HTTP locale, lock file anti-istanza duplicata (come panel.js). Fornisce API REST al bridge.

**Endpoint**:

#### `POST /retrieve`
Input:
```json
{ "chatId": "270997894", "message": "Come va con Leo oggi?", "topK": 5 }
```
Output:
```json
{
  "soul": "...",               // T0
  "tacit": "...",              // T1
  "episodic": [...],           // T2 (ultimi 5 turni)
  "entities": [                // T4 graph expansion
    { "name": "leo-corte", "facts": ["..."], "last_seen": "2026-04-18" }
  ],
  "semantic": [                // T3 vector top-K
    { "text": "...", "score": 0.82, "source": "daily/2026-04-17.md" }
  ],
  "injected_tokens_estimate": 2341
}
```

Pipeline interna (zero LLM):
1. Tokenize `message` → keyword list
2. Query LanceDB top-K embedding similarity
3. Per ogni entity name nel messaggio → Kuzu 1-hop neighbors
4. Reciprocal Rank Fusion dei risultati
5. MMR diversification (max 5 risultati diversi semanticamente)
6. Read file T0/T1 + ultimi 5 dal Redis/file turns ring buffer
7. Return JSON

Target latenza: **<150ms**. Se lento, aggiungere cache LRU in-process.

#### `POST /capture`
Input:
```json
{
  "chatId": "270997894",
  "turn": {
    "user_message": "...",
    "assistant_response": "...",
    "tool_calls": [...],
    "timestamp": "2026-04-20T14:23:10Z",
    "status": "completed"  // skip se "failed"
  }
}
```
Comportamento:
1. **Regola anti-pollution**: se `status !== "completed"`, skip (no save)
2. Append al `daily/YYYY-MM-DD.md` del chatId
3. Append a episodic ring buffer (mantieni ultimi 5)
4. Async job → estrai entità via Cognee `add()` (non bloccante)
5. Log in `audit.jsonl`

#### `POST /consolidate`
Input:
```json
{
  "chatId": "270997894",
  "scope": "daily" | "weekly" | "full",
  "dryRun": true
}
```
Esegue il ciclo autoDream (vedi § 2.3).

#### `GET /entities/:chatId`
Lista tutte le entità conosciute per una chat + count fatti.

#### `GET /stats`
Metriche: #turni indicizzati, #entità, size DB, ultime consolidazioni.

### 2.2 cognee-bridge (Python sidecar)

Cognee è Python-native. Lo wrappiamo via sidecar spawn-on-demand oppure daemon persistente.

**Decisione**: daemon persistente su porta 47475 (loopback). Spawn all'avvio del memory-service, kill alla shutdown. Evita startup cost per ogni richiesta.

Funzioni esposte (JSON-RPC over HTTP):
- `cognee.add(text, metadata)` → ingesta testo, costruisce graph + vector
- `cognee.search(query, top_k)` → hybrid search (vector + graph)
- `cognee.prune(rules)` → cleanup

### 2.3 autoDream — consolidation watcher

Nuovo watcher in `telegram-bridge/watchers.json`:

```json
{
  "id": "memory-consolidate",
  "interval_seconds": 86400,
  "schedule_cron": "0 3 * * *",
  "browser_slot": null,
  "prompt": "..."
}
```

**Pipeline** (spawn Haiku, non Opus):
1. Leggi `daily/YYYY-MM-DD.md` dell'ultimo giorno per ogni chat attiva
2. Prompt Haiku:
   ```
   Analizza questi turni. Produci JSON con:
   - new_entities: {name, type, initial_facts[]}
   - updated_entities: {name, new_facts[], invalidated_facts[]}
   - contradictions_resolved: [{old, new, reason}]
   - tacit_updates: {user_preferences[], communication_style[]}
   - concepts_to_promote: []
   - decisions_logged: []
   Regole:
   - NON inventare. Usa solo testo esplicito dai turni.
   - Se contraddizione non risolvibile, lasciala marcata ⚠️.
   ```
3. Il worker applica i diff:
   - Scrive/aggiorna `entities/<name>.md`
   - Riscrive `tacit.md` (merge non-distruttivo)
   - Appende a `concepts/` e `decisions/`
   - Invalida nodi graph obsoleti (non cancella, set `valid_until`)
   - Notifica via Telegram diff summary (opzionale, dietro flag)
4. Lint: runs `lint.mjs` → 7 check integrità
5. Se qualsiasi check fallisce → rollback + alert

**Costo stimato per notte**: ~30-50k token Haiku = **$0.012-0.020/notte** = ~$6/anno.

### 2.4 lint.mjs — 7 check integrità

Ispirato a claude-memory-compiler. Prima del commit di ogni consolidation:
1. **Orphan check**: ogni entità referenziata in `connections/` esiste come file `entities/*.md`
2. **Dead link check**: tutti i link markdown puntano a file esistenti
3. **Duplicate entity**: no due file con stesso nome entità
4. **Schema frontmatter**: ogni file ha header YAML valido
5. **Contradiction flag**: nessun fatto contraddetto senza `⚠️` o `valid_until`
6. **Size cap**: nessun file >10KB (indice di bloat)
7. **Token budget**: index.md <3000 token totali

Se fallisce → exit 1, consolidation rollback automatico, log in `audit.jsonl`.

### 2.5 Modifiche al bridge

Due soli punti di integrazione in `bridge.js`:

#### Pre-turn (prima di spawnare Claude)
```javascript
const { retrieve } = require('./memory-client');
// ...
const mem = await retrieve({ chatId, message: userText, topK: 5 });
const systemPromptAug = buildPrompt({
  base: cfg.systemPrompt,
  memory: mem,
});
// passa systemPromptAug a claude.exe
```

#### Post-turn (dopo completion)
```javascript
const { capture } = require('./memory-client');
// ...
if (status === 'completed') {
  await capture({ chatId, turn: { user_message, assistant_response, tool_calls, timestamp, status } });
}
```

**Totale righe aggiunte al bridge: <30**. Nessuna modifica alla coda messaggi, sessioni, rate limit, watchers esistenti.

### 2.6 memory-client.js — wrapper HTTP

Piccolo modulo (~60 righe) che:
- Fa `fetch` al memory-service
- Circuit breaker: 3 fallimenti consecutivi → apre circuito per 60s, bridge prosegue senza memoria
- Timeout 500ms sul retrieve (hard limit)
- Logs in `bridge.log`

**Principio**: se memory-service è down, il bridge deve funzionare comunque.

---

## 3. Rollout phased

### Fase 0 — Prerequisiti (1h)
- [ ] Installare Cognee: `pip install cognee` in un venv dedicato `memory-service/.venv`
- [ ] Scelta Node: già presente
- [ ] Verificare porte libere 47474, 47475
- [ ] Creare scheletro cartella `memory-service/`
- [ ] Backup attuale `docs/memory/`

### Fase 1 — Shadow mode (2-3h)
Obiettivo: sistema gira ma non influenza le risposte, solo raccoglie dati.
- [ ] Stand-up `memory-service/server.js` con endpoint `/capture` + `/stats`
- [ ] Spawn cognee-bridge daemon
- [ ] Hook POST-turn nel bridge → `capture` (fire-and-forget, log error)
- [ ] Seed iniziale: ingestare i transcripts JSONL esistenti via script one-shot
- [ ] Panel port 7777: aggiungere pagina `/memory` con contatori + preview

**Validazione**: dopo 3 giorni di traffico reale, verificare:
- Graph Cognee ha entità sensate (Leo, Tommy, bridge.js, ecc.)
- Nessun crash, nessun memory leak processo
- Audit log pulito

### Fase 2 — Identity + Tacit (1h)
- [ ] Scrivere `soul.md` iniziale (identità dell'agente, tono, regole)
- [ ] Per ogni chat attiva, seed di `tacit.md` da `docs/memory/context.md` + preferenze note
- [ ] Abilitare retrieval di T0+T1 nel pre-turn hook (bassissimo rischio — solo static text)

**Validazione**: risposte coerenti con identità/profilo, nessuna regressione.

### Fase 3 — Retrieval attivo (3-4h)
- [ ] Implementare `/retrieve` completo (T2+T3+T4)
- [ ] Attivare pre-turn hook che inietta ~1500 tok extra
- [ ] A/B test: alternare 1 turno con memory, 1 senza, loggare differenze qualitative per 1 settimana

**Gate**: se il token injection peggiora qualità percepita (hallucination, drift), rollback.

### Fase 4 — autoDream watcher (3h)
- [ ] Creare watcher `memory-consolidate`
- [ ] Prima esecuzione in **dryRun=true** — scrive il diff in file `pending-consolidation.md`, notifica Telegram, aspetta conferma umana
- [ ] Dopo 1 settimana di dry-run review, passare a auto-apply con rollback attivo
- [ ] Lint check integrato nel watcher

**Gate**: zero alert lint per 7 giorni consecutivi prima di rimuovere dry-run.

### Fase 5 — Cleanup + migrazione legacy (1-2h)
- [ ] Deprecare `docs/memory/memory.md` (resta read-only come archivio storico)
- [ ] Aggiornare `CLAUDE.md` con nuova struttura memoria
- [ ] Aggiornare `docs/memory/context.md` con link al nuovo sistema
- [ ] Aggiungere comando Telegram `/memory <query>` per query interattive

### Fase 6 — Osservabilità (1h)
- [ ] Dashboard panel `/memory`:
  - Entità top per chat
  - Growth graph daily
  - Token injection medio
  - Last consolidation diff
- [ ] Alert: graph Kuzu size >500MB, audit errors >10/giorno

**Totale stimato: 12-14h di lavoro concentrato**, spalmabile in 3-5 sessioni.

---

## 4. Policy di sicurezza e privacy

1. **Dati sensibili**: `chats/<chatId>/` non committare su git pubblico. Aggiungere `.gitignore` se non c'è.
2. **Backup cifrato**: script weekly che zippa `memory-service/` e lo cifra con `openssl enc -aes-256-cbc`.
3. **Audit immutabile**: `audit.jsonl` append-only, no overwrite, rotate a 100MB.
4. **Rate limit interno**: max 1 `/capture` per 2s per chatId (anti-flood).
5. **Sanitize input**: nessun command injection nei path file (validazione chatId regex `^\d+$`).
6. **Human-in-the-loop per modifiche tacit**: `tacit.md` updates richiedono conferma via `/memo_confirm` su Telegram la prima volta (rimovibile dopo trust build).

---

## 5. Criteri di successo (misurabili)

| Metrica | Target | Come misurare |
|---------|--------|---------------|
| Retrieval latency | <150ms p95 | Log bridge |
| Token injection per turno | <3500 | Log memory-service |
| Citazioni corrette senza prompt | >80% qualitativo | A/B test settimanale |
| Crash memory-service | 0 in 30gg | Uptime log |
| Consolidazioni rollback | <5% dei giorni | Audit log |
| Perceived continuity (user) | qualitativo: "si ricorda di cose" | Feedback diretto |
| Costo Haiku consolidation | <$1/mese | Log spesa |

Dopo 30 giorni di operatività stabile → considerare feature avanzate: multi-modal memory (immagini inviate), temporal query UI, export Obsidian vault.

---

## 6. Rischi e mitigazioni

| Rischio | Probabilità | Impatto | Mitigazione |
|---------|-------------|---------|-------------|
| Cognee subprocess leak (simile ChromaDB) | Media | Alto | Watchdog processo, auto-kill se >2GB RAM |
| autoDream scrive contraddizioni | Media | Medio | Dry-run + lint pre-apply, rollback trivial |
| Python sidecar crash Windows | Media | Medio | Health check ogni 60s, restart auto, circuit breaker |
| Token injection peggiora qualità | Bassa | Alto | A/B test gate prima di fase 3 full |
| Graph esplode in dimensione | Media | Basso | Prune trimestrale + size cap |
| Perdita dati consolidation | Bassa | Alto | Append-only + backup cifrato weekly |
| Circular hook (KAIROS-like 2^N) | Molto bassa | Critico | Circuit breaker hard-coded su hook, max 10 call/min |
| Privacy leak | Bassa | Critico | Gitignore, no cloud, cifratura backup |

---

## 7. Alternative scartate (per completezza)

- **claude-mem drop-in**: scartato perché ChromaDB leak su Windows + orientato a coding session, non chat Telegram.
- **Mem0 Cloud**: scartato per privacy e lock-in.
- **Letta runtime**: scartato perché richiede di riscrivere il flusso spawn-claude.
- **Zep/Graphiti**: scartato perché Neo4j/FalkorDB overhead non giustificato.
- **Pure markdown senza DB**: scartato perché perde graph queries e fuzzy retrieval. Tenuto però per T0/T1.
- **Solo SQLite FTS**: scartato perché nessun vector semantic. Cognee lo include comunque come layer.

---

## 8. Prossimi passi immediati

**Per iniziare**:
1. Conferma che questo approccio ti convince (o elenca modifiche desiderate)
2. Stabilire ordine priorità: `shadow mode` prima (raccoglie dati zero-rischio) o `identity layer` prima (quick win visibile)?
3. Decidere su dry-run di autoDream: vuoi review manuale dei diff via Telegram le prime settimane o full-auto da subito?

**Il primo PR concreto sarà**:
- Creazione scheletro `memory-service/`
- `server.js` con endpoint `/stats` + `/capture` in shadow mode
- `memory-client.js` nel bridge con hook POST-turn
- Migration script one-shot che ingesta i JSONL esistenti

Stima tempo fino al primo ingest funzionante: **~3 ore di lavoro concentrato**.

---

## 9. Riferimenti

Ritrovamenti completi: `./findings.md`.

Key papers da rileggere se emergono dubbi tecnici:
- MemGPT (tier management): arXiv 2310.08560
- Zep (temporal graph): arXiv 2501.13956
- Mem0 (extraction pipeline): arXiv 2504.19413
- MemMachine (ground-truth preservation): arXiv 2604.04853
