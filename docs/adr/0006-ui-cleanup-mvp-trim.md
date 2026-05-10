# ADR-0006: UI cleanup MVP trim post-rework

- **Status:** Accepted
- **Date:** 2026-05-11
- **Deciders:** @ArmandoBattaglino
- **Tags:** ui, mvp-scope, dead-code, dependency-pruning, settings, dashboard, onboarding, debug-tooling

## Context

Il rework `armando-rework` (ADR-0001 → ADR-0005, commits 7e4a7f5...59df272) ha sradicato Gemini, Wake Word, Day Plan Reasoner, mDNS, channel router e Google Sign-In a livello runtime/codice, ma ha **lasciato la UI gonfia** di artefatti delle feature rimosse: setup card di feature morte, debug button da test issue chiusi, sezioni Settings duplicate, sheet voice-config wizard con stringhe italiane hardcoded, banner di migrazione Tailscale (path abbandonato post-Phase 4 QR pair), ridondanze multi-entry-point per status brain/harness, tab Presence con bug latente (manca `.tag()`).

L'audit UI condotto il 2026-05-11 (`general-purpose` subagent + revisione manuale @ArmandoBattaglino) ha identificato:

- **5 sorprese strutturali** (tab Presence senza tag, 3 UI duplicate per profilo utente, 2 sheet QuickTalk concorrenti, GuidedSetupSheet 240 righe duplicato di ProfileEditSheet, stringa italiana hardcoded in DEBUG button)
- **12 punti di rumore** (R1-R12)
- **5 ridondanze/consolidazioni** (C1-C5)
- **8 decisioni di prodotto** che richiedevano input PM (D1-D8)

Prima di iniziare il Phase 1 design doc del piano 5-path (`docs/plans/frolicking-stargazing-pancake.md`), il PM ha richiesto un cleanup UI completo per ridurre la superficie di test e rendere il branch demo-ready più chiaramente.

## Decision

Eseguiamo il cleanup UI in 3 layer applicati sul branch `armando-rework`:

### Layer 1 — Quick wins (rumore evidente, ~600 righe rimosse)

| Tag | Cosa | File |
|---|---|---|
| R1 | 3 pill stato Dashboard (Brain ON/OFF + HARNESS pill + LOCAL AI badge) → 1 dot semplice | DashboardView |
| R2+R5 | `GuidedSetupSheet` (240 righe voice-config wizard duplicato di ProfileEditSheet + chiavi italiane) | DashboardView |
| R3 | 5 debug FAB (envelope/ladybug/paperplane/xmark/pencil) per stress-test #47/#48/#49 | ChatView |
| R4 | Debug section Settings (5 test button + ToneEnrichment playground con stringa italiana) | SettingsView |
| R7 | Manual Harness config (URL + Bearer secret) nascosto dietro `#if DEBUG` | SettingsView |
| R8 | Tailscale migration banner (post-Phase 4 path abbandonato) | SettingsView |
| R9 | Capability row Spotify hardcoded inactive | DashboardView |
| R10 | Stringhe italiane user-facing tradotte (`"GIGI harness server avviato"` → `"started"`) | GigiPairingSheet |
| R11 | `@AppStorage("gigi.wakeWord.enabled")` dead state | DashboardView |
| R12 | `liveActivityBanner` top overlay (anti-stacking con pairing + harness offline banner) | MainTabView |
| C3 | Sheet QuickTalk duplicata (ChatView vs MainTabView auto-present) | ChatView |
| C5 | Brain badge ChatView header (consolidato in 1 dot) | ChatView |

### Layer 2 — Decisioni di prodotto (D1-D8)

| # | Decisione | Scelta finale | Razionale |
|---|---|---|---|
| **D1** | Force Claude toggle | `#if DEBUG` + **Brain Path Override picker** (Auto/AppleFM/Ollama/Claude) | Il piano 5-path automatizza il routing → toggle utente perde senso architetturale. In DEBUG diventa harness di testing per anteprima Path 2/3/4 con stub. |
| **D2** | HomeKit | Keep + cleanup: icon dynamic, empty state friendly, footer copy user-facing, rimosso Refresh button (auto-refresh on focus) | HomeKit è citato nei 15 tool Apple FM del piano + demo wow-factor. |
| **D3** | Tab Presence | **Remove** (4 → 3 tab: Chat / Dashboard / Settings) | Bug latente (no `.tag()`) + duplicazione UI (PresenceModeTabView vs PresenceView sheet). Presence si attiva da bottone mic ChatView o AppIntent. |
| **D4** | TalkingSessionTaskListView overlay | Keep + TODO inline integration col piano | Demo wow-factor (task extraction in tempo reale). TODO: migrare backend Groq cloud → Apple FM / Ollama in Phase 2. |
| **D5** | WhatsApp linking | Consolida in Settings only (rimuovi Dashboard card + showWhatsAppSheet duplicate) | 3 entry point → 1. Web automation custom → integrate con Path 4 MCP harness-browser in Phase 2 (vedi nota nel piano §3.11). |
| **D6** | Onboarding profile step | **Sposta a opt-in Dashboard** (7 → 6 step) | Friction zero al first run. Profilo compila opt-in da Dashboard → "Your Profile" setup card. |
| **D7** | Brain pill Dashboard | Remove (incluso in R1) | Vedi R1. |
| **D8** | Tailscale migration banner | **Delete** | Post-Phase 4 il pairing è solo Cloudflare Tunnel. Banner suggerisce migrazione verso path già canonical. Dead UI. |

### Layer 3 — Xcode project + dependency cleanup (ADR-0004 finalization)

ADR-0004 dichiarava `GoogleSignIn` SDK rimosso ma il rework aveva pulito solo il codice Swift; le 7 dipendenze SPM erano ancora in `project.pbxproj` + `Package.resolved`. Cleanup:

- Rimosse 4 reference da `project.pbxproj` (PBXBuildFile, Frameworks list, packageProductDependencies, packageReferences)
- Rimosse XCRemoteSwiftPackageReference + XCSwiftPackageProductDependency sections
- `Package.resolved` wipe completo (`pins: []`) — Xcode riscriverà al prossimo build con le dep effettive
- Backup `project.pbxproj.bak` lasciato nel filesystem per recovery di emergenza

### Brain Path Override picker (D1) — anteprima testing Phase 2/3/4

Nuovo enum `BrainPathOverride` in `SettingsView.swift` (DEBUG only) + helper `DebugBrainPath` letto da `GigiAgentEngine.process()` come **primo gate** prima di Force Claude:

```swift
switch DebugBrainPath.current {
case .auto:    // fall through al flow normale
case .appleFM: // direct call to GigiFoundationAgent.shared.process()
case .ollama:  // stub: "Path 3 not configured yet"
case .claude:  // forces processForceClaude() helper (equivalente Force Claude=true)
}
```

UI: Picker segmented in Settings → Debug → "Brain Path Override (DEBUG)", persistito in UserDefaults (`gigi.debug.brainPath`), con help text per ogni path. Quando i path 2/3/4 saranno wired in Phase 2, il picker resta utile per testare path-specific latency / fallback / regression.

## Alternatives considered

- **A — Cleanup completo senza decisioni bloccanti**: scartato perché 8 dei punti audit (D1-D8) erano scelte di prodotto che non potevano essere fatte senza input PM (es. HomeKit MVP scope).
- **B — Lasciare la UI gonfia, fare Phase 2 sopra**: scartato perché ogni feature nuova nel piano 5-path ereditava il rumore. La superficie test cresceva linearmente.
- **C — Refactor UI in framework SwiftUI customizzato (Design System)**: scartato come scope creep. Il MVP non richiede design system, richiede UI snella e testabile.
- **D — Aggiungere shim per WakeWord/DayPlan invece di refactor call site**: scartato (vedi ADR-0003/0005), già discusso. `_legacy/` folder reference è la scelta.

## Consequences

### Positive

- **~600 righe Swift rimosse** dal target compilato. xcodebuild surface ridotta.
- **4 tab → 3 tab** in MainTabView. Test surface più chiara.
- **7 → 6 step onboarding**. Friction zero al first run.
- **5 entry point Brain status → 1** (Settings → Brain section).
- **3 entry point WhatsApp → 1** (Settings → WhatsApp section).
- **Brain Path Override picker** abilita testing empirico Path 2/3/4 in anteprima senza aspettare Phase 2 implementation completa.
- **Zero ref GoogleSignIn** nel `.pbxproj` — chiude finalmente la dipendenza Google iniziata da ADR-0004.
- **Stringhe italiane user-facing tradotte** — regola hard CLAUDE.md rispettata.
- **Build più snello** (no SPM `GoogleSignIn-iOS` 9.1.0 + 6 dep transitive: app-check, appauth-ios, googleutilities, gtm-session-fetcher, gtmappauth, promises).

### Negative / Trade-off

- **Force Claude scompare dalla UI prod**. Utenti che lo usavano esplicitamente devono affidarsi al routing automatico (oggi: NLU fast-path + Groq). Quando piano 5-path è live, il routing automatico diventa Apple FM + Ollama + Claude Code, quindi l'esperienza è strettamente superiore — ma c'è un gap temporale (Phase 2 → completion).
- **PresenceView accessible solo da ChatView mic long-press / Siri AppIntent**. Utenti che usavano la tab dedicata devono imparare il nuovo entry. Mitigazione: documentare in onboarding step hardwareTrigger.
- **Profile vuoto al first run** in Dashboard può sembrare "incomplete" all'utente. Il setup card "Your Profile" mostra "Not set" → invita azione, ma è friction visibile. Trade-off accettato per ridurre onboarding length.
- **`whatsappLinked` state in DashboardView resta** anche se la card è rimossa — usato solo da `loadStatus()` per refresh background. Non causa overhead UI ma è state morto. Rimozione completa post-Phase 2.
- **Backup `project.pbxproj.bak`** non versioned ma resta sul filesystem locale. Da rimuovere a mano dopo verifica build OK.

### Neutral / Note

- **Build verify obbligatorio post-cleanup**: il `.pbxproj` cleanup è la modifica più rischiosa (file format complesso). Verificare con xcodebuild SSH MacInCloud prima del commit. Backup `.bak` come fallback.
- **Xcode normalizzazione automatica**: il prossimo open del progetto può riordinare `.pbxproj` (eliminare commenti, rimuovere sezioni vuote). Funzionalmente non rompe nulla.
- **`_legacy/` folder reference**: da aggiungere manualmente in Xcode (Project → Add Files → seleziona `_legacy/` → **Create folder references, NOT groups**). Senza questo step Xcode potrebbe re-compilare i file `_legacy/*.swift`.
- **`whatsappLinked` cleanup deferred**: tracciato come TODO per Phase 2 quando il path WhatsApp viene rivisto col MCP harness-browser.
- **TODO inline in TalkingSessionTaskListView.swift**: documenta migrazione backend al piano 5-path. Da rimuovere quando `GigiTaskExtractor.setBackend()` è implementato.

## References

- `docs/plans/frolicking-stargazing-pancake.md` §3.11 "UI Cleanup pre-Phase 2"
- ADR-0001 — Pairing Cloudflare Tunnel MVP
- ADR-0003 — Wake word soft-kill MVP
- ADR-0004 — Uproot Gemini and Google Sign-In
- ADR-0005 — Day Plan Reasoner soft-kill MVP
- `02_GIGI_APP/GIGI/_legacy/README.md` — files moved out of build target
- Audit UI report (in-conversation 2026-05-11, general-purpose subagent)

---

> Una volta `Accepted`, **non si edita più questo file**. Se la decisione cambia,
> si crea un nuovo ADR che la _supersedes_ e si aggiorna lo Status di questo a
> `Superseded by ADR-XXXX`.
