# GIGI — Capability Map (rework decisional)

> Generato 2026-05-07 da `main @ 7ec7e94` per il rework `armando-rework`.
> Branch: `armando-rework` · Worktree: `GIGI-work/Armando-Rework`.
> Owner: Armando (PM e ora unico dev).

Questo doc è il **cruscotto** per decidere cosa tagliare. Le 4 sezioni dettagliate sono linkate sotto.

## Sezioni

| File | Capability totali | Scope |
|---|---|---|
| [CAPABILITIES_iOS.md](CAPABILITIES_iOS.md) | 56 | App `02_GIGI_APP/` (Swift/SwiftUI) |
| [CAPABILITIES_harness.md](CAPABILITIES_harness.md) | 38 | Harness `03_HARNESS/` (Node) |
| [CAPABILITIES_infra.md](CAPABILITIES_infra.md) | ~38 | MDM, GH Actions, hooks, scripts, runbooks |
| [CAPABILITIES_crosscut.md](CAPABILITIES_crosscut.md) | 30 user-facing | Vista trasversale iOS+Harness end-to-end |

**Totale ~160 capability** mappate (con sovrapposizione ovvia tra cross-cut e i singoli moduli).

## TL;DR — quello che puoi tagliare subito (alta confidenza)

### KILL LIST (dead-code, zero callers, candidati immediati)

**iOS** (`02_GIGI_APP/`):
1. `GigiMDNSDiscovery.swift` — Bonjour LAN browser, mai chiamato. Eredità di un LAN-only mode mai attivato.
2. `GIGIWidget/GIGIWidget.swift` + `AppIntent.swift` — template Xcode boilerplate ("Time:" + favoriteEmoji), NON registrato in `GIGIWidgetBundle.body`.
3. `MemoryHintView.swift`, `DraftMessagePreviewSheet.swift`, `PermissionConfirmationSheet.swift` — tre sheet definiti, mai instanziati. Residui di sub-issue #47/#77/#79.
4. **Doppio QR scanner**: `GigiPairScanner` (VisionKit) + `HarnessQRScanner` (AVFoundation legacy) — duplicato esplicito, tieni VisionKit.

**Harness** (`03_HARNESS/`):
1. **Channel router Telegram/WhatsApp** + adapters (`channels/telegram.js`, `whatsapp.js`, `audio/{stt,tts,normalize}.js`, `identity/user-mapper.js`, `channel-router.js`) — ~7 file, il file stesso dichiara "GIGI is iPhone-only" e ritorna 410 di default.
2. **Triplo path browser**: `browser-pool/server.js` (Puppeteer MCP) + `server-playwright.js` (Playwright MCP) + `driver.js` (Playwright diretto). Tieni `driver.js`, butta gli altri due.
3. Endpoint senza caller iOS: `GET /api/ios/memory/all`, `POST /api/ios/push/test`.
4. Watcher di default `gigi-morning-briefing` + `gigi-meeting-prep` — entrambi `enabled:false` con prompt che presuppongono tool non garantiti.
5. **Memory store factory** astrae backend ma esiste solo `json-store.js`; `lancedb-store.js` referenziato ma file mancante. → semplifica a `json-store` diretto.

**Infra**:
1. `setup-post-mvp-status.yml` — workflow one-shot già eseguito, dormant.
2. `scripts/setup-project.sh` — idem, dormant.
3. Subagent `timeline-poster` + `bug-tracker` referenziati in CLAUDE.md ma `.claude/agents/` **non esiste**. Doc disallineata, fallback shell funziona — o crei i subagent o tagli i riferimenti dalla doc.
4. MDM server (`01_SERVER_MDM/`) — legacy/dormant, mai stato runtime. Pairing è sempre stato HTTP+QR. Conservare solo se serve a computer-use supervised post-MVP.
5. `health-check.yml` monitora 5/10 workflow attivi (gap, da sistemare o togliere).

**Cross-cut sperimentale / dev-only**:
- `GigiWebAgent`, `GigiVectorStore`, Context Caching, Meta-classifier, Streaming TTS, CoreML Instant, `GigiPlanner` deprecato, memory-upgrade v4, multi-user federated, Iroh killed, Tailscale demoted, Admin Panel dev-only, Diagnostics dev-only — **14 capability sperimentali** che possono essere stralciate senza impatto MVP.

### CHIRURGIA DA FARE (non kill, ma consolidamento)

1. **Doppio path Claude**: `claude-runner.js` (CLI subprocess, Claude Code subscription) vs `ios-computer-use.js` (Anthropic SDK cloud, billing token). **Decisione di prodotto richiesta**: tieni uno o l'altro, non entrambi. Risparmio: significativo (un'intera dipendenza).
2. **`GigiPlannerEngine` (task decomposer Groq) vs `GigiDayPlanReasoner` (day planner LLM)**: naming clash, fanno cose diverse. Mai consolidato. `GigiDayPlanReasoner` è chiamato SOLO in DEBUG da `GIGIApp` — feature ancora in piano.
3. **Wake Word** è kill-switched (#102), ma classe ~600 righe + flag UserDefaults letti da Presence/Dashboard sono ancora live. Se non lo riattivi, taglia.
4. **Google Sign-In + GoogleSignIn SDK**: serve solo per Gemini Live (livello 0 cascade). Se tagli Gemini Live + RealtimeEngine, tutto AuthManager diventa cull.
5. **`GigiToolRegistry` ha 38 tool** in Better-Siri Action. Sfoltire a ~8 tool è il taglio chirurgico più impattante per la complessità del Better-Siri path.
6. **Setup wizard 4-mode** (`api/setup.js`): manual / quick / lan / named — ridondante. Tieni named OAuth, butta manual + lan se non li usi.
7. **Admin panel** (~1500 righe, 37 route, port 7778): utile in dev, eliminabile in deployment minimal.

### NON TOCCARE (alto removal cost, sono il backbone)

1. **`GigiSmartOrchestrator` + `GigiAgentEngine` + `GigiActionDispatcher`** — convergenza obbligata di ogni voice path, ognuno chiamato da 8+ file. Refactor sì, kill no.
2. **`GigiKeychain`** — usato in 20 file. Toccarlo = riassemblare tutta la storage secrets.
3. **`GigiHarnessClient`** — backbone della delegation V3 (11+ siti chiamanti, 14 endpoint).
4. **Talking Session / Presence Mode** — ~16 file iOS+Harness, cuore MVP.

## Sorprese architetturali da sapere prima del rework

- `GigiHarnessStream` **non è in un file separato** (contraddice `docs/COMPONENTS.md`): è inline dentro `GigiHarnessClient.swift:551`.
- Zero test in `03_HARNESS/` — niente `test/`, niente `*.test.js`. Se introduci breakage durante il rework, te ne accorgi solo a runtime.
- 8 decisioni de-facto NON sono ADR (memory backend, computer-use model, drop Telegram, env-var, port mapping, Bearer secret, `GigiPlanner` deprecato, no ambient listening). Da promuovere ad ADR per blindare il rework.
- ADR `0001` (Cloudflare Tunnel) è l'unico esistente ed è coerente. Tutto il resto del routing è "tribal knowledge".
- `ARCHITETTURA_V3.md` ha contraddizioni interne: §"Struttura" cita ancora `telegram-bridge/` (driopato), §8 descrive `GigiWebAgent` (assente in `COMPONENTS.md`), §13 descrive `GigiRealtimeEngine` (assente in MVP_SCOPE), §9 vs §9.BIS descrivono due backend diversi.

## Cosa rimane MVP-critical (NON tagliare prima del lancio)

Da `docs/MVP_SCOPE.md` + cross-cut analysis, **~10 capability strettamente in-scope MVP**:

1. Voice Activation (Action Button / Shortcut trigger)
2. Talking Session (Quick Talk continuous)
3. Dynamic Island (descent + alert)
4. Preference Memory
5. Day Plan
6. Active Help
7. Better-Siri-with-Permission
8. Confirm Mode (action confirmation flow)
9. Pairing (QR code)
10. Session Resume Claude

Tutto il resto (~20 capability user-facing + 100+ moduli interni) è candidato sfoltimento se non serve a queste 10.

## Suggerimento operativo per il rework

**Fase 1 — Kill list (1 commit)**: cancella i file della KILL LIST. Build verify. Se passa, push.
**Fase 2 — Consolidamento Claude path (1 commit)**: scegli CLI subprocess vs SDK cloud, rimuovi l'altro.
**Fase 3 — Sfoltimento Tool Registry (1 commit)**: `GigiToolRegistry` da 38 → 8 tool MVP.
**Fase 4 — Sperimentali (1 commit)**: stralcio 14 capability sperimentali.
**Fase 5 — ADR formalization**: scrivi gli 8 ADR mancanti.
**Fase 6 — Doc reconciliation**: allinea `ARCHITETTURA_V3.md` + `COMPONENTS.md` allo stato reale post-rework.

Build verify dopo ogni fase. Se rompe qualcosa di MVP, rollback solo della fase rotta.
