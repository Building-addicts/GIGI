# GATE 7 — Modes operativi UI + setup wizard OSS-friendly

> **Status**: Pending (richiede GATE 6 chiuso)
> **Effort stimato**: 3-4 giorni lavorativi
> **Bloccanti pre-gate**: GATE 6 chiuso (killer demo Tesla→nota funzionante); decisione UX su mode naming (Minimal / Local-First / Apple Optimized / Full Power) confermata
> **Sblocca**: GATE 8 (hardening + OSS release)
> **Funzione consegnata (1 frase)**: l'utente apre Settings → Modes e sceglie tra 4 modalità (Minimal / Local-First / Apple Optimized / Full Power) — l'app rileva automaticamente quale infrastruttura è disponibile (iPhone capable? Ollama? Claude Code?), propone il mode adatto al boot, e lo setup wizard `setup-oss-demo.sh` aiuta chi clona il repo a far girare la demo in <30 min senza ricaricare alcuna API.

---

## 1. Obiettivo

Per essere veramente OSS-friendly, GIGI deve essere installabile e demoable da chiunque cloni il repo. I prerequisiti sono diversi per ogni mode:
- **Minimal**: solo Claude Code subscription. Path 1+4 attivi. Setup <5 min
- **Local-First** (ex "Privacy Max"): iPhone Apple Intelligence + Ollama. Path 1+2+3 attivi. Setup ~30 min
- **Apple Optimized**: iPhone Apple Intelligence + Claude Code. Path 1+2+4. Setup ~10 min
- **Full Power**: tutto. Path 1+2+3+4+5. Setup ~45 min

GATE 7 implementa:
1. `ModesSelectionView.swift` (nuovo): UI per scelta mode con setup status indicator per ognuna delle 4
2. `GigiFallbackRouter.swift` (già impl in GATE 3): completa fallback per device non-Apple-FM
3. `scripts/setup-oss-demo.sh` (nuovo): detect hardware, verifica Claude Code installato, verifica MCP harness-browser, detect Ollama installato + RAM-based tier proposal, genera `.env.example` senza API keys
4. Auto-detect mode disponibile al boot: `GigiSmartOrchestrator.detectAvailableModes()` esposto, badge in Settings + Onboarding card
5. Mode switching live: cambia mode senza restart app, router rispetta

---

## 2. Pre-condizioni

- [ ] GATE 0-6 chiusi
- [ ] Naming finale 4 modes confermato (questo task plan assume Minimal / Local-First / Apple Optimized / Full Power)
- [ ] Hardware iPhone non-Apple-FM disponibile per test fallback mode (OR simulato disabilitando Apple Intelligence in iOS Settings)

---

## 3. Task implementativi

- **Task 7.1 — Implementare `ModesSelectionView.swift`** (5h)
  - File: `02_GIGI_APP/GIGI/UI/ModesSelectionView.swift` (nuovo, ~180 righe)
  - SwiftUI view con 4 mode cards:
    ```
    ┌─────────────────────────────────────────┐
    │ [Icon] Minimal                          │
    │   Path 1 (native) + Path 4 (Claude)     │
    │   Requires: Claude Code subscription    │
    │   ✅ Ready  /  ❌ Setup required         │
    │   [Setup] / [Select]                    │
    └─────────────────────────────────────────┘
    ```
  - 4 cards: Minimal / Local-First / Apple Optimized / Full Power
  - Per ogni card:
    - Icon (SF Symbol o asset)
    - Name
    - 1-line description
    - Required infrastructure checklist con ✅ / ❌
    - Latency hint ("Action 80ms, Reasoning 7-60s")
    - Privacy hint ("100% on-device" / "On-harness LAN" / "Cloud subscription")
    - Action button: "Setup" (apre wizard) o "Select" (se ready)
  - State: `@AppStorage("gigi.user.mode") var selectedMode: String`
  - Riferimento: piano §3.9 modes table

- **Task 7.2 — `GigiSmartOrchestrator.detectAvailableModes()`** (4h)
  - File: `02_GIGI_APP/GIGI/GigiSmartOrchestrator.swift`
  - Aggiungere:
    ```swift
    enum GigiMode: String, CaseIterable {
        case minimal = "minimal"
        case localFirst = "local_first"
        case appleOptimized = "apple_optimized"
        case fullPower = "full_power"
    }

    struct ModeAvailability {
        let mode: GigiMode
        let isAvailable: Bool
        let missing: [String]  // ["Apple Intelligence", "Ollama", "Claude Code"]
    }

    @MainActor
    func detectAvailableModes() async -> [ModeAvailability] {
        let appleFM = GigiFoundationSession.isAppleFMAvailable
        let ollama = await pingHarness("/api/ios/local-llm/status")
        let claudeCode = await pingHarness("/api/ios/agent/claude-status")

        return GigiMode.allCases.map { mode in
            switch mode {
            case .minimal: return ModeAvailability(mode: mode, isAvailable: claudeCode, missing: claudeCode ? [] : ["Claude Code subscription"])
            case .localFirst: return ModeAvailability(mode: mode, isAvailable: appleFM && ollama, missing: ...)
            // ...
            }
        }
    }
    ```
  - Caching 60s TTL (refresh on app foreground)

- **Task 7.3 — Mode propagation al router** (3h)
  - File: `02_GIGI_APP/GIGI/GigiRequestRouter.swift`
  - Leggere `@AppStorage("gigi.user.mode")` al route()
  - In base al mode, disabilitare path:
    - `minimal`: Path 2 disabled, Path 3 disabled. delegate_local → fallback delegate_cloud
    - `local_first`: Path 4 disabled. delegate_cloud → speak "Cloud mode disabled in Local-First mode"
    - `apple_optimized`: Path 3 disabled. delegate_local → fallback delegate_cloud
    - `full_power`: tutti attivi
  - Quando user cambia mode in Settings → notification → router state updated SENZA restart app

- **Task 7.4 — Auto-detect mode + onboarding badge** (3h)
  - File: `02_GIGI_APP/GIGI/UI/OnboardingFlowView.swift` + `DashboardView.swift`
  - Al boot, chiama `detectAvailableModes()` → propone mode "best available":
    - Se Full Power disponibile → propone Full Power
    - Else se Apple Optimized disponibile → propone Apple Optimized
    - Else se Local-First disponibile → propone Local-First
    - Else → Minimal
  - Onboarding card "Recommended mode: <X>" con button "Activate"
  - In Settings → Modes section ha badge "ACTIVE: <mode_name>"

- **Task 7.5 — `scripts/setup-oss-demo.sh`** (6h)
  - File: `scripts/setup-oss-demo.sh` (nuovo, ~250 righe bash)
  - Script bash che:
    1. Echo welcome banner "Welcome to GIGI OSS setup wizard"
    2. Detect host OS (`uname`)
    3. Check `claude --version`:
       - Se installato + autenticato: ✅
       - Else: echo "Install Claude Code: https://claude.com/code, then `claude login`"
    4. Check MCP harness-browser:
       - `npx playwright install chromium` (idempotent)
       - Test `node -e "import {chromium} from 'playwright'; chromium.launch()"` (in 5s timeout)
    5. Check Ollama:
       - `which ollama` → if installed: detect RAM (`free -h` Linux, `sysctl hw.memsize` Mac, etc), propose tier (lite/standard/default/pro)
       - Else: echo "Ollama not installed. Path 3 will be unavailable. To install: brew install ollama / https://ollama.com/download"
    6. **`unset ANTHROPIC_API_KEY`** + warning if was set (Issue claude-code#45572)
    7. Generate `.env.example` senza API keys (solo `OLLAMA_URL`, `HARNESS_PORT`, `CLAUDE_CODE_HOME`)
    8. Run `npm install` in `03_HARNESS/`
    9. Run smoke test: `node 03_HARNESS/server/index.js --healthcheck` (richiede endpoint dedicato, vedi GATE 8)
    10. Echo "Setup complete. Run `./start-harness.sh` to start. Open the GIGI app and pair via QR."
  - Idempotent: ri-eseguibile senza side effects
  - Exit 0 on success, exit 1+ on failure with descriptive error

- **Task 7.6 — Completare `GigiFallbackRouter` per non-Apple-FM full coverage** (3h)
  - File: `02_GIGI_APP/GIGI/GigiFallbackRouter.swift`
  - Già impl in GATE 3 con 15 keyword entries. Estendere per:
    - Path 3 delegate_local detection: keyword "explain", "summarize", "rephrase" → `delegate_local`
    - Path 4 delegate_cloud detection: keyword "search", "find", "browse" → `delegate_cloud, capabilities=[browser]`
    - Reject detection: keyword "buy bitcoin", "hack", explicit profanity → `reject`
    - Ambiguous fallback: nessun match → ask_clarification "Could you rephrase?"
  - Test su iPhone non-Apple-FM (o Apple Intelligence off): query "explain Bayes" → `delegate_local`, query "search Wikipedia" → `delegate_cloud`

- **Task 7.7 — Settings → Modes UI integration** (2h)
  - File: `02_GIGI_APP/GIGI/SettingsView.swift`
  - Aggiungere sezione "Operating Mode" che:
    - Mostra current mode (badge)
    - Link a `ModesSelectionView`
    - "Last detected: <date>" timestamp

- **Task 7.8 — Test E2E 8 scenari mode switching** (3h)
  - Registrare in `docs/research/gate-7-modes-e2e.md`

---

## 4. Acceptance Criteria (AC)

- **AC1** — `ModesSelectionView.swift` esiste con 4 mode cards SwiftUI
- **AC2** — Ogni card mostra: name, description, required infra checklist (✅/❌), latency hint, privacy hint, action button
- **AC3** — `GigiSmartOrchestrator.detectAvailableModes()` ritorna array `[ModeAvailability]` di 4 elementi
- **AC4** — `@AppStorage("gigi.user.mode")` propaga a `GigiRequestRouter` senza restart app
- **AC5** — Mode `minimal`: Path 2/3 disabilitati nel router; delegate_local cade su delegate_cloud automatically
- **AC6** — Mode `local_first`: Path 4 disabilitato; delegate_cloud → speak "Cloud mode disabled"
- **AC7** — Mode `apple_optimized`: Path 3 disabilitato; delegate_local → delegate_cloud
- **AC8** — Mode `full_power`: tutti attivi
- **AC9** — `scripts/setup-oss-demo.sh` esegue 10 step (Task 7.5) senza errori su macchina fresh con Claude Code + Ollama + harness clone
- **AC10** — Setup script verifica `ANTHROPIC_API_KEY` is unset, warning se settata
- **AC11** — Setup script idempotent (eseguibile 2 volte senza side effects)
- **AC12** — `GigiFallbackRouter` ha logica per delegate_local + delegate_cloud + reject + ask_clarification (oltre native_tool già impl in GATE 3)
- **AC13** — iPhone non-Apple-FM: query "explain Bayes" → fallback router → delegate_local → Ollama (se mode local_first o full_power)
- **AC14** — Auto-detect best mode al boot, onboarding card propone con button "Activate"
- **AC15** — Build verify: tutti targets PASS

---

## 5. Test E2E sul telefono (verificabili dall'utente)

- **E2E-1** — Apri app fresh, Settings → Modes → vedi 4 cards
  - Atteso: Full Power card mostra ✅ Ready (con harness running + Apple FM + Claude Code subscription)
  - Altri mode mostrano i loro stati

- **E2E-2** — Tap mode "Local-First" → confirm → torna a Settings, badge "ACTIVE: Local-First"
  - Pronuncia "Search Wikipedia for Tesla"
  - Atteso: speech "Cloud mode disabled in Local-First mode" (Path 4 blocked)
  - Atteso: NO subprocess Claude Code spawn (verifica con `ps`)

- **E2E-3** — Cambia mode a "Full Power" → pronuncia stessa query
  - Atteso: dispatch a Path 4 normale, response Wikipedia summary

- **E2E-4** — Cambia mode a "Minimal" → pronuncia "Explain Bayes theorem"
  - Atteso: dispatch a Path 4 Claude Code (perché Path 3 disabled in Minimal), response Claude
  - Verifica: NO Ollama hit (`ollama logs` nessuna entry)

- **E2E-5** — Disabilita Apple Intelligence in iOS Settings → riapri app
  - Atteso: in Modes → Apple Optimized + Full Power mostrano ❌ "Apple Intelligence required"
  - Auto-detect propone "Minimal" o "Local-First"

- **E2E-6** — Kill harness → ricarica Settings → Modes
  - Atteso: Local-First + Apple Optimized + Full Power mostrano ❌ "Harness offline"
  - Solo Minimal e Apple Optimized possibilmente parzialmente disponibili

- **E2E-7** — Setup wizard test:
  - Da terminale: `bash scripts/setup-oss-demo.sh`
  - Atteso: output verbose con check per ognuno dei 10 step, exit 0
  - Verifica `.env.example` generato con commenti chiari

- **E2E-8** — Onboarding nuova install: cancella app, reinstalla, primo launch
  - Atteso: dopo 6 step onboarding, appare card "Recommended mode: <best>" con button
  - Tap Activate → mode salvato, primo turn funzionante

---

## 6. Test post-creazione (verifica autonoma)

### 6.1 Verifica via grep / Glob

```bash
ROOT="C:/Users/arman/Desktop/PROGETTI VIBE CODING/GIGI FOLDER/GIGI-work/Armando-Rework"

# 1. ModesSelectionView esiste
ls "$ROOT/02_GIGI_APP/GIGI/UI/ModesSelectionView.swift"

# 2. detectAvailableModes esposto
grep "func detectAvailableModes" "$ROOT/02_GIGI_APP/GIGI/GigiSmartOrchestrator.swift"

# 3. GigiMode enum con 4 case
grep -E "case minimal|case localFirst|case appleOptimized|case fullPower" "$ROOT/02_GIGI_APP/GIGI/GigiSmartOrchestrator.swift" | wc -l
# Output atteso: 4

# 4. setup script esiste + executable
ls -la "$ROOT/scripts/setup-oss-demo.sh"
# Output atteso: -rwxr-xr-x (executable bit set)

# 5. GigiFallbackRouter ha delegate_local + delegate_cloud
grep -E "delegate_local|delegate_cloud|reject|ask_clarification" "$ROOT/02_GIGI_APP/GIGI/GigiFallbackRouter.swift" | wc -l
# Output atteso: 4+

# 6. mode propagation in router
grep -E "selectedMode|GigiMode\.|@AppStorage.*gigi.user.mode" "$ROOT/02_GIGI_APP/GIGI/GigiRequestRouter.swift"
# Output atteso: 1+ match
```

### 6.2 Verifica via setup script smoke test

```bash
bash "$ROOT/scripts/setup-oss-demo.sh" 2>&1 | tail -20
# Output atteso: 
# - Check ✅ per Claude Code, Ollama, harness-browser MCP
# - "Setup complete" final message
# - Exit code 0
```

### 6.3 Verifica via UI

Aprire l'app, andare a Settings → Modes → verificare 4 cards visibili con stati ✅/❌ corretti.

---

## 7. Rollback plan

```bash
git revert <SHA-gate-7>
```

Specifico:
- Mode `@AppStorage` value rimane in UserDefaults — può essere ignorato dal router rollback-ato
- Setup script può essere rimosso senza side effects

---

## 8. Files modificati / creati

| Path | Operazione | Righe stimate |
|---|---|---|
| `02_GIGI_APP/GIGI/UI/ModesSelectionView.swift` | CREATE | ~180 |
| `02_GIGI_APP/GIGI/GigiSmartOrchestrator.swift` | MODIFY (GigiMode + detectAvailableModes) | +120 |
| `02_GIGI_APP/GIGI/GigiRequestRouter.swift` | MODIFY (mode-aware dispatch) | +60 |
| `02_GIGI_APP/GIGI/GigiFallbackRouter.swift` | MODIFY (extend coverage) | +80 |
| `02_GIGI_APP/GIGI/SettingsView.swift` | MODIFY (Modes section link) | +30 |
| `02_GIGI_APP/GIGI/UI/OnboardingFlowView.swift` | MODIFY (Recommended mode card) | +50 |
| `02_GIGI_APP/GIGI/DashboardView.swift` | MODIFY (mode badge) | +20 |
| `scripts/setup-oss-demo.sh` | CREATE | ~250 |
| `docs/research/gate-7-modes-e2e.md` | CREATE | ~80 |
| `docs/adr/0009-hardware-targets-and-modes.md` | MODIFY (final, Accepted) | +40 |

---

## 9. ADR collegati

- **ADR-0009** (Hardware targets and modes) — questo GATE la chiude (Status: Accepted)
- ADR-0007 (Hybrid 5-path) — modes sono il primo "ufficiale" use case di disabling path

---

## 10. Note operative

- **Naming finale modes**: il piano usa "Privacy Max" ma `HOW_GIGI_WILL_WORK.md` §5 propone rename a "Local-First Mode" perché PCC è opaco. Questo task plan adotta "Local-First". Confermare con PM se OK.
- **Conventional Commits suggeriti**:
  ```
  feat(ios): GATE 7.1 — ModesSelectionView SwiftUI
  feat(ios): GATE 7.2 — GigiSmartOrchestrator.detectAvailableModes
  feat(ios): GATE 7.3 — mode propagation to GigiRequestRouter
  feat(ios): GATE 7.4 — auto-detect best mode + onboarding card
  feat(scripts): GATE 7.5 — setup-oss-demo.sh wizard
  feat(ios): GATE 7.6 — GigiFallbackRouter full path coverage
  feat(ios): GATE 7.7 — Settings Modes section integration
  test(e2e): GATE 7.8 — 8 mode-switching scenarios
  ```
- **Privacy clarification**: rinominare definitivamente "Privacy Max" → "Local-First Mode" in tutta UI + docs. Aggiornare ADR-0009 con razionale (PCC opacity).

### Cosa fare se setup script fallisce per host esotico (Linux Arch, WSL, etc.)

- Default: skip Ollama detection con warning
- Documentare in README "Tested on: macOS, Windows 11 + WSL2, Ubuntu 22.04 LTS"
- Issue tracker per richiedere altri OS
