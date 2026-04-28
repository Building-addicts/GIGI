# 00 — QA Setup (sub #64 di parent #17)

> Evidence per Acceptance Criteria di #64.
> Sessione: 2026-04-28 (sign-off pre-gate, gate vero mercoledì 30).

## Test Evidence Packet header

| Field | Value |
|---|---|
| Device model | iPhone 15 Pro |
| iOS version | (PM da confermare al sign-off) |
| Battery state | charging (status bar mostra green plug, ~80%+) |
| Low Power Mode | off |
| Focus mode | off (default) |
| Network state | WiFi + cellular (1 bar), heartbeat su Cloudflare Quick Tunnel |
| Audio route | built-in speaker/mic |
| Dynamic Island available | yes (iPhone 15 Pro) |
| Build SHA | `e3b1b10` |
| Build date/time | 2026-04-28, MacInCloud |
| Tester | Armando Battaglino (@ArmandoBattaglino), PM, sole tester |
| Harness URL | Cloudflare Quick Tunnel attivo (panel locale `localhost:7777`) |
| Harness binding | `0.0.0.0:7779` (post fix da host `127.0.0.1` default Win example) |
| Harness shared secret | match config.json ↔ .env (verified) |

## Acceptance Criteria

| # | Description | Result | Note |
|---|---|---|---|
| AC1 | IPA installato e si apre senza crash su iPhone 15 Pro | ✅ PASS | Sideloadly install, app si apre senza crash, screenshot 1 (`pairing-failed-pre-fix.png`) cattura solo il primo tentativo PRE-fix bind, non un crash |
| AC2 | IPA installato e si apre senza crash su iPhone 14 Pro | ⚠️ N/A | PM solo, nessun secondo device disponibile. Deviazione documentata in `README.md` § Device matrix |
| AC3 | Harness raggiungibile dal device tramite Cloudflare tunnel (200 OK) | ✅ PASS (LAN+CF) | Harness diag mostra Cloudflare Quick Tunnel attivo + 11 req/h heartbeat. Test specifico da 4G (no WiFi) **deferred** al QA gate mercoledì 30 con tunnel CF named (decisione PM 2026-04-28). Caveat: test su LAN+CF Quick valida la pipeline non la failover di rete cellular |
| AC4 | Diag panel mostra TUTTI verdi su iPhone 15 Pro | ✅ PASS | Screenshot 2 (`settings-harness-configured.png`): Permissions all green (Mic, Contacts, Calendar, Notifications), Harness Backend `Configured`, Cloudflare Quick Tunnel attivo, 11 req/h |
| AC5 | `00-setup.md` esiste e contiene tutti i campi obbligatori | ✅ PASS | Questo file |

## Findings & deviations from runbook

### Bug discovered & fixed during setup
- **BUG-1**: `config.example.json` (Win baseline) contiene `server.host: "127.0.0.1"` come default → harness non raggiungibile da iPhone su LAN. Fix locale durante setup: `host: "0.0.0.0"`. **Tracciato come follow-up** (issue da aprire post #64) — va corretto nell'example.
- **BUG-2**: `start-all.sh` non installa deps in `03_HARNESS/browser-pool/` → bridge crasha al primo avvio fresh clone con `Cannot find package 'playwright-core'`. Workaround: `cd 03_HARNESS/browser-pool && npm install` manuale. **Tracciato come follow-up**.
- **BUG-3**: `kill.sh` usa `pkill` (Unix-only) → non killa harness su Win Git Bash (`pkill: command not found`). Workaround: `taskkill //F //PID <pid>` con PID risolto via netstat. **Tracciato come follow-up**.

### Device matrix deviation
- AC2 (iPhone 14 Pro backup) marked N/A — PM ha un solo device.
- Tutti gli AC successivi del QA gate che richiedono strict D1+D2 saranno degraded/single-device.

### Tunnel scope
- Tunnel Cloudflare **Quick** attivo durante setup (URL random `*.trycloudflare.com`). Sufficiente per AC4 diag verde.
- Tunnel **named** (hostname stabile) NON setupato. Decisione: deferred al QA gate mercoledì 30 se serve evidenza 4G end-to-end. Il pairing iPhone è funzionato comunque tramite quick tunnel + LAN bind.

## Evidence files (allegati)

| File | Content | Note |
|---|---|---|
| `screenshots/pairing-failed-pre-fix.png` | Screenshot iPhone "Pairing failed - Harness unreachable" | Documenta BUG-1 (host 127.0.0.1 default), pre-fix |
| `screenshots/permissions-all-green.png` | Screen Onboarding Permissions: 4 toggle verdi | Mic + Contacts + Calendar + Notifications granted |
| `screenshots/settings-harness-configured.png` | Settings → Harness Backend: `Configured` + Cloudflare Quick Tunnel attivo + 11 req/h | AC4 evidence principale |
| `harness-boot-log.txt` | Estratto log harness al boot (last 10 righe) | Riferimento heartbeat + bind |

## PM sign-off

> "Setup OK, procedo W2-W4."
>
> Armando Battaglino — @ArmandoBattaglino — 2026-04-28

(Questo block sarà confermato nel comment di chiusura su issue #64.)
