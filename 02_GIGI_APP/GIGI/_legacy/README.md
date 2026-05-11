# `_legacy/` — codice disconnesso dal target

> Questa cartella contiene codice Swift che il rework `armando-rework` ha
> dichiarato soft-killed (ADR-0003, ADR-0005) e che il cleanup successivo
> (2026-05-11) ha disconnesso fisicamente dal target Xcode.
>
> **In Xcode questa cartella DEVE essere aggiunta come folder reference
> (cartella blu) e NON come group (cartella gialla)**, per garantire che
> i file `.swift` qui dentro non vengano compilati nel target principale.
>
> Se non sai la differenza: in Xcode, click destro sulla cartella `GIGI` →
> `Add Files to "GIGI"` → seleziona `_legacy/` → **deseleziona "Create groups"
> e seleziona "Create folder references"**.

## Perché esistono questi file

I file qui dentro sono stati "spenti" dal team senza essere cancellati,
per preservare il know-how implementativo (jitter buffer, state machine,
constraint specifici di iOS) per eventuali riattivazioni in v1.1 o
successive. Vivono in `_legacy/` invece che in `git history` per due
ragioni:

1. **Discoverability**: chiunque apra il repo li vede subito, capisce che
   sono dormienti, e sa che la storia recente è in git log
   (`git log --follow _legacy/<file>.swift`).
2. **Ridurre noise nel target di compilazione**: 952 righe complessive
   (636 WakeWord + 316 DayPlan) di codice inattivo rimosse da
   `xcodebuild` riducono surface da auditare ad ogni build.

## Inventario

| File | Righe | Disconnesso il | ADR di riferimento | Motivo |
|---|---|---|---|---|
| `GigiWakeWordEngine.swift` | 636 | 2026-05-11 | ADR-0003 (wake-word soft-kill MVP) | iOS non permette mic continuo background per app non-VoIP. Wake sostituito da hardware triggers (Back Tap / Action Button) + Siri AppIntent. |
| `GigiDayPlanReasoner.swift` | 316 | 2026-05-11 | ADR-0005 (DayPlan soft-kill MVP) | Engine per riassunto giornata calendar+preferenze. Soft-killed per scope MVP — riattivare con sub 4/4 #59. |
| `GigiBrainPipeline.swift` | 310 | 2026-05-11 | (audit zombie residui — vedi commit) | Cascade 4-livelli (Gemini Live → Apple FM → Gemini REST → NLU) sostituita prima dal planner Groq (commit `941080f`) e poi vuotata dal rework armando-rework. L'unica funzione live (`localSpeech` static) è stata migrata in `GigiFoundationAgent`. Resto della classe = zombie strutturale (`resolve()`, `refineBrainOutput()`, `entityBoostEligible()`, `enrichIntent()`, `mergeBrainParamsIfSameAction()`, `responseFromEnrichedIntent()`, `localFallback()` — zero call site). Il piano 5-path lo sostituisce con `GigiRequestRouter` upfront. |
| `GigiPlannerEngine.swift` | 139 | 2026-05-11 | (Groq removal, pre-GATE 0) | Decompose multi-task via Groq llama-3.1-8b. Sostituirà `GigiRequestRouter.FoundationRouterDecision` in GATE 2 (decomposizione gestita da Apple FM upfront, no più planner separato). Rimosso pre-GATE 0 perché il free tier Groq saturava i test E2E. Riattivabile temporaneamente ripristinando il file + reintroducendo `agentLoop` in `GigiAgentEngine`, ma sconsigliato — il 5-path plan è la migrazione strategica. |

## Codice rimosso fisicamente (NON in `_legacy/`, solo git history)

Pulizia UI 2026-05-11 (ADR-0006). Per ognuno, fare `git log --follow <path>` per recupero.

| Cosa | File / posizione storica | Motivo rimozione |
|---|---|---|
| `GuidedSetupSheet` struct (240 righe) | `DashboardView.swift` lines ~530-770 | Duplicato di `ProfileEditSheet` + chiavi italiane hardcoded. Profile single source = ProfileEditSheet. |
| `PresenceModeTabView` private struct (~50 righe) | `MainTabView.swift` | Duplicato di `PresenceView` sheet. Tab Presence rimossa (D3, 4→3 tab). |
| Debug FAB stack (5 button + ~70 righe) | `ChatView.swift` lines 75-145 | Stress-test #47/#48/#49 consolidati. |
| Debug section Settings (5 button + ToneEnrichment + Italian seed) | `SettingsView.swift` debugSection | Test #46/#47/#48/#49 consolidati. |
| Tailscale migration banner | `SettingsView.swift` migrationBannerIfNeeded | Post-Phase 4 il pairing è solo Cloudflare Tunnel. |
| `liveActivityBanner` top overlay | `MainTabView.swift` | Evita stacking di 3 banner top (pairing + harness offline + LA error). |
| Brain status pill stack (BRAIN ON/OFF + HARNESS + LOCAL AI) | `DashboardView.swift` headerRow | Consolidato in 1 dot in header (Settings → Brain section è la fonte canonica). |
| Spotify capability row | `DashboardView.swift` | Hardcoded inactive, no integration. |
| WhatsApp setup card Dashboard | `DashboardView.swift` | Consolidato in Settings → WhatsApp section (D5). |
| Force Claude toggle prod-visible | `SettingsView.swift` brainModeSection | Ora `#if DEBUG`. Piano 5-path automatizza il routing. |
| Profile step onboarding (era step 4) | `OnboardingView.swift` totalSteps 7→6 | Profilo è ora opt-in da Dashboard. |
| 7 GoogleSignIn-related SPM dependencies | `project.pbxproj` + `Package.resolved` | ADR-0004 finalization (codice già rimosso, deps SPM rimaste). |

## Come riattivare un file

Se in futuro decidi di resurrectare uno di questi:

1. **Decidi se ha ancora senso** rispetto all'architettura corrente.
   Controlla il piano corrente in `docs/rework/Architecture-Armando-Revision.md`
   per vedere se il pattern è cambiato (es. ora c'è OpenAI Realtime API
   invece di Gemini Live, quindi wake word ambient andrebbe ripensato).

2. **Sposta il file fuori da `_legacy/`**:
   ```bash
   git mv 02_GIGI_APP/GIGI/_legacy/GigiWakeWordEngine.swift 02_GIGI_APP/GIGI/
   ```

3. **Aggiungi il file al target Xcode** (se la cartella `_legacy/` era folder
   reference, il file non era nel target — ora va aggiunto manualmente
   dal target membership inspector).

4. **Riconnetti le call site** che il cleanup aveva sostituito con no-op /
   commenti. Cerca con grep i commenti del tipo
   `// wake word disconnected, see _legacy/` o
   `// DayPlan soft-killed ADR-0005` per trovare i punti di ricucitura.

5. **Scrivi un nuovo ADR** che superseda quello originale di soft-kill,
   con il razionale del nuovo design.

## Cose già fatte dal rework `armando-rework` (ADR-0004)

Altri file che il rework ha cancellato del tutto (non spostato qui),
perché ritenuti non recuperabili senza riscrittura:

- `GigiRealtimeEngine.swift` (1062 righe) — Gemini Live WebSocket pipeline
  full-duplex con barge-in. Se mai si vorrà ambient mode, valutare
  OpenAI Realtime API o Apple AVAudioEngine custom.
- `GigiAuthManager.swift` (134 righe) — Google Sign-In OAuth wrapper.
  Usato solo per scope `generative-language.retriever` (Gemini Live).
  Inutile senza Gemini.

Per il know-how di questi due, `git log --follow` sui path indica i
commit antecedenti il rework.
