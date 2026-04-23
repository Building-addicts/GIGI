# Memory Upgrade — Task Plan v3

> Breakdown operativo di `plan-v3.md` in task concreti.
> Totale: **~7.5h** di lavoro concentrato + **~3 settimane** calendar con gate di validazione.
> Ordine: rispetta dipendenze.
>
> Convenzioni:
> - `[ ]` = da fare
> - `[x]` = fatto
> - `[~]` = in corso
> - `⚠` = gate, non proseguire se non superato
> - `(X min)` = stima in minuti

---

## Fase 0 — Prep (30 min)

### 0.1 Scheletro filesystem
- [ ] `mkdir -p memories/270997894/{entities,skills,daily}` (2)
- [ ] `touch memories/270997894/{identity.md,tacit.md,lessons.md}` (1)
- [ ] `mkdir -p memory-service/{utils,prompts}` (2)
- [ ] `touch memory-service/{executor.js,provenance.js,capture.js,reflector.js,audit.jsonl}` (2)
- [ ] `touch memory-service/utils/{path-guard.js,lint.js}` (1)

### 0.2 Package setup
- [ ] `cd memory-service && npm init -y` (1)
- [ ] `npm i express @anthropic-ai/sdk yaml better-sqlite3 chokidar` (5)
- [ ] Verifica install Windows senza build errors (2)
- [ ] (Fase 4) `npm i @lancedb/lancedb` — solo se arrivi a Fase 4

### 0.3 Gitignore
- [ ] Aggiungi a `.gitignore`:
  ```
  memories/*/daily/
  memory-service/audit.jsonl
  memory-service/storage/
  probe-kuzu/
  ```
  (2)

### 0.4 Backup defensivo
- [ ] Copia `docs/memory/` → `docs/memory.backup-pre-v3/` (2)
- [ ] Backup `telegram-bridge/logs/transcripts/` zippato (2)

**⚠ Gate 0**: `node -e "require('@anthropic-ai/sdk'); require('yaml')"` gira senza errori.

---

## Fase 1 — Memory Tool core (2h)

### 1.1 Path guard (`utils/path-guard.js`) — 20 min
- [ ] Funzione `validatePath(userPath, chatId)`:
  - [ ] Deve iniziare con `/memories/<chatId>/`
  - [ ] Resolve canonical via `path.resolve()`
  - [ ] Check `canonical.startsWith(baseDir)` dopo resolve
  - [ ] Reject patterns: `../`, `..\\`, `%2e%2e`, null bytes, URL-encoded
  - [ ] Return path assoluto safe o throw `PathTraversalError`
- [ ] Test suite con 20 attack patterns:
  ```
  /memories/1/../../etc/passwd
  /memories/1/%2e%2e/secret
  //memories/1/file
  /memories/\x00/file
  ... (vedi OWASP path traversal cheatsheet)
  ```

### 1.2 Executor 6 ops (`executor.js`) — 60 min
Implementa ogni op secondo spec Anthropic esatta (return strings letterali).

- [ ] `viewOp(path, range)`:
  - [ ] Se directory: listing "up to 2 levels deep", skip hidden + node_modules, size in formato `5.5K` `1.2M`
  - [ ] Se file: return con header `"Here's the content of {path} with line numbers:"` + line numbers 6-char right-aligned + tab
  - [ ] Error: `"The path {path} does not exist."`
- [ ] `createOp(path, file_text)`:
  - [ ] Crea file, mkdir ricorsivo se serve
  - [ ] Error se esiste già: `"Error: File {path} already exists"`
  - [ ] Success: `"File created successfully at: {path}"`
- [ ] `strReplaceOp(path, old_str, new_str)`:
  - [ ] Verifica file esiste + non è dir
  - [ ] Error se `old_str` non trovato: formato esatto
  - [ ] Error se occorrenze multiple: elenca line_numbers
  - [ ] Success: `"The memory file has been edited."` + snippet con line numbers
- [ ] `insertOp(path, insert_line, insert_text)`:
  - [ ] Valida `insert_line` in `[0, n_lines]`
  - [ ] Success: `"The file {path} has been edited."`
- [ ] `deleteOp(path)`:
  - [ ] Rimozione ricorsiva se directory
  - [ ] Success: `"Successfully deleted {path}"`
- [ ] `renameOp(old_path, new_path)`:
  - [ ] Entrambi validati
  - [ ] Error se destination esiste
  - [ ] Success: `"Successfully renamed {old_path} to {new_path}"`

### 1.3 Test unit — 15 min
- [ ] Happy path: 6 ops base funzionano
- [ ] Edge cases: file non esistente, path vuoto, line fuori range
- [ ] Stress: file 10KB, directory con 100 file

### 1.4 memory-client (telegram-bridge) — 15 min
- [ ] `telegram-bridge/memory-client.js`:
  - [ ] `execute(chatId, toolInput)` — wrapper che chiama executor, wraps errors, timeout 2s
  - [ ] Circuit breaker: dopo 3 fail consecutivi, return `"Memory temporarily unavailable"` senza crashare bridge

### 1.5 Bridge integration — 10 min
- [ ] `bridge.js`:
  - [ ] Aggiungi `{ type: 'memory_20250818', name: 'memory' }` alla lista tools
  - [ ] Handler nel tool call loop: se `tool_name === 'memory'`, call `memoryClient.execute()`
  - [ ] Log ogni op a `logs/bridge.log` con chatId + command + path

### 1.6 Smoke test manuale — 10 min
- [ ] Via Telegram: "Ricorda che mi chiamo Arman e che uso Windows 11"
- [ ] Verifica: file creato in `memories/270997894/identity.md` (o simile scelto da Claude)
- [ ] Nuovo turno: "Come mi chiamo?"
- [ ] Verifica: Claude fa `view` su identity o directory, legge, risponde

**⚠ Gate 1**: 3 giorni di uso reale
- [ ] Memory Tool usato spontaneamente in almeno 10 turni
- [ ] Zero crash bridge
- [ ] Zero path traversal attempt loggato (se ci sono, review security)
- [ ] File filesystem popolati in modo coerente

---

## Fase 2 — Provenance + Auto-capture (1.5h)

### 2.1 Provenance classifier (`provenance.js`) — 30 min
- [ ] Funzione `classifySource(userText, context)`:
  - [ ] `/\b(ti ho detto|ti avevo detto|come ti ho accennato)\b/i` → `user_stated`
  - [ ] `/\b(ho fatto|ieri|stamattina|l'altro giorno|sono andato|ho visto)\b/i` → `user_lived`
  - [ ] `/\b(mi ha detto|ha detto che|secondo (lui|lei))\b/i` → `user_quoted_other`
  - [ ] Riflettore output → `bot_learned`
  - [ ] Init manuale → `manual`
  - [ ] Fallback → `bot_inferred`

### 2.2 Frontmatter injector — 30 min
- [ ] Wrap `createOp` e `strReplaceOp`:
  - [ ] Se path in `entities/`, `skills/`, o `lessons.md`:
    - [ ] Parse content YAML frontmatter (se presente)
    - [ ] Update: `last_updated`, `last_turn_id`, `updates_count++`
    - [ ] Se assente: aggiungi frontmatter con `source_type` classificato
  - [ ] File in `daily/` NON richiedono frontmatter (auto-capture raw)
  - [ ] Identity/tacit richiedono frontmatter `manual` inizialmente

### 2.3 Auto-capture (`capture.js`) — 20 min
- [ ] Funzione `captureRaw(chatId, turnId, userMsg, assistantResp, toolsUsed)`:
  - [ ] Path: `memories/<chatId>/daily/YYYY-MM-DD.md`
  - [ ] Append sezione:
    ```markdown
    ## t-<id> · HH:MM

    **User**: {userMsg}

    **Assistant**: {assistantResp}

    **Tools used**: {toolsUsed joined}

    ---
    ```
  - [ ] Usa file lock per evitare race con Memory Tool ops

### 2.4 Bridge post-turn hook — 10 min
- [ ] `bridge.js`:
  - [ ] Dopo `status === 'completed'`, chiama `memoryClient.captureRaw()`
  - [ ] Fire-and-forget con timeout 500ms

### 2.5 Seed iniziale — 20 min
- [ ] Script one-shot `memory-service/scripts/seed-identity.js`:
  - [ ] Legge `docs/memory/context.md` + `C:/Users/arman/.claude/projects/.../memory/session_*.md`
  - [ ] Genera `memories/270997894/identity.md` iniziale (soul, regole operative)
  - [ ] Genera `memories/270997894/tacit.md` (preferenze note)
  - [ ] Frontmatter `source_type: manual`
- [ ] Esegui una sola volta

**⚠ Gate 2**: 1 settimana di uso
- [ ] `daily/*.md` si riempiono linearmente (1 file/giorno)
- [ ] Ogni write di Claude in `entities/` o `skills/` ha frontmatter valido
- [ ] Zero file di Claude rifiutati (il layer ripara, non blocca)

---

## Fase 3 — Riflettore notturno (2h)

### 3.1 Watcher config — 5 min
- [ ] Aggiungi a `telegram-bridge/watchers.json`:
  ```json
  {
    "id": "memory-reflect",
    "schedule_cron": "0 3 * * *",
    "browser_slot": null,
    "model": "claude-haiku-4-5-20251001",
    "prompt_file": "memory-service/prompts/reflector.txt"
  }
  ```
- [ ] Hot-reload via `POST /api/watchers/memory-reflect/toggle` su panel 7777

### 3.2 Prompt Riflettore — 30 min
- [ ] `memory-service/prompts/reflector.txt`:
  - [ ] Input structure: daily files ultimi 7gg + entities/skills/lessons correnti
  - [ ] Output JSON strutturato (schema esplicito in prompt)
  - [ ] Regole hard-coded:
    - Non inventare fatti
    - Cita turn_id da daily
    - Marca contraddizioni con `⚠`
    - Max 10KB per file
    - Promuovi skill solo se visto ≥3 volte con outcome positivo
    - Dedup aggressivo

### 3.3 Pipeline `reflector.js` — 40 min
- [ ] `runReflection(chatId)`:
  - [ ] Carica daily ultimi 7gg
  - [ ] Carica stato corrente entities/skills/lessons
  - [ ] Chiama Anthropic API con prompt + contesto + tools opzionali
  - [ ] Parse JSON output (zod validation)
  - [ ] Applica lint (§ 3.4)
  - [ ] Se tutto ok: scrivi diff su `memories/<chatId>/pending-reflection-<date>.md` (dry-run) O applica direttamente (post-validation)
  - [ ] Log risultato in `audit.jsonl`
  - [ ] Notifica Telegram con summary

### 3.4 Lint 5 check (`utils/lint.js`) — 20 min
- [ ] `check1_turnId`: ogni entry cita ≥1 turn_id esistente in daily
- [ ] `check2_size`: nessun file > 10KB
- [ ] `check3_frontmatter`: tutti gli aggiornamenti hanno frontmatter valido
- [ ] `check4_dupEntity`: no entity con nome duplicato
- [ ] `check5_noOverwrite`: no str_replace totale di un file (solo sezioni)

### 3.5 Dry-run 7 giorni — tempo calendario
- [ ] Flag `reflector.dry_run = true`
- [ ] Per 7 notti, output va in `pending-reflection-YYYY-MM-DD.md`
- [ ] Ogni mattina review manuale (lettura rapida + approva/reject)
- [ ] Misura: zero lint error in 7/7 notti?

**⚠ Gate 3**:
- [ ] 7 notti dry-run senza lint error
- [ ] Output semanticamente coerente (controllo manuale)
- [ ] Costo Haiku < $0.03/notte (da misurare)
- [ ] Tempo esecuzione < 3 min/notte

### 3.6 Go-live — 5 min
- [ ] Flag `reflector.dry_run = false`
- [ ] Auto-apply con rollback se lint fallisce
- [ ] Notifica Telegram summary ogni notte

---

## Fase 4 — LanceDB index (OPZIONALE, 1.5h)

**Salta questa fase** se in Fase 1-3 vedi che listing + naming intuitivo basta. Altrimenti:

### 4.1 Setup LanceDB
- [ ] `npm i @lancedb/lancedb`
- [ ] Init in `memory-service/storage/lance/`
- [ ] Schema tabella `memory_chunks`: `{id, chat_id, path, content_hash, embedding, source_type, last_updated}`

### 4.2 Indicizzazione
- [ ] Hook on-write: dopo ogni `create`/`str_replace` in entities/skills/lessons, calcola embedding via LanceDB embedding function (built-in ora, no Xenova)
- [ ] Batch re-index nel Riflettore notturno
- [ ] Cleanup: delete chunks per file non più esistenti

### 4.3 Custom MCP tool `memory.search`
- [ ] Esponilo nel bridge come tool custom
- [ ] Input: `query` string, `top_k` default 5
- [ ] Output: lista paths + score
- [ ] Claude può chiamarlo e poi `memory.view` sui result

**⚠ Gate 4**: Claude usa `memory.search` in almeno 20% dei turni (altrimenti non vale manutenzione).

---

## Fase 5 — Cleanup + observability (30 min)

### 5.1 Archivia legacy
- [ ] Prepend header a `docs/memory/memory.md`:
  ```
  > ⚠ DEPRECATED dal 2026-MM-DD. Memoria ora in `memories/<chatId>/`.
  > Questo file è read-only per riferimento storico.
  ```
- [ ] `docs/memory/context.md` resta (è manuale, diverso scope)
- [ ] Aggiorna `CLAUDE.md` (Harness root) con nuova sezione memoria

### 5.2 Comando Telegram `/memory`
- [ ] `/memory` senza args → summary: file count, size totale, ultima reflection
- [ ] `/memory tree` → printtree di `memories/<chatId>/`
- [ ] `/memory view <path>` → Claude fa `view` e risponde
- [ ] `/memory search <query>` (Fase 4) → top 5

### 5.3 Panel dashboard (opzionale)
- [ ] Pagina `/memory` in `panel.js`:
  - [ ] Tree view filesystem
  - [ ] Audit log tail
  - [ ] Stats: total ops/giorno, Memory Tool usage rate
  - [ ] Last reflection summary
- [ ] Refresh 30s

### 5.4 Alert
- [ ] Watchdog memory-service via `/health`
- [ ] Alert Telegram se:
  - 3x `/health` fail → "memory-service down"
  - Audit log error > 10/giorno → "review ops"
  - Reflector lint fail 2 notti consecutive → "check pending-reflection"

---

## Riepilogo ore

| Fase | Ore | Cumul. |
|---|---|---|
| 0 Prep | 0.5 | 0.5 |
| 1 Memory Tool core | 2.0 | 2.5 |
| 2 Provenance + capture | 1.5 | 4.0 |
| 3 Riflettore | 2.0 | 6.0 |
| 4 LanceDB (opz.) | 1.5 | 7.5 |
| 5 Cleanup | 0.5 | 8.0 |

**Senza Fase 4**: 6.5h.
**Con Fase 4**: 8h.

Calendar time con gate: **~3 settimane**.

---

## Sessioni consigliate

- **Sessione 1** (2.5h): Fase 0 + Fase 1. Smoke test → lascia 3gg validate
- **Sessione 2** (1.5h): Fase 2 + seed. → 1 settimana validate
- **Sessione 3** (2h): Fase 3 dry-run setup. → 7 notti dry-run
- **Sessione 4** (0.5h): Fase 3 go-live + review
- **Sessione 5** (0.5-2h): Fase 5 cleanup + opzionale Fase 4

**Totale sessioni**: 4-5 da 30-150 min ciascuna.

---

## Decision points durante il percorso

1. **Dopo Fase 1**: Claude usa Memory Tool spontaneamente? Se no → rivedi system prompt (verifica che Anthropic auto-inject sia attivo, o aggiungilo manualmente)
2. **Dopo Fase 2**: provenance classifier sbaglia > 20%? → rivedi regex italiane o usa classifier LLM (Haiku)
3. **Dopo Fase 3 dry-run**: Riflettore produce nonsense? → downgrade a Sonnet (costo 4x ma output migliore), rivedi prompt
4. **Dopo 1 mese uso**: skills/ vuota? → inizializza manualmente 3-5 skills da conversazioni passate

---

## File correlati

- `plan-v3.md` — piano completo
- `plan-v2.md` — piano precedente (storico)
- `findings.md` — ricerca stato dell'arte
- `dialogue.md` — 7 leggi architetturali
- `TASK_PLAN.md` — breakdown v2 (obsoleto)
