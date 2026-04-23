# Memory Upgrade — Piano v3 (ibrido Memory Tool + layer custom)

> Revisione di `plan-v2.md` dopo validazione tecnica e riconsiderazione dello scope reale.
> v1 e v2 restano intatti come storico. Il delta è radicale: **cambia il paradigma, non i dettagli**.
>
> Leggere prima: `findings.md` + `dialogue.md` + `plan-v2.md` + questa intro.

---

## 0. Obiettivi e scope rivisti

### 0.1 Scope reale (cambiato da v2)

Il bridge Telegram **non è un progetto di nicchia per debug del bridge stesso**. È l'interfaccia unica verso Claude per **qualsiasi** task:
- Development, debug, refactor (codice)
- Ricerca, scrittura, analisi (contenuti)
- Automazione, browser, scheduling (operativo)
- Assistenza personale 24/7 (generalista)

Pattern di riferimento: **OpenClaw** / **secure-openclaw** (ComposioHQ). Telegram diventa il front-end di un agente AI full-tool persistente.

### 0.2 Obiettivi

1. **Continuità nativa** — Claude ricorda tra sessioni senza setup manuale
2. **Self-improvement misurabile** — l'agente diventa progressivamente più capace nei task ricorrenti (skills file)
3. **Provenance auditabile** — ogni fatto scritto in memoria ha fonte dichiarata
4. **Zero lock-in architetturale** — se il Memory Tool cambia, il layer sopra resta
5. **Bassissima manutenzione** — < 15 min/mese a regime
6. **Leggibilità totale** — ogni memoria è markdown, grep-friendly, git-friendly
7. **Compatibilità Windows nativa** — zero Python, zero binding C++ fragili

### 0.3 Non-obiettivi (deliberati, tagli da v2)

- ❌ Entity graph DB (T4 di v2) — Kuzu è archiviato (2025-10-10). Cross-reference via markdown basta
- ❌ Attitude Ledger / Beliefs (T6 di v2) — dead code per N=1 utente
- ❌ LRS omeostatico con auto-tune — metrica inventata senza significato operativo
- ❌ turn_risk_score formula — non specificato in v2, sostituito da heuristics esplicite
- ❌ memory-audit settimanale — feedback loop utente insostenibile
- ❌ Stenografo sync separato dal capture — ridondanza
- ❌ Seed one-shot via embedding locale CPU — posticipato (LanceDB ha embedding built-in)

---

## 1. Architettura target v3

### 1.1 Principio fondante

**Claude gestisce la sua memoria nativamente via Memory Tool API di Anthropic. Il bridge aggiunge solo 3 guardrail sottili: provenance, auto-capture, consolidation notturno.**

Differenza chiave vs v2:
- **v2**: costruisci un cervello esterno che sostituisce il pensiero di Claude sulla memoria (retrieval via prompt injection di ~3100 tok)
- **v3**: Claude interroga la sua memoria via tool call durante il ragionamento (lazy retrieval, zero token se non serve)

### 1.2 Overview (ASCII, Telegram-safe)

```
USER (Telegram)
   ↓
BRIDGE.JS
   │
   ├─→ Memory Tool executor       ← esegue le 6 ops che Claude richiede
   │   └─ provenance interceptor  ← appende frontmatter YAML a ogni write
   │
   └─→ Auto-capture hook          ← appende ogni turno raw a daily/
       ↓
MEMORY/ (filesystem markdown)
   ├── memories/<chatId>/
   │   ├── identity.md            ← T0 manuale (chi sono)
   │   ├── tacit.md               ← preferenze user (auto)
   │   ├── entities/              ← leo.md, tommy.md, bridge.md, ...
   │   ├── skills/                ← procedure self-scritte (self-improvement)
   │   ├── daily/YYYY-MM-DD.md    ← auto-capture raw turn
   │   └── lessons.md             ← Riflettore notturno
   │
   └── index/ (LanceDB)           ← indice semantico secondario (opzionale)
       ↑
RIFLETTORE HAIKU (watcher memory-reflect, cron 03:00)
   • legge daily/ ultimi 7gg
   • aggiorna entities/, skills/, lessons.md
   • deduplica e compatta
   • re-indicizza LanceDB
```

### 1.3 Memory Tool nativo

Schema API:
```json
{
  "tools": [{
    "type": "memory_20250818",
    "name": "memory"
  }]
}
```

Sei operazioni:
- `view` — listing directory o content file (con line numbers)
- `create` — nuovo file
- `str_replace` — sostituzione testuale atomica
- `insert` — append a linea specifica
- `delete` — rimuove file o dir
- `rename` — sposta/rinomina

**Claude-side**: Anthropic inietta system prompt automatico che dice a Claude di consultare `/memories` prima di iniziare task, registrare progress durante, assumere interruzione.

**Bridge-side**: implementa executor client-side delle 6 ops con path sanitization.

### 1.4 Struttura filesystem finale

```
Harness/
├── memory-upgrade/
│   ├── findings.md
│   ├── plan.md          ← v1, storico
│   ├── plan-v2.md       ← v2, storico
│   ├── plan-v3.md       ← questo file
│   ├── TASK_PLAN.md     ← operativo per v2 (obsoleto)
│   └── TASK_PLAN_v3.md  ← operativo per v3
├── docs/memory/          ← legacy: context.md + memory.md (archive)
├── memories/             ← NUOVO, root Memory Tool
│   └── <chatId>/
│       ├── identity.md
│       ├── tacit.md
│       ├── entities/
│       ├── skills/
│       ├── daily/
│       └── lessons.md
├── memory-service/       ← NUOVO, leggero
│   ├── executor.js       (implementa 6 ops Memory Tool)
│   ├── provenance.js     (intercept write → frontmatter YAML)
│   ├── capture.js        (auto-capture raw turn)
│   ├── reflector.js      (Riflettore watcher)
│   ├── lance-index.js    (indice semantico opzionale)
│   └── utils/
│       ├── path-guard.js (anti path-traversal)
│       └── lint.js       (5 check leggeri)
└── telegram-bridge/
    ├── bridge.js         (+ Memory Tool integration)
    ├── memory-client.js  (wrapper, <100 righe)
    └── watchers.json     (1 watcher: memory-reflect)
```

---

## 2. Componenti in dettaglio

### 2.1 Memory Tool executor (memory-service/executor.js)

Implementa le 6 operazioni client-side seguendo lo spec Anthropic esatto.

```javascript
// Pseudocodice schematico
async function executeMemoryOp(chatId, command, params) {
  const basePath = `memories/${chatId}`;
  const safePath = validatePath(params.path, basePath); // anti-traversal

  switch (command) {
    case 'view': return viewOp(safePath, params.view_range);
    case 'create': return createOp(safePath, params.file_text);
    case 'str_replace': return strReplaceOp(safePath, params.old_str, params.new_str);
    case 'insert': return insertOp(safePath, params.insert_line, params.insert_text);
    case 'delete': return deleteOp(safePath);
    case 'rename': return renameOp(safePath, params.new_path);
  }
}
```

**Path sanitization obbligatoria** (da Anthropic security docs):
- Ogni path deve iniziare con `/memories/<chatId>`
- Resolve canonical + check `relative_to()` equivalente
- Reject `../`, URL-encoded `%2e%2e`, e tutte le sequenze traversal
- Max file size configurabile (default 50KB)
- Max line per view (default 10000)

**Return format esatto** come da spec Anthropic:
- Directory: `"Here're the files and directories up to 2 levels deep in {path}..."`
- File con line numbers: `"Here's the content of {path} with line numbers:\n     1\t..."`
- Success/error messages letterali (Claude è stato fine-tuned su questi)

### 2.2 Provenance layer (memory-service/provenance.js)

Intercetta ogni `create` e `str_replace` di Claude. Prima di scrivere:
1. Legge il file nuovo/modificato
2. Se è un file in `entities/`, `skills/`, o `lessons.md` (files long-lived), verifica presenza frontmatter YAML
3. Se manca o è malformato, appende/ripara:

```yaml
---
last_updated: 2026-04-20T14:23:00Z
last_turn_id: t-2026-04-20-1423
source_type: bot_learned         # o: user_stated, user_lived, external
confidence: 0.8
updates_count: 3
---
```

**NON** è Zod forzato API-level come v2 (che rifiutava 400 se mancava). È **riparazione soft** — se Claude dimentica la provenance, il layer la aggiunge deterministicamente.

Motivo: forzare a 400 confonde Claude. Meglio appender dietro.

**Source type classification**:
- File creato subito dopo un `"ti ho detto"`, `"ti avevo detto"` → `user_stated`
- File creato dopo `"ho fatto"`, `"ieri"`, `"stamattina"` → `user_lived`
- File riscritto dal Riflettore notturno → `bot_learned`
- File inizializzato manuale (es. `identity.md`) → `manual`
- File da link/allegato → `external`

Classificatore basato su regex italiane (vs v2 che aveva mix italiano/inglese).

### 2.3 Auto-capture (memory-service/capture.js)

Indipendente da cosa Claude sceglie di ricordare. Ogni turno completato (`status === 'completed'`), il bridge appende al file daily:

```markdown
## t-2026-04-20-1423 · 14:23

**User**: Come sta Leo?

**Assistant**: Leo è in slot1, ultima sessione attiva dalle 10:30...

**Tools used**: memory.view, browser.snapshot

---
```

Motivo: **rete di sicurezza**. Se Claude non ricorda qualcosa che dopo ti serve, il turno raw è lì. Riflettore notturno può estrarre retrospettivamente.

File rotation: un file per giorno, chiuso a mezzanotte. Dopo 30 giorni viene archiviato in `daily/archive/` (compressed se vuoi).

### 2.4 Riflettore notturno (memory-service/reflector.js + watcher)

Un solo watcher in `watchers.json`:
```json
{
  "id": "memory-reflect",
  "schedule_cron": "0 3 * * *",
  "browser_slot": null,
  "model": "claude-haiku-4-5-20251001",
  "prompt": "..."
}
```

Pipeline Riflettore:
1. Legge `daily/` ultimi 7 giorni (rolling window)
2. Legge stato corrente `entities/`, `skills/`, `lessons.md`
3. Chiede a Haiku output JSON strutturato:
   ```json
   {
     "entities_updates": [{"file": "leo.md", "diff": "..."}],
     "skills_new": [{"file": "browser-pattern-X.md", "content": "..."}],
     "lessons_append": ["pattern ricorrente: ..."],
     "tacit_updates": "..."
   }
   ```
4. Lint (5 check leggeri):
   - Ogni entry cita almeno un `turn_id` dal daily
   - Nessun file supera 10KB
   - Nessun overwrite distruttivo senza motivo
   - Frontmatter YAML presente dopo update
   - No duplicati entity name
5. Applica diff → filesystem
6. Re-indicizza LanceDB (se attivo)
7. Notifica Telegram con summary: "Applicate 3 updates a entities, 1 nuova skill, 2 lessons"

**Costo stimato**: ~30-50k tok Haiku/notte = **~$0.015/notte** = **~$5.50/anno**.

### 2.5 Skills evolution (il cuore del self-improvement)

`memories/<chatId>/skills/` è il posto dove Claude scrive **procedure ricorrenti**.

Esempio: dopo 3-4 volte che hai chiesto "apri browser, navigate a X, estrai Y", Claude (durante il ragionamento o tramite Riflettore) crea:

```markdown
---
source_type: bot_learned
confidence: 0.9
verified_times: 4
last_used: 2026-04-20
---

# Browser — estrazione dati da dashboard operative

Quando utente chiede "apri X e dimmi Y":
1. browser_lease (slot libero)
2. browser_navigate(URL memorizzato in entities/)
3. browser_wait_selector(selector pattern)
4. browser_text + parse
5. browser_release

Note:
- Se X = "calendar", usa slot1 (logged-in Google)
- Se X richiede login, controlla entities/logins.md
```

La volta successiva, Claude `view skills/browser-*.md` prima di riprovare da zero. Se la procedura funziona, `str_replace` per incrementare `verified_times`. Se fallisce, aggiorna.

**Questo è ciò che plan-v2 cercava di fare con T5 self-lessons**, ma fatto da Claude stesso invece che da un sistema metrico con turn_risk_score + situation_hash + clustering.

### 2.6 LanceDB index (opzionale, Fase 2)

Indice semantico **sopra** i markdown, non un sostituto.

Ogni markdown in `entities/`, `skills/`, `lessons.md` viene embedded (on write + on Riflettore run). Tabella LanceDB:
```
{
  id: file_path,
  chat_id: "...",
  content_hash: "...",
  embedding: [1536 floats],
  source_type: "...",
  last_updated: "..."
}
```

Esposto come **MCP tool custom** che Claude può chiamare: `memory.search("query")` → top-5 file paths. Poi Claude fa `view` normale.

**Motivo per posticiparlo a Fase 2**: nella Fase 1 vediamo se Claude se la cava col listing + naming convention + view. Molti casi si risolvono con nomi intuitivi (`leo.md`, `bridge-architecture.md`).

---

## 3. Bridge integration

### 3.1 Modifiche a `bridge.js` (~80 righe)

1. **Inclusione Memory Tool nelle API call**:
   ```javascript
   tools: [
     ...existingTools,
     { type: 'memory_20250818', name: 'memory' }
   ]
   ```
2. **Handler tool call memory**:
   ```javascript
   if (toolCall.name === 'memory') {
     const result = await memoryClient.execute(chatId, toolCall.input);
     // restituisci tool_result a Claude
   }
   ```
3. **Post-turn auto-capture**:
   ```javascript
   if (status === 'completed') {
     await memoryClient.captureRaw(chatId, turnId, userMsg, response, toolsUsed);
   }
   ```
4. **Provenance hook**: wrap del `create`/`str_replace` per iniettare frontmatter

### 3.2 `telegram-bridge/memory-client.js` (~100 righe)

Wrapper thin sopra memory-service endpoints. Funzioni:
- `execute(chatId, toolInput)` — esegue op e ritorna result stringa
- `captureRaw(chatId, turnId, user, assistant, tools)` — appende a daily
- `health()` — per watchdog

Circuit breaker: se memory-service è down, capture fallisce silenzioso, Memory Tool torna error a Claude ("memoria temporaneamente non disponibile"). Bridge **non crasha mai**.

---

## 4. Security

Da Anthropic docs + prassi:

1. **Path traversal protection** (CRITICO):
   - Whitelist: path deve iniziare con `/memories/<chatId>/`
   - Resolve canonical + check prefix
   - Reject sequences: `../`, `..\\`, `%2e%2e%2f`, null bytes
   - Usa `path.resolve()` + check manuale
2. **Size caps**:
   - File max 50KB (raise a 100KB via config se serve)
   - Directory view max 2 levels deep (default Anthropic)
   - view_range default max 10k lines
3. **Rate limit** sulle op Memory Tool: 10 op/sec per chatId (stop runaway)
4. **Chat isolation**: ogni chatId vede solo `memories/<suo-chatId>/`
5. **Sensitive info scrubbing**: prima di ogni write, check regex per:
   - API keys (`sk-`, `ghp_`, `xoxb-`)
   - Email passwords
   - File path con `.env`, `credentials`
   - Se match, warning a Telegram + blocca write
6. **Backup**: `memories/` in git-friendly format, backup settimanale su cloud cifrato (opzionale)
7. **Audit log**: append ogni op a `memory-service/audit.jsonl` (provenance + path + timestamp + source)

---

## 5. Criteri di successo

| Metrica | Target | Come misurare |
|---|---|---|
| Path traversal blocked | 100% | Test suite con 20 attack patterns |
| Memory Tool latency | <100ms p95 | Bench locale |
| Token injected (baseline) | 0 (lazy retrieval) | Bridge log |
| Memory Tool usage rate | >50% dei turni non-triviali | Bridge telemetry |
| Crash memory-service | 0/mese | Watchdog log |
| Tempo manutenzione | <15 min/mese | Self-report |
| Riflettore cost | <$1/mese | API bill |
| Skills accumulate | >10 entries dopo 2 mesi | `ls skills/` |

---

## 6. Rollout phased

### Fase 0 — Prep (30 min)
- [ ] Scheletro `memories/<chatId>/` con identity/tacit/daily iniziali
- [ ] Scheletro `memory-service/` con package.json
- [ ] Deps: `express`, `@anthropic-ai/sdk`, `yaml`, `better-sqlite3` (audit log), `chokidar`
- [ ] `.gitignore`: `memories/*/daily/`, `audit.jsonl`

**Gate 0**: `npm install` senza errori Windows.

### Fase 1 — Memory Tool core (2h)
- [ ] `executor.js` con 6 ops + path guard
- [ ] Test unit su tutte le 6 ops (happy path + edge cases)
- [ ] Test traversal: 20 attack patterns bloccati
- [ ] `memory-client.js` nel bridge
- [ ] Integrazione Memory Tool in API call bridge
- [ ] Smoke test manuale: chiedi a Claude via Telegram "ricorda che mi chiamo X", verifica creazione file

**Gate 1**: 3 giorni di uso, Memory Tool funziona, zero crash.

### Fase 2 — Provenance + Auto-capture (1.5h)
- [ ] `provenance.js` con classifier regex italiano
- [ ] Hook su create/str_replace per inject frontmatter
- [ ] `capture.js` per daily auto-capture
- [ ] Bridge post-turn hook
- [ ] Script seed: inizializza `identity.md` + `tacit.md` a partire da `docs/memory/context.md` + session memory

**Gate 2**: 1 settimana, daily files popolati, provenance presente su tutti i write auto.

### Fase 3 — Riflettore notturno (2h)
- [ ] Watcher `memory-reflect` in watchers.json
- [ ] `reflector.js` con prompt Haiku + JSON output parsing
- [ ] Lint 5 check
- [ ] Apply pipeline + notifica Telegram diff
- [ ] Dry-run 1 settimana (output solo in `pending-reflection.md`, no apply)

**Gate 3**: 7 notti dry-run, zero lint error, output semanticamente corretto. Poi enable apply.

### Fase 4 — LanceDB index (opzionale, 1.5h)
- [ ] Setup LanceDB embedded
- [ ] Indicizzazione incrementale on-write + batch su Riflettore
- [ ] Esposizione come MCP tool custom `memory.search`
- [ ] Claude può chiamarlo durante retrieval

**Gate 4**: solo se in Fase 1-3 noti che listing + view non basta.

### Fase 5 — Cleanup (30 min)
- [ ] Archivia `docs/memory/memory.md` (header "deprecated, vedi memories/")
- [ ] Aggiorna `CLAUDE.md` con nuova struttura
- [ ] Panel dashboard `/memory` per visualizzare filesystem + stats

**Totale**: ~7.5h (vs 17h di v2). Con gate cumulativi: 3 settimane calendar.

---

## 7. Decision points

1. **Se Memory Tool latency > 200ms**: audit executor, possibile cache LRU in-memory dei view frequenti
2. **Se Claude crea troppi file piccoli**: aggiungi istruzione system prompt "consolida file correlati"
3. **Se Riflettore produce output inconsistente**: prova Sonnet 4.6 invece di Haiku (4x costo, meno errori)
4. **Se dopo 3 mesi skills/ resta quasi vuota**: Claude non sta capendo il pattern — rivedi il system prompt del bridge o inizializza skills manualmente con 2-3 esempi

---

## 8. Rischi e mitigazioni

| Rischio | Probabilità | Mitigazione |
|---|---|---|
| Memory Tool API cambia in beta → GA | Media | Layer thin (~200 righe), rewrite in 2h |
| Anthropic restringe accesso come per OpenClaw | Bassa (tu paghi pay-per-token) | Continua a funzionare, solo "subscription plan" è toccato |
| Claude scrive file spazzatura | Media | Riflettore dedup + size cap + lint |
| Path traversal bug | Bassa se implementi bene | Test suite 20 patterns + review externa |
| File sensibili leakati in memory | Media | Sensitive scrubber regex + audit review mensile |
| LanceDB su Windows rotto | Bassa (validato vivo) | Skip Fase 4, tieni naming + listing |
| Manutenzione Riflettore esplode | Bassa | Prompt blindato + lint 5 check + alert se > 5 error/settimana |

---

## 9. Differenze v2 → v3 (riferimento rapido)

| Area | v2 | v3 |
|---|---|---|
| Runtime | Node + embedding locale CPU | Node puro, embedding via LanceDB on-demand |
| Tier count | 7 | 4 funzionali (identity, tacit, entities+skills, daily) + lessons |
| Core storage | Kuzu (morto) + LanceDB + Markdown | Markdown + LanceDB (opzionale) |
| Retrieval | Prompt injection ~3100 tok ogni turno | Memory Tool tool call lazy |
| Capture API | `/capture` custom con Zod 400 | Memory Tool executor + auto-capture |
| Consolidation | Dual sleeper (Stenografo + Riflettore) | Single Riflettore |
| Provenance | Zod forzata API-level | Frontmatter YAML soft |
| Pushback/Beliefs | T6 custom | ❌ rimosso |
| Self-learning | T5 episodes + lessons | skills/ + lessons.md (Claude-maintained) |
| Metric | LRS omeostatico + memory-audit | Metriche elementari + ispezione manuale |
| Bridge delta righe | ~80 | ~80 (simile, ma ops diverse) |
| Ore dev | 17h | 7.5h |
| Ore wait gate | ~5 settimane | ~3 settimane |
| Lock-in | Nessuno (custom) | Medio (Memory Tool API beta) |

---

## 10. Filosofia v3

Plan-v2 partiva da una domanda: *"come replico la memoria umana in un sistema custom?"*

Plan-v3 parte da un'altra: *"Claude è già stato fine-tuned per usare una memoria. Come gli fornisco l'infrastruttura pulita per farlo, aggiungendo solo audit e resilienza?"*

Il primo approccio è **interventista** — scelgo io cosa Claude deve ricordare, come, quando.
Il secondo è **minimalista** — fornisco il terreno, Claude coltiva, io tengo il registro.

Per un assistente generalista personale (scope OpenClaw-like), il secondo approccio vince perché:
1. Claude sa meglio di me quando una lesson è utile
2. La qualità della memoria migliora gratis con Claude 5, 6, N
3. Meno pezzi = meno bug = più uptime
4. Markdown = debug con cat/grep, non con query engine binario
5. Provenance come frontmatter = git-blame equivalente

---

## 11. Riferimenti

- `findings.md` — ricerca stato dell'arte originale
- `plan-v2.md` — piano precedente (ambizioso, parzialmente morto)
- `dialogue.md` — 7 leggi architetturali emerse dalla co-ricerca
- `TASK_PLAN_v3.md` — breakdown operativo di questo piano
- [Anthropic Memory Tool docs](https://platform.claude.com/docs/en/agents-and-tools/tool-use/memory-tool) — spec ufficiale
- [secure-openclaw](https://github.com/ComposioHQ/secure-openclaw) — pattern reference per personal agent via messaging
- [Effective harnesses for long-running agents](https://www.anthropic.com/engineering/effective-harnesses-for-long-running-agents) — Anthropic engineering
