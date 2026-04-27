## What

<!-- Una riga chiara: cosa cambia. Niente "tante piccole modifiche" — se è vero, splitta il PR. -->

## Why

<!-- Il problema che il PR risolve. Linka issue/ADR se esiste.
     Se è una decisione architetturale → apri prima un ADR in `docs/adr/`. -->

Closes #

## How

<!-- Approccio scelto + alternative considerate, se rilevante. -->

## Test plan

- [ ] Unit / integration test aggiunti o aggiornati
- [ ] Build verde (`xcodebuild` per Swift, `npm test` per Node)
- [ ] Per fix iOS: nuovo IPA buildato e testato sul device fisico (vedi `docs/runbooks/build-ipa.md`)
- [ ] Manualmente verificato: <descrivi scenario>

## Checklist

- [ ] Documentazione aggiornata se cambia un contratto API o un runbook
- [ ] Nessun secret committato (`.env`, chiavi APNS, certs)
- [ ] Nessun file temp in `bug/`, `logs/`, `DerivedData/`
- [ ] Commit message segue Conventional Commits (`feat:`, `fix:`, `docs:`, …)
- [ ] Se introduce nuova decisione architetturale → ADR aperto in `docs/adr/`

## Screenshots / output

<!-- Per UI: screenshot prima/dopo. Per CLI/API: output rilevante. -->

---

🤖 Self-review: leggo il diff prima di chiedere review umana.
