# Task plans Phase 2-4 + 5 — 15 GATE modulari (8 ribilanciamento + 6 capability expansion + Smart Router)

> **Cartella**: `docs/taskplans_new_gigi/`
> **Generata**: 2026-05-11 — aggiornata post Groq removal
> **Branch**: `armando-rework`
> **Piano master di riferimento**: `C:/Users/arman/.claude/plans/frolicking-stargazing-pancake.md` (~1080 righe, user-private)
> **Documento PM friendly**: `docs/HOW_GIGI_WILL_WORK.md` (italiano, 14 sezioni)
> **Ultimo commit cleanup**: `<groq-removal-SHA>` — Groq backend rimosso dal main flow (2026-05-11)
>
> ## ⚠️ Update Groq removal (2026-05-11)
>
> Groq cloud (llama-3.3-70b agent loop + llama-3.1-8b planner) è stato **rimosso dal main flow** prima di GATE 0. Razionale: il free tier saturava velocemente e bloccava i test E2E. Il main flow corrente è:
>
> ```
> GigiAgentEngine.process()
>   ├── Gate 1 — NLU rule-based fast-path (24 intent on-device)
>   └── Gate 2 — Harness Claude bridge (per tutto il resto)
> ```
>
> Cosa è stato rimosso fisicamente:
> - `GigiPlannerEngine.swift` → `_legacy/`
> - `GigiAgentEngine.agentLoop` + `orchestratedExecution` + `executeParallel` + `executeToolCall` + `buildMemoryBlock` + `safetyLock` + `pastUserUtterances` (~457 righe)
> - `GigiCloudService.swift` ridotto a thin shell (185 righe vs 496) con stub noop per `extractTasksRaw`, `askRaw`, `summarizeNews`, `testKey`
> - Dashboard "GIGI Brain (Groq)" card + Settings sezione Groq key + Onboarding apiKeyStep (step 2)
> - `GigiWebAgent+Vision` Groq vision call → throws "Web vision unavailable" finché GATE 5 MCP harness-browser
> - `GigiBrainDiagnostics` updated per non riferire Groq
>
> Cosa resta come stub `noop` (i caller funzionano ma feature-degradate):
> - `GigiTaskExtractor.extract` ritorna empty array — task extraction live torna in GATE 3 via Apple FM Tool
> - `GigiFallbackEngine.askRaw` throws `featureUnavailable` — Q&A fallback via harness Claude
> - `GigiActionBridge.summarizeNews` ritorna prefix(200) raw — news summarization torna in GATE 3
>
> Le sezioni GATE che ancora menzionano "Groq" sono storiche (contesto) — nessun task implementativo deve chiamare Groq. Se ne trovi una che lo fa: bug, apri sub-issue.

Questa cartella contiene **8 task plan modulari**, uno per ogni GATE del piano di ribilanciamento architetturale GIGI verso 5-path (Apple FM router + Path 1 NLU + Path 2 Apple FM Tools + Path 3 Ollama harness + Path 4 Claude Code subprocess + Path 5 Reject). Ogni GATE è autonomo: ha pre-condizioni esplicite, task implementativi granulari, AC verificabili binari, test E2E numerati pronunciabili sull'iPhone, **test post-creazione ripetibili anche fra mesi**, rollback plan, file table modificati/creati, ADR collegati, e suggested Conventional Commits.

L'obiettivo finale: GIGI v0.1.0 OSS-ready, demo "Tesla → nota" in <90s, zero API a pagamento, chunknque cloni il repo riesce a far girare la demo in <30 min.

---

## Tabella riassuntiva 8 GATE

| # | Title | Effort | Status | Depends on | Brief outcome |
|---|---|---|---|---|---|
| **0** | Build verify post-cleanup | ~45 min | ✅ DONE (2026-05-11) | nessuno | Baseline `armando-rework` compila (SHA `519f235`), IPA installa, 3 tab, Brain Path Override visibile |
| **1** | Spike A — Apple FM iOS 26.4 regression | 1 g | 📋 SCAFFOLD READY (2026-05-12) | GATE 0 | 50 query test set + results template scritti (`docs/research/spike-a-*.md`); manca esecuzione su device + chiusura ADR-0011 |
| **2** | Router Apple FM upfront | 3-5 g | ✅ IMPLEMENTED (2026-05-12) | GATE 1 + Q11 | `FoundationRouterDecision @Generable` + `routerSystemPrompt` + `GigiRequestRouter` 5-path + AgentEngine wired; ADR-0007 Accepted |
| **3** | Path 2 — Apple FM Tool calling (15 tool) | 4-6 g | ✅ IMPLEMENTED (2026-05-12) | GATE 2 + Q2 | 15 `FM*Tool` struct + `respondWithTools` round-trip via `dispatchNativeTool` (feature flag default-on) + `GigiFallbackRouter` keyword; ADR-0008 Accepted |
| **4** | Path 3 — Ollama harness | 4-5 g | ✅ IMPLEMENTED (Spike B pending, 2026-05-12) | GATE 3 + Spike B | `ollama-client.js` full + `ios-local-llm.js` SSE + `runLocalLLM` Swift + Settings ollamaSection (tier picker + status); ADR-0010 Accepted |
| **5** | Path 4 — Claude Code subprocess + MCP | 5-7 g | ✅ IMPLEMENTED (Spike C pending, 2026-05-12) | GATE 4 + Spike C | Real subprocess via `gigiServer.runClaude` con `mcpServers=["harness-browser"]` → SSE stream; `ios-computer-use.js` deprecato → `examples/.legacy`; `@anthropic-ai/sdk` rimosso da package.json; `unset ANTHROPIC_API_KEY` in `start-harness.sh`. ConfirmComputerUseSheet UI client-side. Manca: server `confirm_required` event (Claude CLI feature pending upstream) |
| **6** | Killer demo Tesla → nota | 2-3 g | ✅ IMPLEMENTED (device tests pending, 2026-05-12) | GATE 5 | 2-turn callback wired in `GigiRequestRouter.dispatchDelegateCloud` → `detectFollowUpAction` matcha 3 verb pattern (note/reminder/email) + sintetizza secondary decision con summary as body; `FMCreateNoteTool` aggiunto come 16° tool; `GigiActionBridge.createNote` (clipboard + Notes app); 5 demo scenarios doc |
| **7** | Modes UI + setup wizard | 3-4 g | ✅ IMPLEMENTED (2026-05-12) | GATE 6 | `GigiMode` enum + `GigiModeDetector` + `ModesSelectionView` (4 cards) + Settings modesSection + `setup-oss-demo.sh` 10-step idempotent |
| **8** | Hardening + OSS release v0.1.0 | 5-7 g | 📋 DOCS READY (device tests + tag pending, 2026-05-12) | GATE 7 | README + LICENSE Apache 2.0 + CHANGELOG v0.1.0-rc + `docs/release/DEMO_VIDEO_SCRIPT.md` 3-min storyboard + `docs/release/v0.1.0-release-checklist.md` 10 AC + dep audit + 12-step tag procedure. Manca: device tests Spike A/B/C + demo video recording + tag |

**Totale effort stimato GATE 0-8: 28-39 giorni lavorativi**, in linea con il piano §10 (5.5-6.5 settimane / 27-32 giorni). Il range superiore include buffer per Spike B/C + rework iterativo.

---

## Tabella riassuntiva 5 GATE Capability Expansion (POST-MVP)

> **Origine**: master plan `docs/plans/gigi-capability-expansion-2026-05-12.md` (~600 righe, 13 sezioni)
> **Scope**: espandere GIGI da 17 a ~62 tool su Apple FM + introdurre meccanismo di discovery a 4 layer (Onboarding, Conversational, UI Sheet, Proactive)
> **Trigger**: MVP shippato (1 maggio 2026) + beta tester onboardati
> **ADR target**: ADR-0010 *"Tool taxonomy + discovery UX"* (Proposed → Accepted alla chiusura GATE 12)

| # | Title | Effort | Status | Depends on | Sub-gate | Brief outcome |
|---|---|---|---|---|---|---|
| **9** | Capability Week 1 — Power User Unlock | ~12h | 📋 PLANNED (2026-05-12) | MVP shipped | 9.A→9.D | `run_shortcut` meta-tool (universal Shortcuts bridge) + `set_homekit_scene` + `web_search` (Safari) + Onboarding Layer A (3-step tour). 18→21 tool. |
| **10** | Capability Week 2 — Productivity Boost | ~14h | 📋 PLANNED (2026-05-12) | GATE 9 | 10.A→10.D | `create_calendar_event` (EventKit) + `add_to_note` (Shortcut bridge) + 3 utility (clipboard/battery/flashlight) + 3 knowledge mini (define/calculate/translate) + **Layer B Conversational Discovery** (`discover_capabilities` pseudo-tool intercept). 21→29 tool. |
| **11** | Capability Week 3 — Ambient & Social | ~14h | 📋 PLANNED (2026-05-12) | GATE 10 | 11.A→11.D | HomeKit fine control (brightness/color/thermostat) + Location (get_now + share) + Messaging deep links (email/Telegram/Signal) + Focus mode. 29→38 tool. |
| **12** | Capability Week 4 — Knowledge & Meta + Discovery UI | ~14h | 📋 PLANNED (2026-05-12) | GATE 11 | 12.A→12.D | `web_search_inline` (DDG instant answer, no Safari) + `scan_document` (VisionKit) + `get_news_headlines` + `repeat_last_action` + `undo_last_action` + **Layer C UI Sheet** (Dashboard tab "Capabilities" con 7 categorie tap-to-try). ADR-0010 promosso Accepted. 38→43 tool. |
| **13** | Capability Week 5+ — Long Tail + Proactive Suggestions | 20-40h variabile | 📋 PLANNED (2026-05-12) | GATE 12 + telemetry MVP | 13.LT + 13.P1+P2+P3 | ~20 long-tail tool prioritized backlog (block_number, move/cancel calendar, podcast/playlist, sensor, geofence reminder, set_volume, screenshot, list_shortcuts, ecc.) + **Layer D Proactive Suggestions** (`GigiSuggestionEngine` + 3 provider concreti + opt-in flow). 43→~62 tool. ADR-0010 finale. |
| **14** | Capability Week 6 — Macro Engine + Voice Authoring + Shortcut Alias Registry | 15-18h | 📋 PLANNED (2026-05-12) | GATE 13 + telemetry | 14.A→14.D + 14.B.2 | **Macro Engine in-process GIGI** bypassa il signing-wall di Apple Shortcuts. User dice *"when I say 'gym time' do A+B+C"* → Apple FM (o Claude Code per condizionali) parsa → save CloudKit → trigger phrase invoca sequence di tool. 4 nuovi tool (`create_macro`, `list_macros`, `delete_macro`, `edit_macro`). **Sub-gate 14.B.2 NUOVO**: Shortcut Alias Registry — user declara *"open torch"* come alias del proprio Shortcut *"accendi torcia"* (literal match + AI semantic match con one-shot learning per varianti). ADR-0011 PROPOSED → Accepted. 62→66 tool + macro infinitamente componibili + alias intelligence sui Shortcut utente. |
| **15-prev** | Smart Router Architecture — semantic embedding fast-path (anticipato PRE-GATE 10 per fixare mis-routing) | MVP shipped 2026-05-12 (~4h); phase 2 +6-10h | ✅ MVP SHIPPED (2026-05-12) — phase 2 PLANNED | nessuno (richiede solo GigiVectorStore + 22 tool registry) | MVP shipped, phase 2 deferred | **GigiSemanticRouter** (NLEmbedding fast-path + ADR-0012). Catalog 22 tool × 5-12 trigger phrases EN+IT, cosine similarity vDSP_dotpr ~3-5ms per query. Hook in `GigiRequestRouter.route()` PRIMA di Apple FM. Top-1 ≥0.55 + gap ≥0.05 → dispatch diretto; below threshold → fall through ad Apple FM (no regression). Sostituisce i regex intercept di GATE 9.A/9.C che non scalavano. **NB**: questa riga è la fondazione su cui poggia il GATE 15 (file `GATE-15-shortcut-intelligence-proactive-routing.md`). MVP semantic catalog hardcoded resta come `staticCatalog`; il nuovo GATE 15 estende con `dynamicCatalog` dinamico dai Shortcut registrati. |
| **15** | Smart Action Loop — Plan / Confirm / Build / Learn | ~6-8h | 📋 PLANNED (refactored 2026-05-13) | Phase 2 ADR-0014 (commit `8a4f1eb`) | 15.A→15.E | **5-step user-driven decision tree** sopra `GigiShortcutRegistry`. Step 1 EXECUTE TRY (Layer A NLU + B registry + C semantic + D Apple FM dynamic tool). Step 2 PLAN — server split `POST /compose-shortcut/plan` (Claude only, returns `{planId, title, summary, actions, aliases, systemPurpose}`, plan held 5min TTL). Step 3 BUILD — `POST /compose-shortcut/build {planId}` consume plan + cherri compile + sign. Step 4 LEARN — auto-register in registry + reload semantic router + toast `"I learned 'X'. Next time you say 'Y' I'll run it directly."`. Step 5 RECOGNIZE — next utterance Step 1 matches, no card. iOS proposal card (`ShortcutProposalCard.swift`) con title + summary + numbered actions emoji + Build/Cancel CTAs. Tutti gli user-facing strings in inglese. ADR-0015 PROPOSED → Accepted. Layer 4 vecchio (pattern detection) spostato in GATE 15.5 Daydream. |
| **15.5** | Daydream — Predictive Shortcuts | ~6-8h | 📋 PLANNED — defer post-MVP | GATE 15 COMPLETED + ≥7d soak | 15.5.A→15.5.C | **Predictive (proactive) layer** sopra Smart Action Loop. Harness watcher `watchers/daydream.js` ogni 6h chiede a Claude *"data cronologia 7d intent + calendario 24h, ci sono Shortcut che farebbero comodo?"* → proposals salvati in `daydream-queue.json` → APNS push → iOS `DaydreamInboxView` pill in ChatView top-bar + sheet con `ShortcutProposalCard` (riusati da GATE 15). Tap Build → GATE 15 Step 3+4. Tap Dismiss → 30-day cooldown su `systemPurpose`. **Privacy-first**: default OFF, opt-in toggle Settings, intent-label-only payload, calendar opt-in radio (count-only / titles), 0 raw speech text mai inviato. NON è blocker MVP. ADR-0016 PROPOSED → Accepted. |

**Totale effort GATE 9-15.5**: ~95-125h (~14-16 giorni full-time, oppure 7-9 settimane part-time @ ~15h/settimana). GATE 15 aggiunge ~6-8h e GATE 15.5 (deferred post-MVP) altri ~6-8h sopra il baseline.

**Capability count finale**: 17 → ~66 tool + macro engine (infinite combinazioni custom). **Discovery completo**: 4 layer (A/B/C/D) accessibili da onboarding, voce, UI passive, proactive + macro voice-authored.

**🌍 Language compliance (hard rule)**: tutte le user-facing string in **inglese** (TTS, Text/Button/Label SwiftUI, Alert, showBanner, push body, accessibility hint, App Store metadata). Italiano consentito ESCLUSIVAMENTE in doc internal, code comment, ADR, commit message, body issue/PR, log structured. Verificato in ogni GATE via grep guard `bash docs/runbooks/language-audit.sh` (creato come deliverable GATE 14, applicato retroattivamente come pre-commit hook ai GATE 9-13).

---

---

## Dependency graph

```
GATE 0 (build verify)
   │
   ▼
GATE 1 (Spike A Apple FM 26.4)  ─── DECISION Q11 ───┐
   │                                                │
   ▼                                                │
GATE 2 (Router Apple FM upfront) ◄──────────────────┘
   │
   ├─────────────────┬─────────────────┐
   ▼                 ▼                 ▼
GATE 3 (Path 2     GATE 4 (Path 3   (parallelo opt-in: nessuno)
 Tool calling)      Ollama)
   │                 │
   │                 │
   └────────┬────────┘
            ▼
        GATE 5 (Path 4 Claude Code + MCP)
            │
            ▼
        GATE 6 (Killer demo Tesla → nota)
            │
            ▼
        GATE 7 (Modes UI + setup wizard)
            │
            ▼
        GATE 8 (Hardening + OSS release v0.1.0)
            │
            ▼
        🎉 v0.1.0 OSS public launch
            │
            │  ─── POST-MVP capability expansion (linear) ───
            ▼
        GATE 9 (Week 1 — power user unlock: run_shortcut + homekit_scene + web_search + Onboarding A)
            │
            ▼
        GATE 10 (Week 2 — productivity: calendar/note/utility/knowledge mini + Layer B discovery)
            │
            ▼
        GATE 11 (Week 3 — ambient & social: HomeKit fine + location + messaging deep links + focus)
            │
            ▼
        GATE 12 (Week 4 — knowledge meta + Layer C UI Sheet — ADR-0010 Accepted)
            │
            ▼
        GATE 13 (Week 5+ — long tail + Layer D Proactive Suggestions)
            │
            ▼
        GATE 14 (Week 6 — Macro Engine + voice authoring — ADR-0011 Accepted)
            │
            ▼
        GATE 15 (Smart Action Loop — ADR-0015 Accepted)
            │  (può anche essere fatto SUBITO dopo Phase 2 ADR-0014, non richiede GATE 9-14)
            ▼
        🚀 v1.1 GIGI capability-rich + 4-layer discovery + voice-authored macro automation + Smart Action Loop user-driven
            │
            │  ─── DEFERRED post-MVP ───
            ▼
        GATE 15.5 (Daydream — Predictive Shortcuts — ADR-0016 Accepted)
            │  (richiede GATE 15 COMPLETED + ≥7d soak test)
            ▼
        🌙 v1.2 GIGI proactive (with explicit opt-in)
```

**Note sul grafo**:
- GATE 3 e GATE 4 sono **parallelizzabili** dopo GATE 2 chiuso (un dev su Path 2, l'altro su Path 3). Ma siccome Armando lavora da solo, di fatto sono sequenziali.
- GATE 5 richiede AMBEDUE chiusi (Path 4 fa fallback su Path 3, e killer demo GATE 6 richiede chain Path 4 → Path 2)
- GATE 1 può sembrare "blocchino" da 1 giorno ma il suo verdetto può richiedere riprogettazione GATE 2 (se Spike A FAIL grave)

---

## Q-decisions bloccanti

Le decisioni PM aperte che **devono essere chiuse** prima di poter avanzare:

| Q | Domanda | Stato | Sblocca | Default conservativo |
|---|---|---|---|---|
| **Q2** | Lista finale 15 tool Apple FM | OPEN | GATE 3 | `set_timer, set_alarm, set_reminder, send_message, make_call, facetime, navigate, play_music, open_app, weather, read_calendar, find_free_slot, read_email, homekit_on, homekit_off` (15 tool, `delegate_to_claude` escluso e gestito come fallback nel router) |
| **Q11** | iOS deployment target 26.3 (pin) vs 26.4 (feature flag) vs unrestricted | OPEN | GATE 2 | Decidere DOPO GATE 1 (Spike A risultati). Default: pin 26.3 finché 26.5+ stabile |

Decisioni di prodotto già prese (`bdc393a`, ADR-0006):
- D1 Force Claude → DEBUG only + Brain Path Override picker (4 opzioni)
- D2 HomeKit kept (5 tool da includere in Q2 subset)
- D3 Tab Presence rimossa (3 tab)
- D4 TalkingSessionTaskListView keep + TODO migration
- D5 WhatsApp consolidato in Settings
- D6 Onboarding profile opt-in (6 step)
- D7 Brain pill Dashboard rimossa
- D8 Tailscale banner rimosso

---

## Spike empirici (Phase 1.1)

Il piano §5 prevede 4 spike empirici da fare PRIMA di committarsi all'implementazione. Sono distribuiti nei GATE:

| Spike | Cosa misura | Pass criteria | Incorporato in |
|---|---|---|---|
| **A** — Apple FM iOS 26.4 regression | Tool selection accuracy, slot extraction, false reject rate, latency P50/P95 su 50 query (3 run ognuna) | 26.4 drop ≤15%, false reject ≤10%, latency ≤2s | **GATE 1** (intero) |
| **B** — Qwen tier-based Ollama validation | BFCL accuracy %, latency P50/P95, RAM peak, loop rate per Qwen 3 4b/8b/14b + Qwen 3.6-27b su 40 query + 200+ multi-turn tool call | Default tier (qwen3:14b) BFCL ≥75%, loop rate <5% | **GATE 4** (Task 4.1-4.2) |
| **C** — Claude Code subscription burn rate | Messages consumed per 5h rolling window, time-to-exhaustion | Pro <30 msg/5h on demo-like usage; Max 5x comfortable | **GATE 5** (Task 5.1) |
| **D** — SwiftMCP feasibility | Latency vs Path 4, context budget con 3 tool MCP attivi | ≥50% faster than Path 4, ≥5 turn sustainable | NON in scope MVP — deferred a Phase 5 post-v0.1.0 |

Ogni Spike ha skeleton in `docs/research/phase-1-1-empirical-validation.md`.

---

## Total effort

| Phase | Range | Razionale |
|---|---|---|
| GATE 0 — Build verify | 0.1 g (~45 min) | CLI + visual check, no codice |
| GATE 1 — Spike A | 1 g | 6-8h test + scrittura ADR |
| GATE 2 — Router upfront | 3-5 g | Schema + GigiRequestRouter ~280 righe + integration |
| GATE 3 — Path 2 (15 tool) | 4-6 g | 15 Tool struct (~50min ognuno) + Fallback router + tool coverage test |
| GATE 4 — Path 3 (Ollama) | 4-5 g | Spike B 1.5g + harness wrapper + iOS extension + Settings tier UI |
| GATE 5 — Path 4 (Claude Code) | 5-7 g | Spike C 0.5g + WS endpoint + ConfirmSheet + dep removal |
| GATE 6 — Killer demo | 2-3 g | 2-turn callback + 5 demo scenarios test |
| GATE 7 — Modes + setup wizard | 3-4 g | ModesSelectionView + setup script + auto-detect |
| GATE 8 — Hardening + release | 5-7 g | 10 AC test + demo video + license audit + tag |
| **Totale** | **27-40 g** | (matches piano §10 5.5-6.5 settimane) |

In settimane lavorative: **6-8 settimane** se Armando lavora pieno time, **3-4 mesi** part-time.

---

## How to use this folder

### Workflow normale

1. **Apri INDEX (questo file)** per il quadro generale
2. **Scegli il prossimo GATE** in base al dependency graph (GATE 0 se all'inizio, altrimenti il primo non chiuso che ha le pre-condizioni satisfied)
3. **Apri il file MD del GATE** (es. `GATE-2-router-applefm-upfront.md`)
4. **Leggi sezioni 1-2** (Obiettivo + Pre-condizioni) per assicurarti di essere pronto
5. **Esegui Task implementativi §3** in ordine, committando per ognuno (Conventional Commits suggeriti in §10)
6. **Verifica AC §4** uno per uno, marcando ✅
7. **Esegui Test E2E §5** sul telefono fisico, registrando in `docs/research/gate-N-*.md`
8. **Verifica §6** (post-creazione) prima di marcare il GATE come "PASS"
9. **Aggiorna INDEX** marcando il GATE come COMPLETED con data
10. **Passa al GATE successivo**

### Workflow rollback

Ogni GATE ha §7 (Rollback plan). Se trovi un bug critico post-merge:
1. Apri sub-issue su GitHub (label `release-blocker`)
2. Esegui `git revert <SHA-gate-N>` OR attiva feature flag se disponibile
3. Documenta in ADR (se decisione architetturale)
4. Re-pianifica GATE con fix integrato

### Workflow review autonomous (3 mesi dopo)

Ogni GATE ha §6 (Test post-creazione) progettata per essere **ripetibile autonomamente anche dopo mesi**. Permette ad Armando di:
- Verificare che il GATE è davvero chiuso
- Detectare regressioni se OS update / dependency change ha rotto qualcosa
- Re-creare il context dimenticato

Esempio: tra 3 mesi Armando vuole sapere "GATE 2 router upfront è chiuso?". Apre `GATE-2-router-applefm-upfront.md`, va a §6, esegue i 6 grep + xcodebuild + runtime check. Se tutti OK, GATE è ancora chiuso. Se uno fail, è regressione.

---

## Verification post-creation — design philosophy

Ogni task plan ha sezione §6 con 3-4 categorie di test:

1. **Filesystem / grep**: comandi shell che verificano che file/strutture esistono con pattern specifici
2. **Build verify**: `xcodebuild` SSH MacInCloud OR `npm test` harness
3. **Runtime inspection**: log Console.app pattern, debug overlay, behavior specifico
4. **Git log**: SHA commit + diff summary attesi

Questa sezione è **critica**: senza di lei un task plan vecchio è inutile (non si può verificare). Con lei, Armando ha sempre un check-the-pulse veloce per ogni GATE.

---

## File di riferimento esterni

| File | Descrizione | Path |
|---|---|---|
| Piano master | Architettura completa 5-path | `C:/Users/arman/.claude/plans/frolicking-stargazing-pancake.md` |
| Doc PM friendly | Spiegazione discorsiva italiana | `docs/HOW_GIGI_WILL_WORK.md` |
| Research validation | Spike A/B/C/D skeleton | `docs/research/phase-1-1-empirical-validation.md` |
| ADR 0001-0006 | Decisioni architetturali già approvate | `docs/adr/` |
| ADR 0007-0012 | Placeholder Phase 2-5 (chiusi nei rispettivi GATE) | `docs/adr/` |
| Knowledge LLM | Deep dive Qwen ecosystem | `docs/knowledge/llm-open-source-research.md` |
| Knowledge NLU | NLU primer | `docs/knowledge/nlu-primer.md` |
| Commit cleanup | Pre-Phase 2 prep state | `bdc393a` |

---

## Changelog INDEX

- **2026-05-13 (Smart Action Loop refactor + Daydream split)** — Refactored **GATE 15** from "4-layer architectural pipeline" narrative to "**Smart Action Loop** — 5-step user-driven decision tree" (Execute Try / Plan / Build / Learn / Recognize). Server endpoint `/compose-shortcut` split in `/plan` + `/build` + `/job` (5-min TTL on planId). New iOS `ShortcutProposalCard.swift` with title + summary + numbered emoji actions + Build/Cancel CTAs in chat. All user-facing strings switched to English (hard rule). Effort revised ~4-6h → ~6-8h. ADR renamed `0015-smart-action-loop.md`. Old "Layer 4 pattern detection" extracted into NEW separate plan **GATE 15.5 Daydream — Predictive Shortcuts** (`GATE-15.5-daydream-predictive-shortcuts.md`, ~6-8h, status `defer post-MVP`). Daydream is proactive (harness watcher every 6h asks Claude for context-aware suggestions → APNS push → DaydreamInboxView pill → tap Build = GATE 15 Step 3+4). Privacy-first: default OFF, intent-label-only payload, calendar opt-in radio. ADR-0016 proposed. GATE 15.5 cannot start until GATE 15 COMPLETED + ≥7 day soak test.
- **2026-05-13 (Shortcut Intelligence — original)** — Added **GATE 15 Shortcut Intelligence — Proactive Intent Routing** (`GATE-15-shortcut-intelligence-proactive-routing.md`, ~4-6h, 4 sub-gate). Chiude il loop avviato da Phase 2 ADR-0014 (commit `8a4f1eb`): dopo che `composeShortcut` genera un Shortcut, GIGI lo riconosce automaticamente al prossimo utterance via pipeline a 4 layer (alias generation al compose time, semantic router enrichment dinamico, Apple FM dynamic tool, proactive pattern detection). ADR-0015 PROPOSED. La riga "15-prev" (Smart Router MVP) resta in tabella come fondazione tecnica — il nuovo GATE 15 estende `GigiSemanticRouter` con `dynamicCatalog` senza modificare `staticCatalog`. Loop matrioska Layer 4 → Layer 1 → Layer 2 chiude la promessa "frizione zero" dell'assistente proattivo.
- **2026-05-12 (Smart Router MVP shipped)** — Added **GATE 15 Smart Router Architecture** ADR-0012. Implementato MVP `GigiSemanticRouter.swift` (NLEmbedding word vectors + 22 tool catalog × 5-12 trigger phrases EN+IT). Hook in `GigiRequestRouter.route()` PRIMA di Apple FM. Sostituisce i regex intercept di GATE 9 (run_shortcut, web_search) con un single semantic match — non scalava più. Latency ~3-5ms per query, full on-device, zero LLM tokens. Phase 2-4 (eval set, telemetry, 2-stage fallback) planned post-MVP.
- **2026-05-12 (latest)** — Added **GATE 14 Macro Engine + Voice Authoring** (~12-15h post-GATE 13). Risolve la richiesta utente *"GIGI può creare automazioni custom dinamicamente?"* bypassando il signing-wall di Apple Shortcuts: Macro Engine in-process GIGI (`GigiMacroEngine.swift` + iCloud sync via CloudKit) compone tool esistenti in sequenze voice-authored. 4 nuovi tool (`create_macro`, `list_macros`, `delete_macro`, `edit_macro`). ADR-0011 PROPOSED → Accepted alla chiusura. Master plan §6 Week 6 esteso, §13 nuova sezione "Note tecniche — perché Macro Engine invece di Shortcut programmatici" (spiega che Apple ha chiuso .shortcut signing dal iOS 16+ con crypto verification). **Rafforzato §2.6 principio HARD RULE English-only user-facing** + AC-T7 cross-cutting language audit per OGNI GATE (9-14) + R9 risk + `docs/runbooks/language-audit.sh` come deliverable GATE 14.
- **2026-05-12 (late)** — Added **GATE 9-13 Capability Expansion** (POST-MVP roadmap, ~10-12 giorni full-time): 5 nuovi task plan in `docs/taskplans_new_gigi/GATE-9-...md` → `GATE-13-...md` (~2500 righe totali). Master plan source: `docs/plans/gigi-capability-expansion-2026-05-12.md`. ADR-0010 *"Tool taxonomy + discovery UX"* in Proposed state, promosso ad Accepted alla chiusura GATE 12. Scope: 17 → ~62 tool + 4 discovery layer (A Onboarding / B Conversational / C UI Sheet / D Proactive).
- **2026-05-12** — GATE 2-3-4-5(scaffold)-7 implemented overnight by Claude Opus 4.7. ADR-0007/0008/0009/0010 → Accepted. Build SUCCEEDED. IPA dropped to Windows. Spike A scaffold ready. See `docs/HANDOFF_2026-05-12.md`.
- **2026-05-11** — versione iniziale creata, 8 GATE + INDEX
