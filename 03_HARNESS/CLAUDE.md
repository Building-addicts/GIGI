# Harness — Componente GIGI (indice memoria)

Questo file è l'indice del sottosistema Harness, parte dell'architettura GIGI.
Harness = layer Node (telegram-bridge + browser MCP + memory) che affianca l'app iOS GIGI.
Quando apri una sessione Claude Code in `03_HARNESS/`, leggi prima questo file per orientarti.

**Posizione nel monorepo GIGI:**
```
GIGI-harness/                      ← root monorepo (remote: Leonardo-Corte/GIGI)
├── 00_DOCS/                       ← architettura + task plan GIGI v3
├── 01_SERVER_MDM/                 ← server Node per profili MDM iOS
├── 02_GIGI_APP/                   ← app iOS Swift (GIGI V3)
└── 03_HARNESS/                    ← sei qui (bridge + browser MCP + memory upgrade)
```

## File di memoria

| File | Tipo | Contenuto |
|------|------|-----------|
| [docs/memory/context.md](docs/memory/context.md) | Statico (manuale) | Struttura del progetto, componenti, file chiave, note operative. Aggiornalo quando cambia qualcosa di strutturale. |
| [docs/memory/memory.md](docs/memory/memory.md) | Dinamico (auto) | Riassunto conversazioni Telegram precedenti. Generato automaticamente dal bridge a 75% di contesto o via `/memo`. |
| `telegram-bridge/logs/transcripts/<chatId>.jsonl` | Mirror grezzo (auto) | Backup letterale del JSONL Claude Code per ogni chat Telegram. Aggiornato via overwrite dopo ogni turno completato. Da consultare solo su richiesta esplicita — costa token. |

## Livelli di memoria

Tre livelli in ordine crescente di costo/dettaglio:
1. **Statico** — `docs/memory/context.md` (manuale)
2. **Semantico** — `docs/memory/memory.md` (riassunto AI)
3. **Letterale** — `logs/transcripts/<chatId>.jsonl` (mirror completo: user + assistant + tool calls + tool results). **Non leggerlo di default**: usalo solo se un dettaglio citato non è nel riassunto. Esposto nel bridge come helper `getChatTranscript(chatId)` che legge prima dal mirror, fallback al JSONL originale.

## File di stato runtime (telegram-bridge/logs/)

| File | Contenuto |
|------|-----------|
| `logs/sessions.json` | Session ID Claude attivi per ogni chat Telegram |
| `logs/interrupted.json` | Task interrotti da rate limit (usato da `/restart`) |
| `logs/bridge.log` | Log operativo del bridge |
| `logs/leo_workspace.json` | Stato watcher Leo Corte (WhatsApp terminal) |
| `logs/tommy_workspace.json` | Stato watcher Tommy (WhatsApp assistant) |
| `logs/state.json` | Statistiche bridge (requests, errors) |
| `logs/transcripts/` | Mirror dei JSONL Claude per chat (vedi sopra) |

## Struttura sottosistema

```
03_HARNESS/
├── CLAUDE.md                      ← sei qui
├── docs/
│   └── memory/
│       ├── context.md             ← contesto statico (leggi sempre)
│       └── memory.md              ← memoria conversazioni (auto-generato)
├── memory-upgrade/                ← PROGETTO IN CORSO: redesign sistema memoria
│   ├── README.md                  ← indice
│   ├── research/                  ← findings, prior-art, dialogue
│   ├── single-user/               ← piani N=1 (v1→v4.2)
│   │   ├── v1/ … v4/              ← piani storici
│   │   └── v4.2/                  ← proposta critica single-user (21/04/2026)
│   └── multi-user-v1/             ← BRANCH ATTIVO: 10 utenti + fine-tuning federated
│       ├── plan-multi-user-v1.md
│       └── gap-analysis.md        ← 31 gap consolidati + severity matrix
├── telegram-bridge/               ← bridge Telegram→Claude
│   ├── bridge.js                  ← processo principale (non killare)
│   ├── panel.js                   ← pannello web (porta 7777)
│   ├── watchers.js / watchers.json← worker autonomi periodici
│   ├── config.json                ← configurazione (token, system prompt, browser)
│   └── logs/                      ← file di stato runtime
│       └── transcripts/           ← mirror JSONL per chat (backup portabile)
├── browser-mcp/
│   └── server.js                  ← server MCP pool browser
├── browser-profile/               ← profilo Chrome "main" (CDP 9224)
├── browser-profile-slot1/         ← profilo Chrome "slot1" (CDP 9225)
└── browser-profile-slot2/         ← profilo Chrome "slot2" (CDP 9226)
```

## Lavoro in corso — Memory Upgrade (branch Multi-User V1)

Stiamo ridisegnando il sistema di memoria di Harness. Tutto il lavoro sta in `memory-upgrade/`.

- **Branch attivo (22/04/2026)**: `multi-user-v1/` — scenario 10 utenti (3 heavy + 7 casual) con server centrale di fine-tuning federated. Threat model Livello 1 (operator trusted).
  - `plan-multi-user-v1.md` — architettura + 10 decisioni pendenti
  - `gap-analysis.md` — 31 gap consolidati (strutturali + SOTA + federated + research Apr 2026) con severity matrix + top 10 azioni
- **v4.2** (`single-user/v4.2/Proposta-V4.2-Critico.md`) — candidato deployment N=1 single-user se il pivot multi-user non procede.
- **v4** (`single-user/v4/plan-v4.md`) — architettura SOTA 7 layer. Base di riferimento.
- **Stato**: nessuna implementazione iniziata. Gate obbligatorio = spike decisionale di Fase 0.5.
- **Stack validato**: Anthropic Memory Tool + LanceDB + BGE-M3 + SurrealDB embedded + Git versioning. Scartati Kuzu (deprecato 10/2025) e CozoDB.

**Decisioni multi-user-v1 pendenti (10)**: ruolo modello fine-tuned (α/β/γ), pattern global+personal LoRA, base model open (Qwen 3 / Llama 4 / GLM / Mistral), frequenza training, trigger upload, modello incentivo, retention, DP threshold, sqlite-vec vs Zvec, auto-admission skills premium.

**Decisioni v4.2 chiuse**: Punto 2 (effort), Punto 3 (skip classificazione dataset — ora RISORTA in multi-user-v1), Gap 1 (correzione inline con 6 safeguard), Gap 3 (memory doctor).

**Novità di impatto (Apr 2026) da integrare**:
- **OMEGA** — 95.4% LongMemEval, fully-local ONNX
- **Mastra Observational Memory** — 94.87% con solo testo, no vector DB
- **Zvec** (Alibaba, Feb 2026) — sqlite-style con HNSW nativo

Quando l'utente parla di "piano memoria", "v4", "v4.2", "multi-user", "memory upgrade", "fine-tuning federated" → leggi `memory-upgrade/README.md` e poi il file specifico citato (attualmente `multi-user-v1/plan-multi-user-v1.md`).

## Come aggiornare la memoria

- **Aggiornare il contesto statico**: modifica `docs/memory/context.md` direttamente
- **Salvare riassunto conversazione**: invia `/memo` su Telegram
- **Visualizzare memoria**: leggi `docs/memory/memory.md`

## Regola: loop → watcher

Quando l'utente chiede di "mettere in loop" qualcosa: **NON** usare `ScheduleWakeup` o loop in-session. Crea un watcher in `telegram-bridge/watchers.json` (persistente, gira dentro il bridge Node).
Prima di crearlo chiedi SEMPRE all'utente: "Ogni quanto devo pollare?". Il prompt del watcher deve contenere la richiesta originale dell'utente.
Se il task richiede un browser loggato, assegna il watcher al **primo slot libero** (`slot1`, `slot2`, ...) — non usare `main` se già occupato da un'altra chat. Applica con hot-reload via `POST /api/watchers/<id>/toggle` sul panel (porta 7777), senza riavviare il bridge.
