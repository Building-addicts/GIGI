# Plan — Harness preflight script (auto-detect config)

> Status: draft, ready for sanity checks
> Owner: @ArmandoBattaglino (PM, in tandem con Claude)
> Created: 2026-04-28
> Triggered by: #64 (QA setup) bloccata 30 min cercando config sparsi tra `Desktop/Harness/telegram-bridge/`, monorepo `03_HARNESS/server/`, e checkpoint folders

## Requirements summary

Durante #64 (QA setup pre-freeze) abbiamo perso 30 min a cercare config harness sparsi. Lo stesso problema bloccherà il QA gate di mercoledì 30 ore 14:45 (parent #17) se non lo risolviamo prima. Serve uno script preflight che:

- Sa dove cercare config su Win + Mac + Linux
- Diffa con gli example per dire cosa manca
- Restituisce exit code chiaro + tabella leggibile
- È runnable in <10s da chiunque cloni il repo

## Scope (deciso 2026-04-28 con PM)

**Single path strategy — mimicare setup-flow attuale del monorepo**

Il setup ufficiale già esistente (vedi `03_HARNESS/server/start-all.sh:13-24`) cerca config in **un solo path**: `03_HARNESS/server/config.json` (override via `HARNESS_CONFIG`). Lo script preflight estende quella stessa logica — non introduce path alternativi (no `Desktop/Harness/telegram-bridge/` standalone, no fallback). Il PM ha confermato che Leo/Fede su Mac hanno setup nello stesso layout monorepo, quindi la single-path strategy copre tutti gli host.

**Cosa fa MVP**:
- Bash script (`Git Bash` Win + Mac + Linux nativi)
- OS detect via `uname -s` solo per scegliere quale example usare:
  - Mac (`Darwin`) → confronta vs `config.example.mac.json`
  - Win (`MINGW64_NT-*`) / Linux → confronta vs `config.example.json`
- Verifica `03_HARNESS/server/config.json` + `.env` esistono
- Diff keys vs example, lista mancanti
- Tabella + exit code (0 ready / 1 missing / 2 file totalmente assente)

**Fuori scope (PR separato)**:
- PowerShell version (Git Bash è disponibile su tutte le macchine team)
- `cloudflared` install detect
- Hook in `start-harness.sh`
- Doc runbook
- Test E2E su Mac di Fede (Fede testa quando installa)

## Acceptance Criteria (MVP)

- [ ] **AC1**: `bash 03_HARNESS/server/preflight.sh` da repo root su Git Bash Win → exit 0 quando config.json + .env presenti e completi vs `config.example.json`
- [ ] **AC2**: Stesso script su Mac (Darwin) usa `config.example.mac.json` come baseline per il diff
- [ ] **AC3**: Se `config.json` o `.env` mancante → exit 2 con messaggio "run: cp config.example.json config.json && edit"
- [ ] **AC4**: Se config presente ma manca una key richiesta → exit 1 con tabella che lista le key mancanti
- [ ] **AC5**: Output sempre tabella `[file] [exists] [missing keys] [status]`, leggibile in <5s
- [ ] **AC6**: Verificato sul Win di Armando in Git Bash con 3 scenari (ready / missing key / missing file)

## Implementation steps (MVP)

1. **Read templates** — estraggo lista keys richieste:
   - `03_HARNESS/server/config.example.json` (Win baseline)
   - `03_HARNESS/server/config.example.mac.json` (variant Mac, possibile drift)
   - `03_HARNESS/server/.env.example`

2. **Crea `03_HARNESS/server/preflight.sh`** con:
   - `set -euo pipefail` + log helper colorati POSIX-compatibili
   - Risolve repo root via `git rev-parse --show-toplevel` (script gira da qualsiasi cwd dentro il repo)
   - OS detect via `uname -s` per scegliere example baseline (Darwin → `config.example.mac.json`, altri → `config.example.json`)
   - Verifica `03_HARNESS/server/config.json` + `.env` esistono — se no exit 2 con suggerimento `cp ...example...`
   - Diff con example chosen: jq se disponibile, fallback a grep+sed parser POSIX
   - Output tabella: `[file] [exists] [missing keys] [status]`
   - Exit 0 ready, 1 missing keys, 2 file assente

3. **Test** sul Win di Armando con 3 scenari:
   - Setup attuale (config in `Desktop/Harness/`) → trova → exit 0
   - `mv` config altrove temporaneo → exit 1 con tabella che dice missing
   - Cancella temporaneamente 1 key in config → exit 1 con tabella key mancante

4. **Commit + PR + merge** dietro normal review

## Files

| File | Azione | Note |
|---|---|---|
| `03_HARNESS/server/preflight.sh` | create | core script |
| `03_HARNESS/server/config.example.json` | read-only | extract required keys |
| `03_HARNESS/server/config.example.mac.json` | read-only | variant check |
| `03_HARNESS/server/.env.example` | read-only | extract required env vars |

(Per Full scope, future PR: `preflight.ps1`, `start-harness.sh` hook, `docs/runbooks/harness-preflight.md`)

## Risks & mitigations

| Risk | Mitigation |
|---|---|
| `jq` non installato su Git Bash Win | Fallback grep+sed parser POSIX, no jq dependency strict |
| Config drift tra `config.example.json` (Win) e `config.example.mac.json` (Mac) → false positive | Whitelist keys "platform-specific", warning vs error level |
| User ha config valido ma in path non listato → false negative | Logga search paths usati + exit code 2 (not 1) per "no config trovato in paths noti" + suggerimento "passa --path X" come futuro |
| `~/Desktop/...` non porta su Mac (è invece `~/Desktop/...` ok) | Funziona, $HOME è cross-platform |
| Git Bash riscrive `/c/...` differentemente da PowerShell | Solo bash output, nessun call a tool che espande paths Windows-style |

## Verification (post-implementation)

- [ ] V1: `bash 03_HARNESS/server/preflight.sh` da `GIGI-work/issue-N-...` su Git Bash → exit 0, tabella mostra `Desktop/Harness/telegram-bridge` come source
- [ ] V2: `mv ~/Desktop/Harness/telegram-bridge/config.json ~/Desktop/Harness/telegram-bridge/config.json.bak && bash preflight.sh` → exit 1, tabella dice "config.json missing"
- [ ] V3: `git apply` di un patch che rimuove una key dal config → exit 1, tabella dice "missing key: X"
- [ ] V4: `cp ~/Desktop/Harness/telegram-bridge/{config.json,.env} 03_HARNESS/server/` → preflight prefere monorepo path (priority 1)

## DECISIONE D2 da prendere ora — Worktree

Lo sblocco serve a #64 ma lo script è scope diverso. 2 strategie:

- **D2.A — Stesso worktree**: piggyback su `feat/issue-64-qa-setup`. Pro: 1 PR sola fa unblock end-to-end. Contro: rompe regola workflow "1 issue = 1 branch", il merge bundla tutto.
- **D2.B — Worktree separato**: `feat/issue-N-harness-preflight`. Pro: clean history. Contro: 2 PR da gestire in serie (preflight prima, poi #64).

**Raccomandazione**: D2.B. Il preflight è general infrastructure, va merged prima e Fede potrà beneficiarne anche per altri lavori.

## Open decisions — sintesi per Armando

1. **D1 — Scope**: MVP oggi only (raccomandato), o Full PR singolo?
2. **D2 — Worktree**: separato (raccomandato), o piggyback #64?

## Issue da aprire

- Title: `feat(harness): preflight script auto-detect config (Win + Mac + Linux)`
- Author: ArmandoBattaglino (PM apre direttamente)
- Assignee: ArmandoBattaglino (lavora con Claude in tandem)
- Labels: `type:feat`, `area:harness`, `priority:P0`, `release-blocker`, `effort:M`
- Linked: derives from #64, blocks #17 QA gate (mercoledì 30)
- Body: usa template feature.md + sezioni 🎯/🔧/✨ + AC sopra + Riferimenti a questo plan
