# GATE 15 — Shortcut Intelligence: Proactive Intent Routing

> **Status**: 📋 PLANNED (2026-05-13)
> **Effort stimato**: ~4-6h (mezza giornata lavorativa) — Layer 1 ~1h + Layer 2 ~30min + Layer 3 ~1-2h + Layer 4 ~2-3h
> **Bloccanti pre-gate**: Phase 2 ADR-0014 AI Shortcut Authoring Pipeline IMPLEMENTED e funzionante end-to-end (loop chiuso 2026-05-13 commit `8a4f1eb` — torch tier1 via registered Shortcut → Control Center synced). `composeShortcut` produce 22KB AEA1 firmato, share sheet, install confermato sul device.
> **Sblocca**: GIGI passa da "AI builder dumb" a "AI builder intelligent" — gli Shortcut creati dall'utente sono automaticamente riconosciuti via voce senza configurazione manuale. Prepara GATE 14 (Macro Engine) con un pattern già validato (alias + routing dinamico).
> **Funzione consegnata (1 frase)**: Dopo che l'utente dice *"build me a shortcut that flashes the torch 10 seconds"* + tap "Add Shortcut", al **prossimo** *"torch on"* (o *"accendi torcia"* o *"flashlight"*) GIGI invoca direttamente lo Shortcut installato via Tier 1 (Control Center synced) — zero friction, zero manual binding in Settings.

---

## 1. Obiettivo

Phase 2 (ADR-0014, chiuso 2026-05-13) ha reso GIGI capace di **costruire** Shortcut da prompt naturali. Manca però il loop di **riconoscimento**: dopo l'install, GIGI non sa che "torch on" → "Quick Torch". L'utente deve aprire Settings → My Shortcuts → assegnare manualmente `systemPurpose`. Friction inaccettabile per un assistente che vende "frizione zero".

GATE 15 chiude il loop con **4 layer di intelligenza** stratificati per costo computazionale crescente:

1. **Layer 1 — Auto-alias generation at compose time**. L'harness, dopo aver generato il JSON Cherri, fa un secondo prompt Claude (oppure estende il primo) per produrre 5-10 alias EN+IT + inferire `systemPurpose` dalle azioni. iPhone, ricevuto il response, dopo install registra automaticamente in `GigiShortcutRegistry`. Costo: 1 LLM call extra (~200 token), latency +500ms. Beneficio: 90% dei casi risolto a livello deterministico.

2. **Layer 2 — Dynamic semantic router enrichment**. `GigiSemanticRouter` (NLEmbedding word vectors + cosine, ADR-0012) viene esteso per caricare a boot e on-change gli alias dei Shortcut registrati come trigger phrases addizionali mappati a un intent virtuale `run_registered_shortcut(name)`. Costo: ~3-5ms per query, full on-device, zero LLM. Beneficio: alias mai detti prima ma semanticamente vicini matchano.

3. **Layer 3 — Apple FM dynamic tools**. Quando Layer 1+2 sono inconclusivi (confidence sotto soglia OR multiple match equiprobabili), espongo a Apple FM la lista degli Shortcut registrati come **Tool dinamici** (`FMShortcutInvokeTool` con generated list). Apple FM sceglie con context reasoning multi-turn (history conversazionale + disambiguation). Costo: ~800ms Apple FM call. Beneficio: gestisce *"il mio bedtime"* dove "bedtime" è semanticamente debole ma context-aware.

4. **Layer 4 — Proactive pattern detection**. `GigiUsagePatterns.swift` (nuovo) logga le ultime 50 dispatch (intent + timestamp + speech). Detection rule: se uno stesso pattern (sequenza intent o singolo intent) si ripete **≥3 volte in 7 giorni** AND **non esiste già uno Shortcut registrato per quel purpose**, GIGI propone proattivamente *"Noto che chiedi 'X' spesso — vuoi che ne costruisca uno Shortcut?"*. Su yes → invoca `composeShortcut` con prompt sintetizzato dal pattern → Layer 1 fa il resto (registry popolato → da quel momento Tier 1). Costo: O(50) iterazione array in-memory, zero LLM finché user non accetta. Beneficio: closing the loop dell'assistente proattivo — GIGI non aspetta più, propone.

GATE 15 ha **4 sub-gate sequenziali** (15.A → 15.B → 15.C → 15.D). Ognuno è shippabile in isolamento ma il GATE è COMPLETE solo quando tutti 4 sono mergeati. **Layer 1 è SBLOCCANTE per tutti gli altri** (gli alias/purpose generati da Layer 1 sono input di Layer 2/3/4).

Output concreto:
- `03_HARNESS/server/api/ios-build-shortcut.js` MODIFY (+~80 righe: composer prompt + response shape con `aliases[]` + `systemPurpose`)
- `02_GIGI_APP/GIGI/GigiActionBridge.swift` MODIFY (+~40 righe: post-install registry registration + toast)
- `02_GIGI_APP/GIGI/GigiHarnessClient+Streams.swift` MODIFY (+~15 righe: response decoding `aliases` + `systemPurpose`)
- `02_GIGI_APP/GIGI/GigiSemanticRouter.swift` MODIFY (+~60 righe: dynamic catalog reload from registry)
- `02_GIGI_APP/GIGI/GigiRequestRouter.swift` MODIFY (+~30 righe: handle `run_registered_shortcut` intent virtuale)
- `02_GIGI_APP/GIGI/GigiFoundationToolRegistry.swift` MODIFY (+1 Tool struct `FMShortcutInvokeTool` con dynamic name list)
- `02_GIGI_APP/GIGI/GigiUsagePatterns.swift` CREATE (~180 righe: ring buffer + pattern detection + 7-day decay)
- `02_GIGI_APP/GIGI/GigiActionDispatcher.swift` MODIFY (+~10 righe: log dispatch event to GigiUsagePatterns)
- `02_GIGI_APP/GIGI/GigiAgentEngine.swift` MODIFY (+~20 righe: periodic check pattern detection con throttle)
- `docs/adr/0015-shortcut-intelligence-proactive-routing.md` CREATE (~150 righe — extension a ADR-0014)

---

## 2. Pre-condizioni

- [ ] Phase 2 ADR-0014 IMPLEMENTED e funzionante (commit `8a4f1eb` 2026-05-13). Verifica: pronunciare *"build me a shortcut that turns on the torch for 5 seconds"* → JSON Cherri generato → AEA1 22KB firmato → share sheet su iPhone → "Add Shortcut" → installato in Shortcuts.app
- [ ] `GigiShortcutRegistry.swift` esistente con API stabili: `register(name:aliases:systemPurpose:source:)`, `find(byPurpose:)`, `matchAlias(_:)`, `recordUse(name:)`, `deregister(name:)`
- [ ] `GigiSemanticRouter.swift` esistente con catalog hardcoded (22 tool × 5-12 trigger phrases EN+IT) e cosine similarity vDSP_dotpr funzionante (GATE 15 MVP precedente — ADR-0012)
- [ ] `GigiRequestRouter.route()` chiama `GigiSemanticRouter` PRIMA di Apple FM (verificato: grep `semanticRouter.classify` in `GigiRequestRouter.swift`)
- [ ] `composeShortcut(rawText:)` API stabile in `GigiActionBridge.swift` con `presentShortcutFile(_:title:)` follow-up
- [ ] Endpoint harness `/compose-shortcut/start` + `/job/<id>` operativi (testati con commit `8a4f1eb`)
- [ ] `cherri` JS vocabulary + HubSign signing pipeline funzionanti (no regression on AEA1 byte size ~22KB)
- [ ] iPhone con Apple Intelligence on per Apple FM (Layer 3)
- [ ] Build verify baseline: `xcodebuild` BUILD SUCCEEDED su `armando-rework` commit `8a4f1eb`
- [ ] Decisione PM Q-15.1: confermare soglia `confidence >= 0.55` per Layer 2 dispatch diretto (consistente con GATE 15 MVP semantic router). Decisione al merge Task 15.B.
- [ ] Decisione PM Q-15.2: confermare politica proactive (Layer 4) — opt-in via Settings flag `gigi.suggestion.enabled` default `true` ma silent first 24h (no toast finché user ha fatto ≥5 turni). Decisione al merge Task 15.D.

---

## 3. Task implementativi

### Task 15.A (Layer 1) — Auto-alias generation at compose time (~1h)

**File modificati**:
- `03_HARNESS/server/api/ios-build-shortcut.js` (composer prompt extension + response shape)
- `02_GIGI_APP/GIGI/GigiHarnessClient+Streams.swift` (response decoding `aliases[]` + `systemPurpose`)
- `02_GIGI_APP/GIGI/GigiActionBridge.swift` (post-install registry registration)

**Output API arricchito (response shape)**:

```json
{
  "ok": true,
  "url": "https://<tunnel>/static/shortcut/<uuid>.shortcut",
  "title": "Quick Torch",
  "aliases": ["torch on", "torch off", "flashlight", "torcia", "accendi torcia", "spegni torcia", "blink torch"],
  "systemPurpose": "torch_on",
  "actions": [
    {"action": "torchOn"},
    {"action": "waitSeconds", "seconds": 5},
    {"action": "torchOff"}
  ]
}
```

**Pattern code esempio harness `ios-build-shortcut.js`** (extensione del composer prompt esistente):

```javascript
// In ios-build-shortcut.js, dopo il primo Claude call che produce { title, actions[] }:

const enrichmentPrompt = `Given this Apple Shortcut JSON, generate:
1. An array of 5-10 natural-language aliases (mix English + Italian) that a user might say to invoke this shortcut. Include verb variations ("torch on", "turn on torch", "accendi torcia"). Keep them short (1-4 words each).
2. A systemPurpose key from this canonical list: torch_on, torch_off, set_timer, set_alarm, send_message, make_call, play_music, open_app, weather, navigate, homekit_on, homekit_off, set_homekit_scene, web_search, run_shortcut, custom.

Use "custom" only if NO canonical purpose fits.

Shortcut JSON:
${JSON.stringify({ title, actions }, null, 2)}

Respond with ONLY a valid JSON object: { "aliases": [...], "systemPurpose": "..." }
No prose, no markdown fences.`;

const enrichmentResp = await callClaude({ prompt: enrichmentPrompt, maxTokens: 300 });
const enrichment = JSON.parse(stripFences(enrichmentResp));

return res.json({
    ok: true,
    url: signedUrl,
    title,
    actions,
    aliases: enrichment.aliases || [],
    systemPurpose: enrichment.systemPurpose || "custom"
});
```

**Pattern Swift `GigiHarnessClient+Streams.swift`** (response decoding):

```swift
struct ComposeShortcutResponse: Decodable {
    let ok: Bool
    let url: String
    let title: String
    let aliases: [String]?       // NUOVO
    let systemPurpose: String?   // NUOVO
    let actions: [ShortcutAction]?
}
```

**Pattern Swift `GigiActionBridge.swift`** (post-install registration):

```swift
@MainActor
func composeShortcut(rawText: String) async {
    let resp = try await harnessClient.composeShortcut(prompt: rawText)
    // ... existing logic ...
    await presentShortcutFile(localURL, title: resp.title)

    // NUOVO: registry registration dopo presentazione
    if let aliases = resp.aliases, let purpose = resp.systemPurpose {
        GigiShortcutRegistry.shared.register(
            name: resp.title,
            aliases: aliases,
            systemPurpose: purpose == "custom" ? nil : purpose,
            source: .aiGenerated
        )
        await GigiSemanticRouter.shared.reloadRegistry()  // Layer 2 hook
        await showToast("Registered '\(resp.title)' with \(aliases.count) aliases — Tap to edit")
    }
}
```

**Sub-task atomici**:
- 15.A.1 — Estendere composer in `ios-build-shortcut.js` con secondo prompt Claude per `aliases` + `systemPurpose` (30min)
- 15.A.2 — Aggiornare response JSON shape + test su `/compose-shortcut/start` con curl (15min)
- 15.A.3 — Aggiornare `ComposeShortcutResponse` Decodable in `GigiHarnessClient+Streams.swift` (5min)
- 15.A.4 — Aggiungere `GigiShortcutRegistry.shared.register(...)` call dopo `presentShortcutFile` in `GigiActionBridge.swift` (10min)
- 15.A.5 — Build verify xcodebuild + E2E "build me a shortcut that turns on torch for 5 seconds" → registry popolato (15min)

**Riferimento**: ADR-0014 §4 "Pipeline", ADR-0015 (questo GATE) §3 "Layer 1".

### Task 15.B (Layer 2) — Dynamic semantic router enrichment (~30min)

**File modificati**:
- `02_GIGI_APP/GIGI/GigiSemanticRouter.swift` (dynamic catalog reload)
- `02_GIGI_APP/GIGI/GigiRequestRouter.swift` (handle `run_registered_shortcut` intent virtuale)

**Pattern Swift `GigiSemanticRouter.swift`** (extension a catalog hardcoded):

```swift
@MainActor
func reloadRegistry() async {
    // Carica gli alias dei Shortcut registrati come trigger phrases addizionali
    let registered = GigiShortcutRegistry.shared.allRegistered()
    var dynamicEntries: [SemanticEntry] = []
    for shortcut in registered {
        let virtualIntent = "run_registered_shortcut:\(shortcut.name)"
        for alias in shortcut.aliases {
            dynamicEntries.append(SemanticEntry(
                intent: virtualIntent,
                phrase: alias,
                vector: try? embed(alias)
            ))
        }
    }
    self.dynamicCatalog = dynamicEntries
    GigiLog.info("[semantic] reloaded registry: \(registered.count) shortcuts, \(dynamicEntries.count) total alias entries")
}

// In classify(_:):
func classify(_ utterance: String) async -> (intent: String, confidence: Double, alias: String)? {
    let allEntries = staticCatalog + dynamicCatalog  // dynamic first
    // ... esistente cosine similarity loop ...
    // Se top match è da dynamicCatalog, l'intent ha prefix "run_registered_shortcut:<name>"
}
```

**Pattern Swift `GigiRequestRouter.swift`** (handle virtual intent):

```swift
// In route():
if let (intent, conf, alias) = await semanticRouter.classify(utterance), conf >= 0.55 {
    if intent.hasPrefix("run_registered_shortcut:") {
        let shortcutName = String(intent.dropFirst("run_registered_shortcut:".count))
        GigiLog.info("[semantic+registry run_registered_shortcut \(conf) '\(alias)']")
        return await dispatchRegisteredShortcut(name: shortcutName, source: .semantic)
    }
    // ... esistente dispatch per intent canonici ...
}

@MainActor
func dispatchRegisteredShortcut(name: String, source: DispatchSource) async -> RouterDecision {
    let encoded = name.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? name
    let url = URL(string: "shortcuts://x-callback-url/run-shortcut?name=\(encoded)")!
    let ok = await UIApplication.shared.open(url)
    GigiShortcutRegistry.shared.recordUse(name: name)
    return RouterDecision(path: .tier1, response: ok ? "Running '\(name)'." : "Couldn't run '\(name)'.")
}
```

**Sub-task atomici**:
- 15.B.1 — Aggiungere `dynamicCatalog: [SemanticEntry]` + `reloadRegistry()` in `GigiSemanticRouter.swift` (10min)
- 15.B.2 — Estendere `classify()` per matchare `run_registered_shortcut:<name>` intent (10min)
- 15.B.3 — Aggiungere `dispatchRegisteredShortcut` in `GigiRequestRouter.swift` + handle prefix nel routing (10min)
- 15.B.4 — Wire `reloadRegistry()` su `GigiShortcutRegistry` change (delegate o NotificationCenter) (verify in Task 15.A.4)

**Riferimento**: ADR-0012 §3 "Semantic embedding fast-path", ADR-0015 §3 "Layer 2".

### Task 15.C (Layer 3) — Apple FM dynamic tools fallback (~1-2h)

**File modificati**:
- `02_GIGI_APP/GIGI/GigiFoundationToolRegistry.swift` (NUOVO Tool struct `FMShortcutInvokeTool` con dynamic name list)
- `02_GIGI_APP/GIGI/GigiRequestRouter.swift` (route fallback quando Layer 2 confidence < 0.55)

**Pattern Tool struct dinamico**:

```swift
@available(iOS 26.0, *)
struct FMShortcutInvokeTool: Tool {
    let name = "run_registered_shortcut"

    var description: String {
        let registered = GigiShortcutRegistry.shared.allRegistered()
        let names = registered.map { $0.name }.joined(separator: ", ")
        return "Run one of the user's installed Shortcuts by exact name. Available shortcuts: [\(names)]. Use when the user references one by name, purpose, or close paraphrase."
    }

    @Generable
    struct Arguments {
        @Guide(description: "Exact name of the registered Shortcut to run. Must match one of the available shortcuts in the description.")
        var shortcutName: String
    }

    @MainActor
    func call(arguments: Arguments) async -> String {
        let name = arguments.shortcutName
        guard GigiShortcutRegistry.shared.find(byName: name) != nil else {
            return "I don't have a Shortcut called '\(name)' registered."
        }
        let encoded = name.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? name
        let url = URL(string: "shortcuts://x-callback-url/run-shortcut?name=\(encoded)")!
        let ok = await UIApplication.shared.open(url)
        GigiShortcutRegistry.shared.recordUse(name: name)
        GigiLog.info("[appleFM run_registered_shortcut '\(name)']")
        return ok ? "Running '\(name)'." : "Couldn't run '\(name)'."
    }
}
```

**Wire in `allTools`** (con guard: tool aggiunto solo se ≥1 Shortcut registrato):

```swift
static var allTools: [any Tool] {
    var tools: [any Tool] = [
        FMSetTimerTool(), FMSetAlarmTool(), /* ... 17 esistenti ... */
    ]
    if GigiShortcutRegistry.shared.allRegistered().isEmpty == false {
        tools.append(FMShortcutInvokeTool())
    }
    return tools
}
```

**Route fallback in `GigiRequestRouter.swift`**:

```swift
// In route(): se Layer 2 (semantic) NON matcha o confidence troppo bassa,
// Apple FM riceve la lista dinamica di tool e decide context-aware.
// FMShortcutInvokeTool è già in allTools, no logica extra qui — Apple FM lo userà autonomamente.
```

**Sub-task atomici**:
- 15.C.1 — Aggiungere `FMShortcutInvokeTool` con dynamic `description` computed property (45min)
- 15.C.2 — Estendere `allTools` static var con guard `isEmpty == false` (15min)
- 15.C.3 — Aggiungere `canonicalActions` entry `"run_registered_shortcut"` + handler in `GigiActionDispatcher+Native.swift` (15min)
- 15.C.4 — Build verify + E2E "il mio bedtime" con Shortcut "Bedtime Routine" registrato (30min)
- 15.C.5 — Test disambiguation: 2 Shortcut con alias overlap → Apple FM sceglie il più probabile (15min)

**Riferimento**: ADR-0008 "Apple FM Tool calling vs scored registry", ADR-0015 §3 "Layer 3".

### Task 15.D (Layer 4) — Proactive pattern detection (~2-3h)

**File creati / modificati**:
- `02_GIGI_APP/GIGI/GigiUsagePatterns.swift` CREATE (~180 righe — ring buffer + pattern detection)
- `02_GIGI_APP/GIGI/GigiActionDispatcher.swift` MODIFY (hook logging dopo ogni dispatch)
- `02_GIGI_APP/GIGI/GigiAgentEngine.swift` MODIFY (periodic check con throttle)

**Pattern Swift `GigiUsagePatterns.swift`**:

```swift
import Foundation

@MainActor
final class GigiUsagePatterns: ObservableObject {
    static let shared = GigiUsagePatterns()

    struct DispatchEvent: Codable {
        let intent: String          // "torch_on", "set_timer", ecc.
        let speech: String          // utterance originale
        let timestamp: Date
        let resultedInTier: String  // "tier1", "tier2", "tier3", ecc.
    }

    private let maxBuffer = 50
    private let detectionWindowDays: Int = 7
    private let repetitionThreshold: Int = 3
    private let suggestionCooldown: TimeInterval = 86_400 // 24h
    private let key = "gigi.usage_patterns.buffer"
    private let cooldownKey = "gigi.usage_patterns.last_suggestion"

    @Published private(set) var buffer: [DispatchEvent] = []

    init() {
        load()
    }

    func log(intent: String, speech: String, resultedInTier: String) {
        let event = DispatchEvent(intent: intent, speech: speech, timestamp: Date(), resultedInTier: resultedInTier)
        buffer.append(event)
        if buffer.count > maxBuffer {
            buffer.removeFirst(buffer.count - maxBuffer)
        }
        save()
    }

    /// Returns a candidate pattern if user repeated the same intent ≥3 times in last 7 days
    /// AND no registered Shortcut for that purpose exists yet AND cooldown elapsed.
    func detectCandidate() -> (intent: String, sampleSpeech: String, count: Int)? {
        let suggestionEnabled = UserDefaults.standard.object(forKey: "gigi.suggestion.enabled") as? Bool ?? true
        guard suggestionEnabled else { return nil }
        let lastSuggestion = UserDefaults.standard.object(forKey: cooldownKey) as? Date ?? .distantPast
        guard Date().timeIntervalSince(lastSuggestion) >= suggestionCooldown else { return nil }

        let cutoff = Date().addingTimeInterval(-Double(detectionWindowDays) * 86_400)
        let recent = buffer.filter { $0.timestamp >= cutoff }
        let groups = Dictionary(grouping: recent, by: { $0.intent })
        for (intent, events) in groups where events.count >= repetitionThreshold {
            // Skip if already registered with this purpose
            if GigiShortcutRegistry.shared.find(byPurpose: intent) != nil { continue }
            let sample = events.last!.speech
            return (intent, sample, events.count)
        }
        return nil
    }

    func markSuggestionShown() {
        UserDefaults.standard.set(Date(), forKey: cooldownKey)
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: key) else { return }
        buffer = (try? JSONDecoder().decode([DispatchEvent].self, from: data)) ?? []
    }
    private func save() {
        UserDefaults.standard.set(try? JSONEncoder().encode(buffer), forKey: key)
    }
}
```

**Hook in `GigiActionDispatcher.swift`**:

```swift
// Alla fine di dispatch(_:) — single chokepoint, defer-style
defer {
    Task { @MainActor in
        GigiUsagePatterns.shared.log(
            intent: label,
            speech: rawText,
            resultedInTier: tier.rawValue
        )
    }
}
```

**Periodic check in `GigiAgentEngine.swift`** (throttled ogni N=10 dispatch):

```swift
private var dispatchCounter = 0

func processFinalize() async {
    dispatchCounter += 1
    guard dispatchCounter % 10 == 0 else { return }  // throttle
    if let candidate = GigiUsagePatterns.shared.detectCandidate() {
        await proposeShortcutBuild(for: candidate)
    }
}

private func proposeShortcutBuild(for candidate: (intent: String, sampleSpeech: String, count: Int)) async {
    GigiUsagePatterns.shared.markSuggestionShown()
    let prompt = "I noticed you've asked '\(candidate.sampleSpeech)' \(candidate.count) times recently. Want me to build a Shortcut for this so it runs instantly next time?"
    await speak(prompt)
    let response = await listenForYesNo(timeout: 8)
    if response == .yes {
        await GigiActionBridge.shared.composeShortcut(rawText: candidate.sampleSpeech)
    }
}
```

**Sub-task atomici**:
- 15.D.1 — Creare `GigiUsagePatterns.swift` con ring buffer + UserDefaults persistence (1h)
- 15.D.2 — Implementare `detectCandidate()` con filter 7-day window + grouping + 3-rep threshold + cooldown 24h (45min)
- 15.D.3 — Hook log call in `GigiActionDispatcher.dispatch(_:)` con defer pattern (15min)
- 15.D.4 — Aggiungere `dispatchCounter` + throttled check in `GigiAgentEngine.swift` (30min)
- 15.D.5 — Implementare `proposeShortcutBuild(for:)` con TTS + listen yes/no + composeShortcut chain (30min)
- 15.D.6 — Settings toggle `gigi.suggestion.enabled` in `SettingsView.swift` (15min)
- 15.D.7 — Build verify + E2E: ripeti "torcia accesa 10 secondi" 3 volte → al 3° GIGI propone build (45min)

**Riferimento**: Master plan §6 Week 5+ Layer D Proactive Suggestions (GATE 13), ADR-0015 §3 "Layer 4".

---

## 4. Acceptance Criteria

**GATE 15.A — Auto-alias generation (Layer 1)**:
- [ ] **AC-15.1**: `/compose-shortcut/start` response JSON contiene `aliases: string[]` non vuoto (≥3 entries) e `systemPurpose: string` (canonical key oppure "custom")
- [ ] **AC-15.2**: `ComposeShortcutResponse` Decodable in `GigiHarnessClient+Streams.swift` decodifica entrambi i field
- [ ] **AC-15.3**: Dopo install via share sheet, `GigiShortcutRegistry.shared.find(byName: title)` ritorna entry con `name`, `aliases.count >= 3`, `systemPurpose` popolato
- [ ] **AC-15.4**: `GigiShortcutRegistry.find(byPurpose: "torch_on")` ritorna lo Shortcut registrato
- [ ] **AC-15.5**: Successivo *"torch on"* → routing va su Tier 1 (Control Center synced come da commit `8a4f1eb`)

**GATE 15.B — Semantic router enrichment (Layer 2)**:
- [ ] **AC-15.6**: `GigiSemanticRouter.reloadRegistry()` esiste e carica gli alias dei Shortcut registrati come `SemanticEntry` con intent prefix `run_registered_shortcut:<name>`
- [ ] **AC-15.7**: `classify(_:)` matcha alias mai detto prima ma semanticamente vicino (es. "accendi torcia" matcha "torch on") con confidence ≥ 0.55
- [ ] **AC-15.8**: `GigiRequestRouter.route()` riconosce prefix `run_registered_shortcut:` e invoca `dispatchRegisteredShortcut(name:source:)`
- [ ] **AC-15.9**: Log riga contiene `[semantic+registry run_registered_shortcut <conf> '<alias>']`
- [ ] **AC-15.10**: Dopo `GigiShortcutRegistry.deregister(name:)`, `reloadRegistry()` viene chiamato e classify NON matcha più l'alias

**GATE 15.C — Apple FM dynamic tools (Layer 3)**:
- [ ] **AC-15.11**: `FMShortcutInvokeTool` struct esiste con `name = "run_registered_shortcut"` e `description` computed property che enumera i nomi dei Shortcut registrati
- [ ] **AC-15.12**: `allTools` include `FMShortcutInvokeTool()` SOLO quando `GigiShortcutRegistry.allRegistered().isEmpty == false`
- [ ] **AC-15.13**: `canonicalActions` contiene `"run_registered_shortcut"`
- [ ] **AC-15.14**: Pronunciando *"il mio bedtime"* (con Shortcut "Bedtime Routine" registrato + alias "bedtime"), Apple FM invoca `FMShortcutInvokeTool(shortcutName: "Bedtime Routine")`
- [ ] **AC-15.15**: Log riga contiene `[appleFM run_registered_shortcut 'Bedtime Routine']`

**GATE 15.D — Proactive pattern detection (Layer 4)**:
- [ ] **AC-15.16**: `GigiUsagePatterns.swift` esiste come `@MainActor ObservableObject` singleton con `buffer: [DispatchEvent]` (max 50 entries, FIFO)
- [ ] **AC-15.17**: `log(intent:speech:resultedInTier:)` viene chiamato dopo ogni `GigiActionDispatcher.dispatch(_:)` (verificato con instrumented log)
- [ ] **AC-15.18**: `detectCandidate()` ritorna `(intent, sampleSpeech, count)` SOLO se intent ripetuto ≥3 volte negli ultimi 7 giorni AND nessuno Shortcut già registrato per quel purpose AND cooldown 24h elapsed AND `gigi.suggestion.enabled == true`
- [ ] **AC-15.19**: `GigiAgentEngine` chiama `detectCandidate()` ogni 10 dispatch (throttle)
- [ ] **AC-15.20**: Su candidate detected → TTS "I noticed you've asked '<X>' N times recently. Want me to build a Shortcut...?" → listenForYesNo timeout 8s → yes → invoca `composeShortcut(rawText: sampleSpeech)`
- [ ] **AC-15.21**: Buffer persiste cross-launch via `UserDefaults` JSON encoded
- [ ] **AC-15.22**: Settings toggle `gigi.suggestion.enabled` disponibile in SettingsView; off → `detectCandidate()` ritorna nil

**Trasversali**:
- [ ] **AC-15.23**: Build verify: `xcodebuild` BUILD SUCCEEDED su iPhone 15 Pro+ iOS 26+
- [ ] **AC-15.24**: Tutte le user-facing string (TTS, toast, alert) sono in **inglese** (regola CLAUDE.md hard rule)
- [ ] **AC-15.25**: Nessuna regression: i 22 tool pre-esistenti + i Shortcut built pre-GATE 15 continuano a funzionare
- [ ] **AC-15.26**: ADR-0015 creato e in stato Proposed → Accepted al merge Task 15.D
- [ ] **AC-15.27**: Loop chain Layer 4 → Layer 1: user accetta proposta → `composeShortcut` chiamato → Layer 1 popola registry → 4° tentativo stesso prompt → routing va su Tier 1 (no più build proposal)

---

## 5. E2E test sul telefono (verificabili dall'utente)

**E2E-15.1 (Layer 1 — alias generation)**:
- Pronunciare: *"build me a shortcut that turns on the torch for 5 seconds"*
- Atteso: compose ~6-8s → share sheet → "Add Shortcut" → toast "Registered 'Quick Torch' with N aliases" → `GigiShortcutRegistry.find(byName: "Quick Torch")` ha `aliases.count >= 3`, `systemPurpose == "torch_on"`

**E2E-15.2 (Layer 1 — Tier 1 sync post-install)**:
- Continuazione di E2E-15.1
- Pronunciare: *"torch on"*
- Atteso: dispatch va su Tier 1 (Control Center) come da commit `8a4f1eb` — torcia accesa, log `[tier1 torch_on registered]`

**E2E-15.3 (Layer 2 — semantic match alias mai detto)**:
- Pre-requisito: E2E-15.1 completato (Shortcut "Quick Torch" registrato con alias inclusi "flashlight", "torcia")
- Pronunciare: *"accendi la torcia per favore"* (variante mai esplicitamente in alias)
- Atteso: `GigiSemanticRouter.classify` matcha "accendi torcia" con confidence ≥ 0.55 → log `[semantic+registry run_registered_shortcut 0.7X 'accendi torcia']` → torcia accesa

**E2E-15.4 (Layer 2 — deregister)**:
- In Settings → My Shortcuts → swipe-delete "Quick Torch"
- Pronunciare: *"flashlight"*
- Atteso: `classify` NON matcha più (alias rimossi da dynamicCatalog) → fall-through ad Apple FM → no torch action (oppure fallback search)

**E2E-15.5 (Layer 3 — Apple FM context-aware)**:
- Pre-requisito: Shortcut "Bedtime Routine" registrato manualmente con alias `["bedtime", "go to sleep", "night routine"]`
- Pronunciare: *"il mio bedtime"*
- Atteso: Layer 2 può matchare con conf ~0.55-0.60 OPPURE Apple FM invoca `FMShortcutInvokeTool(shortcutName: "Bedtime Routine")` → log `[appleFM run_registered_shortcut 'Bedtime Routine']` → Shortcuts.app esegue routine

**E2E-15.6 (Layer 3 — disambiguation)**:
- Pre-requisito: 2 Shortcut registrati: "Morning Coffee" (alias "morning routine") + "Morning Workout" (alias "morning")
- Pronunciare: *"morning"*
- Atteso: Apple FM disambigua e sceglie il più probabile basandosi su contesto conversazionale (history) OR chiede *"Did you mean Morning Coffee or Morning Workout?"*

**E2E-15.7 (Layer 4 — proactive proposal)**:
- Pre-requisito: nessun Shortcut registrato per "torch on with 10s timer"
- Pronunciare 3 volte in 1 giorno (separate): *"torcia accesa 10 secondi"* (ogni volta GIGI deve eseguire torch + timer + torch off manualmente)
- Atteso: alla 3ª esecuzione (al check periodico successivo, dispatch #30 circa), GIGI propone via TTS: *"I noticed you've asked 'torcia accesa 10 secondi' 3 times recently. Want me to build a Shortcut for this?"*
- Utente: *"yes"*
- Atteso: invoca `composeShortcut(rawText: "torcia accesa 10 secondi")` → share sheet → install → Layer 1 popola registry

**E2E-15.8 (Layer 4 — chain end-to-end)**:
- Continuazione di E2E-15.7 con install completato
- Pronunciare: *"torcia accesa 10 secondi"* (4ª volta)
- Atteso: dispatch va su Tier 1 registered → torcia accesa 10s spegne — **no più build proposal** (Shortcut già registrato per purpose)

**E2E-15.9 (Layer 4 — cooldown)**:
- Dopo E2E-15.7 (proposta mostrata)
- Ripetere altro intent 3 volte stesso giorno (es. *"play jazz"* x3)
- Atteso: NON viene proposto build entro le 24h dalla precedente proposta (`cooldownKey` elapsed check fail)

**E2E-15.10 (Layer 4 — opt-out)**:
- Settings → disabilita `gigi.suggestion.enabled`
- Ripeti qualsiasi intent N volte
- Atteso: nessuna proposta proattiva mai (detectCandidate ritorna nil immediato)

**E2E-15.11 (regression non-broken)**:
- Pronunciare i 3 comandi base pre-GATE 15: *"set timer 5 minutes"*, *"call Marco"*, *"weather"*
- Atteso: tutti funzionano come pre-GATE 15 (no regression Apple FM)

---

## 6. Test post-creazione (verifica autonoma)

### 6.1 Verifica via grep (filesystem checks)

```bash
ROOT="C:/Users/arman/Desktop/PROGETTI VIBE CODING/GIGI FOLDER/GIGI-work/Armando-Rework/02_GIGI_APP/GIGI"
HARNESS="C:/Users/arman/Desktop/PROGETTI VIBE CODING/GIGI FOLDER/GIGI-work/Armando-Rework/03_HARNESS/server/api"

# 1. Layer 1 — harness composer arricchito
grep -E "aliases|systemPurpose" "$HARNESS/ios-build-shortcut.js" | wc -l
# Atteso: >= 4 (prompt + response shape)

# 2. Layer 1 — Swift Decodable estesa
grep -E "let aliases:|let systemPurpose:" "$ROOT/GigiHarnessClient+Streams.swift" | wc -l
# Atteso: 2

# 3. Layer 1 — registry registration in ActionBridge
grep "GigiShortcutRegistry.shared.register" "$ROOT/GigiActionBridge.swift"
# Atteso: 1 match in composeShortcut completion

# 4. Layer 2 — dynamic catalog in semantic router
grep -E "dynamicCatalog|reloadRegistry" "$ROOT/GigiSemanticRouter.swift" | wc -l
# Atteso: >= 3

# 5. Layer 2 — virtual intent handling
grep "run_registered_shortcut:" "$ROOT/GigiRequestRouter.swift"
# Atteso: >= 1 match (prefix check)

# 6. Layer 2 — dispatchRegisteredShortcut
grep "func dispatchRegisteredShortcut" "$ROOT/GigiRequestRouter.swift"
# Atteso: 1 match

# 7. Layer 3 — FMShortcutInvokeTool
grep "struct FMShortcutInvokeTool" "$ROOT/GigiFoundationToolRegistry.swift"
# Atteso: 1 match
grep "run_registered_shortcut" "$ROOT/GigiFoundationToolRegistry.swift" | wc -l
# Atteso: >= 2 (tool name + canonicalActions entry)

# 8. Layer 4 — GigiUsagePatterns esiste
test -f "$ROOT/GigiUsagePatterns.swift" && echo "OK" || echo "MISSING"
grep -E "DispatchEvent|detectCandidate|markSuggestionShown" "$ROOT/GigiUsagePatterns.swift" | wc -l
# Atteso: >= 3

# 9. Layer 4 — hook in ActionDispatcher
grep "GigiUsagePatterns.shared.log" "$ROOT/GigiActionDispatcher.swift"
# Atteso: 1 match

# 10. Layer 4 — throttle in AgentEngine
grep -E "dispatchCounter|detectCandidate\(\)" "$ROOT/GigiAgentEngine.swift" | wc -l
# Atteso: >= 2

# 11. Layer 4 — UserDefaults keys
grep -E "gigi.usage_patterns|gigi.suggestion.enabled" "$ROOT/" -r | wc -l
# Atteso: >= 3 (buffer key, cooldown key, settings toggle)

# 12. ADR collegato
test -f "C:/Users/arman/Desktop/PROGETTI VIBE CODING/GIGI FOLDER/GIGI-work/Armando-Rework/docs/adr/0015-shortcut-intelligence-proactive-routing.md" && echo "OK" || echo "MISSING"
```

### 6.2 Verifica via xcodebuild

```bash
ssh user297422@FF125.macincloud.com "cd ~/GIGI-armando-rework/02_GIGI_APP && /usr/bin/xcodebuild -project GIGI.xcodeproj -scheme GIGI -destination 'generic/platform=iOS' build 2>&1 | grep -E 'BUILD SUCCEEDED|error:'"
# Atteso: BUILD SUCCEEDED, 0 error
```

### 6.3 Verifica runtime (logging Console.app)

Dopo install IPA con GATE 15, eseguire E2E-15.1 → E2E-15.7 e verificare via Console.app filter `subsystem:com.armando.gigi`:

```
[compose] shortcut built: title='Quick Torch' aliases=[7] systemPurpose='torch_on'
[registry] registered 'Quick Torch' with 7 aliases, purpose=torch_on
[semantic] reloaded registry: 1 shortcuts, 7 alias entries
[semantic+registry run_registered_shortcut 0.78 'flashlight']  ← E2E-15.3
[appleFM run_registered_shortcut 'Bedtime Routine']  ← E2E-15.5
[usage_patterns] candidate detected: intent='torch_on_10s' count=3 sample='torcia accesa 10 secondi'  ← E2E-15.7
[usage_patterns] proposal accepted → composeShortcut chain
```

### 6.4 Verifica behavioral mesi dopo

Re-eseguire annualmente:
1. Build 1 nuovo Shortcut via prompt → verifica `aliases[]` + `systemPurpose` ancora nel response
2. Pronunciare alias mai detto ma semanticamente vicino → verifica semantic router lo cattura
3. Pronunciare paraphrase ambigua → verifica Apple FM disambigua
4. Ripeti stesso prompt 3 volte → verifica proposal proattiva (se cooldown elapsed)

---

## 7. Rollback plan

Se uno dei 4 layer si rivela problematico in produzione:

```bash
cd "C:/Users/arman/Desktop/PROGETTI VIBE CODING/GIGI FOLDER/GIGI-work/Armando-Rework"
# Rollback sub-gate specifico (es. solo Layer 4 perché troppo intrusivo)
git revert <SHA-15.D-proactive>
# Oppure rollback intero GATE
git revert <SHA-15.A>..<SHA-15.D>
```

**Alternative meno destructive — feature flags**:
- `gigi.feature.shortcut_intelligence.layer1` default `true` — toggle off → composer torna a response shape v1 (no aliases, no purpose)
- `gigi.feature.shortcut_intelligence.layer2` default `true` — toggle off → `reloadRegistry()` no-op, `dynamicCatalog` resta vuoto
- `gigi.feature.shortcut_intelligence.layer3` default `true` — toggle off → `FMShortcutInvokeTool` esclusa da `allTools`
- `gigi.feature.shortcut_intelligence.layer4` default `true` AND `gigi.suggestion.enabled` user-toggle — entrambi off → no proactive proposals

**Side effects rollback**:
- `GigiShortcutRegistry` entries già scritti permangono (innocuo, sopravvivono al rollback)
- `GigiUsagePatterns` buffer resta in UserDefaults ma non viene letto se Layer 4 disabilitato
- Apple FM context budget si riduce di ~50-100 token (descrizione `FMShortcutInvokeTool` rimossa)

**Backward compat**: utenti con Shortcut buildati pre-GATE 15 (senza `aliases`/`systemPurpose`) continuano a funzionare via routing Tier 1 manuale (assegnazione purpose in Settings → My Shortcuts come pre-GATE 15).

---

## 8. Files modificati / creati

| Path | Operazione | Layer | Righe stimate |
|---|---|---|---|
| `03_HARNESS/server/api/ios-build-shortcut.js` | MODIFY (composer prompt + response shape) | 1 | +80 |
| `02_GIGI_APP/GIGI/GigiHarnessClient+Streams.swift` | MODIFY (Decodable `aliases` + `systemPurpose`) | 1 | +15 |
| `02_GIGI_APP/GIGI/GigiActionBridge.swift` | MODIFY (post-install registry registration + toast) | 1 | +40 |
| `02_GIGI_APP/GIGI/GigiSemanticRouter.swift` | MODIFY (dynamicCatalog + reloadRegistry) | 2 | +60 |
| `02_GIGI_APP/GIGI/GigiRequestRouter.swift` | MODIFY (handle virtual intent + dispatchRegisteredShortcut) | 2 | +30 |
| `02_GIGI_APP/GIGI/GigiFoundationToolRegistry.swift` | MODIFY (+`FMShortcutInvokeTool` + guard `allTools`) | 3 | +50 |
| `02_GIGI_APP/GIGI/GigiActionDispatcher+Native.swift` | MODIFY (+handler `handleRunRegisteredShortcut`) | 3 | +20 |
| `02_GIGI_APP/GIGI/GigiUsagePatterns.swift` | CREATE | 4 | ~180 |
| `02_GIGI_APP/GIGI/GigiActionDispatcher.swift` | MODIFY (hook log call con defer) | 4 | +10 |
| `02_GIGI_APP/GIGI/GigiAgentEngine.swift` | MODIFY (throttled check + proposeShortcutBuild) | 4 | +30 |
| `02_GIGI_APP/GIGI/SettingsView.swift` | MODIFY (toggle `gigi.suggestion.enabled`) | 4 | +15 |
| `docs/adr/0015-shortcut-intelligence-proactive-routing.md` | CREATE | — | ~150 |
| `docs/research/gate-15-intelligence-coverage.md` | CREATE (registra E2E results) | — | ~80 |

---

## 9. ADR collegati

- **ADR-0014** (AI Shortcut Authoring Pipeline) — riferimento per loop compose → AEA1 → share sheet → install. GATE 15 estende il post-install step con auto-registration nel registry. No breaking change al pipeline, solo arricchimento response API
- **ADR-0015** (NUOVO, da creare in Task 15.A.1 PRIMA del merge) — *"Shortcut Intelligence — Proactive Intent Routing"*. Documenta la 4-layer strategy (alias generation / semantic enrichment / Apple FM dynamic tools / proactive detection). Status: Proposed → Accepted al merge Task 15.D
- **ADR-0012** (Path 2 fast SwiftMCP bridge / Smart Router semantic fast-path) — riferimento per `GigiSemanticRouter` API stabili. GATE 15 estende dynamicCatalog senza modificare staticCatalog (no regression sui 22 tool esistenti)
- **ADR-0008** (Apple FM Tool calling vs scored registry) — riferimento per pattern `Tool` struct + `@Generable Arguments`. `FMShortcutInvokeTool` è il primo Tool con `description` computed property dinamica. Documentare in ADR-0015 §6 "Pattern dinamici"

---

## 10. Note operative

- **Ordine implementazione OBBLIGATORIO**: Layer 1 → Layer 2 → Layer 3 → Layer 4. Layer 1 è sbloccante per tutti (gli alias/purpose sono input di Layer 2/3/4). Layer 2 dipende da Layer 1 (`aliases[]` deve essere popolato). Layer 3 dipende da Layer 1 (`FMShortcutInvokeTool.description` enumera `name`). Layer 4 dipende da Layer 1 (chain proposta → `composeShortcut` → registry).

- **Conventional Commits suggeriti** (uno per sub-gate, mai bulk):
  ```
  feat(harness): GATE 15.A — auto-alias generation in compose-shortcut response
  feat(ios): GATE 15.A — register shortcuts in GigiShortcutRegistry post-install
  feat(ios): GATE 15.B — semantic router dynamicCatalog from registered shortcuts
  feat(ios): GATE 15.C — FMShortcutInvokeTool dynamic Apple FM tool
  feat(ios): GATE 15.D — proactive pattern detection via GigiUsagePatterns
  docs(adr): GATE 15 — accept ADR-0015 shortcut intelligence
  docs(taskplan): GATE 15 closed — 4-layer intent routing live
  ```

- **Branch suggerito**: `feat/gate-15-shortcut-intelligence` (singolo branch per i 4 sub-gate). Se preferito ship incrementale come patch: `feat/gate-15a-auto-alias`, `feat/gate-15b-semantic-enrich`, ecc.

- **Test su device fisico OBBLIGATORIO** per:
  - Layer 1: install via system share sheet (simulator non rispetta correttamente AEA1 unsigned)
  - Layer 2: NLEmbedding precision varia su simulator vs device
  - Layer 3: Apple FM disponibile solo iPhone 15 Pro+ con Apple Intelligence on
  - Layer 4: ring buffer persistence cross-launch (richiede uninstall/reinstall reale)

- **Decisione Q-15.1 (al merge Task 15.B)**: confermare soglia `confidence >= 0.55` per Layer 2 dispatch diretto. Default conservativo: 0.55 (allineato a GATE 15 MVP). Se telemetria mostra troppi false positives, salire a 0.60 con gap ≥0.08 (richiede ADR follow-up).

- **Decisione Q-15.2 (al merge Task 15.D)**: confermare politica proactive. Default proposto: `gigi.suggestion.enabled = true` di default ma silent per primi 5 turni di vita app (no toast finché user ha confidence con assistente). Se beta tester reportano "GIGI mi ha proposto troppo presto", aumentare floor a 20 turni.

- **Context budget Apple FM**: aggiunta `FMShortcutInvokeTool` con description dinamica (enumera nomi Shortcut) può crescere O(N) con N = Shortcut registrati. Strategia mitigazione se N > 20: emettere solo i 10 più recentemente usati (sort by `recordUse` timestamp). Documentare in ADR-0015 §7 "Scaling".

- **Privacy**: `GigiUsagePatterns.buffer` contiene `speech` (utterance utente raw). Resta on-device in UserDefaults, mai uploaded. Documentare in `docs/PRIVACY.md` se esiste.

- **Discord notify**: ogni sub-gate completato → comment timeline su issue #19 LIVE FEED via subagent `timeline-poster`:
  - `🎉 GATE 15.A merged — shortcuts now auto-register with AI-generated aliases + systemPurpose`
  - `🎉 GATE 15.B merged — semantic router catches alias variants on-device (no LLM cost)`
  - `🎉 GATE 15.C merged — Apple FM fallback chooses between ambiguous shortcuts context-aware`
  - `🎉 GATE 15.D merged — GIGI proactively proposes shortcut builds for repeated patterns`
  - `🏆 GATE 15 COMPLETE — Shortcut Intelligence Proactive Routing live (4-layer pipeline)`

### Cosa fare se composer enrichment fallisce JSON parsing

Il secondo Claude call può ritornare prose invece di pure JSON (especially con prompt poorly tuned). Mitigazioni:
1. `stripFences(text)` helper in harness rimuove markdown fences
2. Try/catch JSON.parse → fallback a `{ aliases: [], systemPurpose: "custom" }` (no crash, Shortcut installa senza intelligence)
3. Loggare il raw response per debug + open sub-issue se fallisce >5% delle volte
4. Considerare `response_format: { type: "json_object" }` se Claude SDK lo supporta (deterministic structured output)

### Cosa fare se semantic router matcha l'alias sbagliato

Esempio: 2 Shortcut con alias overlap "set the mood" (Lighting Mood vs Music Mood). Semantic router può scegliere quello sbagliato.
1. Detectare gap < 0.05 tra top-1 e top-2 → fall-through ad Apple FM (Layer 3) per disambiguation context-aware
2. In `GigiSemanticRouter.classify`, ritornare tupla `(top1, gap)` invece di solo top1
3. Documentare in ADR-0015 §8 "Disambiguation" + AC-15.7 + AC-15.10 estesi

### Cosa fare se proactive proposal annoys user

Beta tester reportano "GIGI mi ha proposto build per pattern banale". Mitigazioni:
1. Aumentare `repetitionThreshold` da 3 a 5
2. Aumentare `detectionWindowDays` da 7 a 14
3. Aumentare `suggestionCooldown` da 24h a 72h
4. Aggiungere skip-list: pattern che NON propongono mai (es. `set_timer` con duration variabile — è già parametrizzato, no senso buildare uno Shortcut)
5. UX: invece di TTS interrupt, mostrare badge silenzioso nella tab Dashboard "1 suggestion available" che user può ignorare

### Loop matrioska — chain Layer 4 → Layer 1 → Layer 2

Il vero magic moment di GATE 15: utente ripete 3 volte un task → GIGI propone → user accetta → composeShortcut → install → da quel momento Tier 1 silent → utente non chiede più "torcia accesa 10 secondi", lo dice e funziona istantaneo. È il **closing the loop** del proactive assistant. AC-15.27 è l'AC più importante del GATE.
