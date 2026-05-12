# GATE 9 — Capability Expansion Week 1: Power User Unlock

> **Status**: Pending (post-MVP, requires GATE 0-8 closed + v0.1.0 OSS released)
> **Effort stimato**: ~12h (1.5 giorni lavorativi) — 3h + 4h + 1h + 4h
> **Bloccanti pre-gate**: MVP shippato (venerdì 1 maggio 2026); GATE 8 chiuso (OSS release v0.1.0 live); device test con HomeKit casa (almeno 1 scene già definita in app Home); iPhone 15 Pro+ Apple Intelligence-capable; almeno 1 Apple Shortcut pre-installato sul device test (per E2E run_shortcut)
> **Sblocca**: GATE 10 Week 2 (productivity boost — calendar, note, clipboard, translate); Layer B conversational discovery
> **Funzione consegnata (1 frase)**: GIGI passa da 17 tool a 20 tool con 3 capability ad altissimo value/effort ratio (Shortcuts universal bridge, HomeKit scenes, Web search) e mostra agli utenti nuovi un mini tour conversazionale di 3 step al primo avvio (Layer A onboarding).

---

## 1. Obiettivo

Il master plan `docs/plans/gigi-capability-expansion-2026-05-12.md` §6 Week 1 identifica 4 deliverables post-MVP che sbloccano un salto qualitativo nella perceived capability dell'app:

1. **`run_shortcut`** — meta-tool universal bridge a `shortcuts://x-callback-url/run-shortcut?name=<name>&input=<input>`. È l'escape hatch che permette agli utenti power di estendere GIGI con QUALSIASI Apple Shortcut custom (es. *"esegui modo lavoro"* invoca uno Shortcut che attiva Focus + apre Notion + manda messaggio al team). Value enorme, effort minimo (3h) — il bridge è un singolo URL scheme.

2. **`set_homekit_scene`** — attivazione scene HomeKit by name. L'entitlement HomeKit è già presente in `02_GIGI_APP/GIGI/GIGI.entitlements`, ma manca l'engine. GATE 9 crea `GigiHomeKitEngine.swift` (lazy `HMHomeManager`, scene lookup by name fuzzy match, `HMActionSet.execute()`) + il tool wrapper. Frase target: *"accendi scena cinema"* → activate scene "Cinema".

3. **`web_search`** — apertura Safari con query DuckDuckGo. È un tool da 1h: solo URL scheme `https://duckduckgo.com/?q=<query>` aperto via `UIApplication.shared.open(_:)`. Coverage di richieste informative che oggi cadono nel fallback `delegate_cloud` (lento, costoso).

4. **Onboarding Layer A** — mini tour conversazionale di 3 step al primo avvio dopo `OnboardingView` (che gestisce permessi). Trigger: UserDefaults flag `gigi.onboarding.layer_a_complete` false. Flusso: GIGI dice *"Hi, I'm GIGI. Try saying 'set a timer for 5 minutes'"* → user tenta → celebration → GIGI elenca 3 capability categories → setup completo. Skip automatico se user ha già fatto ≥5 turni (utente upgrade).

GATE 9 ha **4 sub-gate sequenziali** (9.A → 9.B → 9.C → 9.D). Ognuno è shippabile in isolamento (può uscire come patch incrementale v0.1.1, v0.1.2, ecc.) ma il GATE è COMPLETE solo quando tutti 4 sono mergeati.

Output concreto:
- `GigiFoundationToolRegistry.swift` (+3 Tool struct: `FMRunShortcutTool`, `FMSetHomeKitSceneTool`, `FMWebSearchTool`)
- `GigiHomeKitEngine.swift` (nuovo file, ~200 righe)
- `GigiActionDispatcher+Native.swift` (3 nuovi handler: `handleRunShortcut`, `handleSetHomeKitScene`, `handleWebSearch`)
- `GigiOnboardingFlow.swift` (nuovo file, ~250 righe — coordinator Layer A)
- `OnboardingTourView.swift` (nuovo file, ~150 righe — SwiftUI view per i 3 step)
- `canonicalActions` aggiornato da 17 → 20 entries
- `allTools` aggiornato da 17 → 20 entries

---

## 2. Pre-condizioni

- [ ] GATE 0-8 tutti chiusi (build verify, router, Apple FM tool calling, Ollama, Claude subprocess, killer demo, modes wizard, hardening)
- [ ] MVP v0.1.0 shippato + osservato in beta tester field per ≥1 settimana senza regression critiche
- [ ] Entitlement `com.apple.developer.homekit` presente in `02_GIGI_APP/GIGI/GIGI.entitlements` (verificato con grep)
- [ ] `Info.plist` contiene `NSHomeKitUsageDescription` con stringa user-facing in inglese (verifica grep)
- [ ] Device test ha almeno 1 HomeKit Home configurato in app Home iOS con almeno 1 scene (es. "Buongiorno", "Cinema", "Notte")
- [ ] Device test ha almeno 1 Apple Shortcut creato in app Shortcuts (es. "Modo lavoro" che attiva Focus)
- [ ] iPhone 15 Pro+ con Apple Intelligence on per Apple FM Tool calling Path 2
- [ ] `GigiActionBridge.shared.execute(_:)` API stabile (verificato in GATE 3, non modificato in GATE 4-8)
- [ ] `OnboardingView.swift` esistente non modificato in scope — Layer A è coordinator separato che parte DOPO la dismiss di OnboardingView
- [ ] Decisione tool naming: confermare `set_homekit_scene` (non `activate_scene` / `homekit_scene_on`) — consistente con pattern `homekit_on`/`homekit_off` esistenti. Decisione PM nel commit body Task 9.2.

---

## 3. Task implementativi

### Task 9.1 — `run_shortcut` meta-tool (3h)

**File modificati**:
- `02_GIGI_APP/GIGI/GigiFoundationToolRegistry.swift` (+1 Tool struct, +1 entry in `allTools`, +1 entry in `canonicalActions`)
- `02_GIGI_APP/GIGI/GigiActionDispatcher+Native.swift` (+1 handler `handleRunShortcut`)
- `02_GIGI_APP/GIGI/GigiActionBridge.swift` (dispatch a `handleRunShortcut` se label == "run_shortcut")

**Pattern code esempio** (segui esattamente lo stile di `FMSetTimerTool`):

```swift
// MARK: - 18. RunShortcutTool

@available(iOS 26.0, *)
struct FMRunShortcutTool: Tool {
    let name = "run_shortcut"
    let description = "Run any user-installed Apple Shortcut by name. Use when the user explicitly asks to run a shortcut or names a routine they configured themselves (e.g. 'run my morning routine', 'execute work mode')."

    @Generable
    struct Arguments {
        @Guide(description: "Exact or fuzzy name of the Shortcut to run. The user said this name. Examples: 'morning routine', 'work mode', 'arrive home'.")
        var name: String

        @Guide(description: "Optional text input to pass to the Shortcut. Empty string if none.")
        var input: String
    }

    @MainActor
    func call(arguments: Arguments) async -> String {
        await dispatchAction(label: "run_shortcut", params: [
            "name": arguments.name,
            "input": arguments.input,
            "raw": arguments.name
        ])
    }
}
```

**Handler in `GigiActionDispatcher+Native.swift`**:

```swift
@MainActor
func handleRunShortcut(params: [String: String]) async -> String {
    let name = params["name"] ?? ""
    let input = params["input"] ?? ""
    guard !name.isEmpty else {
        return "I need the name of the Shortcut to run."
    }
    let encodedName = name.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? name
    var urlString = "shortcuts://x-callback-url/run-shortcut?name=\(encodedName)"
    if !input.isEmpty {
        let encodedInput = input.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? input
        urlString += "&input=text&text=\(encodedInput)"
    }
    guard let url = URL(string: urlString),
          await UIApplication.shared.canOpenURL(url) else {
        return "Couldn't open Shortcuts. Make sure the app is installed."
    }
    let ok = await UIApplication.shared.open(url)
    return ok ? "Running '\(name)'." : "Couldn't run '\(name)'. Check that the Shortcut exists."
}
```

**Sub-task atomici**:
- 9.1.1 — Aggiungere `FMRunShortcutTool` struct in `GigiFoundationToolRegistry.swift` (45min)
- 9.1.2 — Aggiungere a `allTools` e `canonicalActions` (5min)
- 9.1.3 — Aggiungere `handleRunShortcut` in `GigiActionDispatcher+Native.swift` (1h)
- 9.1.4 — Wire dispatch in `GigiActionBridge.execute(_:)` per label "run_shortcut" (15min)
- 9.1.5 — Build verify xcodebuild + smoke test E2E "esegui modo lavoro" (1h)

**Riferimento**: master plan §4 row `run_shortcut`, §6 Week 1.

### Task 9.2 — `set_homekit_scene` (4h)

**File modificati / creati**:
- `02_GIGI_APP/GIGI/GigiHomeKitEngine.swift` (NUOVO, ~200 righe)
- `02_GIGI_APP/GIGI/GigiFoundationToolRegistry.swift` (+1 Tool struct, +1 entry in `allTools`, +1 entry in `canonicalActions`)
- `02_GIGI_APP/GIGI/GigiActionDispatcher+Native.swift` (+1 handler `handleSetHomeKitScene`)
- `02_GIGI_APP/GIGI/GigiActionBridge.swift` (dispatch a `handleSetHomeKitScene` se label == "set_homekit_scene")

**Pattern `GigiHomeKitEngine.swift`**:

```swift
import Foundation
import HomeKit

@MainActor
final class GigiHomeKitEngine: NSObject {
    static let shared = GigiHomeKitEngine()

    private var manager: HMHomeManager?
    private var managerReady: Bool = false
    private var continuations: [CheckedContinuation<Void, Never>] = []

    func ensureReady() async {
        if managerReady { return }
        if manager == nil {
            manager = HMHomeManager()
            manager?.delegate = self
        }
        await withCheckedContinuation { cont in
            continuations.append(cont)
        }
    }

    /// Returns the primary home, or first home if no primary set.
    func primaryHome() async -> HMHome? {
        await ensureReady()
        return manager?.primaryHome ?? manager?.homes.first
    }

    /// Fuzzy match a scene name to the actionSets of the primary home.
    /// Match strategy: case-insensitive contains, fallback to Levenshtein distance ≤2.
    func findScene(named query: String) async -> HMActionSet? {
        guard let home = await primaryHome() else { return nil }
        let normalized = query.lowercased().trimmingCharacters(in: .whitespaces)
        // Exact match first
        if let exact = home.actionSets.first(where: { $0.name.lowercased() == normalized }) {
            return exact
        }
        // Contains match
        if let contained = home.actionSets.first(where: { $0.name.lowercased().contains(normalized) }) {
            return contained
        }
        // Fallback: levenshtein (≤2)
        return home.actionSets.min(by: { lev($0.name.lowercased(), normalized) < lev($1.name.lowercased(), normalized) })
            .flatMap { lev($0.name.lowercased(), normalized) <= 2 ? $0 : nil }
    }

    func activateScene(named query: String) async -> String {
        guard let scene = await findScene(named: query) else {
            return "I couldn't find a scene called '\(query)'. Check the Home app."
        }
        guard let home = await primaryHome() else {
            return "No HomeKit home configured."
        }
        return await withCheckedContinuation { cont in
            home.executeActionSet(scene) { error in
                if let error = error {
                    cont.resume(returning: "Couldn't activate '\(scene.name)': \(error.localizedDescription).")
                } else {
                    cont.resume(returning: "Activated '\(scene.name)'.")
                }
            }
        }
    }

    // MARK: - Levenshtein helper (private)
    private func lev(_ a: String, _ b: String) -> Int { /* standard impl */ }
}

extension GigiHomeKitEngine: HMHomeManagerDelegate {
    nonisolated func homeManagerDidUpdateHomes(_ manager: HMHomeManager) {
        Task { @MainActor in
            self.managerReady = true
            let pending = self.continuations
            self.continuations.removeAll()
            pending.forEach { $0.resume() }
        }
    }
}
```

**Tool struct**:

```swift
@available(iOS 26.0, *)
struct FMSetHomeKitSceneTool: Tool {
    let name = "set_homekit_scene"
    let description = "Activate a HomeKit scene by name (e.g. 'Good Morning', 'Cinema', 'Goodnight'). Use when the user asks to activate, run, or trigger a scene."

    @Generable
    struct Arguments {
        @Guide(description: "Scene name as the user said it. Examples: 'Cinema', 'Good morning', 'Sleep mode'.")
        var sceneName: String
    }

    @MainActor
    func call(arguments: Arguments) async -> String {
        await dispatchAction(label: "set_homekit_scene", params: [
            "sceneName": arguments.sceneName,
            "raw": arguments.sceneName
        ])
    }
}
```

**Handler**:

```swift
@MainActor
func handleSetHomeKitScene(params: [String: String]) async -> String {
    let sceneName = params["sceneName"] ?? params["raw"] ?? ""
    guard !sceneName.isEmpty else { return "Which scene should I activate?" }
    return await GigiHomeKitEngine.shared.activateScene(named: sceneName)
}
```

**Sub-task atomici**:
- 9.2.1 — Creare `GigiHomeKitEngine.swift` con HMHomeManager lazy + delegate (2h)
- 9.2.2 — Implementare `findScene(named:)` con fuzzy match (30min)
- 9.2.3 — Implementare `activateScene(named:)` con error handling (30min)
- 9.2.4 — Aggiungere `FMSetHomeKitSceneTool` + `allTools` + `canonicalActions` (15min)
- 9.2.5 — Aggiungere `handleSetHomeKitScene` + wire `GigiActionBridge` (15min)
- 9.2.6 — Build verify + E2E "accendi scena cinema" su device con scene Cinema esistente (30min)

**Riferimento**: master plan §4 row `set_homekit_scene`, ADR-0010 PROPOSTA tool taxonomy.

### Task 9.3 — `web_search` (1h)

**File modificati**:
- `02_GIGI_APP/GIGI/GigiFoundationToolRegistry.swift` (+1 Tool struct, +1 entry in `allTools`, +1 entry in `canonicalActions`)
- `02_GIGI_APP/GIGI/GigiActionDispatcher+Native.swift` (+1 handler `handleWebSearch`)
- `02_GIGI_APP/GIGI/GigiActionBridge.swift` (dispatch a `handleWebSearch`)

**Pattern**:

```swift
@available(iOS 26.0, *)
struct FMWebSearchTool: Tool {
    let name = "web_search"
    let description = "Open Safari with a search query. Use when the user asks to search the web, look up something online, or find information that GIGI doesn't have natively."

    @Generable
    struct Arguments {
        @Guide(description: "The search query in natural language. Examples: 'pasta carbonara recipe', 'weather in Tokyo tomorrow', 'best ramen Milan'.")
        var query: String
    }

    @MainActor
    func call(arguments: Arguments) async -> String {
        await dispatchAction(label: "web_search", params: [
            "query": arguments.query,
            "raw": arguments.query
        ])
    }
}
```

**Handler**:

```swift
@MainActor
func handleWebSearch(params: [String: String]) async -> String {
    let query = params["query"] ?? params["raw"] ?? ""
    guard !query.isEmpty else { return "What should I search for?" }
    let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
    guard let url = URL(string: "https://duckduckgo.com/?q=\(encoded)") else {
        return "Invalid search query."
    }
    let ok = await UIApplication.shared.open(url)
    return ok ? "Searching for '\(query)'." : "Couldn't open Safari."
}
```

**Sub-task atomici**:
- 9.3.1 — Aggiungere `FMWebSearchTool` + `allTools` + `canonicalActions` (15min)
- 9.3.2 — Aggiungere `handleWebSearch` + wire `GigiActionBridge` (15min)
- 9.3.3 — Build verify + E2E "cerca su web ricette pasta" (30min)

**Riferimento**: master plan §4 row `web_search`.

### Task 9.4 — Onboarding Layer A conversational tour (4h)

**File modificati / creati**:
- `02_GIGI_APP/GIGI/GigiOnboardingFlow.swift` (NUOVO, ~250 righe — coordinator)
- `02_GIGI_APP/GIGI/OnboardingTourView.swift` (NUOVO, ~150 righe — SwiftUI view)
- `02_GIGI_APP/GIGI/ContentView.swift` o root view (mount logic per Layer A dopo OnboardingView)

**Logic Coordinator `GigiOnboardingFlow.swift`**:

```swift
import Foundation
import SwiftUI

@MainActor
final class GigiOnboardingFlow: ObservableObject {
    static let shared = GigiOnboardingFlow()

    private let key = "gigi.onboarding.layer_a_complete"
    private let turnCountKey = "gigi.usage.turn_count"

    @Published var shouldShowTour: Bool = false
    @Published var currentStep: Int = 0  // 0=intro, 1=try, 2=enumerate, 3=done

    func evaluateOnLaunch() {
        let completed = UserDefaults.standard.bool(forKey: key)
        let turns = UserDefaults.standard.integer(forKey: turnCountKey)
        // Skip if already done OR user is upgrade with ≥5 turns history
        if completed || turns >= 5 {
            shouldShowTour = false
            return
        }
        shouldShowTour = true
        currentStep = 0
    }

    func advance() {
        currentStep += 1
        if currentStep >= 3 {
            complete()
        }
    }

    func complete() {
        UserDefaults.standard.set(true, forKey: key)
        shouldShowTour = false
    }

    func skip() {
        complete()
    }
}
```

**View `OnboardingTourView.swift`**:

```swift
import SwiftUI

struct OnboardingTourView: View {
    @StateObject private var flow = GigiOnboardingFlow.shared

    var body: some View {
        VStack(spacing: 24) {
            switch flow.currentStep {
            case 0:
                stepIntro()
            case 1:
                stepTry()
            case 2:
                stepEnumerate()
            default:
                EmptyView()
            }
            Spacer()
            HStack {
                Button("Skip") { flow.skip() }
                    .foregroundColor(.secondary)
                Spacer()
                Button(flow.currentStep == 2 ? "Done" : "Next") {
                    flow.advance()
                }
                .buttonStyle(.borderedProminent)
            }
            .padding()
        }
        .padding()
    }

    private func stepIntro() -> some View {
        VStack(spacing: 16) {
            Text("Hi, I'm GIGI.").font(.largeTitle).bold()
            Text("Try saying 'set a timer for 5 minutes' to see how I work.")
                .multilineTextAlignment(.center)
        }
    }

    private func stepTry() -> some View {
        VStack(spacing: 16) {
            Text("Nice!").font(.title).bold()
            Text("I can also help with calendar, contacts, smart home, and more. Want a quick tour?")
                .multilineTextAlignment(.center)
        }
    }

    private func stepEnumerate() -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("What I can do").font(.title2).bold()
            categoryRow("System", example: "'Set a timer for 10 minutes'")
            categoryRow("Smart home", example: "'Turn on the living room light'")
            categoryRow("Communication", example: "'Send Marco a WhatsApp saying hi'")
            Text("Whenever you're not sure, just ask 'what can you do?'")
                .font(.caption).foregroundColor(.secondary)
        }
    }

    private func categoryRow(_ name: String, example: String) -> some View {
        VStack(alignment: .leading) {
            Text(name).font(.headline)
            Text(example).font(.caption).foregroundColor(.secondary)
        }
    }
}
```

**Mount logic** (in `ContentView.swift` root):

```swift
.sheet(isPresented: $flow.shouldShowTour) {
    OnboardingTourView()
        .interactiveDismissDisabled(true)
}
.onAppear {
    GigiOnboardingFlow.shared.evaluateOnLaunch()
}
```

**Sub-task atomici**:
- 9.4.1 — Creare `GigiOnboardingFlow.swift` coordinator + UserDefaults logic (1h)
- 9.4.2 — Creare `OnboardingTourView.swift` SwiftUI con 3 step + Skip/Next (1.5h)
- 9.4.3 — Wire mount in root ContentView con `.sheet(isPresented:)` (30min)
- 9.4.4 — Aggiungere `turnCountKey` increment in `GigiSmartOrchestrator.process(text:)` finale di ogni turn (15min)
- 9.4.5 — Build verify + E2E fresh install (reset UserDefaults) → tour visibile, click Next 3 volte → dismissed, UserDefaults flag true (45min)

**Riferimento**: master plan §5.1 Layer A.

---

## 4. Acceptance Criteria

**GATE 9.A — `run_shortcut`**:
- [ ] **AC-9.1**: `FMRunShortcutTool` struct conforme al protocol `Tool` esiste in `GigiFoundationToolRegistry.swift` con `name = "run_shortcut"`, description in inglese ≤100 token
- [ ] **AC-9.2**: `Arguments` ha 2 fields: `name: String` + `input: String`, entrambi con `@Guide`
- [ ] **AC-9.3**: `canonicalActions` array contiene `"run_shortcut"` (18 entries totali)
- [ ] **AC-9.4**: `allTools` array contiene `FMRunShortcutTool()` (18 entries totali)
- [ ] **AC-9.5**: `handleRunShortcut(params:)` in `GigiActionDispatcher+Native.swift` apre URL `shortcuts://x-callback-url/run-shortcut?name=<encoded>&input=text&text=<encoded>` via `UIApplication.shared.open`

**GATE 9.B — `set_homekit_scene`**:
- [ ] **AC-9.6**: `GigiHomeKitEngine.swift` esiste come singleton `@MainActor` con `HMHomeManager` lazy + `HMHomeManagerDelegate`
- [ ] **AC-9.7**: `findScene(named:)` ritorna `HMActionSet?` con strategia 3-step (exact → contains → Levenshtein ≤2)
- [ ] **AC-9.8**: `activateScene(named:)` invoca `home.executeActionSet(_:completionHandler:)` e ritorna stringa user-facing
- [ ] **AC-9.9**: `FMSetHomeKitSceneTool` struct esiste con `name = "set_homekit_scene"`, description inglese, `Arguments` con `sceneName`
- [ ] **AC-9.10**: `canonicalActions` contiene `"set_homekit_scene"` (19 entries totali); `allTools` contiene `FMSetHomeKitSceneTool()` (19 entries totali)
- [ ] **AC-9.11**: `handleSetHomeKitScene(params:)` delega a `GigiHomeKitEngine.shared.activateScene(named:)`

**GATE 9.C — `web_search`**:
- [ ] **AC-9.12**: `FMWebSearchTool` struct esiste con `name = "web_search"`, description inglese, `Arguments` con `query`
- [ ] **AC-9.13**: `canonicalActions` contiene `"web_search"` (20 entries totali); `allTools` contiene `FMWebSearchTool()` (20 entries totali)
- [ ] **AC-9.14**: `handleWebSearch(params:)` apre URL `https://duckduckgo.com/?q=<encoded>` via `UIApplication.shared.open`

**GATE 9.D — Onboarding Layer A**:
- [ ] **AC-9.15**: `GigiOnboardingFlow.swift` esiste come `@MainActor ObservableObject` singleton con `shouldShowTour: Bool` e `currentStep: Int` @Published
- [ ] **AC-9.16**: `evaluateOnLaunch()` legge `UserDefaults.standard.bool(forKey: "gigi.onboarding.layer_a_complete")` AND `UserDefaults.standard.integer(forKey: "gigi.usage.turn_count")`, set `shouldShowTour = true` SOLO se completed == false AND turns < 5
- [ ] **AC-9.17**: `OnboardingTourView.swift` esiste con 3 step (intro, try, enumerate) + bottoni Skip/Next
- [ ] **AC-9.18**: Tutte le stringhe user-facing della tour sono in inglese (regola CLAUDE.md hard)
- [ ] **AC-9.19**: Mount via `.sheet(isPresented:)` in ContentView root con `interactiveDismissDisabled(true)`
- [ ] **AC-9.20**: `GigiSmartOrchestrator.process(text:)` incrementa `UserDefaults.standard.integer(forKey: "gigi.usage.turn_count")` al termine di ogni turn

**Trasversali**:
- [ ] **AC-9.21**: Build verify: `xcodebuild` BUILD SUCCEEDED su iPhone 15 Pro+ iOS 26+
- [ ] **AC-9.22**: Tutte le tool description e tutti i `@Guide` sono in inglese
- [ ] **AC-9.23**: Nessuna regression: i 17 tool pre-esistenti continuano a funzionare (smoke test 3 random tool da GATE 3 E2E list)

---

## 5. E2E test sul telefono (verificabili dall'utente)

**E2E-9.1 (run_shortcut)** — Pre-requisito: Shortcut "Modo Lavoro" pre-installato in app Shortcuts
- Pronunciare: *"esegui modo lavoro"* (o *"run my work mode shortcut"*)
- Atteso: Apple FM invoca `FMRunShortcutTool` con `Arguments(name: "modo lavoro", input: "")` → handler apre `shortcuts://x-callback-url/run-shortcut?name=modo%20lavoro` → app Shortcuts si apre, Shortcut "Modo Lavoro" esegue → ritorno a GIGI con TTS "Running 'modo lavoro'."

**E2E-9.2 (run_shortcut with input)** — Pre-requisito: Shortcut "Aggiungi Nota" che accetta text input
- Pronunciare: *"esegui aggiungi nota con testo comprare latte"*
- Atteso: Apple FM invoca `FMRunShortcutTool(name: "aggiungi nota", input: "comprare latte")` → URL include `&input=text&text=comprare%20latte` → Shortcut esegue con input "comprare latte"

**E2E-9.3 (set_homekit_scene exact match)** — Pre-requisito: HomeKit Home con scene "Cinema"
- Pronunciare: *"accendi scena cinema"*
- Atteso: Apple FM invoca `FMSetHomeKitSceneTool(sceneName: "cinema")` → `findScene` exact match → `executeActionSet` invocato → luci/TV dimmano come configurato in app Home → TTS "Activated 'Cinema'."

**E2E-9.4 (set_homekit_scene fuzzy)** — Pre-requisito: HomeKit Home con scene "Buongiorno"
- Pronunciare: *"attiva la scena buon giorno"* (con typo intenzionale: "buon giorno" vs "Buongiorno")
- Atteso: `findScene` Levenshtein match (distance ≤2) → scene "Buongiorno" attivata → TTS "Activated 'Buongiorno'."

**E2E-9.5 (set_homekit_scene scene non esistente)**:
- Pronunciare: *"attiva scena marziano"*
- Atteso: `findScene` ritorna nil → TTS "I couldn't find a scene called 'marziano'. Check the Home app." (no crash, no fallback silenzioso)

**E2E-9.6 (web_search)**:
- Pronunciare: *"cerca su web ricette pasta"*
- Atteso: Apple FM invoca `FMWebSearchTool(query: "ricette pasta")` → URL `https://duckduckgo.com/?q=ricette%20pasta` aperto in Safari → TTS "Searching for 'ricette pasta'."

**E2E-9.7 (web_search English)**:
- Pronunciare: *"search the web for best ramen milan"*
- Atteso: Safari aperto con query "best ramen milan", TTS "Searching for 'best ramen milan'."

**E2E-9.8 (Onboarding Layer A fresh install)**:
- Reset device: disinstalla GIGI, reinstalla, completa OnboardingView (permessi)
- Atteso: dopo dismiss di OnboardingView, sheet con `OnboardingTourView` appare → step 0 mostra "Hi, I'm GIGI. Try saying 'set a timer for 5 minutes'" → tap Next → step 1 "I can also help with calendar, contacts, smart home, and more" → tap Next → step 2 enumera 3 categories → tap Done → sheet dismiss

**E2E-9.9 (Onboarding Layer A skip)**:
- Fresh install, OnboardingTourView visibile → tap Skip al primo step
- Atteso: sheet dismiss, `UserDefaults.standard.bool(forKey: "gigi.onboarding.layer_a_complete") == true`, riapri app → tour NON riappare

**E2E-9.10 (Onboarding Layer A skip per turn count)**:
- User esistente con `turn_count >= 5` → install update con Layer A
- Atteso: tour NON appare (skip automatico per upgrade), `shouldShowTour == false`

**E2E-9.11 (regression non-broken)**:
- Pronunciare i 3 comandi base: *"set timer 5 minutes"*, *"call Marco"*, *"navigate to Bologna"*
- Atteso: tutti funzionano come pre-GATE 9 (no regression Path 2 Apple FM)

---

## 6. Test post-creazione (verifica autonoma)

### 6.1 Verifica via grep (filesystem checks)

```bash
ROOT="C:/Users/arman/Desktop/PROGETTI VIBE CODING/GIGI FOLDER/GIGI-work/Armando-Rework/02_GIGI_APP/GIGI"

# 1. 3 nuovi Tool struct esistono
grep -E "struct (FMRunShortcutTool|FMSetHomeKitSceneTool|FMWebSearchTool): Tool" "$ROOT/GigiFoundationToolRegistry.swift" | wc -l
# Atteso: 3

# 2. canonicalActions aggiornato a 20 entries
grep -A30 "static let canonicalActions" "$ROOT/GigiFoundationToolRegistry.swift" | grep -E "\"[a-z_]+\"," | wc -l
# Atteso: >= 20 (era 17, +3 nuovi)

# 3. allTools contiene i 3 nuovi
grep -E "FMRunShortcutTool\(\)|FMSetHomeKitSceneTool\(\)|FMWebSearchTool\(\)" "$ROOT/GigiFoundationToolRegistry.swift" | wc -l
# Atteso: 3

# 4. GigiHomeKitEngine.swift creato con HMHomeManager + delegate
test -f "$ROOT/GigiHomeKitEngine.swift" && echo "OK" || echo "MISSING"
grep -E "HMHomeManager|HMHomeManagerDelegate|executeActionSet" "$ROOT/GigiHomeKitEngine.swift" | wc -l
# Atteso: >= 3

# 5. 3 handler in GigiActionDispatcher+Native.swift
grep -E "func handleRunShortcut|func handleSetHomeKitScene|func handleWebSearch" "$ROOT/GigiActionDispatcher+Native.swift" | wc -l
# Atteso: 3

# 6. URL scheme shortcut bridge presente
grep "shortcuts://x-callback-url/run-shortcut" "$ROOT/GigiActionDispatcher+Native.swift"
# Atteso: 1 match

# 7. URL scheme web search presente
grep "duckduckgo.com" "$ROOT/GigiActionDispatcher+Native.swift"
# Atteso: 1 match

# 8. Onboarding Layer A files creati
test -f "$ROOT/GigiOnboardingFlow.swift" && echo "OK" || echo "MISSING"
test -f "$ROOT/OnboardingTourView.swift" && echo "OK" || echo "MISSING"

# 9. UserDefaults key Layer A
grep "gigi.onboarding.layer_a_complete" "$ROOT/GigiOnboardingFlow.swift"
# Atteso: 1+ match

# 10. Turn count tracking
grep "gigi.usage.turn_count" "$ROOT/"
# Atteso: 2+ match (set in GigiOnboardingFlow, increment in GigiSmartOrchestrator)

# 11. HomeKit entitlement presente
grep "com.apple.developer.homekit" "$ROOT/GIGI.entitlements"
# Atteso: 1 match

# 12. NSHomeKitUsageDescription in Info.plist
grep "NSHomeKitUsageDescription" "$ROOT/../GIGI/Info.plist" || grep -r "NSHomeKitUsageDescription" "$ROOT/../"
# Atteso: 1+ match
```

### 6.2 Verifica via xcodebuild

```bash
ssh user297422@FF125.macincloud.com "cd ~/GIGI-armando-rework/02_GIGI_APP && /usr/bin/xcodebuild -project GIGI.xcodeproj -scheme GIGI -destination 'generic/platform=iOS' build 2>&1 | grep -E 'BUILD SUCCEEDED|error:'"
# Atteso: BUILD SUCCEEDED, 0 error
```

### 6.3 Verifica runtime (logging)

Dopo install IPA con GATE 9, eseguire le E2E-9.1, E2E-9.3, E2E-9.6 e verificare via Console.app filter `subsystem:com.armando.gigi`:

```
tool_invoked: run_shortcut name="modo lavoro"
tool_invoked: set_homekit_scene sceneName="cinema"
tool_invoked: web_search query="ricette pasta"
```

### 6.4 Verifica behavioral mesi dopo

Re-eseguire annualmente:
1. Fresh install → conferma Layer A appare 1 volta sola
2. *"esegui <qualsiasi shortcut)"* → app Shortcuts si apre e Shortcut esegue
3. *"accendi scena <name>"* → scene HomeKit attivata
4. *"cerca su web <qualcosa>"* → Safari aperto con query

---

## 7. Rollback plan

Se uno dei 3 tool si rivela problematico in produzione (es. `set_homekit_scene` crasha su device senza Home configurata):

```bash
cd "C:/Users/arman/Desktop/PROGETTI VIBE CODING/GIGI FOLDER/GIGI-work/Armando-Rework"
# Rollback sub-gate specifico (es. solo HomeKit)
git revert <SHA-9.2-set-homekit-scene>
# Oppure rollback intero GATE
git revert <SHA-9.1>..<SHA-9.4>
```

**Alternative meno destructive — feature flags**:
- Aggiungere a `GigiFoundationToolRegistry.allTools` filter su `UserDefaults.bool(forKey: "gigi.feature.run_shortcut")` (default true) → toggle runtime senza redeploy
- `gigi.feature.set_homekit_scene` default true; se Console crash report mostra crash in HMHomeManager → set false → tool sparisce da Apple FM context
- `gigi.feature.web_search` default true
- `gigi.feature.onboarding_layer_a` default true; se beta tester si lamentano del tour → set false

**Side effects rollback**:
- UserDefaults: `gigi.onboarding.layer_a_complete` e `gigi.usage.turn_count` resterebbero scritti ma inutilizzati (no-op)
- `canonicalActions` e `allTools` tornerebbero a 17 entries
- HomeKit entitlement resta nel target (innocuo, già presente da MVP)

**Backward compat**: utenti che hanno già fatto Layer A non vedono il tour una seconda volta se viene re-shippato in patch successiva (flag persiste).

---

## 8. Files modificati / creati

| Path | Operazione | Righe stimate |
|---|---|---|
| `02_GIGI_APP/GIGI/GigiFoundationToolRegistry.swift` | MODIFY (+3 Tool struct, +3 entries `allTools`, +3 entries `canonicalActions`) | +90 |
| `02_GIGI_APP/GIGI/GigiActionDispatcher+Native.swift` | MODIFY (+3 handler) | +60 |
| `02_GIGI_APP/GIGI/GigiActionBridge.swift` | MODIFY (+3 case dispatch in switch) | +10 |
| `02_GIGI_APP/GIGI/GigiHomeKitEngine.swift` | CREATE | ~200 |
| `02_GIGI_APP/GIGI/GigiOnboardingFlow.swift` | CREATE | ~250 |
| `02_GIGI_APP/GIGI/OnboardingTourView.swift` | CREATE | ~150 |
| `02_GIGI_APP/GIGI/ContentView.swift` (o root) | MODIFY (mount `.sheet`) | +10 |
| `02_GIGI_APP/GIGI/GigiSmartOrchestrator.swift` | MODIFY (turn count increment) | +5 |
| `02_GIGI_APP/GIGI/Info.plist` | VERIFY (NSHomeKitUsageDescription già presente) | 0 |
| `02_GIGI_APP/GIGI/GIGI.entitlements` | VERIFY (entitlement già presente) | 0 |
| `docs/research/gate-9-tool-coverage.md` | CREATE (registra E2E results) | ~60 |

---

## 9. ADR collegati

- **ADR-0008** (Apple FM Tool calling vs scored registry) — riferimento per pattern Tool struct + `@Generable Arguments`. GATE 9 estende il registro da 17 a 20 tool, no breaking change al pattern
- **ADR-0010 PROPOSTA** (tool taxonomy + discovery) — da estrarre dal master plan §3.1 "Tassonomia Tool" e formalizzare PRIMA del merge di Task 9.1. Definisce le 7 categorie + naming convention (`<verb>_<noun>` snake_case). GATE 9 è il primo GATE che ne segue le regole rigorosamente
- **ADR-0009** (Hardware targets and modes) — `set_homekit_scene` richiede HomeKit framework che non è disponibile su iPad Wi-Fi-only senza HomePod paired; documentare graceful degradation in ADR follow-up

---

## 10. Note operative

- **Conventional Commits suggeriti** (uno per sub-gate, mai bulk):
  ```
  feat(ios): GATE 9.A — add run_shortcut meta-tool (closes #<issue>)
  feat(ios): GATE 9.B — add set_homekit_scene + GigiHomeKitEngine
  feat(ios): GATE 9.C — add web_search tool (DuckDuckGo bridge)
  feat(ios): GATE 9.D — onboarding Layer A conversational tour
  docs(plans): GATE 9 — Week 1 capability expansion complete
  ```

- **Branch suggerito**: `feat/gate-9-capability-week1` (singolo branch per i 4 sub-gate, oppure 4 branch dedicati `feat/gate-9a-run-shortcut` ecc. se i sub-gate vengono shippati come patch separate v0.1.1, v0.1.2, v0.1.3, v0.1.4)

- **Test su device fisico OBBLIGATORIO** per:
  - `set_homekit_scene`: Simulator non ha HomeKit reale
  - `run_shortcut`: Simulator può avere Shortcuts ma il bridge URL scheme è più affidabile su device fisico
  - Onboarding Layer A: fresh install richiede uninstall/reinstall reale

- **Decisione Q-9.1 (decisione PM al merge Task 9.2)**: confermare strategia fuzzy match HomeKit (exact → contains → Levenshtein ≤2) vs alternativa Apple Intelligence semantic match (più costoso ma più robusto multilingua). Default proposto: fuzzy match locale, perché `set_homekit_scene` deve essere <500ms latency.

- **Decisione Q-9.2 (skippable se non emerge)**: se beta tester chiedono `web_search` con risultato inline (snippet leggibile da TTS senza aprire Safari), spostare quella feature a GATE 12 Week 4 come `web_search_inline` (master plan §6 Week 4 row dedicata).

- **Context budget Apple FM**: passando da 17 a 20 tool descriptions, il context usage aumenta di ~240 token (80 token/tool × 3). Total context ~1.6k token < 4096 budget, no overflow atteso. Se telemetry mostra `.exceededContextWindowSize` aumentata, applicare strategia subset selection upfront già documentata in GATE 3 §10.

- **Discord notify**: ogni sub-gate completato → comment timeline su issue #19 LIVE FEED via subagent `timeline-poster`:
  - `🎉 GATE 9.A merged — run_shortcut shipped, beta tester can now invoke any Apple Shortcut by voice`
  - `🎉 GATE 9.B merged — set_homekit_scene shipped, scene activation by name`
  - `🎉 GATE 9.C merged — web_search shipped, Safari bridge ready`
  - `🎉 GATE 9.D merged — onboarding Layer A live, new users see 3-step tour`
  - `🏆 GATE 9 COMPLETE — Capability Expansion Week 1 shipped (17 → 20 tools, +Layer A)`

### Cosa fare se Apple Shortcut "run by name" non trova lo Shortcut

Esempio: utente dice *"esegui modo lavoro"* ma lo Shortcut si chiama "Modalità Lavoro".

1. Loggare in `docs/research/gate-9-tool-coverage.md` la frase utente + nome reale Shortcut
2. Apple FM dovrebbe già fare fuzzy matching nella `Arguments.name` extraction, ma se fallisce:
   - Aggiungere `@Guide` esempio: *"Try the closest name you remember. iOS will fuzzy match it."*
   - In Task 9.1 handler, aggiungere fallback: se primo `open` ritorna false, retry con `name` lowercased
3. Documentare nel changelog v0.1.1 come limitation nota

### Cosa fare se HomeKit Home Manager non risponde

`HMHomeManager` può essere lento al primo accesso (>2s). Il pattern `continuations` in `ensureReady()` gestisce ma se diventa problematico:
1. Aggiungere timeout 3s su `await ensureReady()` con fallback "HomeKit isn't ready yet, try again in a moment."
2. Pre-warming: chiamare `GigiHomeKitEngine.shared.ensureReady()` al boot dell'app in background, così il primo *"accendi scena"* è già pronto

### Cosa fare se Onboarding Layer A skip funziona ma turn count non incrementa

Bug più comune: `GigiSmartOrchestrator.process(text:)` ha più exit point e l'increment è solo in uno. Fix:
1. Wrap `process(text:)` con `defer { incrementTurnCount() }` per garantire increment a prescindere
2. Oppure spostare l'increment a fine `GigiActionBridge.execute(_:)` (più downstream, single chokepoint)
