# GATE 15 — Smart Action Loop (Plan / Confirm / Build / Learn)

> **Status**: 📋 PLANNED (refactored 2026-05-13)
> **Effort stimato**: ~6-8h (era 4-6h; +2h per split endpoints + card UI)
> **Bloccanti pre-gate**: Phase 2 ADR-0014 AI Shortcut Authoring Pipeline IMPLEMENTED e funzionante end-to-end (loop chiuso 2026-05-13 commit `8a4f1eb` — torch tier1 via registered Shortcut → Control Center synced). `composeShortcut` produce 22KB AEA1 firmato, share sheet, install confermato sul device.
> **Sblocca**: GIGI passa da "AI builder dumb" a "AI builder con consenso esplicito + auto-recognition". Ogni richiesta utente attraversa un **decision tree a 5 step** (Execute Try → Plan → Build → Learn → Recognize). Prepara GATE 14 (Macro Engine) con un pattern già validato (alias + routing dinamico + user consent UX).
> **Funzione consegnata (1 frase)**: utente dice *"build a shortcut to flash the torch 10 seconds"* → GIGI mostra una **proposal card** in chat con summary + actions → utente tappa "Build Shortcut" → install + auto-register → la prossima volta che dice *"torch on"* GIGI invoca direttamente lo Shortcut via Tier 1 senza passare da `composeShortcut`.

---

## 1. Obiettivo — riframing user-driven

Phase 2 (ADR-0014, chiuso 2026-05-13) ha reso GIGI capace di **costruire** Shortcut da prompt naturali, ma con due gap UX:
1. **No consent** — utente non sa cosa GIGI sta per costruire finché non vede il share sheet
2. **No recognition** — dopo install, GIGI non riconosce gli alias del proprio Shortcut

GATE 15 chiude entrambi i gap riposizionando il flusso come un **unico decision tree user-driven**:

```
USER UTTERANCE
   ↓
[Step 1] EXECUTE TRY — match against existing capabilities
   • Layer A: NLU fast-path (hardcoded intents)
   • Layer B: Registry exact alias / purpose match → invoke shortcuts://
   • Layer C: Semantic router enriched with registered aliases
   • Layer D: Apple FM with dynamic registered-shortcut tools
   MATCH → invoke → done.
   ↓ (no match)
[Step 2] PLAN PHASE — generate shortcut proposal
   • Server POST /compose-shortcut/plan
   • Claude returns: { planId, title, summary, actions, aliases, systemPurpose }
   • iOS renders a CARD in chat with summary + numbered actions list
   • CTAs: [✓ Build Shortcut] [✗ Cancel]
   ↓ (user taps Build)
[Step 3] BUILD PHASE — compile + sign
   • Server POST /compose-shortcut/build {planId} → returns {jobId}
   • cherri compile + HubSign + return signed URL (existing)
   • iOS download in-app + system share sheet (existing)
   ↓ (user taps Add to Shortcuts)
[Step 4] LEARN PHASE — auto-register
   • iOS registers in GigiShortcutRegistry with aliases + purpose
   • Toast: "I learned '<title>'. Next time you say '<top alias>' I'll run it directly."
   ↓
[Step 5] (next time) Step 1 succeeds → invoke via shortcuts://x-callback-url
```

I 4 "layer" del piano originale diventano **sotto-componenti di questo decision tree**:
- Vecchio Layer 1 (auto-alias) → **Step 4 Learn Phase**
- Vecchio Layer 2 (semantic router enrichment) → **Step 1 Layer C**
- Vecchio Layer 3 (FM dynamic tools) → **Step 1 Layer D**
- Vecchio Layer 4 (pattern detection) → **REMOVED da GATE 15**, spostato in **GATE 15.5 Daydream** (file separato `GATE-15.5-daydream-predictive-shortcuts.md`, post-MVP)

GATE 15 ha **5 sub-gate sequenziali** (15.A → 15.E). Ognuno è shippabile in isolamento ma il GATE è COMPLETE solo quando tutti 5 sono mergeati.

Output concreto:
- `03_HARNESS/server/api/ios-build-shortcut.js` MODIFY (split plan/build, plans Map con TTL 5min, ~120 righe added)
- `03_HARNESS/server/api/ios-router.js` MODIFY (3 route invece di 2: plan + build + job)
- `02_GIGI_APP/GIGI/GigiHarnessClient+Streams.swift` MODIFY (+`postPlanShortcut` + `postBuildShortcutFromPlan`, ~25 righe)
- `02_GIGI_APP/GIGI/GigiActionBridge.swift` MODIFY (split `composeShortcut` → `proposeShortcut` + `buildShortcutFromPlan`, ~50 righe)
- `02_GIGI_APP/GIGI/ShortcutProposalCard.swift` CREATE (SwiftUI custom view ~120 righe)
- `02_GIGI_APP/GIGI/ChatView.swift` MODIFY (render proposal cards as new message type, ~30 righe)
- `02_GIGI_APP/GIGI/GigiSemanticRouter.swift` MODIFY (dynamicCatalog + reloadRegistry, ~60 righe)
- `02_GIGI_APP/GIGI/GigiRequestRouter.swift` MODIFY (handle virtual intent, ~30 righe)
- `02_GIGI_APP/GIGI/GigiFoundationToolRegistry.swift` MODIFY (+`FMShortcutInvokeTool`, ~50 righe)
- `02_GIGI_APP/GIGI/GigiShortcutRegistry.swift` MODIFY (auto-register API + change notification, ~15 righe)
- `docs/adr/0015-smart-action-loop.md` CREATE (~180 righe)
- `docs/adr/0014-ai-shortcut-authoring-pipeline.md` MODIFY (add §9 "Superseded API contract" pointing to ADR-0015)

---

## 2. Pre-condizioni

- [ ] Phase 2 ADR-0014 IMPLEMENTED e funzionante (commit `8a4f1eb` 2026-05-13). Verifica: pronunciare *"build me a shortcut that turns on the torch for 5 seconds"* → JSON Cherri generato → AEA1 22KB firmato → share sheet su iPhone → "Add Shortcut" → installato in Shortcuts.app
- [ ] `GigiShortcutRegistry.swift` esistente con API stabili: `register(name:aliases:systemPurpose:source:)`, `find(byPurpose:)`, `matchAlias(_:)`, `recordUse(name:)`, `deregister(name:)`
- [ ] `GigiSemanticRouter.swift` esistente con catalog hardcoded (22 tool × 5-12 trigger phrases EN+IT) e cosine similarity vDSP_dotpr funzionante (ADR-0012)
- [ ] `GigiRequestRouter.route()` chiama `GigiSemanticRouter` PRIMA di Apple FM (verificato: grep `semanticRouter.classify` in `GigiRequestRouter.swift`)
- [ ] `composeShortcut(rawText:)` API stabile in `GigiActionBridge.swift` con `presentShortcutFile(_:title:)` follow-up — verrà refactored ma il pipeline cherri/HubSign sotto resta uguale
- [ ] Endpoint harness `/compose-shortcut/start` + `/job/<id>` operativi (testati con commit `8a4f1eb`)
- [ ] `cherri` JS vocabulary + HubSign signing pipeline funzionanti (no regression on AEA1 byte size ~22KB)
- [ ] `ChatView.swift` esistente con array di message bubble e capacità di rendering message type custom (verifica: `ChatMessage` enum o protocol)
- [ ] iPhone con Apple Intelligence on per Apple FM (Step 1 Layer D)
- [ ] Build verify baseline: `xcodebuild` BUILD SUCCEEDED su `armando-rework` commit `8a4f1eb`
- [ ] Decisione PM Q-15.1: confermare soglia `confidence >= 0.55` per Step 1 Layer C dispatch diretto (consistente con ADR-0012). Decisione al merge Task 15.D.
- [ ] Decisione PM Q-15.2: confermare TTL plan = 5 min (rationale: Claude planning richiede 3-5s, user può discutere/riflettere ~2-3 min, 5min è safe margin). Decisione al merge Task 15.A.

---

## 3. Task implementativi

### Task 15.A (Step 2+3 backend) — Split endpoint compose-shortcut in plan / build / job (~2h)

**File modificati**:
- `03_HARNESS/server/api/ios-build-shortcut.js` (split logic, plans Map TTL, 2 new handlers)
- `03_HARNESS/server/api/ios-router.js` (3 routes invece di 2)

**Endpoint contracts**:

#### `POST /api/ios/compose-shortcut/plan`

Body: `{ prompt: string }`

Behavior: Claude **only** call (no cherri, no signing). Returns the proposal shape.

```json
{
  "ok": true,
  "planId": "plan-<uuid>",
  "title": "Quick Torch Flash",
  "summary": "Turns the torch on, waits 10 seconds, then turns it off.",
  "actions": [
    { "action": "torchOn", "category": "torch", "displayLabel": "Turn torch on" },
    { "action": "waitSeconds", "seconds": 10, "category": "wait", "displayLabel": "Wait 10 seconds" },
    { "action": "torchOff", "category": "torch", "displayLabel": "Turn torch off" }
  ],
  "aliases": ["torch on", "torch off", "flashlight", "torcia", "accendi torcia", "spegni torcia", "blink torch"],
  "systemPurpose": "torch_on",
  "expiresAt": "2026-05-13T19:35:12Z"
}
```

The plan is held server-side in an in-memory `Map<planId, PlanObject>` with **5-minute TTL** (configurable via env `GIGI_PLAN_TTL_MS`, default 300000). Stale plans are pruned by a `setInterval` running every 60s.

#### `POST /api/ios/compose-shortcut/build`

Body: `{ planId: string }`

Behavior: looks up the plan, kicks off cherri compile + HubSign **in background**, returns the existing `jobId` shape. If plan not found (expired or invalid): **410 Gone** with `{ ok: false, error: "plan_expired", message: "Plan expired, please ask GIGI again." }`. Plan is consumed (deleted from Map) on successful build kickoff to prevent double-build.

```json
{ "ok": true, "jobId": "job-<uuid>" }
```

#### `GET /api/ios/compose-shortcut/job/:jobId`

Unchanged from ADR-0014. Returns `{ status: "pending"|"ready"|"error", url?: string, title?: string }`.

#### `POST /api/ios/compose-shortcut/start` (legacy, kept for backward compat)

Existing endpoint stays functional for older IPAs that don't know about plan/build split. Internally runs plan + build merged inline (the old path). Marked `@deprecated` in JSDoc, slated for removal in v0.2.0.

**Pattern code esempio harness `ios-build-shortcut.js`**:

```javascript
const plans = new Map(); // planId → { title, summary, actions, aliases, systemPurpose, createdAt, prompt }
const PLAN_TTL_MS = parseInt(process.env.GIGI_PLAN_TTL_MS || "300000", 10);

setInterval(() => {
  const now = Date.now();
  for (const [id, plan] of plans) {
    if (now - plan.createdAt > PLAN_TTL_MS) plans.delete(id);
  }
}, 60_000);

export async function handlePlan(req, res) {
  const { prompt } = req.body;
  if (!prompt) return res.status(400).json({ ok: false, error: "prompt_required" });
  const planResp = await callClaude({ prompt: buildPlanPrompt(prompt), maxTokens: 800 });
  const parsed = JSON.parse(stripFences(planResp));
  const planId = `plan-${crypto.randomUUID()}`;
  plans.set(planId, { ...parsed, createdAt: Date.now(), prompt });
  return res.json({
    ok: true,
    planId,
    title: parsed.title,
    summary: parsed.summary,
    actions: parsed.actions,
    aliases: parsed.aliases,
    systemPurpose: parsed.systemPurpose,
    expiresAt: new Date(Date.now() + PLAN_TTL_MS).toISOString(),
  });
}

export async function handleBuild(req, res) {
  const { planId } = req.body;
  const plan = plans.get(planId);
  if (!plan) return res.status(410).json({ ok: false, error: "plan_expired", message: "Plan expired, please ask GIGI again." });
  plans.delete(planId); // consume
  const jobId = `job-${crypto.randomUUID()}`;
  startCherrCompileAndSign(jobId, plan); // async background
  return res.json({ ok: true, jobId });
}
```

The Claude plan prompt asks for `displayLabel` (1-3 word humanized action name) and `category` (one of: torch, music, settings, homekit, timer, message, navigation, web, system, custom) for rich card rendering.

**Sub-task atomici**:
- 15.A.1 — Refactor `ios-build-shortcut.js` extracting `buildCherriAndSign(plan, jobId)` from the existing `/start` handler so it can be reused by `handleBuild` (45min)
- 15.A.2 — Implement `plans` Map + TTL pruner + `handlePlan` with extended Claude prompt asking for summary + displayLabel + category (45min)
- 15.A.3 — Implement `handleBuild` with 410 Gone on expired/missing planId + consume-on-success (15min)
- 15.A.4 — Wire 3 routes in `ios-router.js` keeping legacy `/start` (10min)
- 15.A.5 — Manual curl test: `/plan` → 200 with planId → `/build` → 200 with jobId → `/job/<id>` → ready (15min)

**Riferimento**: ADR-0014 §4 "Pipeline", ADR-0015 §3 "Plan/Build split".

### Task 15.B (Step 2 frontend) — Proposal card + iOS bridge split (~2h)

**File modificati**:
- `02_GIGI_APP/GIGI/GigiHarnessClient+Streams.swift` (+`postPlanShortcut` + `postBuildShortcutFromPlan`)
- `02_GIGI_APP/GIGI/GigiActionBridge.swift` (split `composeShortcut` → `proposeShortcut` + `buildShortcutFromPlan`)
- `02_GIGI_APP/GIGI/ShortcutProposalCard.swift` (CREATE)
- `02_GIGI_APP/GIGI/ChatView.swift` (render new message type)

**Decodable contracts**:

```swift
struct ShortcutPlanResponse: Decodable {
    let ok: Bool
    let planId: String
    let title: String
    let summary: String
    let actions: [PlanAction]
    let aliases: [String]
    let systemPurpose: String?
    let expiresAt: Date
}

struct PlanAction: Decodable, Identifiable {
    let id = UUID()
    let action: String
    let displayLabel: String
    let category: String
    // CodingKeys excludes id
}

struct ShortcutBuildResponse: Decodable {
    let ok: Bool
    let jobId: String?
    let error: String?
    let message: String?
}
```

**Pattern Swift `GigiActionBridge.swift`** (split flow):

```swift
@MainActor
func proposeShortcut(rawText: String) async {
    showBanner("Planning Shortcut...")
    do {
        let plan = try await harnessClient.postPlanShortcut(prompt: rawText)
        hideBanner()
        // Insert a proposal card message in the chat
        ChatStore.shared.appendMessage(.shortcutProposal(plan))
        GigiLog.info("[propose] plan='\(plan.planId)' title='\(plan.title)' aliases=\(plan.aliases.count)")
    } catch {
        hideBanner()
        await showToast("Couldn't plan the shortcut: \(error.localizedDescription)")
    }
}

@MainActor
func buildShortcutFromPlan(_ plan: ShortcutPlanResponse) async {
    showBanner("Building Shortcut...")
    do {
        let buildResp = try await harnessClient.postBuildShortcutFromPlan(planId: plan.planId)
        guard let jobId = buildResp.jobId else {
            hideBanner()
            await showToast(buildResp.message ?? "Build failed.")
            return
        }
        let job = try await pollJob(jobId: jobId, timeout: 30)
        hideBanner()
        await presentShortcutFile(job.localURL, title: plan.title)
        // Learn Phase (Step 4) — auto-register
        GigiShortcutRegistry.shared.register(
            name: plan.title,
            aliases: plan.aliases,
            systemPurpose: plan.systemPurpose == "custom" ? nil : plan.systemPurpose,
            source: .aiGenerated
        )
        await GigiSemanticRouter.shared.reloadRegistry()
        let topAlias = plan.aliases.first ?? plan.title.lowercased()
        await showToast("I learned '\(plan.title)'. Next time you say '\(topAlias)' I'll run it directly.")
    } catch {
        hideBanner()
        if (error as NSError).code == 410 {
            await showToast("Plan expired. Ask me again to start over.")
        } else {
            await showToast("Build failed: \(error.localizedDescription)")
        }
    }
}

@MainActor
func cancelShortcutPlan(_ planId: String) {
    // Local discard. Server plan evaporates after 5min TTL.
    ChatStore.shared.removeProposalCard(planId: planId)
    GigiLog.info("[propose] cancelled plan='\(planId)'")
}
```

**Pattern `ShortcutProposalCard.swift`**:

```swift
import SwiftUI

@available(iOS 16.0, *)
struct ShortcutProposalCard: View {
    let plan: ShortcutPlanResponse
    let onBuild: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "wand.and.stars")
                    .font(.title3)
                    .foregroundStyle(.tint)
                Text(plan.title)
                    .font(.headline)
                Spacer()
            }
            Text(plan.summary)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Divider()
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(plan.actions.enumerated()), id: \.offset) { idx, action in
                    HStack(spacing: 8) {
                        Text("\(idx + 1).")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                        Text(emoji(for: action.category))
                        Text(action.displayLabel)
                            .font(.body)
                    }
                }
            }
            HStack(spacing: 12) {
                Button(action: onCancel) {
                    Text("Cancel")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                Button(action: onBuild) {
                    Text("Build Shortcut")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 16).fill(.background))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(.tint.opacity(0.3), lineWidth: 1))
        .padding(.horizontal)
    }

    private func emoji(for category: String) -> String {
        switch category {
        case "torch": return "🔦"
        case "music": return "🎵"
        case "settings": return "⚙️"
        case "homekit": return "🏠"
        case "timer": return "⏱️"
        case "message": return "💬"
        case "navigation": return "🗺️"
        case "web": return "🌐"
        case "system": return "📱"
        default: return "✨"
        }
    }
}
```

**Pattern `ChatView.swift`** (render new message type):

```swift
// In ChatMessage enum (or equivalent):
case shortcutProposal(ShortcutPlanResponse)

// In ChatView body, switch on message type:
case .shortcutProposal(let plan):
    ShortcutProposalCard(
        plan: plan,
        onBuild: {
            Task { await GigiActionBridge.shared.buildShortcutFromPlan(plan) }
            ChatStore.shared.removeProposalCard(planId: plan.planId)
        },
        onCancel: {
            GigiActionBridge.shared.cancelShortcutPlan(plan.planId)
        }
    )
```

**Sub-task atomici**:
- 15.B.1 — Add `postPlanShortcut(prompt:)` and `postBuildShortcutFromPlan(planId:)` to `GigiHarnessClient+Streams.swift` (20min)
- 15.B.2 — Add `Decodable` structs `ShortcutPlanResponse` + `PlanAction` + `ShortcutBuildResponse` (15min)
- 15.B.3 — Split `composeShortcut` into `proposeShortcut(rawText:)` + `buildShortcutFromPlan(plan:)` + `cancelShortcutPlan(planId:)` in `GigiActionBridge.swift`. Keep legacy `composeShortcut` as thin wrapper that calls propose (for backward compat with existing call sites) (30min)
- 15.B.4 — Create `ShortcutProposalCard.swift` SwiftUI view with title/summary/numbered actions/CTAs (30min)
- 15.B.5 — Extend `ChatMessage` enum with `.shortcutProposal(ShortcutPlanResponse)` case + render branch in `ChatView.swift`. Add `ChatStore.appendMessage` + `removeProposalCard` helpers (25min)
- 15.B.6 — Banner "Planning Shortcut..." during `/plan` call + "Building Shortcut..." during `/build` + polling (10min)

**Riferimento**: ADR-0015 §4 "User consent UX".

### Task 15.C (Step 1 Layer C) — Dynamic semantic router enrichment (~30min)

**File modificati**:
- `02_GIGI_APP/GIGI/GigiSemanticRouter.swift` (dynamic catalog reload)
- `02_GIGI_APP/GIGI/GigiRequestRouter.swift` (handle `run_registered_shortcut` virtual intent)
- `02_GIGI_APP/GIGI/GigiShortcutRegistry.swift` (post change notification)

**Pattern Swift `GigiSemanticRouter.swift`**:

```swift
@MainActor
func reloadRegistry() async {
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
```

**Pattern Swift `GigiRequestRouter.swift`** (handle virtual intent):

```swift
if let (intent, conf, alias) = await semanticRouter.classify(utterance), conf >= 0.55 {
    if intent.hasPrefix("run_registered_shortcut:") {
        let shortcutName = String(intent.dropFirst("run_registered_shortcut:".count))
        GigiLog.info("[semantic+registry run_registered_shortcut \(conf) '\(alias)']")
        return await dispatchRegisteredShortcut(name: shortcutName, source: .semantic)
    }
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

**Pattern `GigiShortcutRegistry.swift`** (post Notification on change so router reloads):

```swift
static let didChangeNotification = Notification.Name("GigiShortcutRegistry.didChange")

func register(name: String, aliases: [String], systemPurpose: String?, source: Source) {
    // ... existing logic ...
    NotificationCenter.default.post(name: Self.didChangeNotification, object: nil)
}
```

**Sub-task atomici**:
- 15.C.1 — Add `dynamicCatalog: [SemanticEntry]` + `reloadRegistry()` in `GigiSemanticRouter.swift` (10min)
- 15.C.2 — Extend `classify()` to include `dynamicCatalog` and recognize `run_registered_shortcut:<name>` virtual intent (10min)
- 15.C.3 — Add `dispatchRegisteredShortcut` in `GigiRequestRouter.swift` + prefix handling (10min)
- 15.C.4 — Add `didChangeNotification` post in `GigiShortcutRegistry.register/deregister` + observer in `GigiSemanticRouter.init` that calls `reloadRegistry` (10min)

**Riferimento**: ADR-0012 §3 "Semantic embedding fast-path", ADR-0015 §3 "Step 1 Layer C".

### Task 15.D (Step 1 Layer D) — Apple FM dynamic tools fallback (~1-2h)

**File modificati**:
- `02_GIGI_APP/GIGI/GigiFoundationToolRegistry.swift` (+`FMShortcutInvokeTool` with dynamic name list)
- `02_GIGI_APP/GIGI/GigiActionDispatcher+Native.swift` (+handler `handleRunRegisteredShortcut`)

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

**Wire in `allTools`** (guard: tool added only when ≥1 Shortcut registered):

```swift
static var allTools: [any Tool] {
    var tools: [any Tool] = [
        FMSetTimerTool(), FMSetAlarmTool(), /* ... 17 existing ... */
    ]
    if GigiShortcutRegistry.shared.allRegistered().isEmpty == false {
        tools.append(FMShortcutInvokeTool())
    }
    return tools
}
```

**Sub-task atomici**:
- 15.D.1 — Add `FMShortcutInvokeTool` with dynamic `description` computed property (45min)
- 15.D.2 — Extend `allTools` static var with guard `isEmpty == false` (15min)
- 15.D.3 — Add `canonicalActions` entry `"run_registered_shortcut"` + handler in `GigiActionDispatcher+Native.swift` (15min)
- 15.D.4 — Build verify + manual test "il mio bedtime" with Shortcut "Bedtime Routine" registered (30min)
- 15.D.5 — Disambiguation test: 2 Shortcuts with overlapping aliases → Apple FM picks the most probable (15min)

**Riferimento**: ADR-0008 "Apple FM Tool calling vs scored registry", ADR-0015 §3 "Step 1 Layer D".

### Task 15.E (ADR + integration test) — Documentation + 5 E2E scenarios (~1h)

**File modificati / creati**:
- `docs/adr/0015-smart-action-loop.md` CREATE (~180 righe, see §9 below for skeleton)
- `docs/adr/0014-ai-shortcut-authoring-pipeline.md` MODIFY (add §9 "Superseded API contract — see ADR-0015")
- `docs/research/gate-15-smart-action-loop-e2e.md` CREATE (record E2E results)

**Sub-task atomici**:
- 15.E.1 — Draft `docs/adr/0015-smart-action-loop.md` (status: Proposed) with 5-step decision tree diagram + Plan/Build API contracts + TTL rationale + card UX rationale (30min)
- 15.E.2 — Add §9 to ADR-0014 referencing ADR-0015 as the user-facing UX layer (15min)
- 15.E.3 — Run all 5 E2E scenarios on device + record results in `gate-15-smart-action-loop-e2e.md` (15min)
- 15.E.4 — Promote ADR-0015 to Accepted on GATE merge (close out commit)

---

## 4. Acceptance Criteria

**GATE 15.A — Plan/Build endpoint split**:
- [ ] **AC-15.1**: `POST /api/ios/compose-shortcut/plan` with body `{prompt}` returns 200 with `{ok, planId, title, summary, actions[], aliases[], systemPurpose, expiresAt}` — Claude call only, no cherri compile
- [ ] **AC-15.2**: `POST /api/ios/compose-shortcut/build` with body `{planId}` returns 200 with `{ok, jobId}` for valid planId
- [ ] **AC-15.3**: `POST /api/ios/compose-shortcut/build` with stale/missing planId returns 410 Gone with `{ok: false, error: "plan_expired"}`
- [ ] **AC-15.4**: After successful build, planId is consumed (second `/build` call with same planId returns 410)
- [ ] **AC-15.5**: Plans Map TTL prunes entries after 5 min (verify via env override `GIGI_PLAN_TTL_MS=5000` + manual test)
- [ ] **AC-15.6**: Legacy `POST /api/ios/compose-shortcut/start` still works (old IPA backward compat)
- [ ] **AC-15.7**: `actions[]` includes `displayLabel` (1-3 word humanized) and `category` (one of: torch, music, settings, homekit, timer, message, navigation, web, system, custom) per item

**GATE 15.B — Proposal card UX**:
- [ ] **AC-15.8**: `proposeShortcut(rawText:)` calls `/plan` → appends a `.shortcutProposal(plan)` message to chat within 5s of utterance
- [ ] **AC-15.9**: `ShortcutProposalCard` displays: title with wand-and-stars icon, summary, numbered list of actions with category emoji, "Build Shortcut" primary button, "Cancel" secondary button
- [ ] **AC-15.10**: Tap "Build Shortcut" → calls `/build` → polls `/job` → presents share sheet within 15s
- [ ] **AC-15.11**: Tap "Cancel" → card removed from chat, no `/build` call made, registry untouched
- [ ] **AC-15.12**: Banner "Planning Shortcut..." visible during `/plan` call (3-5s)
- [ ] **AC-15.13**: Banner "Building Shortcut..." visible during `/build` + polling (8-15s)
- [ ] **AC-15.14**: On plan expiry mid-flow (user waits >5min before tap Build), toast "Plan expired. Ask me again to start over." appears
- [ ] **AC-15.15**: All user-facing strings in **English** (hard rule). Verify with `grep -ER 'costruisci|aggiungi|imparat|spegn|accendi' 02_GIGI_APP/GIGI/ShortcutProposalCard.swift 02_GIGI_APP/GIGI/GigiActionBridge.swift` returns empty
- [ ] **AC-15.16**: Banner texts exactly: `"Planning Shortcut..."` and `"Building Shortcut..."`. Toast on register exactly: `"I learned '<title>'. Next time you say '<top alias>' I'll run it directly."`

**GATE 15.C — Semantic router enrichment (Step 1 Layer C)**:
- [ ] **AC-15.17**: `GigiSemanticRouter.reloadRegistry()` exists and loads aliases of registered Shortcuts as `SemanticEntry` with intent prefix `run_registered_shortcut:<name>`
- [ ] **AC-15.18**: `classify(_:)` matches an alias never literally said but semantically close (e.g. "accendi la torcia per favore" matches "torch on") with confidence ≥ 0.55
- [ ] **AC-15.19**: `GigiRequestRouter.route()` recognizes `run_registered_shortcut:` prefix and invokes `dispatchRegisteredShortcut(name:source:)`
- [ ] **AC-15.20**: Log line contains `[semantic+registry run_registered_shortcut <conf> '<alias>']`
- [ ] **AC-15.21**: After `GigiShortcutRegistry.deregister(name:)`, `didChangeNotification` is posted → `reloadRegistry` is called → classify NO LONGER matches the alias

**GATE 15.D — Apple FM dynamic tools (Step 1 Layer D)**:
- [ ] **AC-15.22**: `FMShortcutInvokeTool` struct exists with `name = "run_registered_shortcut"` and `description` computed property enumerating registered Shortcut names
- [ ] **AC-15.23**: `allTools` includes `FMShortcutInvokeTool()` ONLY when `GigiShortcutRegistry.allRegistered().isEmpty == false`
- [ ] **AC-15.24**: `canonicalActions` includes `"run_registered_shortcut"`
- [ ] **AC-15.25**: Saying *"il mio bedtime"* (with Shortcut "Bedtime Routine" registered + alias "bedtime"), Apple FM invokes `FMShortcutInvokeTool(shortcutName: "Bedtime Routine")`
- [ ] **AC-15.26**: Log line contains `[appleFM run_registered_shortcut 'Bedtime Routine']`

**GATE 15.E — Smart Action Loop end-to-end + Learn Phase**:
- [ ] **AC-15.27**: After tap Build success, `GigiShortcutRegistry.find(byName: title)` returns entry with `aliases.count >= 3`, `systemPurpose` populated
- [ ] **AC-15.28**: Toast after install matches exact format: `"I learned 'Quick Torch'. Next time you say 'torch on' I'll run it directly."`
- [ ] **AC-15.29**: Smart Action Loop closure: pronouncing the same trigger AGAIN after install → Step 1 matches → NO new proposal card appears, Shortcut runs directly via Tier 1 (`[tier1 run_registered_shortcut ...]` log)
- [ ] **AC-15.30**: ADR-0015 created and in state Proposed → Accepted at merge of Task 15.E
- [ ] **AC-15.31**: ADR-0014 §9 added with `Superseded API contract — see ADR-0015`

**Trasversali**:
- [ ] **AC-15.32**: Build verify: `xcodebuild` BUILD SUCCEEDED on iPhone 15 Pro+ iOS 26+
- [ ] **AC-15.33**: All user-facing strings in **English** (CLAUDE.md hard rule). Verify across new files with `grep -ER 'costruisci|aggiungi|imparat|spegn|accendi|in attesa|elaborazione' 02_GIGI_APP/GIGI/ShortcutProposalCard.swift 02_GIGI_APP/GIGI/GigiActionBridge.swift` returns empty
- [ ] **AC-15.34**: No regression: the 22 pre-existing tools + Shortcuts built pre-GATE 15 keep working
- [ ] **AC-15.35**: Legacy `composeShortcut(rawText:)` thin wrapper exists for backward compat with non-card callers (e.g. future GATE 15.5 daydream flow)

---

## 5. E2E test sul telefono (verificabili dall'utente) — 5 scenarios

**E2E-15.1 — Existing capability (no card)**:
- Pre: Shortcut "Quick Torch" already registered from previous session
- Say: *"torch on"*
- Expected: NO proposal card appears. Tier 1 dispatch direct → torch on. Log `[tier1 torch_on registered]`. Total latency <500ms.

**E2E-15.2 — New buildable (full Smart Action Loop)**:
- Pre: empty registry, no shortcut for "play music and dim lights"
- Say: *"build a shortcut to play music and dim the lights"*
- Expected (Step 2): Banner "Planning Shortcut..." appears for 3-5s → proposal card in chat with:
  - title: "Music + Dim Lights" (or similar)
  - summary: "Plays your music and dims the lights to 30%."
  - 2 numbered actions with emojis (🎵 Play music, 🏠 Dim lights to 30%)
  - "Build Shortcut" + "Cancel" CTAs
- Tap **Build Shortcut** (Step 3): Banner "Building Shortcut..." for 8-15s → share sheet → Add to Shortcuts
- Expected (Step 4): toast `"I learned 'Music + Dim Lights'. Next time you say 'music and dim' I'll run it directly."`. Registry contains entry with aliases≥3.
- Continuation (Step 5): Say *"play music and dim the lights"* again → Step 1 Layer C matches → Tier 1 dispatch (no new card). Log `[semantic+registry run_registered_shortcut 0.7X 'play music and dim']`.

**E2E-15.3 — Cancel mid-plan**:
- Pre: empty registry
- Say: *"build a shortcut that opens YouTube and plays jazz"*
- Expected: Banner "Planning Shortcut..." → proposal card appears
- Tap **Cancel**: card disappears from chat. Registry NOT modified. No `/build` request in network log.
- After 6 min, server `plans` Map auto-prunes the orphan planId (verify via harness logs).

**E2E-15.4 — Plan expiry**:
- Pre: empty registry
- Say: *"build a shortcut to set a 5 minute timer and call mom"*
- Expected: card appears
- Wait 6 minutes (with phone unlocked, app foreground)
- Tap **Build Shortcut**
- Expected: toast `"Plan expired. Ask me again to start over."`. No share sheet. Registry untouched.

**E2E-15.5 — Auto-learn closure (Step 5)**:
- Pre: E2E-15.2 completed successfully (Shortcut "Music + Dim Lights" registered)
- Say a phrasing NOT in the explicit aliases but semantically close: *"can you start the music and dim my lights"*
- Expected: Step 1 Layer C catches it. Confidence ≥0.55. NO new proposal card. Tier 1 dispatch.
- Log `[semantic+registry run_registered_shortcut 0.6X 'start the music and dim my lights']`.

**E2E-15.6 (regression)** — pronunciare i 3 comandi base pre-GATE 15: *"set timer 5 minutes"*, *"call Marco"*, *"weather"*. All work as pre-GATE 15 (no regression Apple FM).

---

## 6. Test post-creazione (verifica autonoma)

### 6.1 Verifica via grep (filesystem checks)

```bash
ROOT="C:/Users/arman/Desktop/PROGETTI VIBE CODING/GIGI FOLDER/GIGI-work/Armando-Rework/02_GIGI_APP/GIGI"
HARNESS="C:/Users/arman/Desktop/PROGETTI VIBE CODING/GIGI FOLDER/GIGI-work/Armando-Rework/03_HARNESS/server/api"

# 1. Backend split — plans Map + 3 handlers
grep -E "handlePlan|handleBuild|plans = new Map" "$HARNESS/ios-build-shortcut.js" | wc -l
# Expected: >= 3

# 2. Backend router — 3 routes
grep -E "compose-shortcut/plan|compose-shortcut/build|compose-shortcut/job" "$HARNESS/ios-router.js" | wc -l
# Expected: >= 3

# 3. iOS bridge split
grep -E "func proposeShortcut|func buildShortcutFromPlan|func cancelShortcutPlan" "$ROOT/GigiActionBridge.swift" | wc -l
# Expected: 3

# 4. iOS client new methods
grep -E "postPlanShortcut|postBuildShortcutFromPlan" "$ROOT/GigiHarnessClient+Streams.swift" | wc -l
# Expected: 2

# 5. Proposal card view file exists
test -f "$ROOT/ShortcutProposalCard.swift" && echo "OK" || echo "MISSING"
grep -E "Build Shortcut|Cancel" "$ROOT/ShortcutProposalCard.swift" | wc -l
# Expected: >= 2

# 6. ChatView renders shortcutProposal case
grep "shortcutProposal" "$ROOT/ChatView.swift"
# Expected: >= 1 match

# 7. Semantic router dynamicCatalog (Step 1 Layer C)
grep -E "dynamicCatalog|reloadRegistry" "$ROOT/GigiSemanticRouter.swift" | wc -l
# Expected: >= 3

# 8. RequestRouter virtual intent
grep "run_registered_shortcut:" "$ROOT/GigiRequestRouter.swift"
# Expected: >= 1 match

# 9. Apple FM dynamic tool (Step 1 Layer D)
grep "struct FMShortcutInvokeTool" "$ROOT/GigiFoundationToolRegistry.swift"
# Expected: 1 match

# 10. Registry change notification
grep "didChangeNotification" "$ROOT/GigiShortcutRegistry.swift"
# Expected: >= 1 match

# 11. ENGLISH-ONLY guard
grep -ER 'costruisci|aggiungi|imparat|spegn|accendi|in attesa|elaborazione' \
    "$ROOT/ShortcutProposalCard.swift" \
    "$ROOT/GigiActionBridge.swift" | wc -l
# Expected: 0

# 12. ADR present
test -f "C:/Users/arman/Desktop/PROGETTI VIBE CODING/GIGI FOLDER/GIGI-work/Armando-Rework/docs/adr/0015-smart-action-loop.md" && echo "OK" || echo "MISSING"

# 13. ADR-0014 references ADR-0015
grep "ADR-0015" "C:/Users/arman/Desktop/PROGETTI VIBE CODING/GIGI FOLDER/GIGI-work/Armando-Rework/docs/adr/0014-ai-shortcut-authoring-pipeline.md"
# Expected: >= 1
```

### 6.2 Verifica via xcodebuild

```bash
ssh user297422@FF125.macincloud.com "cd ~/GIGI-armando-rework/02_GIGI_APP && /usr/bin/xcodebuild -project GIGI.xcodeproj -scheme GIGI -destination 'generic/platform=iOS' build 2>&1 | grep -E 'BUILD SUCCEEDED|error:'"
# Expected: BUILD SUCCEEDED, 0 error
```

### 6.3 Verifica runtime (Console.app)

After installing IPA with GATE 15 and running E2E-15.2:

```
[propose] plan='plan-abc-123' title='Music + Dim Lights' aliases=7
[chat] appended .shortcutProposal(plan-abc-123)
[build] kickoff planId='plan-abc-123' jobId='job-xyz-789'
[job ready] url='https://<tunnel>/static/shortcut/xyz.shortcut' size=22341B
[registry] registered 'Music + Dim Lights' with 7 aliases, purpose=play_music
[semantic] reloaded registry: 1 shortcuts, 7 alias entries
[semantic+registry run_registered_shortcut 0.78 'start the music and dim my lights']  ← E2E-15.5
[appleFM run_registered_shortcut 'Bedtime Routine']  ← if Layer D triggered
```

### 6.4 Verifica behavioral mesi dopo

Re-execute annually:
1. Plan a new Shortcut via spoken request → verify proposal card appears with all required fields
2. Tap Build → verify install + auto-register + closure log
3. Tap Cancel on a card → verify no registry mutation + planId evaporates after 5 min on server
4. Wait >5 min then Build → verify 410 Gone + "Plan expired" toast

---

## 7. Rollback plan

Per sub-gate:

```bash
cd "C:/Users/arman/Desktop/PROGETTI VIBE CODING/GIGI FOLDER/GIGI-work/Armando-Rework"
# Revert one sub-gate (e.g. only Step 1 Layer D Apple FM dynamic tool)
git revert <SHA-15.D-apple-fm-tool>
# Or full GATE revert
git revert <SHA-15.A>..<SHA-15.E>
```

**Feature flags** (preferable over hard revert):
- `gigi.feature.smart_action_loop.plan_build_split` default `true` — toggle off → frontend falls back to legacy `composeShortcut` (`/start` endpoint)
- `gigi.feature.smart_action_loop.semantic_enrichment` default `true` — toggle off → `reloadRegistry()` no-op
- `gigi.feature.smart_action_loop.fm_dynamic_tool` default `true` — toggle off → `FMShortcutInvokeTool` excluded from `allTools`

**Side effects on rollback**:
- `GigiShortcutRegistry` entries already written persist (innocuous)
- Server `plans` Map is in-memory, evaporates on restart
- Apple FM context budget loses ~50-100 tokens when `FMShortcutInvokeTool` description is removed

**Backward compat**: legacy `composeShortcut(rawText:)` is preserved as a thin wrapper around `proposeShortcut` so any existing call site keeps compiling. Future GATE 15.5 (Daydream) can call `proposeShortcut` directly without UI by passing a flag (planned design, not part of GATE 15 scope).

---

## 8. Files modificati / creati

| Path | Operazione | Step | Righe stimate |
|---|---|---|---|
| `03_HARNESS/server/api/ios-build-shortcut.js` | MODIFY (split plan/build, plans Map TTL) | 2+3 | +120 |
| `03_HARNESS/server/api/ios-router.js` | MODIFY (3 routes instead of 2) | 2+3 | +6 |
| `02_GIGI_APP/GIGI/GigiHarnessClient+Streams.swift` | MODIFY (+`postPlanShortcut` + `postBuildShortcutFromPlan`) | 2+3 | +25 |
| `02_GIGI_APP/GIGI/GigiActionBridge.swift` | MODIFY (split propose/build/cancel + Learn) | 2+3+4 | +50 |
| `02_GIGI_APP/GIGI/ShortcutProposalCard.swift` | CREATE | 2 | ~120 |
| `02_GIGI_APP/GIGI/ChatView.swift` | MODIFY (render `.shortcutProposal` case) | 2 | +30 |
| `02_GIGI_APP/GIGI/GigiSemanticRouter.swift` | MODIFY (dynamicCatalog + reloadRegistry) | 1C | +60 |
| `02_GIGI_APP/GIGI/GigiRequestRouter.swift` | MODIFY (virtual intent + dispatchRegisteredShortcut) | 1C | +30 |
| `02_GIGI_APP/GIGI/GigiFoundationToolRegistry.swift` | MODIFY (+`FMShortcutInvokeTool` + guard) | 1D | +50 |
| `02_GIGI_APP/GIGI/GigiActionDispatcher+Native.swift` | MODIFY (+handler) | 1D | +20 |
| `02_GIGI_APP/GIGI/GigiShortcutRegistry.swift` | MODIFY (didChangeNotification) | 1C | +15 |
| `docs/adr/0015-smart-action-loop.md` | CREATE | — | ~180 |
| `docs/adr/0014-ai-shortcut-authoring-pipeline.md` | MODIFY (add §9) | — | +15 |
| `docs/research/gate-15-smart-action-loop-e2e.md` | CREATE (E2E results) | — | ~80 |

---

## 9. ADR collegati

- **ADR-0014** (AI Shortcut Authoring Pipeline) — pipeline cherri+HubSign unchanged. GATE 15 splits the API surface in front of it (plan/build/job) and adds the UX layer above it (card → confirm → auto-register). New §9 added pointing to ADR-0015.
- **ADR-0015** (NEW, created in Task 15.E.1) — *"Smart Action Loop — Plan/Confirm/Build/Learn"*. Documents the 5-step decision tree, the plan/build endpoint split rationale, TTL choice (5 min), proposal card UX, and Step 5 closure semantics. Status: Proposed → Accepted at merge of Task 15.E.
- **ADR-0012** (Smart Router semantic fast-path) — reference for `GigiSemanticRouter` stable APIs. GATE 15 extends `dynamicCatalog` without modifying `staticCatalog` (no regression on the 22 baseline tools).
- **ADR-0008** (Apple FM Tool calling vs scored registry) — reference for `Tool` struct + `@Generable Arguments` pattern. `FMShortcutInvokeTool` is the first Tool with a dynamic `description` computed property.

---

## 10. Note operative

- **Ordine implementazione OBBLIGATORIO**: Task 15.A (backend split) → 15.B (frontend card + bridge split) → 15.C (semantic enrichment) → 15.D (Apple FM dynamic tool) → 15.E (ADR + E2E). 15.A is blocking for 15.B (frontend needs new endpoint to call). 15.C and 15.D are independent but both depend on 15.B (registry must auto-populate from Learn Phase before they have anything to enrich). 15.E is documentation + final test pass.

- **Conventional Commits suggeriti**:
  ```
  feat(harness): GATE 15.A — split compose-shortcut into plan/build/job endpoints
  feat(ios): GATE 15.B — Smart Action Loop proposal card + bridge split
  feat(ios): GATE 15.C — semantic router dynamicCatalog from registered shortcuts
  feat(ios): GATE 15.D — FMShortcutInvokeTool dynamic Apple FM tool
  docs(adr): GATE 15.E — accept ADR-0015 Smart Action Loop
  docs(taskplan): GATE 15 closed — Smart Action Loop live
  ```

- **Branch suggerito**: `feat/gate-15-smart-action-loop` (single branch for 5 sub-gate).

- **Test on physical device MANDATORY** per:
  - 15.B card UX: simulator does not respect AEA1 install correctly
  - 15.C: NLEmbedding precision varies sim vs device
  - 15.D: Apple FM available only on iPhone 15 Pro+ with Apple Intelligence on

- **Decisione Q-15.1 (merge Task 15.C)**: confirm threshold `confidence >= 0.55`. Default conservative: 0.55. If telemetry shows too many false positives, raise to 0.60 with gap ≥0.08.

- **Decisione Q-15.2 (merge Task 15.A)**: confirm `GIGI_PLAN_TTL_MS = 300000` (5 min). Rationale: planning Claude call ~3-5s, user reading + reflection ~2-3 min, 5 min is safe margin. Override via env for stress test.

- **🌍 Language compliance HARD RULE**: ALL user-facing strings in **English**. New strings introduced by GATE 15:
  - `"Build Shortcut"` (button)
  - `"Cancel"` (button)
  - `"Planning Shortcut..."` (banner)
  - `"Building Shortcut..."` (banner)
  - `"I learned '<title>'. Next time you say '<top alias>' I'll run it directly."` (toast)
  - `"Plan expired. Ask me again to start over."` (toast)
  - `"Couldn't plan the shortcut: <err>"` (toast)
  - `"Couldn't run '<name>'."` / `"Running '<name>'."` (fallback)
  - `"I don't have a Shortcut called '<name>' registered."` (FM tool response)

- **Context budget Apple FM**: `FMShortcutInvokeTool.description` grows O(N) with registered Shortcut count. Mitigation for N > 20: emit only 10 most-recently-used (sort by `recordUse` timestamp). Document in ADR-0015 §7 "Scaling".

- **Privacy**: server `plans` Map holds raw user `prompt` for 5 min in memory. Documented in ADR-0015 §8 "Privacy".

- **Discord notify** (subagent `timeline-poster`):
  - `🎉 GATE 15.A merged — server now splits compose into /plan + /build + /job`
  - `🎉 GATE 15.B merged — proposal cards in chat with Build / Cancel CTAs`
  - `🎉 GATE 15.C merged — semantic router auto-recognizes user shortcuts`
  - `🎉 GATE 15.D merged — Apple FM dynamic tool for context-aware shortcut invoke`
  - `🏆 GATE 15 COMPLETE — Smart Action Loop live (Plan / Confirm / Build / Learn / Recognize)`

### Cosa fare se planner output is malformed JSON

The Claude `/plan` call may return prose instead of pure JSON. Mitigations:
1. `stripFences(text)` helper removes markdown fences
2. Try/catch JSON.parse → return 500 with `{ok: false, error: "plan_parse_failed", raw: text.slice(0,200)}` so iOS shows informative toast
3. Log raw response for debug + open sub-issue if it happens >5% of the time
4. Consider `response_format: { type: "json_object" }` if Claude SDK supports it for deterministic structured output

### Cosa fare se user taps Build but network drops

`/build` returns 200 but `/job` polling times out. Current `pollJob` already has 30s timeout. On timeout:
- Show toast `"Build is taking longer than expected. Try again in a moment."`
- Plan has already been consumed server-side (cannot retry with same planId)
- User must restart from utterance (`proposeShortcut`)

### Cosa fare se user has 0 Shortcut registered when Apple FM call happens

`FMShortcutInvokeTool` is excluded from `allTools` via `isEmpty` guard. Apple FM doesn't even see it. No 0-result confusion.

### Loop chiusura "matrioska" — Step 4 → Step 5 → Step 1

The magic moment of GATE 15: user says X → proposal card → tap Build → install → next time user says X (or variant) → Step 1 matches without re-asking. This is the **closing of the loop** of the user-driven assistant. AC-15.29 is the most important AC of the GATE.

### Relation to GATE 15.5 (Daydream)

GATE 15.5 is a separate, post-MVP plan (`GATE-15.5-daydream-predictive-shortcuts.md`). It calls the same `proposeShortcut` API but with proactive triggers (from harness watcher analyzing usage history + calendar) instead of reactive user utterance. GATE 15 must be COMPLETED + soak-tested 1 week before GATE 15.5 starts.
