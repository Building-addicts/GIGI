# Contesto Progetto — Harness (componente GIGI)

## Cos'è questo sistema
Harness è il sottosistema Node che fa parte dell'architettura GIGI. Espone tre capability:
- **telegram-bridge** — interfaccia remota via Telegram + gateway verso Claude Code
- **browser-mcp** — pool browser loggati per automazione web (WhatsApp Web, booking, ecc.)
- **memory-upgrade** — progettazione sistema memoria condiviso GIGI

Quando il bridge gira in produzione, riceve messaggi Telegram e ha accesso pieno alla macchina host (PC Windows o Mac dev).

Il processo che stai girando è `telegram-bridge/bridge.js` — NON killarlo mai, è il processo che gestisce questa conversazione.

## REGOLE CRITICHE — NON VIOLARE MAI

1. **Non chiamare mai `POST /api/bridge/stop` o `POST /api/bridge/restart`** — queste API killano bridge.js che è il tuo stesso processo. Ti autokilli e la conversazione muore.
2. **Non killare mai `panel.js` o `bridge.js`** — stessa ragione.
3. **Non eseguire `kill.ps1`** — killa tutto il sistema Harness.
4. **Non eseguire `restart_panel.ps1`** — idem.
5. Se Armando chiede di riavviare il bridge: digli di aprire `http://localhost:7777` e cliccare "Restart" dal panel, OPPURE di chiudere e riaprire Harness manualmente. Tu non puoi farlo senza autokillare.

## Struttura del sistema
```
<GIGI-root>/03_HARNESS/
├── telegram-bridge/        ← questo processo (bridge.js)
│   ├── bridge.js           ← il bridge Telegram-Claude (TU sei qui)
│   ├── panel.js            ← pannello web di controllo (porta 7777)
│   ├── watchers.js/json    ← worker autonomi periodici
│   ├── config.json         ← configurazione principale
│   └── logs/               ← log, sessioni, memoria, stato
├── memory-upgrade/         ← PROGETTO IN CORSO: redesign sistema memoria
│   ├── README.md           ← indice
│   ├── research/           ← findings, prior-art, dialogue
│   ├── single-user/        ← piani N=1 (v1→v4.2)
│   └── multi-user-v1/      ← BRANCH ATTIVO: 10 utenti + fine-tuning federated
│       ├── plan-multi-user-v1.md
│       └── gap-analysis.md  ← 31 gap + severity matrix
├── browser-mcp/            ← server MCP per il pool browser (server.js)
├── browser-profile/        ← profilo Chrome istanza "main" (porta CDP 9224)
├── browser-profile-slot1/  ← profilo Chrome istanza "slot1" (porta CDP 9225)
├── browser-profile-slot2/  ← profilo Chrome istanza "slot2" (porta CDP 9226)
├── downloads/              ← file scaricati
└── screenshots/            ← screenshot salvati
```

## Progetto in corso — Memory Upgrade (branch Multi-User V1)

Ridisegno del sistema di memoria Harness. Tutto in `memory-upgrade/`.

- **Branch attivo (22/04/2026)**: `multi-user-v1/` — scenario 10 utenti con fine-tuning federated. Threat model L1.
  - `plan-multi-user-v1.md` — architettura, 10 decisioni pendenti
  - `gap-analysis.md` — 31 gap + severity matrix + top 10 azioni
- **v4.2**: `single-user/v4.2/Proposta-V4.2-Critico.md` — candidato N=1 single-user.
- **v4**: `single-user/v4/plan-v4.md` — architettura SOTA 7 layer, base di riferimento.
- **Stack validato**: Anthropic Memory Tool + LanceDB + BGE-M3 + SurrealDB embedded + Git versioning.
- **Stato**: implementazione non iniziata.

**Multi-User V1 — 10 decisioni pendenti**: ruolo fine-tuning (α/β/γ), pattern global+personal LoRA, base model, frequenza training, trigger upload, incentivo, retention, DP ε, sqlite-vec vs Zvec, auto-admission premium.

**Novità Apr 2026**: OMEGA (ONNX locale 95.4% LongMemEval), Mastra Observational Memory (94.87% senza vector DB), Zvec Alibaba (sqlite+HNSW).

Quando l'utente parla di "piano memoria", "v4", "v4.2", "multi-user", "fine-tuning federated" → entra in `memory-upgrade/multi-user-v1/plan-multi-user-v1.md`.

## Pool browser (SEMPRE attivi, non avviarne di nuovi)
- **main** — porta CDP 9224, profilo `browser-profile` — browser principale, WhatsApp Web loggato
- **slot1** — porta CDP 9225, profilo `browser-profile-slot1`
- **slot2** — porta CDP 9226, profilo `browser-profile-slot2`

Usa SEMPRE i tool `mcp__harness-browser__*`. Per task paralleli chiama `browser_lease(app, task_id)` prima e `browser_release(task_id)` alla fine.

## Watchers attivi (worker autonomi ogni 60s)
- **leo-wa-terminal** — monitora WhatsApp con Leo Corte. Funziona come "terminale remoto": Leo manda comandi/link repo, il watcher li esegue e risponde. Stato in `logs/leo_workspace.json`.
- **tommy-wa-assistant** — assistente personale di Tommy su WhatsApp. Risponde ai messaggi di Tommy ed esegue task. Stato in `logs/tommy_workspace.json`.

Per gestirli: `/watchers`, `/watcher_fire <id>`, `/watcher_on <id>`, `/watcher_off <id>`, `/watcher_budget <id> <n|off>`, `/watcher_reset <id>`.

### Budget responses (auto-disable)
Ogni watcher può avere un campo opzionale `max_responses` in `watchers.json` (o impostato da panel / `/watcher_budget`). Il bridge intercetta l'output `[...] action=sent` nel summary del fire: incrementa `responses_count` in `logs/watchers_state.json` e, al raggiungimento del budget, disabilita automaticamente il watcher (rimuovendo i suoi timer in-memory). Skip/done non consumano il budget. Il contatore si resetta solo manualmente (pulsante panel o `/watcher_reset <id>`). Il watcher che usa questa feature deve stampare `[...] action=sent` solo quando ha effettivamente inviato una risposta — NON deve gestire il budget dal prompt né auto-disabilitarsi via toggle.

## File di stato importanti
- `logs/sessions.json` — session ID Claude per ogni chat Telegram
- `logs/memory.md` — riassunto auto-generato conversazioni precedenti
- `logs/context.md` — questo file (conoscenza statica del progetto)
- `logs/bridge.log` — log operativo
- `logs/leo_workspace.json` — stato watcher Leo
- `logs/tommy_workspace.json` — stato watcher Tommy
- `logs/transcripts/<chatId>.jsonl` — mirror locale dei JSONL Claude, uno per chat Telegram (backup portabile)

## Livelli di memoria
Tre livelli distinti, da leggere in ordine crescente di costo/dettaglio:
1. **Statico** — `docs/memory/context.md` (questo file): conoscenza di progetto curata a mano.
2. **Semantico** — `docs/memory/memory.md`: riassunto AI dell'ultima conversazione, generato a 75% contesto o via `/memo`.
3. **Letterale** — `telegram-bridge/logs/transcripts/<chatId>.jsonl`: mirror grezzo e completo (user, assistant, tool calls, tool results) della sessione Claude Code associata a quella chat. Mirror overwrite-based aggiornato dopo ogni turno completato. NON consultarlo di default (costa token) — solo su richiesta esplicita o se un dettaglio citato non è nel riassunto.

Vantaggi del mirror transcripts rispetto al JSONL originale in `~/.claude/projects/`:
- Portabilità: se la cartella `03_HARNESS/` viene spostata, lo storico viaggia con essa.
- Resilienza: se `~/.claude/` viene ripulita (reinstall, purge), il backup sopravvive.
- Isolamento per-chat: un file per utente Telegram, facile da ispezionare/esportare/cancellare.

## Comandi Telegram disponibili
`/ping` · `/cancel` · `/reset` · `/memo` · `/restart` · `/live` · `/model` · `/watchers` · `/watcher <id>` · `/watcher_fire <id>` · `/watcher_on/off <id>` · `/watcher_log` · `/watcher_budget <id> <n|off>` · `/watcher_reset <id>`

## Note operative
- Il pannello web è su `http://localhost:7777`
- I Chrome sono già aperti e loggati — non aprirne altri, usa il pool
- WhatsApp Web è già autenticato sul profilo `main`
- `kill.ps1` nella cartella bridge serve a stoppare tutto il sistema — usalo solo se richiesto esplicitamente da Armando
- La sessione Telegram ha un timeout di 60 minuti di inattività
