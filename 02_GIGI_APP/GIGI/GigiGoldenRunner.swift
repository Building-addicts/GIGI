import Foundation

// MARK: - GigiGoldenRunner
//
// Item A — Router golden-set harness. On launch, IF the process env
// `GIGI_GOLDEN=1` is set, routes each golden utterance through
// `GigiRequestRouter.classify(text:)` (dry-run — no side effects), compares
// against the expected fields, writes a results JSON to the app Documents
// directory, and logs a one-line PASS/FAIL summary.
//
// Cases are EMBEDDED below (see `embeddedCases`). An optional RouterGolden.jsonl
// in the app bundle, if present, OVERRIDES the embedded set — but the Xcode
// synchronized group does not auto-bundle .jsonl, so the embedded set is the
// working source until that resource is wired explicitly.
//
// Run (simulator, over SSH):
//   xcrun simctl launch --console-pty booted com.killsiri.GIGI --setenv GIGI_GOLDEN 1
// then read:
//   $(xcrun simctl get_app_container booted com.killsiri.GIGI data)/Documents/golden-results.json
//
// A case asserts only the fields it specifies (nil = don't care). Tier labels
// shift appleFM<->fallback with FM availability, so prefer expectedPath /
// expectedTool over expectedTier.

@MainActor
enum GigiGoldenRunner {

    struct GoldenCase: Codable {
        let utterance: String
        var expectedTool: String?
        var expectedPath: String?
        var expectedTier: String?
        var expectedSlotContains: String?
        var note: String?

        init(_ utterance: String, tool: String? = nil, path: String? = nil,
             tier: String? = nil, slotContains: String? = nil, note: String? = nil) {
            self.utterance = utterance
            self.expectedTool = tool
            self.expectedPath = path
            self.expectedTier = tier
            self.expectedSlotContains = slotContains
            self.note = note
        }
    }

    struct CaseResult: Codable {
        let utterance: String
        let pass: Bool
        let gotTier: String
        let gotTool: String
        let gotPath: String?
        let gotSlot: String?
        let gotConfidence: Float
        let mismatches: [String]
        let note: String?
    }

    struct Summary: Codable {
        let total: Int
        let passed: Int
        let failed: Int
        let timestamp: Date
        let results: [CaseResult]
    }

    // MARK: - Embedded seed (Item A v1)

    static let embeddedCases: [GoldenCase] = [
        .init("what is 42 times 11", tool: "calculate_math", tier: "regex", note: "math must NOT be a memory recall"),
        .init("quanto fa 18 per 7", tool: "calculate_math", tier: "regex"),
        .init("calculate 100 divided by 4", tool: "calculate_math"),
        .init("run my morning routine", tool: "run_shortcut"),
        .init("esegui la shortcut buongiorno", tool: "run_shortcut"),
        .init("build me a shortcut that turns the flashlight on and off", tool: "build_shortcut"),
        .init("create a shortcut to text my wife when I leave work", tool: "build_shortcut"),
        .init("send a message to Marco", tool: "ask_clarification", note: "message without body -> ask for body"),
        .init("send him a message", tool: "ask_clarification", note: "unresolved contact -> ask who"),
        .init("send a message to Armando Bata and ask him if he is online", tool: "send_message", slotContains: "armando", note: "Item C regression: contact extracted; body should be 'Are you online?'"),
        .init("remind me to buy milk tomorrow", tool: "set_reminder"),
        .init("remember me to call the bank at 3pm", tool: "set_reminder", note: "NLU PREEMPT: nlu_fast make_call fires before FM/ReminderUpgrade; consolidation must let reminder win"),
        .init("ricordami di chiamare il dentista", tool: "set_reminder"),
        .init("remember that my wifi password is hunter2", tool: "remember", note: "NLU PREEMPT: substring wifi -> nlu_fast toggle_wifi before FactAssertion/FM; consolidation must let remember win"),
        .init("who is Albert Einstein", path: "delegate_local", note: "open knowledge -> local LLM"),
        .init("explain how photosynthesis works", path: "delegate_local"),
        .init("order a margherita pizza from Just Eat", tool: "world_action_propose", note: "order verb -> propose-first then cloud (legacy web_order_food retired)"),
        .init("compra le batterie AA su Amazon", tool: "world_action_propose", note: "propose-first turn 1, cloud on confirm"),
        .init("book a table for two at Sushi Zen tonight", tool: "world_action_propose", note: "propose-first turn 1, cloud on confirm"),
        .init("search the web for the latest iPhone reviews", path: "delegate_cloud", note: "FIXED 2026-05-24: was NLU make_call (substring 'phone' inside 'iphone'), NOT an FM quirk as long believed; word-boundary fix -> FM routes to delegate_cloud. Device-verified."),
        .init("turn on the flashlight", tool: "toggle_flashlight"),
        .init("set a timer for 5 minutes", tool: "set_timer"),
        .init("call mom", tool: "make_call"),
        .init("what can you do", tool: "discovery_overview", note: "capability discovery"),
        .init("take me to Roma Termini", tool: "navigate", note: "LABEL MISMATCH: NLU emits navigation, canonical/semantic/FM use navigate; consolidation must unify the label"),
        // web-search class coverage (radius measured 2026-05-23 on real FM:
        // only the "iPhone reviews" phrasing misroutes to make_call; the rest
        // route correctly, so #2 is an isolated quirk, not a broken class)
        .init("search the web for the best pizza in Rome", path: "delegate_cloud"),
        .init("look up the latest news online", path: "delegate_cloud"),
        .init("what is the latest news about AI", path: "delegate_cloud"),

        // --- NLU fast-path boundary (2026-05-24) — mapping consolidation
        // target (a): NLU substring layer vs SemanticRouter vs FM. The
        // harness now exercises the NLU deterministic fast-path (>=0.95 +
        // fastPathIntents) that sits between tier-0 and FM in process().
        // Cases marked "NLU PREEMPT" are real prod misroutes the old
        // harness masked (it skipped NLU and reported the FM result).
        .init("remind me to call mom tomorrow", tool: "set_reminder", note: "NLU PREEMPT: substring 'call' -> nlu_fast make_call before ReminderUpgrade/FM; reminder must win"),
        .init("what time is it", tool: "ask_time", note: "clean NLU fast-path"),
        .init("what is the date today", tool: "ask_date", note: "clean NLU fast-path"),
        .init("open spotify", tool: "open_app", note: "clean NLU fast-path / semantic"),
        .init("play despacito", tool: "play_music", note: "NLU/semantic music"),
        .init("facetime my brother", tool: "facetime", note: "clean NLU fast-path"),
        .init("skip this song", tool: "media_next", note: "NLU-only (no semantic catalog entry)"),
        .init("turn off the living room lights", tool: "homekit_off", note: "homekit NOT in fastPathIntents -> must reach semantic/FM, not NLU"),
        .init("flashlight off", tool: "toggle_flashlight", note: "NLU label torch_off vs canonical toggle_flashlight; semantic should catch"),
        .init("what's my battery level", tool: "get_device_battery", note: "NOT in fastPathIntents -> semantic/FM, not NLU"),

        // --- ML-territory (2026-05-24) — rule MISSES on purpose, so pre-Option-B
        // these fell to MobileBERT/MaxEnt. Used to A/B the ML removal: do they
        // still route sensibly via semantic/FM (device) / fallback (sim)?
        .init("give mom a call", tool: "make_call", note: "ML-territory + FM GAP: rule misses ('call' at end); device FM routes to delegate_local not make_call. Future: FM few-shot / rule coverage."),
        .init("put some music on", tool: "play_music", note: "rule misses ('put on' not contiguous)"),
        .init("remind me about the dentist tomorrow", tool: "set_reminder", note: "ML-territory + FM GAP: rule misses ('remind me about'); device FM routes to delegate_local not set_reminder."),
        .init("I'd love to hear some jazz", tool: "play_music", note: "ML-territory + FM GAP: rule misses (no play verb); device FM routes to delegate_local not play_music."),
    ]

    static let bodyChecks: [(String, String)] = [
        ("send a message to Armando Bata and ask him if he's online", "Are you online?"),
        ("send a message to Leo asking if he's on", "Are you on?"),
        ("text mom saying I'll be late", "I'll be late"),
        ("message Anna saying he is late", "You are late"),
    ]

    /// Launch hook — no-op unless GIGI_GOLDEN=1.
    static func runIfRequested() async {
        let viaEnv = ProcessInfo.processInfo.environment["GIGI_GOLDEN"] == "1"
        let viaArg = ProcessInfo.processInfo.arguments.contains("GIGI_GOLDEN")
            || UserDefaults.standard.bool(forKey: "GIGI_GOLDEN")
        GigiDebugLogger.log("GoldenRunner: trigger check env=\(viaEnv) arg=\(viaArg)")
        guard viaEnv || viaArg else { return }
        GigiDebugLogger.log("GoldenRunner: triggered — starting golden-set run")
        await run()
    }

    static func run() async {
        let cases = loadCases()
        var results: [CaseResult] = []
        var passed = 0

        for c in cases {
            // Reset cross-case transient state so a clarification / proposal
            // staged by one case can't leak into the next.
            GigiConversationMemory.shared.clear()
            GigiConversationMemory.shared.clearPendingClarification()
            GigiConversationMemory.shared.clearPendingWorldAction()

            let cls = await GigiRequestRouter.shared.classify(text: c.utterance)

            var mismatches: [String] = []
            if let t = c.expectedTool, t != cls.tool {
                mismatches.append("tool: expected '\(t)' got '\(cls.tool)'")
            }
            if let p = c.expectedPath, p != (cls.path ?? "") {
                mismatches.append("path: expected '\(p)' got '\(cls.path ?? "nil")'")
            }
            if let tr = c.expectedTier, tr != cls.tier {
                mismatches.append("tier: expected '\(tr)' got '\(cls.tier)'")
            }
            if let s = c.expectedSlotContains,
               !(cls.slot ?? "").lowercased().contains(s.lowercased()) {
                mismatches.append("slot: expected contains '\(s)' got '\(cls.slot ?? "nil")'")
            }

            let ok = mismatches.isEmpty
            if ok { passed += 1 }
            results.append(CaseResult(
                utterance: c.utterance, pass: ok,
                gotTier: cls.tier, gotTool: cls.tool, gotPath: cls.path,
                gotSlot: cls.slot, gotConfidence: cls.confidence,
                mismatches: mismatches, note: c.note))
            GigiDebugLogger.log("GoldenRunner: \(ok ? "PASS" : "FAIL") '\(c.utterance.prefix(56))' -> tier=\(cls.tier) tool=\(cls.tool) path=\(cls.path ?? "-") slot=\(cls.slot ?? "-")\(ok ? "" : "  [" + mismatches.joined(separator: "; ") + "]")")
        }

        // Item C — deterministic message-body composition checks. These test
        // the static body builder directly (the dispatch path is skipped in
        // dry-run, so the routing cases above can't observe the final body).
        for (utterance, expected) in bodyChecks {
            let got = GigiRequestRouter.deriveMessageBody(from: utterance)
            let ok = got == expected
            if ok { passed += 1 }
            results.append(CaseResult(
                utterance: "[body] " + utterance, pass: ok,
                gotTier: "body", gotTool: got, gotPath: nil, gotSlot: nil,
                gotConfidence: 1, mismatches: ok ? [] : ["body: expected '\(expected)' got '\(got)'"], note: nil))
            GigiDebugLogger.log("GoldenRunner: \(ok ? "PASS" : "FAIL") [body] '\(utterance.prefix(46))' -> '\(got)'")
        }

        GigiDebugLogger.log("GoldenRunner: ===== \(passed)/\(results.count) PASS (\(results.count - passed) FAIL) =====")
        write(Summary(total: results.count, passed: passed, failed: results.count - passed,
                      timestamp: Date(), results: results))
    }

    // MARK: - IO

    /// Bundle RouterGolden.jsonl overrides the embedded set when present.
    private static func loadCases() -> [GoldenCase] {
        guard let url = Bundle.main.url(forResource: "RouterGolden", withExtension: "jsonl"),
              let text = try? String(contentsOf: url, encoding: .utf8) else {
            GigiDebugLogger.log("GoldenRunner: using \(embeddedCases.count) embedded cases (no bundle RouterGolden.jsonl)")
            return embeddedCases
        }
        let dec = JSONDecoder()
        var out: [GoldenCase] = []
        for line in text.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("//") { continue }
            guard let data = trimmed.data(using: .utf8),
                  let c = try? dec.decode(GoldenCase.self, from: data) else { continue }
            out.append(c)
        }
        GigiDebugLogger.log("GoldenRunner: loaded \(out.count) cases from bundle RouterGolden.jsonl")
        return out.isEmpty ? embeddedCases : out
    }

    private static func write(_ summary: Summary) {
        guard let dir = try? FileManager.default.url(
            for: .documentDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true) else { return }
        let url = dir.appendingPathComponent("golden-results.json")
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        if let data = try? enc.encode(summary) {
            try? data.write(to: url)
            GigiDebugLogger.log("GoldenRunner: results written to \(url.path)")
        }
    }
}
