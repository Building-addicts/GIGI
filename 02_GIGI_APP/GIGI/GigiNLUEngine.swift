import Foundation
import CoreML
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
// 3-level classification pipeline:
//   1. English rule-based (highest priority — fast, reliable)
//   2. MobileBERT transformer (if loaded)
//   3. GigiNLU Maximum Entropy (fallback)
//   4. ask_cloud (ultra-fallback)
class GigiNLUEngine {
    static let shared = GigiNLUEngine()

    private var transformerModel: MLModel?
    private var fallbackClassifier: NLModel?
    private var labels: [String] = []
    private let maxLen = 64
    private var vocab: [String: Int] = [:]
    private lazy var entityNLTagger = NLTagger(tagSchemes: [.nameType, .lexicalClass, .language])

    private init() {
        loadTransformer()
        loadFallback()
        loadLabels()
    }

    // MARK: - Classificazione principale

    func classify(_ text: String) -> GigiIntent {
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower   = cleaned.lowercased()

        // 1. English rule-based (highest priority — fast, reliable)
        if let rule = classifyRules(lower, original: cleaned) {
            print("GIGI NLU [rules]: '\(lower)' → \(rule.label) (\(Int(rule.confidence * 100))%)")
            return rule
        }

        // 2. MobileBERT
        if let result = classifyWithTransformer(lower) {
            print("GIGI NLU [BERT]: '\(lower)' → \(result.label) (\(Int(result.confidence * 100))%)")
            let params = extractParams(from: lower, intent: result.label)
            return GigiIntent(label: result.label, confidence: result.confidence, params: params)
        }

        // 3. Maximum Entropy fallback
        if let result = classifyWithFallback(lower) {
            print("GIGI NLU [ME]: '\(lower)' → \(result.label) (\(Int(result.confidence * 100))%)")
            let params = extractParams(from: lower, intent: result.label)
            return GigiIntent(label: result.label, confidence: result.confidence, params: params)
        }

        // 4. Ultra-fallback
        print("GIGI NLU: fallback ask_cloud")
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

        // ── NAVIGATION ───────────────────────────────────────────────────────
        let navTriggers = [
            "take me to ", "navigate to ", "directions to ", "go to ",
            "how do i get to ", "get directions to ", "drive to ",
            "show me how to get to ", "route to "
        ]
        for trigger in navTriggers {
            if let dest = extractAfter(trigger, from: text), !dest.isEmpty {
                return GigiIntent(label: "navigation", confidence: 0.97,
                                  params: ["destination": dest.capitalized, "raw": original])
            }
        }

        // ── MUSIC ─────────────────────────────────────────────────────────────
        let hasSpotify = text.contains("spotify")
        let hasMusicAction = text.contains("play ") || text.contains("put on ") ||
                             text.contains("listen to ")

        if hasSpotify || hasMusicAction {
            let query = extractMusicQuery(from: text) ?? ""
            var params: [String: String] = ["raw": original]
            if !query.isEmpty { params["query"] = query }
            if hasSpotify { params["app"] = "spotify" }
            return GigiIntent(label: "play_music", confidence: 0.95, params: params)
        }

        // ── CALL ─────────────────────────────────────────────────────────────
        let callTriggers = ["call ", "phone ", "dial ", "ring "]
        for trigger in callTriggers {
            if let contact = extractAfter(trigger, from: text), !contact.isEmpty {
                return GigiIntent(label: "make_call", confidence: 0.97,
                                  params: ["contact": cleanContactName(contact), "raw": original])
            }
        }

        // ── MESSAGE ──────────────────────────────────────────────────────────
        let msgTriggers = [
            "send a whatsapp to ", "whatsapp ", "send a message to ",
            "text ", "message ", "send a text to ", "iMessage "
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

        // ── REMINDER ─────────────────────────────────────────────────────────
        let reminderTriggers = ["remind me to ", "remind me that ", "set a reminder to ",
                                "set a reminder for "]
        for trigger in reminderTriggers {
            if let body = extractAfter(trigger, from: text), !body.isEmpty {
                return GigiIntent(label: "set_reminder", confidence: 0.95,
                                  params: ["text": body, "raw": original])
            }
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
            if let t = extractAfter("at ", from: text) {
                let candidate = t.components(separatedBy: " ").prefix(2).joined(separator: " ")
                if candidate.range(of: "\\d", options: .regularExpression) != nil {
                    params["time"] = candidate
                }
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

        // ── MEMORY ────────────────────────────────────────────────────────────
        for trigger in ["remember that ", "note that ", "keep in mind that ", "save that "] {
            if let body = extractAfter(trigger, from: text), !body.isEmpty {
                return GigiIntent(label: "remember", confidence: 0.97,
                                  params: ["body": body, "raw": original])
            }
        }
        for trigger in ["tell me about ", "what do you know about ", "who is ", "recall "] {
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

    private func cleanContactName(_ raw: String) -> String {
        var name = raw
        let suffixes = [" please", " now", " immediately",
                        " on the phone", " on whatsapp", " on telegram"]
        for s in suffixes {
            if let r = name.lowercased().range(of: s) {
                name = String(name[..<r.lowerBound])
            }
        }
        // Prendi solo le prime 2-3 parole (nome + cognome)
        return name.components(separatedBy: " ")
            .prefix(3).joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
    }

    private func splitContactBody(_ text: String) -> (String, String) {
        let bodySeparators = [" e digli ", " dicendo ", " con il messaggio ", " saying ", " that "]
        for sep in bodySeparators {
            if let range = text.lowercased().range(of: sep) {
                let contact = String(text[..<range.lowerBound]).trimmingCharacters(in: .whitespaces)
                let body    = String(text[range.upperBound...]).trimmingCharacters(in: .whitespaces)
                return (contact, body)
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

    // MARK: - Caricamento modelli

    private func loadTransformer() {
        guard let url = Bundle.main.url(forResource: "GigiNLU_Transformer", withExtension: "mlpackage") ??
                        Bundle.main.url(forResource: "GigiNLU_Transformer", withExtension: "mlmodelc")
        else {
            // Opzionale: aggiungi `GigiNLU_Transformer.mlpackage` al target per classificazione BERT on-device.
            return
        }
        do {
            let config = MLModelConfiguration()
            config.computeUnits = .all
            transformerModel = try MLModel(contentsOf: url, configuration: config)
            print("GIGI NLU: MobileBERT caricato ✓")
        } catch { print("GIGI NLU: Transformer error — \(error)") }
    }

    private func loadFallback() {
        do {
            let config = MLModelConfiguration()
            let mlModel = try GigiNLU(configuration: config)
            fallbackClassifier = try NLModel(mlModel: mlModel.model)
            print("GIGI NLU: Fallback GigiNLU caricato ✓")
        } catch { print("GIGI NLU: Fallback error — \(error)") }
    }

    private func loadLabels() {
        if let url  = Bundle.main.url(forResource: "gigi_labels", withExtension: "json"),
           let data = try? Data(contentsOf: url),
           let dec  = try? JSONDecoder().decode([String].self, from: data) {
            labels = dec
            print("GIGI NLU: \(labels.count) labels caricate ✓")
            return
        }
        labels = [
            "ask_cloud","create_event","create_note","find_nearby",
            "food_delivery","make_call","music_control","navigation",
            "open_app","open_settings","open_settings_vpn",
            "phone_system","play_music","read_calendar","read_email",
            "read_messages","ride_share","search_web","send_email",
            "send_message","set_alarm","set_brightness_down",
            "set_brightness_up","set_reminder","set_timer",
            "social_media","take_photo","toggle_bluetooth",
            "toggle_do_not_disturb","toggle_wifi","torch_off",
            "torch_on","weather"
        ]
    }

    // MARK: - MobileBERT inference

    private func classifyWithTransformer(_ text: String) -> (label: String, confidence: Double)? {
        guard let model = transformerModel else { return nil }
        let tokens = tokenize(text)
        guard !tokens.isEmpty else { return nil }
        do {
            let inputIds = try MLMultiArray(shape: [1, NSNumber(value: maxLen)], dataType: .int32)
            let attnMask = try MLMultiArray(shape: [1, NSNumber(value: maxLen)], dataType: .int32)
            inputIds[0] = 101; attnMask[0] = 1
            for (i, tok) in tokens.prefix(maxLen - 2).enumerated() {
                inputIds[i + 1] = NSNumber(value: tok); attnMask[i + 1] = 1
            }
            let sepIdx = min(tokens.count + 1, maxLen - 1)
            inputIds[sepIdx] = 102; attnMask[sepIdx] = 1
            let provider = try MLDictionaryFeatureProvider(dictionary: [
                "input_ids": MLFeatureValue(multiArray: inputIds),
                "attention_mask": MLFeatureValue(multiArray: attnMask)
            ])
            let output = try model.prediction(from: provider)
            guard let logits = output.featureValue(for: "logits")?.multiArrayValue else { return nil }
            var scores = (0..<labels.count).map { Double(truncating: logits[$0]) }
            let maxScore = scores.max() ?? 0
            scores = scores.map { exp($0 - maxScore) }
            let sum = scores.reduce(0, +)
            scores = scores.map { $0 / sum }
            let bestIdx = scores.indices.max(by: { scores[$0] < scores[$1] }) ?? 0
            return (labels[bestIdx], scores[bestIdx])
        } catch { print("GIGI NLU transformer error: \(error)"); return nil }
    }

    // MARK: - Maximum Entropy fallback

    private func classifyWithFallback(_ text: String) -> (label: String, confidence: Double)? {
        guard let clf = fallbackClassifier else { return nil }
        let label = clf.predictedLabel(for: text) ?? "ask_cloud"
        let conf  = clf.predictedLabelHypotheses(for: text, maximumCount: 3)[label] ?? 0.5
        return (label, conf)
    }

    // MARK: - Tokenizer

    private func tokenize(_ text: String) -> [Int] {
        let words = text.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
        return words.compactMap { word -> Int? in
            if let id = vocab[word] { return id }
            var hash = 5381
            for char in word.unicodeScalars { hash = ((hash << 5) &+ hash) &+ Int(char.value) }
            return abs(hash) % 30522
        }
    }

    // MARK: - Estrazione parametri (English — usata solo dai modelli ML)

    func extractParams(from text: String, intent: String) -> [String: String] {
        var params: [String: String] = ["raw": text]
        switch intent {
        case "send_message", "make_call", "send_email":
            if let name = extractName(from: text) { params["contact"] = name }
            if let body = extractBody(from: text) { params["body"] = body }
            if let platform = extractPlatform(from: text) { params["platform"] = platform }
        case "create_event", "set_alarm":
            if let time = extractTime(from: text) { params["time"] = time }
            if let date = extractDate(from: text) { params["date"] = date }
            if let title = extractEventTitle(from: text) { params["title"] = title }
        case "set_timer":
            if let s = extractDuration(from: text) { params["seconds"] = String(s) }
        case "open_app", "social_media", "food_delivery", "ride_share":
            if let app = extractAppName(from: text) { params["app"] = app }
        case "navigation", "find_nearby":
            if let dest = extractDestination(from: text) { params["destination"] = dest }
        case "play_music":
            if let q = extractMusicQuery(from: text) { params["query"] = q }
        case "set_reminder":
            params["text"] = text
        default: break
        }
        return params
    }

    // MARK: - English extractors (legacy — solo per ML fallback)

    private func extractName(from text: String) -> String? {
        let triggers = ["to ", "call ", "message ", "text ", "email ", "from ", "with "]
        for trigger in triggers {
            if let range = text.range(of: trigger) {
                var remainder = String(text[range.upperBound...]).trimmingCharacters(in: .whitespaces)
                for p in ["on whatsapp","on telegram","on imessage","saying","that"] {
                    if let r = remainder.range(of: " " + p) { remainder = String(remainder[..<r.lowerBound]) }
                }
                let name = remainder.components(separatedBy: " ").prefix(2).joined(separator: " ")
                if name.count > 1 { return name }
            }
        }
        return nil
    }

    private func extractBody(from text: String) -> String? {
        let triggers = ["saying ", "that says ", "tell him ", "tell her ", "with the message "]
        for t in triggers {
            if let range = text.range(of: t) {
                return String(text[range.upperBound...]).trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }

    private func extractPlatform(from text: String) -> String? {
        let lower = text.lowercased()
        if lower.contains("whatsapp") || lower.contains("wa") { return "whatsapp" }
        if lower.contains("telegram") { return "telegram" }
        if lower.contains("imessage") || lower.contains("sms") { return "imessage" }
        return nil
    }

    private func extractTime(from text: String) -> String? {
        let patterns = ["at\\s+(\\d{1,2}:\\d{2})\\s*(am|pm)?",
                        "at\\s+(\\d{1,2})\\s*(am|pm)",
                        "(\\d{1,2}:\\d{2})\\s*(am|pm)?"]
        for p in patterns {
            if let m = text.range(of: p, options: .regularExpression) {
                return String(text[m]).replacingOccurrences(of: "at ", with: "").trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }

    private func extractDate(from text: String) -> String? {
        if text.contains("tomorrow") { return "tomorrow" }
        if text.contains("today") { return "today" }
        for day in ["monday","tuesday","wednesday","thursday","friday","saturday","sunday"] {
            if text.contains(day) { return day }
        }
        return "today"
    }

    private func extractEventTitle(from text: String) -> String? {
        let kw = ["doctor","dentist","gym","lunch","dinner","meeting","interview","appointment"]
        return kw.first(where: { text.contains($0) })?.capitalized
    }

    private func extractDuration(from text: String) -> Int? {
        let patterns: [(String, Int)] = [("(\\d+)\\s*hour", 3600), ("(\\d+)\\s*minute", 60), ("(\\d+)\\s*second", 1)]
        for (p, mult) in patterns {
            if let m = text.range(of: p, options: .regularExpression) {
                let digits = String(text[m]).filter { $0.isNumber }
                if let n = Int(digits) { return n * mult }
            }
        }
        return nil
    }

    private func extractAppName(from text: String) -> String? {
        let apps = ["spotify","instagram","tiktok","twitter","youtube","netflix","whatsapp",
                    "telegram","uber","doordash","gmail","slack","zoom","notion","discord",
                    "snapchat","facebook","reddit","linkedin","facetime","maps","waze"]
        return apps.first(where: { text.lowercased().contains($0) })?.capitalized
    }

    private func extractDestination(from text: String) -> String? {
        let triggers = [
            "take me to ", "navigate to ", "directions to ", "go to ", "get me to ",
            "drive to ", "head to ",
        ]
        for t in triggers {
            if let range = text.range(of: t) {
                return String(text[range.upperBound...]).trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }

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
        print("GIGI Entities: \(entities)")
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
