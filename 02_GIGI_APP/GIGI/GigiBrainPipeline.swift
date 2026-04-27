import Foundation

// MARK: - GigiBrainPipeline
//
// Owns the 4-level response cascade:
//   0. Gemini Live WebSocket (streaming, ~200 ms)
//   1. Apple Foundation Models (on-device, iOS 18.1+)
//   2. Gemini REST API (online, all devices)
//   3. Local rule-based NLU (offline, always works)
//
// Returns a GigiAgentResponse regardless of which level fires.

@MainActor
final class GigiBrainPipeline {
    static let shared = GigiBrainPipeline()

    private let agent   = GigiFoundationAgent.shared
    private let cloud   = GigiCloudService.shared
    private let nlu     = GigiNLUEngine.shared

    private init() {}

    // Action intents that must be executed — never handed to Gemini Live text path.
    private static let actionIntents: Set<String> = [
        "make_call", "send_message", "navigate", "navigation", "play_music", "open_app",
        "set_reminder", "create_event", "set_alarm", "set_timer", "weather", "search_web",
        "send_email", "facetime", "facetime_audio", "torch_on", "torch_off",
        "toggle_wifi", "toggle_bluetooth", "media_play_pause", "media_next", "media_previous",
        "read_calendar", "read_week_calendar", "find_free_slot", "remember", "recall", "read_email",
        "homekit_on", "homekit_off", "homekit_dim", "homekit_temp",
        "homekit_lock", "homekit_unlock", "homekit_scene",
        "read_news", "order_food", "book_restaurant",
        "ask_time", "ask_date",
    ]

    /// When local NLU is this confident, it may override a weak `respond` from on-device / cloud NLU.
    private static let localOverrideConfidence: Double = 0.70

    /// With strong extracted entities (contact, place, app), allow slightly lower NLU score to still override bad `respond`.
    private static let localOverrideWithEntityBoost: Double = 0.64

    func resolve(text: String, history: String) async -> GigiAgentResponse {

        // Pre-check: if local NLU is confident about an action intent (≥0.85),
        // skip Gemini Live (which returns plain text, not tool calls) and go straight
        // to structured brain levels. Fixes "call mom" being answered conversationally.
        let localIntent = nlu.classify(text)
        let isHighConfidenceAction = localIntent.confidence >= 0.85
            && Self.actionIntents.contains(localIntent.label)

        // Level 0: Gemini Live WebSocket — only for conversational/question turns.
        // Lazy connect: if not yet connected, trigger in background for the next request.
        if !isHighConfidenceAction, !GigiRealtimeEngine.shared.isConnected {
            GigiRealtimeEngine.shared.connect()
        }
        if !isHighConfidenceAction, GigiRealtimeEngine.shared.isConnected {
            let prompt = history.isEmpty
                ? text
                : "--- Conversation history ---\n\(history)\n--- End history ---\n\nCurrent message: \(text)"
            if let speech = await GigiRealtimeEngine.shared.sendTextAwaitingReply(
                userText: prompt,
                timeoutSeconds: 15
            ) {
                let trimmed = speech.trimmingCharacters(in: .whitespacesAndNewlines)
                let sanitized = GigiFoundationAgent.sanitizeSpeech(trimmed)
                if !sanitized.isEmpty {
                    print("GIGI brain: Realtime ✓")
                    return GigiAgentResponse(
                        action: "respond", contact: "", body: "", platform: "",
                        dest: "", query: "", app: "", taskText: "", date: "", time: "",
                        speech: sanitized, followUp: ""
                    )
                }
            }
        }

        // Level 1: Apple Foundation Models (on-device)
        if GigiFoundationAgent.isSupported {
            if let r = await agent.process(text: text, history: history) {
                let refined = refineBrainOutput(r, userText: text, localIntent: localIntent)
                print("GIGI brain: Foundation Models ✓")
                return refined
            }
        }

        // Level 2: Gemini REST API — skip for high-confidence local action intents
        if !isHighConfidenceAction, let r = await cloud.processWithGemini(text, history: history) {
            let refined = refineBrainOutput(r, userText: text, localIntent: localIntent)
            print("GIGI brain: Gemini ✓")
            return refined
        }

        // Level 3: Local offline fallback — notify user that AI is unavailable
        print("GIGI brain: local fallback")
        Task { @MainActor in
            GigiSmartOrchestrator.shared.showBanner("⚠️ Offline — limited responses", autoHideAfter: 3)
        }
        return localFallback(text: text, precomputed: localIntent)
    }

    // MARK: - Refine Foundation / Gemini with deterministic NLU

    private static func enrichIntent(_ intent: GigiIntent, with entities: GigiEntities, text: String) -> GigiIntent {
        var params = intent.params
        params["raw"] = text
        if (params["contact"] ?? "").isEmpty, let contact = entities.contacts.first {
            params["contact"] = contact
        }
        if params["date"] == nil, let date = entities.dates.first {
            params["date"] = date
        }
        if params["time"] == nil, let time = entities.times.first {
            params["time"] = time
        }
        if params["app"] == nil, let app = entities.apps.first {
            params["app"] = app
        }
        if params["destination"] == nil, let place = entities.places.first {
            params["destination"] = place
        }
        if intent.label == "create_event", params["title"] == nil {
            params["title"] = (entities.topics.first ?? "Event").capitalized
        }
        return GigiIntent(label: intent.label, confidence: intent.confidence, params: params)
    }

    /// Named places / contacts / apps from NLTagger — helps rescue when the on-device LLM under-fills slots.
    private func entityBoostEligible(_ entities: GigiEntities, enriched: GigiIntent) -> Bool {
        guard enriched.label != "ask_cloud", enriched.label != "respond" else { return false }
        guard Self.actionIntents.contains(enriched.label) || enriched.label == "navigation" else { return false }
        if !entities.contacts.isEmpty || !entities.places.isEmpty || !entities.apps.isEmpty { return true }
        if !entities.times.isEmpty, ["create_event", "set_alarm", "set_reminder", "find_free_slot", "book_restaurant"].contains(enriched.label) {
            return true
        }
        return false
    }

    /// When Apple Intelligence or Gemini returns a generic `respond` but local rules/ML are sure of an action,
    /// prefer the structured local intent. When both agree on the action, merge missing slots (e.g. contact name).
    private func refineBrainOutput(_ brain: GigiAgentResponse, userText: String, localIntent: GigiIntent) -> GigiAgentResponse {
        let base = GigiFoundationAgent.normalizedResponse(brain)
        let entities = nlu.extractEntities(from: userText)
        let enriched = Self.enrichIntent(localIntent, with: entities, text: userText)

        if enriched.label == "ask_cloud" {
            return mergeBrainParamsIfSameAction(base, enriched: enriched, userText: userText)
        }

        let entityBoost = entityBoostEligible(entities, enriched: enriched)
        let threshold = entityBoost ? Self.localOverrideWithEntityBoost : Self.localOverrideConfidence

        let localStrong = enriched.confidence >= threshold
            && (Self.actionIntents.contains(enriched.label) || enriched.label == "navigation")

        let brainWeak = base.action == "respond" || base.action.isEmpty

        if localStrong && brainWeak {
            return responseFromEnrichedIntent(enriched, userText: userText)
        }

        return mergeBrainParamsIfSameAction(base, enriched: enriched, userText: userText)
    }

    private func mergeBrainParamsIfSameAction(
        _ brain: GigiAgentResponse,
        enriched: GigiIntent,
        userText: String
    ) -> GigiAgentResponse {
        let canonBrain = GigiFoundationAgent.canonicalizeAction(brain.action)
        var localAction = enriched.label == "navigation" ? "navigate" : enriched.label
        localAction = GigiFoundationAgent.canonicalizeAction(localAction)

        guard canonBrain == localAction || (canonBrain == "navigate" && enriched.label == "navigation") else {
            return brain
        }

        let p = enriched.params
        func pick(_ b: String, _ key: String) -> String {
            let v = p[key] ?? ""
            if b.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !v.isEmpty { return v }
            return b
        }

        let mergedTask: String = {
            if !brain.taskText.isEmpty { return brain.taskText }
            return p["text"] ?? p["title"] ?? p["restaurant"] ?? ""
        }()

        return GigiAgentResponse(
            action:   brain.action,
            contact:  pick(brain.contact, "contact"),
            body:     pick(brain.body, "body"),
            platform: pick(brain.platform, "platform"),
            dest:     pick(brain.dest, "destination"),
            query:    pick(brain.query, "query"),
            app:      pick(brain.app, "app"),
            taskText: mergedTask,
            date:     pick(brain.date, "date"),
            time:     pick(brain.time, "time"),
            speech:   brain.speech.isEmpty ? Self.localSpeech(for: GigiIntent(label: enriched.label, confidence: enriched.confidence, params: p)) : brain.speech,
            followUp: brain.followUp
        )
    }

    private func responseFromEnrichedIntent(_ enriched: GigiIntent, userText: String) -> GigiAgentResponse {
        let label: String = {
            if enriched.label == "navigation" { return "navigate" }
            return GigiFoundationAgent.canonicalizeAction(enriched.label)
        }()

        var params = enriched.params
        params["raw"] = userText
        let intent = GigiIntent(label: label, confidence: enriched.confidence, params: params)

        return GigiAgentResponse(
            action:   label,
            contact:  intent.params["contact"]     ?? "",
            body:     intent.params["body"]        ?? "",
            platform: intent.params["platform"]    ?? "",
            dest:     intent.params["destination"] ?? "",
            query:    intent.params["query"]       ?? "",
            app:      intent.params["app"]         ?? "",
            taskText: intent.params["text"]        ?? intent.params["title"] ?? intent.params["restaurant"] ?? "",
            date:     intent.params["date"]        ?? "",
            time:     intent.params["time"]        ?? "",
            speech:   Self.localSpeech(for: intent),
            followUp: ""
        )
    }

    // MARK: - Level 3 implementation

    private func localFallback(text: String, precomputed: GigiIntent) -> GigiAgentResponse {
        let intent   = precomputed   // reuse already-classified intent from resolve()
        let entities = nlu.extractEntities(from: text)
        let enriched = Self.enrichIntent(intent, with: entities, text: text)

        // Low confidence → safe respond instead of random action
        let resolved = enriched.confidence < 0.70
            ? GigiIntent(label: "respond", confidence: enriched.confidence, params: enriched.params)
            : enriched

        return GigiAgentResponse(
            action:   resolved.label,
            contact:  resolved.params["contact"]     ?? "",
            body:     resolved.params["body"]        ?? "",
            platform: resolved.params["platform"]    ?? "",
            dest:     resolved.params["destination"] ?? "",
            query:    resolved.params["query"]       ?? "",
            app:      resolved.params["app"]         ?? "",
            taskText: resolved.params["text"]        ?? "",
            date:     resolved.params["date"]        ?? "",
            time:     resolved.params["time"]        ?? "",
            speech:   Self.localSpeech(for: resolved),
            followUp: ""
        )
    }

    static func localSpeech(for intent: GigiIntent) -> String {
        let contact = intent.params["contact"]     ?? ""
        let dest    = intent.params["destination"] ?? ""
        let query   = intent.params["query"]       ?? ""
        let app     = intent.params["app"]         ?? ""

        switch intent.label {
        case "make_call":
            return contact.isEmpty ? "Who do you want to call?" : "Calling \(contact)."
        case "send_message":
            let platform = (intent.params["platform"] ?? "iMessage").capitalized
            return contact.isEmpty ? "Who should I message?" : "Messaging \(contact) on \(platform)."
        case "navigate", "navigation":
            return dest.isEmpty ? "Where do you want to go?" : "Opening Maps to \(dest)."
        case "play_music":
            return query.isEmpty ? "Opening your music." : "Playing \(query)."
        case "open_app":
            return app.isEmpty ? "Which app?" : "Opening \(app)."
        case "set_reminder":   return "Reminder set."
        case "create_event":   return "Adding that to your calendar."
        case "set_alarm":      return "Setting your alarm."
        case "set_timer":      return "Timer started."
        case "weather":        return "Checking the weather."
        case "torch_on":       return "Flashlight on."
        case "torch_off":      return "Flashlight off."
        case "toggle_wifi":    return "Opening Wi-Fi settings."
        case "toggle_bluetooth": return "Opening Bluetooth settings."
        case "ask_time":
            let f = DateFormatter(); f.locale = Locale(identifier: "en-US"); f.dateFormat = "h:mm a"
            return "It's \(f.string(from: Date()))."
        case "ask_date":
            let f = DateFormatter(); f.locale = Locale(identifier: "en-US"); f.dateStyle = .full
            return "Today is \(f.string(from: Date()))."
        case "ask_cloud":      return "I need internet to answer that."
        case "facetime":
            return contact.isEmpty ? "Who do you want to FaceTime?" : "Starting FaceTime with \(contact)."
        case "facetime_audio":
            return contact.isEmpty ? "Who do you want to call?" : "FaceTime audio with \(contact)."
        case "media_play_pause": return "Done."
        case "media_next":       return "Next track."
        case "media_previous":   return "Previous track."
        case "read_calendar":    return "Checking your calendar."
        case "read_week_calendar": return "Checking this week's schedule."
        case "read_email":       return "Opening your inbox."
        case "find_free_slot":   return "Looking for a free slot."
        case "search_web":
            return query.isEmpty ? "What do you want to search?" : "Searching for \(query)."
        case "send_email":
            return contact.isEmpty ? "Who should I email?" : "Opening email to \(contact)."
        case "remember":         return "Got it — I'll remember that."
        case "recall":           return "One moment."
        case "read_news":        return query.isEmpty ? "Let me check the news." : "Fetching news about \(query)."
        case "order_food":
            let rest = intent.params["restaurant"] ?? ""
            return rest.isEmpty ? "Checking delivery options." : "Looking for delivery from \(rest)."
        case "book_restaurant":
            let rest = intent.params["restaurant"] ?? ""
            return rest.isEmpty ? "Let me book that." : "Booking a table at \(rest)."
        case "homekit_on":       return "Turning it on."
        case "homekit_off":      return "Turning it off."
        case "homekit_dim":      return "Adjusting brightness."
        case "homekit_temp":     return "Setting the thermostat."
        case "homekit_lock":     return "Locking the door."
        case "homekit_unlock":   return "Unlocking the door."
        case "homekit_scene":    return "Activating scene."
        case "respond":
            let lower = (intent.params["raw"] ?? "").lowercased()
            if lower.contains("hello") || lower.contains("hey") || lower.hasPrefix("hi") {
                return "Hey! What can I do for you?"
            }
            if lower.contains("thank") { return "Anytime." }
            if lower.contains("how are you") { return "Running at full speed. What do you need?" }
            return "I'm here — what do you need?"
        default:
            return "I'm not sure how to do that yet."
        }
    }
}
