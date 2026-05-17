# scripts/

Script operativi per il PM e i dev. Devono essere idempotenti (rilanciabili senza danno).

## `setup-project.sh`

Crea/aggiorna il GitHub Project v2 "GIGI — Lancio v1" + custom fields + linka il repo.

**Prerequisito:** token gh con scope `project,read:project`.

```bash
gh auth status                       # check
gh auth refresh -s project,read:project   # se manca lo scope (interattivo)
bash scripts/setup-project.sh
```

Output: numero Project + URL. La parte view/iteration/workflow si fa in browser (1 minuto, sezione spiegata in fondo allo script).

## `analyze-router-trace.mjs`

Legge `gigi-router-trace.jsonl` (scaricato dal container dell'app via Xcode → Devices and Simulators → app container download) e stampa un report Markdown con:

- distribuzione decisioni per tier / tool / path
- istogramma confidence (low / mid / high)
- percentili latenza (p50, p95, max) + top 5 slowest
- reprompt rate + tier-transitions quando un reprompt scatta
- low-confidence + empty-tool dispatches (casi probabili di mis-routing)

```bash
node scripts/analyze-router-trace.mjs path/to/gigi-router-trace.jsonl
node scripts/analyze-router-trace.mjs trace.jsonl > report.md
```

Richiede solo Node 20+ (no deps).

## (Più avanti)

- `build-ipa.sh` — eseguibile del runbook `docs/runbooks/build-ipa.md`
- `lint-pr.sh` — usato da CI per validare il body del PR
