# GATE 15.5 — Daydream: Predictive Shortcuts

> **Status**: 📋 PLANNED — **defer post-MVP**
> **Effort stimato**: ~6-8h
> **Bloccanti pre-gate**:
>   - GATE 15 COMPLETED (Smart Action Loop live, including `proposeShortcut` callable without UI)
>   - ≥1 week soak test of GATE 15 on the device with real user traffic (no critical bugs reported)
>   - MVP shipped (v0.1.0 OSS public)
> **Sblocca**: GIGI evolves from **reactive** (waits for user utterance) to **predictive** (suggests Shortcuts before being asked). Closes the "ambient assistant" promise of the master plan §6 Week 5+.
> **Funzione consegnata (1 frase)**: every N hours (default 6h) the harness asks Claude *"given this user's recent dispatch history + calendar context, are there Shortcuts that would save them time?"* — Claude returns a list of plan proposals, harness pushes APNS, iOS shows them in a **Daydream Inbox** pill in chat. User can tap to review → Build (Smart Action Loop Step 3+4) or Dismiss.

---

## 1. Obiettivo — predictive vs reactive

GATE 15 Smart Action Loop is **reactive**: the user says something → GIGI matches or proposes a build. The user must initiate.

GATE 15.5 is **predictive**: GIGI itself initiates a proposal based on **observed patterns + upcoming context**.

Difference from the old "Layer 4 pattern detection" (removed from GATE 15):
| Aspect | Old Layer 4 (removed) | New Daydream (GATE 15.5) |
|---|---|---|
| Trigger | repetition threshold (≥3 same intent in 7 days) | proactive Claude analysis of full context every N hours |
| Action | interrupts user with TTS *"want me to build…"* | silent: deposits into Daydream Inbox, surfaces a pill |
| Privacy | on-device, no LLM cost | server-side Claude call with intent-label-only payload |
| User burden | forced yes/no in 8s | user opens inbox at their own pace |

The flow:

```
[every N hours, harness watcher]
   ↓
Claude analyses {last 7d dispatches as intent labels, next 24h calendar events}
   ↓
returns [proposalPlan_1, proposalPlan_2, ...]  (each is a Smart Action Loop plan)
   ↓
harness saves to daydream-queue.json (per-user)
   ↓
APNS push: "GIGI prepared N shortcut suggestions for you"
   ↓
[user opens iOS app]
   ↓
DaydreamInboxView pill in chat top-bar (count badge)
   ↓
tap → list of proposal cards (same ShortcutProposalCard from GATE 15)
   ↓
user taps Build on one → GATE 15 Step 3+4 (build + install + Learn)
   ↓
or taps Dismiss → marked seen + 30-day cooldown on same intent pattern
```

Privacy guarantee: **prompt to Claude contains ONLY intent labels + calendar event titles when user has explicitly opted in to share titles**. Raw speech text is NEVER sent. User can opt out fully via Settings switch `gigi.daydream.enabled` (default OFF).

---

## 2. Pre-condizioni

- [ ] GATE 15 COMPLETED with all 35 AC passing
- [ ] GATE 15 deployed and soak-tested ≥7 days on the user device — no rollback, no critical bug ledger entries
- [ ] `GigiUsagePatterns.swift` exists OR is created here (small ring buffer of intent labels + timestamps; ~150 lines). Note: this was originally in GATE 15 old plan, lives here now.
- [ ] `GigiActionBridge.proposeShortcut(rawText:)` exists and is callable with arbitrary text (verified at GATE 15.B.3)
- [ ] `ShortcutProposalCard` view exists and is renderable outside ChatView (refactor in 15.5.A if needed)
- [ ] Harness `watchers.json` infrastructure exists (recurring jobs runner) — see `03_HARNESS/CLAUDE.md` "Regola: loop → watcher"
- [ ] APNS push notification pipeline already functional (used elsewhere in GIGI for HITL prompts)
- [ ] MVP shipped → user is in real-world usage so dispatch history is meaningful
- [ ] Decisione PM Q-15.5.1: confirm default cadence (proposed: 6 hours). Decisione al merge Task 15.5.A.
- [ ] Decisione PM Q-15.5.2: confirm calendar opt-in policy. Two levels: (a) "use only event count + free/busy" or (b) "include event titles". Default: (a). Decisione al merge Task 15.5.A.
- [ ] Decisione PM Q-15.5.3: confirm dismiss cooldown (proposed: 30 days). Decisione al merge Task 15.5.C.

---

## 3. Task implementativi

### Task 15.5.A — Harness Daydream watcher + queue (~2-3h)

**File creati / modificati**:
- `03_HARNESS/server/watchers/daydream.js` CREATE — recurring job loop
- `03_HARNESS/server/watchers.json` MODIFY — register `daydream` watcher with interval (env-configurable)
- `03_HARNESS/server/api/ios-daydream.js` CREATE — REST endpoints `/inbox`, `/dismiss`, `/build/:planId`, `/sync-usage`
- `03_HARNESS/server/api/ios-router.js` MODIFY — wire the 4 routes
- `03_HARNESS/server/storage/daydream-queue.json` (auto-created at first watcher run)

**Watcher pseudo-flow** (`daydream.js`):

```javascript
import { callClaude } from "../llm/claude-client.js";
import { loadUsageSnapshot, loadCalendarSnapshot, saveQueue, loadQueue } from "./daydream-storage.js";
import { pushAPNS } from "../apns.js";

export async function runDaydreamCycle() {
  const enabled = await loadUserPref("gigi.daydream.enabled");
  if (!enabled) return { skipped: true };

  const usage = await loadUsageSnapshot(); // { intentCounts: {...}, last7DaysEvents: [...] }
  const calendar = await loadCalendarSnapshot(); // { next24hEvents: [...] }

  const prompt = buildPredictivePrompt(usage, calendar);
  const claudeResp = await callClaude({ prompt, maxTokens: 1500 });
  const proposals = parseProposals(claudeResp); // [{ title, summary, actions, aliases, systemPurpose }]

  if (proposals.length === 0) return { proposalCount: 0 };

  const queue = await loadQueue();
  for (const p of proposals) {
    if (isCooldownActive(queue, p.systemPurpose)) continue;
    const planId = `daydream-${crypto.randomUUID()}`;
    queue.push({ planId, ...p, createdAt: Date.now(), dismissed: false, seen: false });
  }
  await saveQueue(queue);

  const unseen = queue.filter(q => !q.seen && !q.dismissed).length;
  if (unseen > 0) {
    await pushAPNS({
      title: "GIGI Suggestions",
      body: `GIGI prepared ${unseen} shortcut suggestion${unseen === 1 ? "" : "s"} for you`,
      payload: { daydreamCount: unseen },
    });
  }
  return { proposalCount: proposals.length };
}
```

**Predictive prompt skeleton**:

```
You are GIGI's daydream planner. The user has a personal assistant that can build iOS Shortcuts.
Given the user's recent activity, suggest 0-3 Shortcuts that would save them time. 
ONLY suggest if a clear pattern emerges OR the calendar shows context where automation helps.

USER ACTIVITY (last 7 days, intent labels only — no raw speech):
{ intentCounts: { "torch_on": 12, "set_timer": 8, "play_music": 6, ... },
  sequencePatterns: [["torch_on", "wait", "torch_off"] (8 times)] }

UPCOMING CALENDAR (next 24h, opt-in level: count only / count+titles):
{ next24hEvents: 3, types: ["work_meeting", "personal"] }

For each suggested Shortcut, return:
{ title: string, summary: string (1 sentence), actions: PlanAction[], aliases: string[], systemPurpose: string }

PlanAction = { action: string, displayLabel: string (1-3 words), category: enum }

Respond with ONLY a valid JSON array. No prose, no markdown fences.
If no suggestions are warranted, return [].
```

**API endpoints** (`ios-daydream.js`):

| Method | Path | Behavior |
|---|---|---|
| `GET` | `/api/ios/daydream/inbox` | Returns `{ items: [{ planId, title, summary, actions, aliases, systemPurpose, createdAt, seen }] }` for all unseen+undismissed |
| `POST` | `/api/ios/daydream/dismiss` body `{planId}` | Marks item dismissed, starts 30-day cooldown on `systemPurpose` |
| `POST` | `/api/ios/daydream/build/:planId` | Promotes a daydream plan into the regular `plans` Map (from GATE 15.A) and returns `{ ok, jobId }` — kicks off cherri+sign |
| `POST` | `/api/ios/daydream/sync-usage` body `{ intents: [...], calendar?: [...] }` | iOS pushes anonymized intent/calendar snapshots (called periodically by iOS background task) |

**Watcher registration** (`watchers.json`):

```json
{
  "daydream": {
    "module": "watchers/daydream.js",
    "intervalMs": 21600000,
    "comment": "6 hours default; env GIGI_DAYDREAM_INTERVAL_MS override"
  }
}
```

**Sub-task atomici**:
- 15.5.A.1 — Scaffold `daydream.js` watcher module + storage helpers (`daydream-storage.js`) backed by `daydream-queue.json` (45min)
- 15.5.A.2 — Implement `buildPredictivePrompt` + JSON parsing + cooldown detection (45min)
- 15.5.A.3 — Implement 4 REST endpoints in `ios-daydream.js` (45min)
- 15.5.A.4 — Wire watcher in `watchers.json` + verify it runs every 6h via local harness logs (15min)
- 15.5.A.5 — APNS push integration: payload `{ daydreamCount }` so iOS shows badge (15min)

### Task 15.5.B — iOS sync-usage background sender + Daydream pill UI (~2-3h)

**File creati / modificati**:
- `02_GIGI_APP/GIGI/GigiUsagePatterns.swift` CREATE OR extend — ring buffer of recent intents (no raw speech) + serializer for sync-usage payload
- `02_GIGI_APP/GIGI/GigiDaydreamSync.swift` CREATE — BGAppRefreshTask that calls `/api/ios/daydream/sync-usage` and `/api/ios/daydream/inbox` periodically
- `02_GIGI_APP/GIGI/DaydreamInboxView.swift` CREATE — chat top-bar pill + sheet with list of proposal cards
- `02_GIGI_APP/GIGI/ChatView.swift` MODIFY — host the pill
- `02_GIGI_APP/GIGI/SettingsView.swift` MODIFY — toggle `gigi.daydream.enabled` + calendar opt-in radio (count-only / titles)
- `02_GIGI_APP/GIGI/GigiActionBridge.swift` MODIFY — `buildShortcutFromDaydreamPlan(planId:)` calls `/api/ios/daydream/build/:planId` then polls `/job/:jobId` then auto-register (Learn Phase, identical to GATE 15)

**Pattern Swift `DaydreamInboxView.swift`**:

```swift
@available(iOS 16.0, *)
struct DaydreamInboxView: View {
    @StateObject var store = DaydreamInboxStore.shared

    var body: some View {
        if store.items.isEmpty {
            EmptyView()
        } else {
            Button(action: { store.isPresentingSheet = true }) {
                HStack(spacing: 6) {
                    Image(systemName: "sparkles")
                    Text("\(store.items.count) GIGI Suggestion\(store.items.count == 1 ? "" : "s")")
                        .font(.subheadline.weight(.medium))
                }
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(Capsule().fill(.tint.opacity(0.15)))
            }
            .sheet(isPresented: $store.isPresentingSheet) {
                DaydreamInboxSheet()
            }
        }
    }
}

struct DaydreamInboxSheet: View {
    @StateObject var store = DaydreamInboxStore.shared
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    ForEach(store.items) { item in
                        ShortcutProposalCard(
                            plan: item.toPlanResponse(),
                            onBuild: {
                                Task { await GigiActionBridge.shared.buildShortcutFromDaydreamPlan(planId: item.planId, plan: item.toPlanResponse()) }
                                store.markBuilding(planId: item.planId)
                            },
                            onCancel: {
                                Task { await store.dismiss(planId: item.planId) }
                            }
                        )
                    }
                }.padding()
            }
            .navigationTitle("GIGI Suggestions")
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { store.isPresentingSheet = false } } }
        }
    }
}
```

**Settings switch + privacy radio**:

```swift
Section("GIGI Suggestions (beta)") {
    Toggle("Allow GIGI to suggest proactively", isOn: $daydreamEnabled)
    if daydreamEnabled {
        Picker("Calendar context shared", selection: $calendarOptInLevel) {
            Text("Count only (private)").tag(0)
            Text("Include event titles").tag(1)
        }
        Text("GIGI never sees raw speech text. Only intent labels are sent.")
            .font(.caption).foregroundStyle(.secondary)
    }
}
```

**Sub-task atomici**:
- 15.5.B.1 — Create / extend `GigiUsagePatterns.swift` with ring buffer (max 200 events) + serializer that returns ONLY {intent label, timestamp, dispatch tier} — never speech text (30min)
- 15.5.B.2 — Create `GigiDaydreamSync.swift` background task: every 1h foreground OR BGAppRefreshTask in background, POST `/sync-usage` + GET `/inbox` (45min)
- 15.5.B.3 — Create `DaydreamInboxView.swift` pill + sheet (45min)
- 15.5.B.4 — Wire pill in `ChatView` top-bar with count badge (15min)
- 15.5.B.5 — Add Settings section with toggle + calendar opt-in radio (30min)
- 15.5.B.6 — Add `buildShortcutFromDaydreamPlan` in `GigiActionBridge` reusing GATE 15 Learn Phase (15min)
- 15.5.B.7 — Build verify + visual check on device (15min)

### Task 15.5.C — Dismiss cooldown + privacy guard tests (~1-2h)

**File modificati**:
- `03_HARNESS/server/watchers/daydream.js` — implement `isCooldownActive` (30-day window per `systemPurpose`)
- `02_GIGI_APP/GIGI/DaydreamInboxStore.swift` — local persisted state of seen/dismissed
- `docs/adr/0016-daydream-predictive-shortcuts.md` CREATE
- `docs/PRIVACY.md` MODIFY — add §"Daydream telemetry" section listing exactly what is sent

**Sub-task atomici**:
- 15.5.C.1 — Implement 30-day cooldown in watcher per `systemPurpose` (15min)
- 15.5.C.2 — Implement local `seen`/`dismissed` state + sync to harness on dismiss (30min)
- 15.5.C.3 — Privacy audit: grep harness server logs for any `rawText` or `speech` field — must be 0 (15min)
- 15.5.C.4 — Draft `docs/adr/0016-daydream-predictive-shortcuts.md` (45min)
- 15.5.C.5 — Update `docs/PRIVACY.md` with explicit table of telemetry sent in daydream mode (15min)

---

## 4. Acceptance Criteria

**GATE 15.5.A — Watcher + queue**:
- [ ] **AC-15.5.1**: `watchers/daydream.js` exists and is registered in `watchers.json` with `intervalMs: 21600000` (6h default)
- [ ] **AC-15.5.2**: Watcher reads `gigi.daydream.enabled` user pref — if false, exits early returning `{ skipped: true }`
- [ ] **AC-15.5.3**: When enabled and usage data exists, watcher calls Claude with intent-label-only prompt (verify with logged prompt: 0 occurrences of raw `speech` field)
- [ ] **AC-15.5.4**: Claude returns proposals → saved to `daydream-queue.json` with `planId`, `createdAt`, `dismissed: false`, `seen: false`
- [ ] **AC-15.5.5**: APNS push sent only when `unseen > 0` count of items in queue
- [ ] **AC-15.5.6**: `GET /api/ios/daydream/inbox` returns array of pending items
- [ ] **AC-15.5.7**: `POST /api/ios/daydream/build/:planId` promotes daydream plan into regular `plans` Map (GATE 15.A) and returns `{ ok, jobId }`

**GATE 15.5.B — iOS UI + sync**:
- [ ] **AC-15.5.8**: With Settings switch OFF (default), no `/sync-usage` POST is ever sent, no daydream pill ever appears
- [ ] **AC-15.5.9**: With switch ON, after ≥1 valid daydream cycle, `DaydreamInboxView` pill appears in ChatView top-bar with item count badge
- [ ] **AC-15.5.10**: Tap pill → sheet opens showing list of `ShortcutProposalCard` (reused from GATE 15)
- [ ] **AC-15.5.11**: Tap Build on a card → GATE 15 Step 3+4 flow (build + install + Learn Phase auto-register) — identical to reactive flow
- [ ] **AC-15.5.12**: Tap Cancel on a card → `POST /dismiss` called → card removed from sheet → 30-day cooldown active
- [ ] **AC-15.5.13**: After tap Build success, the original Inbox item is also marked dismissed (no duplicate suggestion)
- [ ] **AC-15.5.14**: Calendar opt-in radio: at level "count only" the payload to `/sync-usage` contains only `{ next24hEventCount: N }`, no titles
- [ ] **AC-15.5.15**: Calendar opt-in at level "include titles" sends event titles to harness

**GATE 15.5.C — Privacy + cooldown**:
- [ ] **AC-15.5.16**: `isCooldownActive(queue, systemPurpose)` returns true for 30 days after dismiss → prevents same `systemPurpose` from being re-proposed
- [ ] **AC-15.5.17**: Harness logs across one watcher cycle contain 0 occurrences of raw user speech (verify via `grep -i "speech\|rawtext" harness.log` returns 0 lines from daydream module)
- [ ] **AC-15.5.18**: ADR-0016 created with Proposed → Accepted at merge
- [ ] **AC-15.5.19**: `docs/PRIVACY.md` updated with daydream telemetry table

**Trasversali**:
- [ ] **AC-15.5.20**: All user-facing strings in **English**: pill `"N GIGI Suggestion"`, sheet title `"GIGI Suggestions"`, Settings header `"GIGI Suggestions (beta)"`, push body `"GIGI prepared N shortcut suggestion(s) for you"`, privacy hint `"GIGI never sees raw speech text. Only intent labels are sent."`
- [ ] **AC-15.5.21**: No regression on GATE 15 reactive flow (E2E-15.2 still passes)
- [ ] **AC-15.5.22**: Build verify: `xcodebuild` BUILD SUCCEEDED

---

## 5. E2E test sul telefono

**E2E-15.5.1 (default off — silent)**:
- Pre: fresh install, switch OFF
- Wait 24h with normal usage
- Expected: no pill ever appears in ChatView, no APNS notification, no `/sync-usage` POST in harness logs

**E2E-15.5.2 (enable + first suggestion)**:
- Settings → "Allow GIGI to suggest proactively" → ON, calendar level "count only"
- Use GIGI for 3 days normally (mix of intents: torch, timer, music)
- Expected: within 1-2 daydream cycles (6-12h), an APNS notification appears `"GIGI prepared 1 shortcut suggestion for you"`
- Open app → pill `"1 GIGI Suggestion"` visible in ChatView top
- Tap pill → sheet shows one proposal card, e.g. *"Bedtime Routine"* with summary + numbered actions

**E2E-15.5.3 (build from daydream)**:
- From E2E-15.5.2 sheet, tap **Build Shortcut** on the card
- Expected: banner "Building Shortcut..." → share sheet → Add to Shortcuts → toast `"I learned 'Bedtime Routine'. Next time you say 'bedtime' I'll run it directly."`
- Sheet closes the consumed card

**E2E-15.5.4 (dismiss + cooldown)**:
- In sheet, swipe-tap **Cancel** on a card
- Expected: card removed. After 6h next watcher cycle, the same `systemPurpose` is NOT re-proposed (cooldown active)
- Verify: in `daydream-queue.json` the dismissed entry has `dismissed: true, dismissedAt: <ts>`

**E2E-15.5.5 (calendar opt-in)**:
- Toggle calendar level to "include titles"
- Watch next daydream cycle
- Inspect harness log for the prompt sent to Claude: it should contain event titles (e.g., `"team standup"`) NOT `"event 1"` placeholders

**E2E-15.5.6 (privacy guard)**:
- With switch ON for 7 days
- Inspect entire harness log for the daydream module: `grep -i "speech\|rawtext" daydream.log`
- Expected: 0 results

---

## 6. Test post-creazione

```bash
ROOT="C:/Users/arman/Desktop/PROGETTI VIBE CODING/GIGI FOLDER/GIGI-work/Armando-Rework"

# Files exist
test -f "$ROOT/03_HARNESS/server/watchers/daydream.js" && echo "OK"
test -f "$ROOT/03_HARNESS/server/api/ios-daydream.js" && echo "OK"
test -f "$ROOT/02_GIGI_APP/GIGI/DaydreamInboxView.swift" && echo "OK"
test -f "$ROOT/02_GIGI_APP/GIGI/GigiDaydreamSync.swift" && echo "OK"
test -f "$ROOT/docs/adr/0016-daydream-predictive-shortcuts.md" && echo "OK"

# Watcher registered
grep '"daydream"' "$ROOT/03_HARNESS/server/watchers.json"

# Privacy guard
grep -ER "speech|rawText" "$ROOT/03_HARNESS/server/watchers/daydream.js" | wc -l
# Expected: 0 (or only in privacy comments / negative assertions)

# Settings switch
grep "gigi.daydream.enabled" "$ROOT/02_GIGI_APP/GIGI/SettingsView.swift"
# Expected: >= 1 match

# Build verify
ssh user297422@FF125.macincloud.com "cd ~/GIGI-armando-rework/02_GIGI_APP && xcodebuild ... | grep BUILD"
```

---

## 7. Rollback plan

Feature flags:
- `gigi.feature.daydream.enabled` (global server-side off-switch) — set false on harness env → watcher skips all users regardless of per-user pref
- `gigi.daydream.enabled` user pref — already user-facing toggle

Hard revert: `git revert <SHA-15.5.A>..<SHA-15.5.C>` — backend watcher stops, iOS UI compiles harmlessly with no items.

Side effects: `daydream-queue.json` persists on disk; harmless. Can delete manually with `rm`.

---

## 8. Files modificati / creati

| Path | Operation | Sub-gate | Lines est. |
|---|---|---|---|
| `03_HARNESS/server/watchers/daydream.js` | CREATE | A | ~200 |
| `03_HARNESS/server/watchers/daydream-storage.js` | CREATE | A | ~80 |
| `03_HARNESS/server/watchers.json` | MODIFY | A | +5 |
| `03_HARNESS/server/api/ios-daydream.js` | CREATE | A | ~120 |
| `03_HARNESS/server/api/ios-router.js` | MODIFY | A | +6 |
| `03_HARNESS/server/storage/daydream-queue.json` | (auto-created at runtime) | A | — |
| `02_GIGI_APP/GIGI/GigiUsagePatterns.swift` | CREATE | B | ~150 |
| `02_GIGI_APP/GIGI/GigiDaydreamSync.swift` | CREATE | B | ~120 |
| `02_GIGI_APP/GIGI/DaydreamInboxView.swift` | CREATE | B | ~140 |
| `02_GIGI_APP/GIGI/DaydreamInboxStore.swift` | CREATE | B | ~80 |
| `02_GIGI_APP/GIGI/ChatView.swift` | MODIFY (pill placement) | B | +15 |
| `02_GIGI_APP/GIGI/SettingsView.swift` | MODIFY (switch + radio) | B | +25 |
| `02_GIGI_APP/GIGI/GigiActionBridge.swift` | MODIFY (+buildShortcutFromDaydreamPlan) | B | +20 |
| `docs/adr/0016-daydream-predictive-shortcuts.md` | CREATE | C | ~160 |
| `docs/PRIVACY.md` | MODIFY (telemetry table) | C | +30 |

---

## 9. ADR collegati

- **ADR-0015** (Smart Action Loop) — GATE 15.5 reuses the `plans` Map mechanism and `ShortcutProposalCard` UI from GATE 15. No breaking change.
- **ADR-0016** (NEW) — *"Daydream — Predictive Shortcuts"*. Documents: predictive vs reactive trade-off, privacy stance (intent-label-only by default), cooldown policy (30 days), watcher cadence (6h default), opt-in flow. Status: Proposed → Accepted at merge.
- **ADR-0014** (AI Shortcut Authoring Pipeline) — pipeline unchanged.

---

## 10. Note operative

- **Not a blocker of any other GATE.** GATE 15.5 is purely additive. Skipping it doesn't affect MVP.
- **Cannot start before GATE 15 is COMPLETED + soak-tested.** Reuses `proposeShortcut` plumbing and `ShortcutProposalCard`. If GATE 15 has UX bugs, they propagate.
- **Conventional Commits**:
  ```
  feat(harness): GATE 15.5.A — Daydream watcher + queue + APNS push
  feat(ios): GATE 15.5.B — Daydream Inbox UI + sync background task
  feat(ios): GATE 15.5.C — Daydream cooldown + privacy guard
  docs(adr): GATE 15.5 — accept ADR-0016 Daydream predictive shortcuts
  ```
- **Branch suggerito**: `feat/gate-15.5-daydream` (single branch).
- **Test su device fisico OBBLIGATORIO** per APNS reception + BGAppRefreshTask execution (simulator doesn't run background tasks reliably).
- **Privacy is the load-bearing concept**. The default-OFF posture + intent-label-only payload + explicit calendar opt-in radio are non-negotiable. Any future change that increases telemetry scope requires a new ADR.
- **🌍 Language compliance HARD RULE**: all user-facing strings in English:
  - Pill: `"<N> GIGI Suggestion(s)"`
  - Sheet title: `"GIGI Suggestions"`
  - APNS push: `"GIGI prepared N shortcut suggestions for you"`
  - Settings: `"GIGI Suggestions (beta)"`, `"Allow GIGI to suggest proactively"`, `"Calendar context shared"`, `"Count only (private)"`, `"Include event titles"`, `"GIGI never sees raw speech text. Only intent labels are sent."`
- **Telemetry table for ADR-0016 + PRIVACY.md** (exact fields sent to Claude in daydream prompt):
  | Field | Sent? | Notes |
  |---|---|---|
  | Intent labels (e.g., `torch_on`) | Yes | aggregated counts last 7d |
  | Sequence patterns | Yes | top 3 repeated sequences |
  | Calendar event count | Yes | level 0 + level 1 |
  | Calendar event titles | Only level 1 | explicit opt-in |
  | Raw user speech | **Never** | hard guard |
  | Location | **Never** | not in scope |
  | Contact data | **Never** | not in scope |
- **Future expansion (post-GATE 15.5)**: smart timing — instead of fixed 6h cadence, watcher fires when device is plugged in + Wi-Fi (low power impact). Out of scope here.
