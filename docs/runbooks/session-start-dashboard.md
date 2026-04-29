# Runbook — Session-start dashboard (3 colonne)

> Quando ti serve: capire cosa l'hook `.claude/hooks/session-start.sh` mostra ai dev all'apertura di Claude Code, come marcare le issue per finire in colonna giusta, troubleshoot output bizzarro.
>
> Owner: PM (Armando) per la convention; tutti i dev per uso quotidiano.

## Cosa è il dashboard

All'apertura di Claude Code, il SessionStart hook stampa un dashboard breve (max 8 righe) diviso in 3 colonne:

```
🟢 ACTIONABLE NOW                                  ← cosa puoi iniziare ORA (max 3)
  🔴🚨 #65 — Voice & Wake W2 quiet + W3 noise...
  🔴🚨 #66 — Dynamic Island D1 + Follow-up F1/F2...
  🟧 #130 — feat(infra): smart session-start...

🟡 WAITING (blocked by dependency)                 ← bloccate da dipendenze (max 3)
  🔴🚨 #17 — [QA] Pre-freeze QA gate                  ⏸️ blocked

🔴 PR IN REVIEW (shared, all devs)                 ← PR aperte tutti, visibili a tutti (max 2)
  PR #128 — feat(ios): Claude bridge auto-fallback (by @fc200490-sketch) [🔴 CI failing]
  👤 PR #124 — feat(ios): persistent harness banner   (by @ArmandoBattaglino) [✅ CI green]
```

L'icona `👤` indica una PR che il dev attuale ha aperto (priority visibility).

## Logica di categorizzazione

### 🟢 Actionable
Issue che soddisfano TUTTE queste condizioni:
- `state: open`
- Assegnata al dev
- **NO label `blocked`**

Ordinate per `priority_score`:
- `release-blocker` → 0 (top)
- `priority:P0` → 1
- `priority:P1` → 2
- `priority:P2` → 3
- `priority:P3` → 4
- nessun label priority → 99

Stesso score → ordinate per numero issue (più vecchio prima).

### 🟡 Waiting
Issue che soddisfano:
- `state: open`
- Assegnata al dev
- **HA label `blocked`** esplicita

Stesso ordinamento di Actionable.

### 🔴 PR in review
PR aperte di **tutto il repo** (NON filtrate per author — visibili a tutti i dev):
- Sort: prima le PR del dev attuale, poi le altre
- Max 2 mostrate
- Status icon:
  - `✅ CI green` — tutti i check passati
  - `✅ approved` — review approvata
  - `🔴 CI failing` — almeno un check failed
  - `🔴 changes requested` — review chiede modifiche
  - `⏳ pending` — review/CI in corso

## Come marcare issue per finire in colonna giusta

### Mettere issue in 🟡 WAITING (= dipende da altra)

```bash
gh issue edit <N> --repo Building-addicts/GIGI --add-label blocked
```

Quando la dipendenza è risolta:

```bash
gh issue edit <N> --repo Building-addicts/GIGI --remove-label blocked
```

Best practice: aggiungi sempre nel body un **comment** che spiega COSA blocca, es.:

```
⏸️ Blocked by #127 — multi-instance Live Activities pollution.
Riprenderò dopo merge fix #127.
```

### Verificare label `blocked` esistente

La label `blocked` deve esistere nel repo. Se non c'è:

```bash
gh label create blocked --repo Building-addicts/GIGI \
  --description "Blocked by dependency (parent issue or external resource)" \
  --color "ededed"
```

## Troubleshoot

### "Vedo issue X in colonna sbagliata"

| Sintomo | Probabile causa | Fix |
|---|---|---|
| Issue blocked sta in 🟢 invece di 🟡 | Manca label `blocked` | `gh issue edit N --add-label blocked` |
| Issue chiusa appare ancora | Cache locale gh CLI | Riapri Claude Code (rifa fetch) |
| Tutte le sub QA gate (#65-#70) appaiono in 🟢 con stesso colore | Corretto: hanno tutte `release-blocker` + `P0`. Decisione PM 2026-04-29: parent epic non vanno in 🟡 anche se hanno sub aperte | Resta come è |
| 🔴 PR section mostra PR di altri ma NON le mie | Le tue PR vengono prima per default — se mancano potrebbe essere che hai 0 PR aperte, oppure sono >2 e quelle altrui rientrano nel top-2 | Conta `gh pr list --author @me --state open` |
| 🟢 vuoto, tutte in 🟡 | Tutte le tue issue sono blocked. Sblocca quelle resolvable | rimuovi label da issue completate, oppure prendi una PR review da 🔴 |

### "Output troppo lungo / non vedo bene il messaggio"

Limit attuale: max 3 actionable + 3 waiting + 2 PR = 8 righe issue + 3 header + 2 separatori = ~13 righe. Se vedi più, è un bug del rendering — apri issue.

### "Il dashboard non si aggiorna"

Causa: hook session-start gira **una sola volta all'apertura**. Per vedere stato fresh, riapri Claude Code (`Ctrl+D` poi rilancia).

## Convention future (parking lot)

Se serve in futuro:
- **Marker comment `<!-- BLOCKING:N,M -->`** automatico — costoso fetchare comment di ogni issue (1 API call extra per issue), valutare se vale per repo grandi
- **Auto-detect parent epic con sub aperte** → 🟡 — decisione attuale (2026-04-29) PM: NON farlo, parent epic resta 🟢 release-blocker
- **GitHub Action auto-clear blocked label** quando issue dipendenza chiude — utile ma scope separato

## Riferimenti
- File hook: `.claude/hooks/session-start.sh` — Python embedded section ~163-260
- Decisione architetturale: issue #130
- Background motivante: PM feedback 2026-04-29 ore 03:30 — "ranking sembra a caso"
