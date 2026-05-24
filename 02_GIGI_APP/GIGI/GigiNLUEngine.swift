import Foundation
import NaturalLanguage

// MARK: - GigiIntent
struct GigiIntent {
    let label: String
    let confidence: Double
    let params: [String: String]
}

// MARK: - Named entities (NLTagger)

struct GigiEntities {
    var contacts: [String] = []
    var dates: [String] = []
    var times: [String] = []
    var apps: [String] = []
    var places: [String] = []
    var topics: [String] = []
    var actions: [String] = []
    var numbers: [String] = []
    var rawText: String = ""
    var sentiment: String = "neutral"

    var isEmpty: Bool {
        contacts.isEmpty && dates.isEmpty && times.isEmpty &&
            apps.isEmpty && places.isEmpty && topics.isEmpty
    }
}

// MARK: - GigiNLUEngine
// Rules-only classification (the MobileBERT + MaxEnt ML classifiers were
// removed 2026-05-24 — they duplicated the SemanticRouter + Apple FM and
// over-matched; see Option B):
//   1. English rule-based fast-path (deterministic)
//   2. ask_cloud — everything else falls through to semantic / Apple FM
class GigiNLUEngine {
    static let shared = GigiNLUEngine()

    private lazy var entityNLTagger = NLTagger(tagSchemes: [.nameType, .lexicalClass, .language])

    private init() {}

    // MARK: - Classificazione principale

    func classify(_ text: String) -> GigiIntent {
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower   = cleaned.lowercased()

        // 1. English rule-based (highest priority — fast, reliable)
        if let rule = classifyRules(lower, original: cleaned) {
            GigiDebugLogger.log("GIGI NLU [rules]: '\(lower)' → \(rule.label) (\(Int(rule.confidence * 100))%)")
            return rule
        }

        // 2. No explicit rule matched. The opaque on-device ML classifiers
        // (MobileBERT + MaxEnt) were removed here on 2026-05-24 (Option B):
        // they emitted an over-confident label for EVERY input (e.g. a web
        // search -> make_call at >=0.95), firing the deterministic fast-path
        // on garbage and duplicating the SemanticRouter + Apple FM layers.
        // Returning ask_cloud (0.5) keeps NLU below the fast-path threshold so
        // unmatched utterances fall through to the smarter semantic / FM
        // routing, which have full-sentence semantics and memory context.
        GigiDebugLogger.log("GIGI NLU: no rule match → ask_cloud (ML classifiers removed)")
        return GigiIntent(label: "ask_cloud", confidence: 0.5, params: ["raw": cleaned])
    }

    // MARK: - English Rule-Based Classifier
    // Runs before ML models. English patterns only — fast and deterministic.
    // Returns nil if no match → falls through to ML models.

    private func classifyRules(_ text: String, original: String) -> GigiIntent? {
        // ── GREETINGS / SMALL TALK ────────────────────────────────────────────
        let greetings = ["hello", "hey", "hi", "how are you", "what's up", "yo", "sup"]
        if greetings.contains(where: { text == $0 || text.hasPrefix($0 + " ") || text.hasPrefix($0 + ",") }) {
            return GigiIntent(label: "respond", confidence: 0.99, params: ["raw": original])
        }
        let conversational = ["thanks", "thank you", "ok", "okay", "cool", "great", "got it",
                              "awesome", "perfect", "sounds good", "sure", "alright"]
        if conversational.contains(where: { text == $0 }) {
            return GigiIntent(label: "respond", confidence: 0.99, params: ["raw": original])
        }

        // ── INTENT-PREFIX PRIORITY (reminder / remember) ──────────────────────
        // An explicit "remind me to ..." / "remember to ..." / "remember that
        // X is Y" prefix names the intent up front. It MUST win before the
        // substring action checks below (make_call grabs the inner "call",
        // toggle_wifi grabs "wifi"), otherwise "remind me to call the bank"
        // dials the bank and "remember that my wifi password is X" toggles
        // wi-fi. Hoisted here so the prefix decides, not the inner verb.
        // ("remember me to ..." is the common colloquial form of "remind me".)
        let reminderTriggers = ["remind me to ", "remind me that ", "set a reminder to ",
                                "set a reminder for ", "remember me to ", "remember to "]
        for trigger in reminderTriggers {
            if let body = extractAfter(trigger, from: text), !body.isEmpty {
                return GigiIntent(label: "set_reminder", confidence: 0.95,
                                  params: ["text": body, "raw": original])
            }
        }
        // Fact assertion: "remember X is Y" (copula required so we don't catch
        // the "remember to ..." reminders handled just above) or an explicit
        // "remember that ..." / "note that ..." prefix.
        let rememberCopula = #"^remember\s+\S+.*?(?:\s+is\s+|\s+are\s+|\s+=\s+|\s+equals\s+|\s+means\s+)"#
        if text.range(of: rememberCopula, options: .regularExpression) != nil,
           let body = extractAfter("remember ", from: text), !body.isEmpty {
            return GigiIntent(label: "remember", confidence: 0.97,
                              params: ["text": body, "raw": original])
        }
        for trigger in ["remember that ", "note that ", "keep in mind that ", "save that "] {
            if let body = extractAfter(trigger, from: text), !body.isEmpty {
                return GigiIntent(label: "remember", confidence: 0.97,
                                  params: ["text": body, "raw": original])
            }
        }

        // ── NAVIGATION ───────────────────────────────────────────────────────
        // Strong, unambiguous triggers → instant fast-path (0.97).
        let navTriggers = [
            "take me to ", "navigate to ", "directions to ",
            "how do i get to ", "get directions to ", "drive to ",
            "show me how to get to ", "route to "
        ]
        for trigger in navTriggers {
            if let dest = extractAfter(trigger, from: text), !dest.isEmpty {
                return GigiIntent(label: "navigate", confidence: 0.97,
                                  params: ["destination": dest.capitalized, "raw": original])
            }
        }
        // "go to X" is lexically overloaded: it covers real navigation
        // ("go to the airport") but ALSO reminders / plans / routines
        // ("go to the dentist at 5 pm tomorrow", "go to bed", "go to the
        // gym"). Do NOT instant-fire navigation off it. Return a
        // sub-fast-path confidence (< 0.95) so deterministicFastPath
        // declines and the utterance falls through to the Apple FM router,
        // which reasons about temporal / list context to decide nav vs
        // reminder. Per "intelligence over regex": no temporal-exclusion
        // regex here — we just stop trusting a weak lexical cue.
        if let dest = extractAfter("go to ", from: text), !dest.isEmpty {
            return GigiIntent(label: "navigate", confidence: 0.60,
                              params: ["destination": dest.capitalized, "raw": original])
        }

        // ── MUSIC ─────────────────────────────────────────────────────────────
        let hasSpotify = text.contains("spotify")
        let hasMusicAction = text.contains("play ") || text.contains("put on ") ||
                             text.contains("listen to ")

        // Require a real music action verb — the bare service name ("spotify")
        // must NOT route here, so "open spotify" reaches the OPEN APP block.
        if hasMusicAction {
            let query = extractMusicQuery(from: text) ?? ""
            var params: [String: String] = ["raw": original]
            if !query.isEmpty { params["query"] = query }
            if hasSpotify { params["app"] = "spotify" }
            return GigiIntent(label: "play_music", confidence: 0.95, params: params)
        }

        // ── CALL ─────────────────────────────────────────────────────────────
        let callTriggers = ["call ", "phone ", "dial ", "ring "]
        for trigger in callTriggers {
            // word-boundary match: "phone " must not fire inside "iphone",
            // "call " inside "recall", "ring " inside "during".
            if let contact = extractAfterWord(trigger, from: text), !contact.isEmpty {
                return GigiIntent(label: "make_call", confidence: 0.97,
                                  params: ["contact": cleanContactName(contact), "raw": original])
            }
        }

        // ── MESSAGE ──────────────────────────────────────────────────────────
        // ORDER MATTERS: most specific triggers FIRST. Otherwise
        // "send a message on whatsapp to Leo" matches "whatsapp " short
        // trigger (rest="to Leo") and the contact gets a stray "to" prefix.
        // 2026-05-12 fix: explicit on-whatsapp variants come first; bare
        // "whatsapp " kept as last-resort fallback.
        let msgTriggers = [
            "send a message on whatsapp to ", "send a message on telegram to ",
            "send a message on imessage to ", "send a message on sms to ",
            "send a whatsapp to ", "send a text to ", "send a message to ",
            "sent a message to ", "sent a whatsapp to ", "sent a text to ",
            "text ", "message ", "iMessage ", "whatsapp "
        ]
        for trigger in msgTriggers {
            if let rest = extractAfter(trigger, from: text), !rest.isEmpty {
                let (contact, body) = splitContactBody(rest)
                var platform = "imessage"
                if trigger.contains("whatsapp") { platform = "whatsapp" }
                var params: [String: String] = ["contact": cleanContactName(contact),
                                                "platform": platform, "raw": original]
                if !body.isEmpty { params["body"] = body }
                return GigiIntent(label: "send_message", confidence: 0.95, params: params)
            }
        }
        // "message John saying I'll be late"
        if let range = text.range(of: " saying ") ?? text.range(of: " with the message ") {
            let body   = String(text[range.upperBound...]).trimmingCharacters(in: .whitespaces)
            let before = String(text[..<range.lowerBound])
            let contact = extractContactFromFragment(before)
            if !contact.isEmpty {
                let platform = text.contains("whatsapp") ? "whatsapp" : "imessage"
                return GigiIntent(label: "send_message", confidence: 0.93,
                                  params: ["contact": contact, "body": body,
                                           "platform": platform, "raw": original])
            }
        }

        // ── TIME / DATE ───────────────────────────────────────────────────────
        if ["what time is it", "what's the time", "current time", "tell me the time"]
            .contains(where: { text.contains($0) }) {
            return GigiIntent(label: "ask_time", confidence: 0.99, params: ["raw": original])
        }
        if ["what day is it", "what's today's date", "what's the date", "today's date"]
            .contains(where: { text.contains($0) }) {
            return GigiIntent(label: "ask_date", confidence: 0.99, params: ["raw": original])
        }

        // ── CALENDAR EVENT ────────────────────────────────────────────────────
        let eventTriggers = ["create event ", "add event ", "add to calendar ",
                             "schedule a ", "add a meeting ", "create a meeting "]
        for trigger in eventTriggers {
            if let title = extractAfter(trigger, from: text), !title.isEmpty {
                return GigiIntent(label: "create_event", confidence: 0.93,
                                  params: ["title": title, "raw": original])
            }
        }
        // Implicit event: "I have a doctor appointment tomorrow at 12"
        let implicitEventPatterns = ["i have a doctor", "i have an appointment", "i have a meeting",
                                     "i have a class", "i have an exam", "i have a job interview"]
        if implicitEventPatterns.contains(where: { text.contains($0) }) {
            return GigiIntent(label: "create_event", confidence: 0.93, params: ["title": original, "raw": original])
        }

        // ── WEATHER ──────────────────────────────────────────────────────────
        let weatherTriggers = ["weather", "forecast", "temperature"]
        if weatherTriggers.contains(where: { text.contains($0) }) {
            var params: [String: String] = ["raw": original]
            for locTrigger in ["weather in ", "forecast for ", "weather for "] {
                if let loc = extractAfter(locTrigger, from: text), !loc.isEmpty {
                    params["destination"] = loc.components(separatedBy: " ").prefix(3).joined(separator: " ").capitalized
                    break
                }
            }
            return GigiIntent(label: "weather", confidence: 0.92, params: params)
        }

        // ── OPEN APP ──────────────────────────────────────────────────────────
        for trigger in ["open ", "launch ", "start "] {
            if let appName = extractAfter(trigger, from: text), !appName.isEmpty {
                let app = appName.components(separatedBy: " ").first ?? appName
                if app.lowercased() == "spotify" && hasMusicAction { break }
                // Articles as first token mean the real intent is elsewhere ("start a timer", "open the mail").
                // Bail so the timer/alarm/etc. rules below get a chance to match.
                if ["a", "an", "the"].contains(app.lowercased()) { break }
                return GigiIntent(label: "open_app", confidence: 0.90,
                                  params: ["app": app.capitalized, "raw": original])
            }
        }

        // ── FLASHLIGHT ───────────────────────────────────────────────────────
        if ["turn on flashlight", "flashlight on", "turn on the flashlight",
            "torch on", "turn on torch", "open flashlight"]
            .contains(where: { text.contains($0) }) {
            return GigiIntent(label: "torch_on", confidence: 0.99, params: ["raw": original])
        }
        if ["turn off flashlight", "flashlight off", "turn off the flashlight",
            "torch off", "turn off torch", "close flashlight"]
            .contains(where: { text.contains($0) }) {
            return GigiIntent(label: "torch_off", confidence: 0.99, params: ["raw": original])
        }
        if text == "flashlight" || text == "torch" {
            return GigiIntent(label: "torch_on", confidence: 0.90, params: ["raw": original])
        }

        // ── ALARM ─────────────────────────────────────────────────────────────
        if ["set an alarm", "set alarm", "wake me up", "alarm at ", "alarm for "]
            .contains(where: { text.contains($0) }) {
            var params: [String: String] = ["raw": original]

            // Try 3 extraction patterns in priority order:
            // 1. "at <time>" — canonical English ("set alarm at 7 am")
            // 2. "for <time>" — common variant ("set alarm for 7 am")
            // 3. Regex fallback — any HH(:MM)? AM/PM in the text
            //
            // Each prefix-extraction takes the next 2 words and validates
            // they contain at least one digit. The regex fallback is the
            // catch-all for utterances that skip the preposition.
            var timeCandidate: String?
            for prefix in ["at ", "for "] {
                if let t = extractAfter(prefix, from: text) {
                    let candidate = t.components(separatedBy: " ").prefix(2).joined(separator: " ")
                    if candidate.range(of: "\\d", options: .regularExpression) != nil {
                        timeCandidate = candidate
                        break
                    }
                }
            }
            if timeCandidate == nil,
               let r = text.range(of: #"\d{1,2}(?::\d{2})?\s*(?:am|pm)?"#, options: .regularExpression) {
                timeCandidate = String(text[r]).trimmingCharacters(in: .whitespaces)
            }
            if let time = timeCandidate, !time.isEmpty {
                params["time"] = time
            }

            return GigiIntent(label: "set_alarm", confidence: 0.97, params: params)
        }

        // ── TIMER ─────────────────────────────────────────────────────────────
        if text.contains("timer") || text.contains("countdown") {
            return GigiIntent(label: "set_timer", confidence: 0.97, params: ["text": original, "raw": original])
        }
        let timerPattern = #"(\d+)\s*(min|sec|second|seconds|minute|minutes|hour|hours)"#
        if (text.contains("set a") || text.contains("start a") || text.contains("start")) &&
            text.range(of: timerPattern, options: .regularExpression) != nil {
            return GigiIntent(label: "set_timer", confidence: 0.95, params: ["text": original, "raw": original])
        }

        // ── WIFI / BLUETOOTH ──────────────────────────────────────────────────
        if text.contains("wifi") || text.contains("wi-fi") {
            return GigiIntent(label: "toggle_wifi", confidence: 0.97, params: ["raw": original])
        }
        if text.contains("bluetooth") {
            return GigiIntent(label: "toggle_bluetooth", confidence: 0.97, params: ["raw": original])
        }

        // ── FACETIME ──────────────────────────────────────────────────────────
        if text.contains("facetime") {
            let isAudio = text.contains("audio")
            let action  = isAudio ? "facetime_audio" : "facetime"
            for trigger in ["facetime ", "facetime with "] {
                if let contact = extractAfter(trigger, from: text), !contact.isEmpty {
                    return GigiIntent(label: action, confidence: 0.97,
                                      params: ["contact": cleanContactName(contact), "raw": original])
                }
            }
            return GigiIntent(label: action, confidence: 0.90, params: ["raw": original])
        }

        // ── MEDIA CONTROLS ────────────────────────────────────────────────────
        if ["next song", "next track", "skip song", "skip track", "skip"]
            .contains(where: { text.contains($0) }) {
            return GigiIntent(label: "media_next", confidence: 0.97, params: ["raw": original])
        }
        if ["previous song", "previous track", "go back", "last song"]
            .contains(where: { text.contains($0) }) {
            return GigiIntent(label: "media_previous", confidence: 0.97, params: ["raw": original])
        }
        if ["pause", "pause music", "pause the music", "stop music"]
            .contains(where: { text == $0 || text.contains($0) }) {
            return GigiIntent(label: "media_play_pause", confidence: 0.95, params: ["raw": original])
        }
        if ["resume music", "resume", "unpause", "play music"]
            .contains(where: { text.contains($0) }) {
            return GigiIntent(label: "media_play_pause", confidence: 0.93, params: ["raw": original])
        }

        // ── READ CALENDAR ─────────────────────────────────────────────────────
        if ["what do i have today", "what's on my calendar", "my schedule",
            "any events today", "show my calendar", "check my calendar"]
            .contains(where: { text.contains($0) }) {
            return GigiIntent(label: "read_calendar", confidence: 0.97, params: ["raw": original])
        }

        // ── WEB SEARCH ────────────────────────────────────────────────────────
        for trigger in ["google ", "search for ", "look up ", "search "] {
            if let q = extractAfter(trigger, from: text), !q.isEmpty {
                return GigiIntent(label: "search_web", confidence: 0.93,
                                  params: ["query": q, "raw": original])
            }
        }

        // ── EMAIL ─────────────────────────────────────────────────────────────
        if ["read my email", "read emails", "check email", "check my email",
            "any new emails", "new emails", "open email"]
            .contains(where: { text.contains($0) }) {
            return GigiIntent(label: "read_email", confidence: 0.97, params: ["raw": original])
        }
        for trigger in ["send an email to ", "email to ", "email "] {
            if let rest = extractAfter(trigger, from: text), !rest.isEmpty {
                let (contact, body) = splitContactBody(rest)
                return GigiIntent(label: "send_email", confidence: 0.93,
                                  params: ["contact": cleanContactName(contact), "body": body, "raw": original])
            }
        }

        // ── FOOD / ORDER ──────────────────────────────────────────────────────
        if ["i'm hungry", "i am hungry", "order food", "order pizza"]
            .contains(where: { text.contains($0) }) {
            return GigiIntent(label: "order_food", confidence: 0.85, params: ["raw": original])
        }
        for trigger in ["order food from ", "order pizza from ", "order from "] {
            if let rest = extractAfter(trigger, from: text), !rest.isEmpty {
                return GigiIntent(label: "order_food", confidence: 0.95,
                                  params: ["restaurant": rest, "raw": original])
            }
        }

        // ── BOOK RESTAURANT ───────────────────────────────────────────────────
        for trigger in ["book a table at ", "book a restaurant ", "reserve a table at ",
                        "make a reservation at "] {
            if let rest = extractAfter(trigger, from: text), !rest.isEmpty {
                var restName = rest.trimmingCharacters(in: .whitespaces)
                var time = ""
                var guests = "2"
                if let aRange = restName.range(of: " at ") {
                    time     = String(restName[aRange.upperBound...]).trimmingCharacters(in: .whitespaces)
                    restName = String(restName[..<aRange.lowerBound]).trimmingCharacters(in: .whitespaces)
                }
                if let fRange = restName.range(of: " for ") {
                    let after    = String(restName[fRange.upperBound...])
                    let guestStr = after.components(separatedBy: " ").first ?? ""
                    if let n = Int(guestStr), n > 0 {
                        guests   = "\(n)"
                        restName = String(restName[..<fRange.lowerBound]).trimmingCharacters(in: .whitespaces)
                    }
                }
                return GigiIntent(label: "book_restaurant", confidence: 0.95,
                                  params: ["restaurant": restName, "time": time,
                                           "guests": guests, "raw": original])
            }
        }

        // ── FREE SLOT ─────────────────────────────────────────────────────────
        if ["when am i free", "find me a slot", "find free time", "find a free slot"]
            .contains(where: { text.contains($0) }) {
            let timeHint = extractAfter("in the afternoon", from: text)
                ?? extractAfter("in the morning", from: text) ?? ""
            return GigiIntent(label: "find_free_slot", confidence: 0.92,
                              params: ["duration": "60", "preferred": timeHint, "raw": original])
        }
        if ["this week", "next few days", "what's this week", "show me this week"]
            .contains(where: { text.contains($0) }) {
            return GigiIntent(label: "read_week_calendar", confidence: 0.91, params: ["raw": original])
        }

        // ── HOMEKIT ───────────────────────────────────────────────────────────
        for trigger in ["turn on ", "switch on ", "lights on"] {
            if trigger == "lights on" && text.contains(trigger) {
                return GigiIntent(label: "homekit_on", confidence: 0.92, params: ["accessory": "light", "raw": original])
            }
            if let rest = extractAfter(trigger, from: text), !rest.isEmpty {
                return GigiIntent(label: "homekit_on", confidence: 0.92, params: ["accessory": rest, "raw": original])
            }
        }
        for trigger in ["turn off ", "switch off ", "lights off"] {
            if trigger == "lights off" && text.contains(trigger) {
                return GigiIntent(label: "homekit_off", confidence: 0.92, params: ["accessory": "light", "raw": original])
            }
            if let rest = extractAfter(trigger, from: text), !rest.isEmpty {
                return GigiIntent(label: "homekit_off", confidence: 0.92, params: ["accessory": rest, "raw": original])
            }
        }
        for trigger in ["activate scene ", "set scene ", "activate mode "] {
            if let scene = extractAfter(trigger, from: text), !scene.isEmpty {
                return GigiIntent(label: "homekit_scene", confidence: 0.91, params: ["scene": scene, "raw": original])
            }
        }
        if text.contains("goodnight") {
            return GigiIntent(label: "homekit_scene", confidence: 0.93, params: ["scene": "goodnight", "raw": original])
        }
        // "set lights to 40%" / "brightness 40%"
        let dimPattern = #"(?:set|dim).*?(?:light|lights|lamp).*?(\d{1,3})\s*%"#
        if let m = text.range(of: dimPattern, options: .regularExpression) {
            let digits = String(text[m]).components(separatedBy: .decimalDigits.inverted).joined()
            return GigiIntent(label: "homekit_dim", confidence: 0.90,
                              params: ["brightness": digits.isEmpty ? "50" : digits, "raw": original])
        }
        // "set thermostat to 72" / "heat to 70"
        let tempPattern = #"(?:thermostat|temperature|heating|heat).*?(\d{1,2})"#
        if let m = text.range(of: tempPattern, options: .regularExpression) {
            let digits = String(text[m]).components(separatedBy: .decimalDigits.inverted).joined()
            return GigiIntent(label: "homekit_temp", confidence: 0.90,
                              params: ["temperature": digits.isEmpty ? "70" : digits, "raw": original])
        }
        if text.contains("lock") && (text.contains("door") || text.contains("front")) {
            return GigiIntent(label: "homekit_lock", confidence: 0.91, params: ["raw": original])
        }
        if text.contains("unlock") && (text.contains("door") || text.contains("front")) {
            return GigiIntent(label: "homekit_unlock", confidence: 0.91, params: ["raw": original])
        }

        // ── MEMORY (recall) ───────────────────────────────────────────────────
        // Fact assertion ("remember X is Y" / "remember that ...") is hoisted
        // to the INTENT-PREFIX PRIORITY block near the top of classifyRules.
        // Recall triggers — include contractions ("who's", "what's") and the
        // bare "X?" form ("Marco?" after a previous recall). The recall
        // confidence stays 0.90 so the memory-recall probe in GigiAgentEngine
        // gates on actual cache presence; if memory misses, the router
        // pipeline still gets to try Apple FM / Ollama for generic knowledge.
        for trigger in [
            "tell me about ",
            "what do you know about ",
            "who is ", "who's ", "whos ",
            "what is ", "what's ", "whats ",
            "recall "
        ] {
            if let q = extractAfter(trigger, from: text), !q.isEmpty {
                return GigiIntent(label: "recall", confidence: 0.90,
                                  params: ["query": q, "raw": original])
            }
        }

        // ── NEWS ──────────────────────────────────────────────────────────────
        for trigger in ["news about ", "latest news about ", "latest on "] {
            if let q = extractAfter(trigger, from: text), !q.isEmpty {
                return GigiIntent(label: "read_news", confidence: 0.95,
                                  params: ["query": q, "raw": original])
            }
        }
        if ["read the news", "latest news", "what's in the news", "top news"]
            .contains(where: { text.hasPrefix($0) || text.contains($0) }) {
            let q = extractAfter("about ", from: text) ?? "top news"
            return GigiIntent(label: "read_news", confidence: 0.93,
                              params: ["query": q, "raw": original])
        }

        // ── GENERAL QUESTIONS (cloud) ─────────────────────────────────────────
        if ["tell me ", "who is ", "what is ", "what are ", "explain ", "how does ", "why "]
            .contains(where: { text.hasPrefix($0) || text.contains($0) }) {
            return GigiIntent(label: "ask_cloud", confidence: 0.80, params: ["raw": original])
        }

        return nil
    }

    // MARK: - Extraction helpers

    private func extractAfter(_ trigger: String, from text: String) -> String? {
        guard let range = text.range(of: trigger) else { return nil }
        let rest = String(text[range.upperBound...]).trimmingCharacters(in: .whitespaces)
        return rest.isEmpty ? nil : rest
    }

    /// Like extractAfter but only matches the trigger at a WORD boundary
    /// (start of string or preceded by a non-letter), so "phone " does not
    /// match inside "iphone", "call " inside "recall", "ring " inside
    /// "during". Returns the trimmed remainder after the first valid match.
    private func extractAfterWord(_ trigger: String, from text: String) -> String? {
        var searchStart = text.startIndex
        while let range = text.range(of: trigger, range: searchStart..<text.endIndex) {
            let before = range.lowerBound
            let boundaryOK = before == text.startIndex
                || !text[text.index(before: before)].isLetter
            if boundaryOK {
                let rest = String(text[range.upperBound...])
                    .trimmingCharacters(in: .whitespaces)
                return rest.isEmpty ? nil : rest
            }
            searchStart = text.index(after: range.lowerBound)
        }
        return nil
    }

    private func cleanContactName(_ raw: String) -> String {
        var name = raw.trimmingCharacters(in: .whitespacesAndNewlines)

        // 2026-05-12 fix: strip leading prepositions left over by trigger
        // matching. E.g. when the trigger "whatsapp " absorbs the prefix and
        // leaves "to Leo Corte" as the rest, the contact resolution fails
        // because Contacts have no "to Leo" entry. Italian aliases included.
        let leadingPrepositions = ["to ", "a ", "al ", "all'", "alla ", "agli ", "alle "]
        var changed = true
        while changed {
            changed = false
            let lower = name.lowercased()
            for prep in leadingPrepositions {
                if lower.hasPrefix(prep) {
                    name = String(name.dropFirst(prep.count))
                        .trimmingCharacters(in: .whitespaces)
                    changed = true
                    break
                }
            }
        }

        // Strip trailing context that the trigger didn't already remove.
        let suffixes = [" please", " now", " immediately",
                        " on the phone", " on whatsapp", " on telegram",
                        " on imessage", " on sms"]
        for s in suffixes {
            if let r = name.lowercased().range(of: s) {
                name = String(name[..<r.lowerBound])
            }
        }
        // Take only the first 2-3 words (name + surname)
        return name.components(separatedBy: " ")
            .prefix(3).joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
    }

    private func splitContactBody(_ text: String) -> (String, String) {
        // Bug #009 fix (2026-05-12): support BOTH common patterns
        //   Pattern A: "to <contact> <verb> <body>"
        //              e.g. "to Leo saying I'll be late"
        //              → contact = before separator, body = after
        //   Pattern B: "and <verb> <body> to <contact>"
        //              e.g. "and say hi to Leo Corte"
        //              → body = between separator and " to ", contact = after " to "
        let bodySeparators = [
            " e digli ", " dicendo ", " con il messaggio ",
            " saying ", " that ", " and say ", " and tell ",
            " telling ", " writing "
        ]
        for sep in bodySeparators {
            if let range = text.lowercased().range(of: sep) {
                let before = String(text[..<range.lowerBound]).trimmingCharacters(in: .whitespaces)
                let after  = String(text[range.upperBound...]).trimmingCharacters(in: .whitespaces)

                // Pattern B: body comes BEFORE " to <contact>".
                // Detect by finding " to " (or " a "/Italian) inside the
                // `after` portion. If found, body = pre-" to ", contact = post.
                let bSeparators = [" to ", " a ", " al ", " alla "]
                for bSep in bSeparators {
                    if let toRange = after.lowercased().range(of: bSep) {
                        let body    = String(after[..<toRange.lowerBound]).trimmingCharacters(in: .whitespaces)
                        let contact = String(after[toRange.upperBound...]).trimmingCharacters(in: .whitespaces)
                        if !body.isEmpty && !contact.isEmpty {
                            return (contact, body)
                        }
                    }
                }
                // Pattern A: default — before is contact, after is body.
                return (before, after)
            }
        }
        return (text, "")
    }

    private func extractContactFromFragment(_ text: String) -> String {
        let lower = text.lowercased()
        for trigger in ["a ", "al ", "alla ", "all'", "to "] {
            if let range = lower.range(of: trigger, options: .backwards) {
                let candidate = String(text[range.upperBound...]).trimmingCharacters(in: .whitespaces)
                let name = candidate.components(separatedBy: " ").prefix(2).joined(separator: " ")
                if name.count > 1 { return cleanContactName(name) }
            }
        }
        return ""
    }

    // MARK: - Music query extraction (used by the MUSIC rule)

    private func extractMusicQuery(from text: String) -> String? {
        let triggers = [
            "play ", "put on ", "listen to ", "queue ", "shuffle "
        ]
        for t in triggers {
            if let range = text.range(of: t) {
                let q = String(text[range.upperBound...]).trimmingCharacters(in: .whitespaces)
                if !q.isEmpty { return q }
            }
        }
        return nil
    }

    // MARK: - Entity extraction (legacy GigiEntityExtractor)

    func extractEntities(from text: String) -> GigiEntities {
        var entities = GigiEntities()
        entities.rawText = text
        let lower = text.lowercased()
        extractNamedEntityTokens(from: text, into: &entities)
        entities.dates = extractEntityDates(from: lower)
        entities.times = extractEntityTimes(from: lower)
        entities.numbers = extractEntityNumbers(from: lower)
        entities.apps = extractEntityApps(from: lower)
        entities.places = extractEntityPlaces(from: lower)
        entities.topics = extractEntityTopics(from: lower)
        entities.actions = extractEntityActions(from: lower)
        entities.sentiment = extractEntitySentiment(from: lower)
        GigiDebugLogger.log("GIGI Entities: \(entities)")
        return entities
    }

    private func extractNamedEntityTokens(from text: String, into entities: inout GigiEntities) {
        entityNLTagger.string = text
        let range = text.startIndex..<text.endIndex
        entityNLTagger.enumerateTags(
            in: range,
            unit: .word,
            scheme: .nameType,
            options: [.omitWhitespace, .omitPunctuation, .joinNames]
        ) { tag, tokenRange in
            let token = String(text[tokenRange])
            switch tag {
            case .personalName: entities.contacts.append(token)
            case .placeName: entities.places.append(token)
            case .organizationName: entities.topics.append(token)
            default: break
            }
            return true
        }
    }

    private func extractEntityDates(from text: String) -> [String] {
        var dates: [String] = []
        let patterns: [(String, String)] = [
            ("tomorrow", "tomorrow"),
            ("today", "today"),
            ("tonight", "tonight"),
            ("next week", "next_week"),
            ("this weekend", "this_weekend"),
            ("next month", "next_month"),
            ("monday", "monday"), ("tuesday", "tuesday"),
            ("wednesday", "wednesday"), ("thursday", "thursday"),
            ("friday", "friday"), ("saturday", "saturday"),
            ("sunday", "sunday"),
            ("january|february|march|april|may|june|july|august|september|october|november|december", "month"),
        ]
        for (pattern, label) in patterns {
            if text.range(of: pattern, options: .regularExpression) != nil, !dates.contains(label) {
                dates.append(label)
            }
        }
        let datePatterns = [
            "\\d{1,2}/\\d{1,2}(?:/\\d{2,4})?",
            "\\d{1,2}-\\d{1,2}(?:-\\d{2,4})?",
            "(jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec)[a-z]* \\d{1,2}",
        ]
        for pattern in datePatterns {
            if let match = text.range(of: pattern, options: .regularExpression) {
                dates.append(String(text[match]))
            }
        }
        return dates
    }

    private func extractEntityTimes(from text: String) -> [String] {
        var times: [String] = []
        let patterns = [
            "\\d{1,2}:\\d{2}\\s*(?:am|pm)?",
            "\\d{1,2}\\s*(?:am|pm)",
            "\\d{1,2}\\s*o'?clock",
            "noon", "midnight", "morning", "afternoon",
            "evening", "tonight", "night",
        ]
        for pattern in patterns {
            if let match = text.range(of: pattern, options: .regularExpression) {
                let t = String(text[match]).trimmingCharacters(in: .whitespaces)
                if !times.contains(t) { times.append(t) }
            }
        }
        return times
    }

    private func extractEntityNumbers(from text: String) -> [String] {
        var numbers: [String] = []
        let pattern = "\\b\\d+\\b"
        var searchRange = text.startIndex..<text.endIndex
        while let match = text.range(of: pattern, options: .regularExpression, range: searchRange) {
            numbers.append(String(text[match]))
            searchRange = match.upperBound..<text.endIndex
        }
        let written: [String: String] = [
            "one": "1", "two": "2", "three": "3", "four": "4", "five": "5",
            "six": "6", "seven": "7", "eight": "8", "nine": "9", "ten": "10",
            "fifteen": "15", "twenty": "20", "thirty": "30", "sixty": "60",
        ]
        for (word, num) in written where text.contains(word) && !numbers.contains(num) {
            numbers.append(num)
        }
        return numbers
    }

    private func extractEntityApps(from text: String) -> [String] {
        let knownApps = [
            "spotify", "instagram", "whatsapp", "telegram", "youtube",
            "netflix", "tiktok", "twitter", "uber", "doordash", "gmail",
            "slack", "zoom", "maps", "waze", "facetime", "discord",
            "snapchat", "linkedin", "reddit", "notion", "chatgpt",
            "claude", "gemini", "signal", "messenger", "apple music",
            "music", "podcasts", "news", "health", "fitness",
        ]
        return knownApps.filter { text.contains($0) }.map { $0.capitalized }
    }

    private func extractEntityPlaces(from text: String) -> [String] {
        let knownPlaces = [
            "home", "office", "work", "school", "gym", "hospital",
            "airport", "station", "downtown", "uptown", "mall",
            "restaurant", "cafe", "bar", "park", "beach", "hotel",
        ]
        return knownPlaces.filter { text.contains($0) }
    }

    private func extractEntityTopics(from text: String) -> [String] {
        var topics: [String] = []
        let topicMap: [String: [String]] = [
            "medical": ["dentist", "doctor", "appointment", "checkup", "hospital", "medicine", "pill", "medication"],
            "travel": ["flight", "plane", "trip", "vacation", "travel", "hotel", "booking", "airport"],
            "fitness": ["gym", "workout", "exercise", "run", "training", "yoga", "swim"],
            "food": ["lunch", "dinner", "breakfast", "restaurant", "eat", "food", "coffee", "drink"],
            "work": ["meeting", "presentation", "deadline", "boss", "colleague", "project", "call", "conference"],
            "family": ["birthday", "anniversary", "party", "wedding", "graduation", "holiday"],
            "finance": ["payment", "bill", "rent", "salary", "bank", "money", "transfer"],
            "music": ["song", "playlist", "album", "artist", "concert", "listen", "music"],
            "shopping": ["buy", "order", "delivery", "package", "store", "shop"],
        ]
        for (topic, keywords) in topicMap where keywords.contains(where: { text.contains($0) }) {
            topics.append(topic)
        }
        return topics
    }

    private func extractEntityActions(from text: String) -> [String] {
        let actionWords = [
            "send", "call", "open", "play", "remind", "schedule", "add",
            "create", "set", "turn", "enable", "disable", "find", "search",
            "navigate", "order", "book", "cancel", "delete", "check",
            "read", "write", "message", "text", "email", "buy", "pay",
        ]
        return actionWords.filter { text.contains($0) }
    }

    private func extractEntitySentiment(from text: String) -> String {
        let urgentWords = ["urgent", "asap", "now", "immediately", "quick", "fast", "emergency", "right now", "hurry"]
        let questionWords = ["what", "who", "where", "when", "why", "how", "which", "can you", "do you", "is it"]
        let casualWords = ["hey", "yo", "sup", "chill", "whatever", "maybe", "kinda"]
        if urgentWords.contains(where: { text.contains($0) }) { return "urgent" }
        if questionWords.contains(where: { text.contains($0) }) { return "question" }
        if casualWords.contains(where: { text.contains($0) }) { return "casual" }
        return "neutral"
    }
}
