---
name: routine-pr
description: Routine PM per review batch delle PR aperte. Smart prioritization (TIER + chain + blocks + risk) + walk-through guidato (test-pr.sh → checklist iPhone → merge-pr.sh / reject-pr.sh). Riservato al PM Armando — pubblicabile ma gating built-in.
---

# /routine-pr — Routine PR review (PM only)

Tu sei Claude Code che esegue questa skill per Armando (PM). Il tuo ruolo: orchestrare la sessione di review delle PR aperte in modo veloce e sicuro, seguendo i 5 livelli L1-L5 documentati in CLAUDE.md.

## STEP 1 — Verifica identità PM

**Esegui** in Bash:
```bash
git config user.name 2>/dev/null
```

Se l'output **NON contiene** "Armando" (case-insensitive), interrompi e mostra:
```
⛔ /routine-pr è riservato al PM in carica (Armando Battaglino).
   Sei riconosciuto come: <nome>.
   Se sei subentrato come PM, aggiorna git config user.name e riprova.
```

Se contiene "Armando", saluta e prosegui:
```
👋 Ciao Armando, avvio routine-pr.
```

## STEP 2 — Smart prioritization

**Esegui** in Bash (mostra l'output al PM):
```bash
bash .claude/scripts/analyze-prs.sh 2>/dev/null | python -c "
import json, sys
prs = json.load(sys.stdin)
if not prs:
    print('Nessuna PR aperta.')
    sys.exit(0)
print(f'Totale PR aperte: {len(prs)}')
print()
print(f'{'#':<5} {'TIER':<8} {'Risk':<8} {'Title':<55} {'Reasoning':<60}')
print('-'*140)
for p in prs:
    tier_em = ['','🚨','🔥','📦','💤'][p['tier']]
    print(f\"#{p['pr']:<4} {tier_em} T{p['tier']:<5} {p['risk']:<8} {p['title'][:53]:<55} {p['reasoning'][:58]}\")
"
```

Mostra la tabella ordinata. La prima riga della tabella è la PR consigliata da fare per prima.

## STEP 3 — Plan presentation + decisione PM

Dopo la tabella, dì:

> **Piano consigliato**: lavoro sequenziale top-down della tabella. La logica:
> - TIER 1 (URGENT, fix build) → sempre prima, sblocca tutto
> - TIER 2 (HIGH, demo-critical o root catena) → secondo blocco
> - TIER 3 (MEDIUM, standalone) → completare quando hai tempo
> - TIER 4 (LOW, refactor) → eventualmente domani
>
> Per le **catene** (es. Sub #15 · 1/4 → 2/4 → 3/4 → 4/4): mergi sempre 1/N prima di N+1.
>
> Vuoi partire dalla **prima** (#X) o ne preferisci un'altra? Dimmi `vai con N` o `partiamo da Y`.

Aspetta la decisione del PM.

## STEP 4 — Walk through PR by PR

Per ogni PR confermata dal PM, segui questa sequenza esatta:

### 4.1 — Inspect quick (10 sec)

```bash
gh pr view <N> --repo Building-addicts/GIGI --json title,body,author,additions,deletions,changedFiles
gh pr diff <N> --repo Building-addicts/GIGI | head -50
```

Mostra al PM una sintesi di **1 paragrafo**: cosa fa la PR + verdetto a colpo d'occhio.

### 4.2 — Test pre-merge (1-3 min)

Dì al PM:
> *Lancio test-pr.sh che fa fetch + build su Mac via SSH + IPA + checklist.*

```bash
bash .claude/scripts/test-pr.sh <N>
```

Mostra l'output completo. Verdetto possibile:
- **BUILD SUCCEEDED** → procedi al 4.3
- **BUILD FAILED** → automaticamente proponi al PM di chiamare `reject-pr.sh <N> "build failed: <errore>"`

### 4.3 — Test E2E manuale (5-15 min, dipende dalla PR)

Dì al PM:
> *Apri Sideloadly + installa `GIGI-pr<N>.ipa` sul tuo iPhone. Apri il file `review-checklists/pr-<N>.md` e marca i checkbox L4+L5 mentre testi. Avvisami quando hai finito.*

ASPETTA il PM. NON proseguire finché non risponde con `fatto`, `ok`, `tutti verdi`, `un AC fail`, ecc.

### 4.4 — Decisione finale

In base al feedback del PM:

**Se tutto ✓**:
```bash
bash .claude/scripts/merge-pr.sh <N>
# Se richiede admin bypass per regex bug noto:
bash .claude/scripts/merge-pr.sh <N> --admin
```

**Se uno ✗** (il PM ti dice il motivo):
```bash
bash .claude/scripts/reject-pr.sh <N> "<motivo strutturato dal feedback>"
```

**Se il PM dice "posticipo"**:
- Lascia la checklist in `review-checklists/pr-<N>.md` (non archiviare)
- Posta su #19: `bash .claude/scripts/post-timeline.sh ArmandoBattaglino <N> standby "review posticipata"`

### 4.5 — Continua o stop

Dopo merge/reject/posticipo, chiedi:
> *Procediamo con la prossima (#X)? O fermiamoci qui?*

Se prosegue: torna a 4.1 con la nuova PR.
Se ferma: vai allo STEP 5.

## STEP 5 — Recap finale

Quando il PM dice "stop" o tutte le PR sono finite, esegui:

```bash
echo "=== Recap sessione $(date +%Y-%m-%d) ==="
ls -1 review-checklists/.merged/ 2>/dev/null | wc -l | xargs echo "Mergiate:"
ls -1 review-checklists/.rejected/ 2>/dev/null | wc -l | xargs echo "Rejected:"
ls -1 review-checklists/*.md 2>/dev/null | wc -l | xargs echo "Posticipate (checklist aperte):"
gh pr list --repo Building-addicts/GIGI --state open --json number --jq '. | length' | xargs echo "PR ancora open:"
```

Mostra i numeri al PM, posta su #19 LIVE FEED un comment di summary:
```bash
bash .claude/scripts/post-timeline.sh ArmandoBattaglino 0 standby "Routine PR session: X mergiate, Y rejected, Z posticipate"
```

Saluta:
> *✅ Routine completata. Vai a riposarti.*

---

## REGOLE VINCOLANTI per Claude

1. **NON saltare** lo STEP 1 (gating PM). Mai eseguire la routine se l'utente non è Armando.
2. **NON forzare** `merge-pr.sh` se il PM non ha confermato test E2E manuale OK.
3. **NON eseguire** `merge-pr.sh` o `reject-pr.sh` senza che `test-pr.sh` sia stato eseguito prima (la checklist non esisterebbe).
4. **NON parallelizzare** le PR — sempre 1 alla volta in sequenza, anche se sembra più veloce.
5. **NON usare** Agent / subagent per chiamare gli script — esegui direttamente via Bash tool nel main context.
6. **NON modificare** file source code nel main repo durante la routine — sei in modalità review, non sviluppo.
7. **Se test-pr.sh fallisce** per setup error (no SSH, no IPA folder, ecc.) → guida il PM ad aggiornare `.claude/local-build.sh` PRIMA di riprovare.

## Errori comuni e fix rapidi

| Sintomo | Causa | Fix |
|---|---|---|
| `lb_sync_branch: command not found` | `.claude/local-build.sh` mancante | `cp .claude/local-build.sh.example .claude/local-build.sh` + edita |
| `Could not resolve to a PullRequest` | PR num sbagliato o già mergiato/chiuso | Verifica con `gh pr list --state all` |
| `BUILD FAILED` con error reale | Codice rotto sul branch | `reject-pr.sh` con motivo "build failed: <error first line>" |
| `Validate PR title + body` rosso ma codice OK | Regex bug noto pr-lint nel branch vecchio | `merge-pr.sh <N> --admin` con bypass giustificato |
| `Checklist incompleta — N checkbox non spuntati` | PM ha dimenticato di marcare L4/L5 | Apri il file checklist, marca, poi rilancia merge-pr.sh |
