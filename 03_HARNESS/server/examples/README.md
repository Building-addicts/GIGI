# Examples — config templates harness

Cartella aggiunta nel rework `armando-rework` (2026-05-07) per separare **template config dimostrativi** dalla config produzione.

## Filosofia

`server/watchers.json` (produzione) era pre-popolato con 2 esempi `enabled: false` che presupponevano tool MCP non implementati (calendar bridge, meteo API, news MCP). Confondeva i nuovi dev: *"perché ci sono dentro? Sono attivi? Devo configurarli?"*. Sposto qui per chiarezza: questi sono **template documentati**, non config viva.

## File

- **`watchers.example.json`** — i 2 watcher originali (`gigi-morning-briefing` + `gigi-meeting-prep`). Per attivare uno: copia l'oggetto in `server/watchers.json`, flip `enabled: true`, riavvia il harness, implementa i tool MCP che il prompt presuppone (vedi commento nel file).

## Convenzione

Ogni nuovo template config che il team vuole conservare ma NON spedire come default attivo va qui, con suffisso `.example.json` o `.example.yml`. Aggiungi sempre un campo `_README` o un commento header che spieghi:

1. Perché esiste
2. Come si attiva
3. Quali dipendenze servono prima di flippare il flag

Vedi anche `docs/ARCHITETTURA_V3.md` §21 per il razionale del rework.
