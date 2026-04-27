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

## (Più avanti)

- `build-ipa.sh` — eseguibile del runbook `docs/runbooks/build-ipa.md`
- `lint-pr.sh` — usato da CI per validare il body del PR
