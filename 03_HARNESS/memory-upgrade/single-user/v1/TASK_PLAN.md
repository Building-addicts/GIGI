# Memory Upgrade — Task Plan (plan-v2)

> Breakdown operativo delle 7 fasi di `plan-v2.md` in task concreti, checkable.
> Ordine: rispetta le dipendenze — non saltare fasi.
> Stima totale: **~17 ore** di lavoro concentrato, spalmabili in 5-6 sessioni.
>
> Convenzione:
> - `[ ]` = da fare
> - `[x]` = fatto
> - `[~]` = in corso / parziale
> - `⚠` = gate di validazione, non proseguire se non superato
> - Stima tra parentesi = tempo in minuti

---

## Fase 0 — Prerequisiti (1h)

Setup ambiente, zero rischi. Fare in una sola sessione.

### 0.1 Scheletro cartella
- [ ] `mkdir -p memory-service/{identity,self,beliefs,chats,storage/lance,storage/kuzu}` (5)
- [ ] `touch memory-service/{server.js,package.json,lint.mjs,audit.jsonl}` (2)
- [ ] `touch memory-service/identity/soul.md` (1)
- [ ] `touch memory-service/self/{episodes.jsonl,lessons.md}` (1)
- [ ] `touch memory-service/beliefs/{agent_beliefs.json,user_positions.json,conflict_log.json}` — init con `{"beliefs":[]}` dove JSON (3)

### 0.2 Backup difensivo
- [ ] Copia `docs/memory/` → `docs/memory.backup-pre-v2/` (2)
- [ ] Dump `telegram-bridge/logs/transcripts/` cifrato (zip + password) come snapshot (5)

### 0.3 Dipendenze Node
- [ ] `cd memory-service && npm init -y` (1)
- [ ] Installare: `npm i kuzu @lancedb/lancedb better-sqlite3 zod @xenova/transformers express` (10)
- [ ] Verificare che `kuzu` si installi su Windows senza build error (se fallisce → fallback: `nodejs-duckdb` + FTS, annotare deviazione)
- [ ] Scaricare modello embedding: script che fa `pipeline('feature-extraction', 'nomic-ai/nomic-embed-text-v1.5')` una volta, ~130MB (5)

### 0.4 Porte e lock
- [ ] Verificare porta 47474 libera: `netstat -ano | findstr 47474` deve tornare vuoto (2)
- [ ] Schema lock file anti-istanza duplicata (come `panel.js`): `memory-service/.lock` (5)

**⚠ Gate 0**: `node -e "require('kuzu'); require('@lancedb/lancedb')"` gira senza errori. Se fallisce → risolvere prima di proseguire.

---

## Fase 1 — Shadow mode + Stenografo (2h)

Sistema scrive ma non influenza risposte. Rischio zero sulla UX.

### 1.1 Server HTTP base
- [ ] `server.js`: Express su 47474, middleware JSON, lock file check (15)
- [ ] Endpoint `GET /stats` → `{ status, uptime, chats, episodes_count, beliefs_count }` (10)
- [ ] Endpoint `GET /health` → `{ ok: true }` per watchdog (3)

### 1.2 Provenance schema (Zod)
- [ ] File `memory-service/schema/provenance.js` con `ProvenanceSchema` (15)
- [ ] Enum `source_type` esatta: `user_stated | user_lived | user_quoted_other | bot_inferred | bot_generated | external_doc` (incluso nel sopra)
- [ ] Test unit: valida + rifiuta payload malformato (15)

### 1.3 Classificatore deterministico
- [ ] `memory-service/classify-provenance.js` con regex heuristics (30)
  - `/^(ti ho detto|ti avevo detto|come ti ho accennato)/i` → `user_stated`
  - `/\b(ho fatto|ieri|stamattina|ho visto|sono andato)\b/i` → `user_lived`
  - `/\b(mi ha detto|ha detto che|secondo (lui|lei))/i` → `user_quoted_other`
  - Fallback: `bot_inferred` (se è output LLM) / `user_stated` (se è input diretto utente)
- [ ] Test unit con 15 frasi rappresentative italiane (10)

### 1.4 Endpoint capture + episode
- [ ] `POST /capture` — valida provenance, scrive a `chats/<chatId>/daily/YYYY-MM-DD.md`, rifiuta 400 senza provenance (20)
- [ ] `POST /self/episode` — append-only a `self/episodes.jsonl`, schema deterministico (15)
- [ ] Audit log: ogni write appende linea JSON a `audit.jsonl` (5)

### 1.5 Integrazione bridge (hook shadow)
- [ ] Creare `telegram-bridge/memory-client.js` (~80 righe): `capture()`, `postEpisode()`, circuit breaker, timeout 500ms (25)
- [ ] Modificare `bridge.js`:
  - Post-turn hook (dopo status=completed) → `capture()` fire-and-forget (10)
  - Stenografo hook (sempre) → `postEpisode()` con situation_hash deterministico (15)
- [ ] Log errori a `logs/bridge.log`, non bloccare mai il bridge (5)

### 1.6 Seed iniziale da JSONL esistenti
- [ ] Script one-shot `memory-service/scripts/seed-from-jsonl.js` (20)
  - Legge `telegram-bridge/logs/transcripts/*.jsonl`
  - Per ogni turno: classifica provenance (user_stated per user, bot_generated per assistant), capture a daily files
  - Dry-run mode per preview

**⚠ Gate 1**: dopo 3 giorni di uso reale:
- [ ] `daily/YYYY-MM-DD.md` si riempiono correttamente
- [ ] `episodes.jsonl` cresce linearmente col numero turni
- [ ] Zero crash memory-service (check via `/stats`)
- [ ] Audit log senza error entries

---

## Fase 2 — Identity + Tacit + Recall-probe (1.5h)

Attivi T0+T1 + fail-safe. Prima influenza reale sul comportamento.

### 2.1 soul.md iniziale
- [ ] Scrivere `memory-service/identity/soul.md` (~300 tok) con (20):
  - Identità dell'agente (assistente operativo, accesso PC Windows)
  - Tono (italiano, conciso)
  - Regole invariate (no kill bridge/panel, no hooks destructive)
  - Utente autorizzato (chat 270997894)

### 2.2 tacit.md seeding
- [ ] Per chat 270997894: estrarre preferenze note da `docs/memory/context.md` + `memory/session_2026-04-18.md` (15)
- [ ] Scrivere `chats/270997894/tacit.md` (~500 tok) con preferenze, stile comunicazione, regole operative

### 2.3 Recall-probe
- [ ] Implementare `similarity(query, memory_chunk)` via cosine su embedding locale (15)
- [ ] Soglia default 0.72, configurabile in `config.json`
- [ ] Endpoint `POST /retrieve` base che ritorna `{ soul, tacit, recall_probe_ok: true }` — per ora solo T0+T1 (15)

### 2.4 Integrazione bridge pre-turn
- [ ] Modificare `bridge.js` pre-turn: chiamare `retrieve()`, iniettare `soul + tacit` nel system prompt (15)
- [ ] Se `recall_probe_ok = false`: aggiungere riga "Non hai memoria affidabile su questo turno — evita citazioni" (5)
- [ ] Token budget log per turno (metrica iniziale) (5)

**⚠ Gate 2**: 48h di uso:
- [ ] Risposte coerenti con identità/tono
- [ ] Nessuna regressione rispetto a prima (stile Claude invariato)
- [ ] Token injection < 900 in questa fase

---

## Fase 3 — Retrieval attivo T3+T4 (3h)

Core retrieval semantic + graph. Prima fase con LLM behavior change significativo.

### 3.1 Storage setup
- [ ] Inizializzare LanceDB in `storage/lance/`, tabella `semantic_chunks` con schema `{id, chat_id, text, embedding, source_type, source_ref, timestamp, confidence}` (20)
- [ ] Inizializzare Kuzu in `storage/kuzu/`, schema graph:
  - Node types: `Entity`, `Concept`, `User`, `Turn` (25)
  - Edge types: `MENTIONS`, `RELATES_TO`, `CONTRADICTS`, `DERIVED_FROM`
- [ ] Script migration one-shot: ingestare daily files esistenti → LanceDB + estrarre entities naive via NER (30)

### 3.2 Retrieval pipeline
- [ ] `POST /retrieve` esteso (45):
  1. Tokenize query → keyword list
  2. LanceDB top-K (K=5) per similarity
  3. Estrai entity names dal messaggio (regex+heuristics), query Kuzu 1-hop
  4. Reciprocal Rank Fusion
  5. MMR diversification
  6. Recall-probe check su ogni chunk recuperato
  7. Return con `injected_tokens_estimate`

### 3.3 Capture pipeline arricchita
- [ ] Capture ora anche: embed → LanceDB insert, entity extract → Kuzu nodes/edges (30)
- [ ] Async job queue (semplice in-memory) per non bloccare bridge (10)

### 3.4 A/B test setup
- [ ] Flag `config.memory.enabled` in `config.json`, togglabile (10)
- [ ] Watcher/script che alterna flag ogni 2h per 7 giorni (15)
- [ ] Log metrics per turno: `memory_on`, `latency_ms`, `tokens_injected`, `user_satisfaction` (da inferire via analysis) (15)

**⚠ Gate 3**: dopo 7 giorni A/B:
- [ ] LRS computed dentro banda 0.6 ± 0.15 almeno 5 giorni/7
- [ ] Latency p95 retrieve < 150ms
- [ ] Token injection < 3500/turno
- [ ] Qualità percepita: feedback utente positivo o neutrale (no peggioramento)

Se gate fallisce → non proseguire a Fase 4, tornare a tarare soglie.

---

## Fase 4 — Self + Beliefs (4h)

Tier meta-memoria + Attitude Ledger. Il cuore della differenza v2.

### 4.1 turn_risk_score
- [ ] Funzione `computeTurnRisk(userText, context)` che combina (20):
  - Irreversibility (keyword "delete", "restart", "send", "cancel")
  - Stakes (length of request, system-level operations)
  - Novelty (query distance dagli ultimi 10 turni)
  - User stress signals (punctuation, ALL CAPS, keyword urgency)
- [ ] Output `[0, 1]`, soglia attivazione self/ = 0.5

### 4.2 Self retrieval
- [ ] `/retrieve` include `self_lessons` solo se `turn_risk > 0.5 AND similar_episodes >= 3` (25)
- [ ] Clustering episodi per `situation_hash` vicino (cosine < 0.3 distance) (20)
- [ ] Return top 2 lessons gated (10)

### 4.3 Beliefs store + API
- [ ] `POST /beliefs/assert` con validation Zod (20)
- [ ] `POST /beliefs/query` ordinato per `confidence × recency` (15)
- [ ] `POST /beliefs/revise` con append-only version bump (20)
- [ ] `GET /beliefs/audit` report settimanale (10)

### 4.4 Pushback mechanism
- [ ] Funzione `conflictScore(userStatement, belief)` con formula esplicita (15)
- [ ] Tre soglie: 0.4 (hold) / 0.4-0.7 (soft) / ≥0.7 (hard) (10)
- [ ] Pushback guard: domain check (safety/factual/irreversible) + authority_expected (20)
- [ ] `/retrieve` output include `pushback_suggested` + `relevant_beliefs` (15)

### 4.5 Bridge integration pushback
- [ ] Pre-turn: se `pushback_suggested = soft` → system prompt include "L'utente sta forse dicendo X, ma credi Y per Z. Valuta dissenso calibrato." (15)
- [ ] Se `hard` → sistema prompt più forte + forzare pushback esplicito (10)
- [ ] Log pushback inviati vs non inviati, per gate validation (10)

### 4.6 Dry-run pushback (1 settimana)
- [ ] Flag `beliefs.pushback_dryrun = true` in config → pushback loggati ma non applicati (10)
- [ ] Review manuale dei 7 giorni: quanti pushback sarebbero stati giusti? quanti invasivi? (tempo utente, non codice)

**⚠ Gate 4**:
- [ ] Zero false-positive pushback gravi in 7 giorni
- [ ] Self lessons attivate < 15% dei turni (altrimenti gating troppo lasco)
- [ ] Nessun loop ricorsivo (check audit)

---

## Fase 5 — Riflettore notturno (3h)

Dual sleeper completo. LLM async via watcher.

### 5.1 Watcher memory-reflect
- [ ] Aggiungere a `telegram-bridge/watchers.json` (10):
  ```json
  { "id": "memory-reflect", "schedule_cron": "0 3 * * *", "browser_slot": null, "model": "claude-haiku-4-5-20251001" }
  ```
- [ ] Hot-reload via `POST /api/watchers/memory-reflect/toggle` sul panel 7777 (5)

### 5.2 Prompt Riflettore
- [ ] Scrivere prompt template in `memory-service/prompts/reflector.txt` (30)
- [ ] Input: episodes.jsonl ultimo giorno + daily files per chat
- [ ] Output JSON strutturato: `new_entities`, `updated_entities`, `new_lessons`, `new_beliefs`, `tacit_updates`, `contradictions_resolved`
- [ ] Regole esplicite: no invenzioni, cita turn_id, marca contraddizioni con ⚠

### 5.3 Apply pipeline
- [ ] Script `memory-service/scripts/apply-reflection.js` (40):
  - Parse JSON output
  - Validate: ogni lesson cita turn_id esistenti, ogni belief ha evidence
  - Apply diff (scrive files + insert Kuzu + LanceDB)
  - Rollback automatico se lint fallisce
- [ ] Notifica Telegram diff summary (10)

### 5.4 Dry-run mode (2 settimane)
- [ ] Output scritto in `pending-consolidation-YYYY-MM-DD.md` invece di applicare (15)
- [ ] Notifica Telegram: "pronto diff, conferma con `/memory apply <date>`" (10)
- [ ] Dopo 14 giorni di dry-run, review settimanale manuale

**⚠ Gate 5**:
- [ ] Zero rollback lint in 7 giorni consecutivi (dry-run)
- [ ] Costo Haiku < $0.03/notte (misurato su 7 notti)
- [ ] Tempo esecuzione < 5 min/notte

### 5.5 Go-live Riflettore
- [ ] Rimuovere dry-run flag (2)
- [ ] Auto-apply con rollback live (già pronto)

---

## Fase 6 — Audit + LRS omeostatico (1.5h)

Closed-loop tuning. Il sistema impara a tararsi.

### 6.1 Watcher memory-audit
- [ ] Aggiungere a watchers.json (5):
  ```json
  { "id": "memory-audit", "schedule_cron": "0 4 * * 0", "browser_slot": null, "model": null }
  ```

### 6.2 Sampling pipeline
- [ ] Script `memory-service/scripts/weekly-audit.js` (30):
  - Seleziona random 20 fatti recuperati durante la settimana
  - Genera messaggio Telegram batched: "questi fatti erano pertinenti? [sì/no/forse]"
  - Salva in `audit-queue-YYYY-WW.json`

### 6.3 User feedback loop
- [ ] Comando Telegram `/audit_respond` per rispondere al batch (15)
- [ ] Parsing risposte → update `recall_precision` metrica (10)

### 6.4 Auto-tune
- [ ] Se precision < 0.7 → alzare `similarity_threshold` di +0.05 (config update) (15)
- [ ] Se precision > 0.9 → abbassare di -0.05 (perdi hit utili) (5)
- [ ] Log change in `audit.jsonl`, max 1 tune/settimana (10)

**⚠ Gate 6**: dopo 4 settimane:
- [ ] LRS in banda stabile
- [ ] `similarity_threshold` converge (non oscilla settimanalmente)

---

## Fase 7 — Cleanup + observability (1h)

Finalizzazione, pulizia legacy.

### 7.1 Migrazione legacy
- [ ] Aggiungere header a `docs/memory/memory.md`: "⚠ DEPRECATO dal 2026-XX-XX, vedi memory-service/" (5)
- [ ] Read-only mode (no nuove scritture via `/memo`, redirigere a memory-service) (10)
- [ ] Aggiornare `CLAUDE.md` con nuova struttura memoria (10)

### 7.2 Comando Telegram `/memory`
- [ ] `/memory <query>` → retrieve interattivo, output preview top 5 risultati (15)
- [ ] `/memory stats` → stats summary (5)
- [ ] `/memory forget <id>` → marca un fatto come deprecated (attenzione: append-only, solo flag) (10)

### 7.3 Panel dashboard `/memory`
- [ ] Pagina in `telegram-bridge/panel.js` con (30):
  - Entità top per chat (Kuzu query)
  - LRS live chart ultimi 30gg
  - Token injection medio
  - Beliefs stats (held/challenged counts)
  - Pushback frequency
  - Last consolidation diff preview
- [ ] Refresh automatico ogni 30s

### 7.4 Alert system
- [ ] Watchdog memory-service: se `/health` fallisce 3x → alert Telegram (10)
- [ ] Alert se audit errors > 10/giorno (5)
- [ ] Alert se LRS fuori banda per 3 giorni consecutivi (5)

---

## Riepilogo ore per fase

| Fase | Ore stimate | Cumulative |
|------|-------------|------------|
| 0 — Prerequisiti | 1.0 | 1.0 |
| 1 — Shadow + Stenografo | 2.0 | 3.0 |
| 2 — Identity + Tacit | 1.5 | 4.5 |
| 3 — Retrieval attivo | 3.0 | 7.5 |
| 4 — Self + Beliefs | 4.0 | 11.5 |
| 5 — Riflettore | 3.0 | 14.5 |
| 6 — Audit + LRS | 1.5 | 16.0 |
| 7 — Cleanup | 1.0 | 17.0 |

Più tempo attesa validation gates (cumulative ~5 settimane calendar time).

---

## Roadmap sessioni consigliata

**Sessione 1** (2h): Fase 0 + Fase 1 parziale (fino a 1.4)
**Sessione 2** (2h): Fase 1 completa + Gate 1 setup, poi 3gg di attesa validazione
**Sessione 3** (1.5h): Fase 2 completa + Gate 2
**Sessione 4** (3h): Fase 3 completa, poi 7gg A/B test
**Sessione 5** (4h): Fase 4 completa, poi 7gg dry-run pushback
**Sessione 6** (3h): Fase 5 completa, poi 14gg dry-run Riflettore
**Sessione 7** (2.5h): Fase 6 + Fase 7 finalizzazione

Totale: **7 sessioni**, ~5-6 settimane incluse validation.

---

## Decision points chiave durante il percorso

1. **Dopo Fase 1**: se `kuzu` ha problemi Windows → fallback a `duckdb` + FTS
2. **Dopo Gate 3**: se LRS non in banda dopo 14gg di tuning → riduci tier (T3+T4 only, skip T5+T6)
3. **Dopo Gate 4**: se pushback troppo invasivo → alza soglie a 0.5/0.8, o disabilita hard pushback
4. **Dopo Fase 5**: se Riflettore produce troppe contraddizioni → downgrade a Sonnet per la consolidation (costo 4× ma meno allucinazioni)

---

## File correlati

- `findings.md` — stato dell'arte
- `plan.md` — v1 piano originale (storico)
- `plan-v2.md` — piano aggiornato con raffinamenti
- `dialogue.md` — ragionamento co-ricerca + 7 leggi architetturali
- `prior-art.md` — confronto con sistemi esistenti
- `TASK_PLAN.md` — questo file, breakdown operativo
