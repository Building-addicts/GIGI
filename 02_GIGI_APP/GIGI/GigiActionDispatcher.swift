import Foundation

// MARK: - GigiToolCall
//
// Generic tool/function call structure used by the agent loop and on-device
// tool dispatcher. Originally lived in GigiRealtimeEngine.swift (Gemini Live
// schema) but the type itself is provider-agnostic — kept here after Gemini
// removal (ADR-0004) since `mapToolCall` and the +Native extension still
// consume it.

struct GigiToolCall: Sendable {
    let name: String
    let args: [String: String]
    let callId: String
}

// MARK: - GigiActionDispatcher
//
// Translates a GigiAgentResponse / GigiToolCall into a concrete action and executes it
// via GigiActionBridge or GigiMemory. Separated from the orchestrator to keep
// GigiSmartOrchestrator focused on conversation flow only.

@MainActor
final class GigiActionDispatcher {
    static let shared = GigiActionDispatcher()

    let bridge      = GigiActionBridge.shared
    private let speech      = GigiSpeechService.shared
    private let longMemory  = GigiMemory.shared
    private let memory      = GigiConversationMemory.shared

    private init() {}

    // MARK: - Execute from AgentResponse

    func execute(_ response: GigiAgentResponse) async {
        let intent = response.toIntent()
        print("GIGI exec: \(intent.label) | \(intent.params.filter { $0.key != "raw" })")

        switch intent.label {
        case "remember":
            await GigiLiveActivityController.shared.transitionToExecuting(message: "Saving...")
            let contact = intent.params["contact"] ?? ""
            let rawBody = intent.params["body"] ?? intent.params["text"] ?? intent.params["raw"] ?? ""
            if let (key, value) = GigiMemory.parseRememberKeyValue(contact: contact, body: rawBody) {
                await longMemory.remember(key: key, value: value)
            }

        case "recall":
            await GigiLiveActivityController.shared.transitionToExecuting(message: "Searching memory...")
            let query = intent.params["query"] ?? intent.params["contact"] ?? intent.params["raw"] ?? ""
            if let value = await longMemory.recallResolving(query) {
                memory.addGigi(value)
                speech.speak(value)
            } else {
                let r = "I don't have anything saved for that."
                memory.addGigi(r)
                speech.speak(r)
            }

        case "read_news":
            await GigiLiveActivityController.shared.transitionToExecuting(message: "Fetching news...")
            let newsResult = await bridge.execute(intent)
            if !newsResult.isEmpty {
                memory.addGigi(newsResult)
                speech.speak(newsResult)
            }

        case "order_food", "book_restaurant":
            let capMsg = intent.label == "order_food" ? "Checking delivery apps..." : "Booking table..."
            await GigiLiveActivityController.shared.transitionToExecuting(message: capMsg)
            let actionResult = await bridge.execute(intent)
            if !actionResult.isEmpty {
                memory.addGigi(actionResult)
                speech.speak(actionResult)
            }

        default:
            await GigiLiveActivityController.shared.transitionToExecuting(message: caption(for: intent))
            let result = await bridge.execute(intent)
            if intent.label == "make_call", result.hasPrefix("Calling ") {
                let c = intent.params["contact"] ?? ""
                if !c.isEmpty { await longMemory.touchContactIfKnown(c) }
            }
            if !result.isEmpty && result != response.speech {
                memory.addGigi(result)
            }
        }
    }

    // MARK: - Caption for Live Activity

    private func caption(for intent: GigiIntent) -> String {
        switch intent.label {
        case "make_call":        return "Calling..."
        case "send_message":     return "Sending message..."
        case "navigation", "navigate": return "Opening Maps..."
        case "play_music":       return "Playing music..."
        case "open_app":         return "Opening app..."
        case "set_reminder":     return "Setting reminder..."
        case "create_event":     return "Adding to calendar..."
        case "set_alarm":        return "Setting alarm..."
        case "set_timer":        return "Starting timer..."
        case "weather":          return "Checking weather..."
        case "read_email":       return "Opening email..."
        case "search_web":       return "Searching..."
        case "facetime", "facetime_audio": return "Starting FaceTime..."
        case "read_news":        return "Fetching news..."
        case "order_food":       return "Checking delivery apps..."
        case "book_restaurant":  return "Booking table..."
        default:                 return "Working on it..."
        }
    }

    // MARK: - Tool call → GigiIntent mapper

    static func mapToolCall(_ call: GigiToolCall) -> GigiIntent {
        let a = call.args

        switch call.name {
        case "make_call":
            return GigiIntent(label: "make_call", confidence: 0.99, params: ["contact": a["contact"] ?? ""])

        case "send_whatsapp":
            return GigiIntent(label: "send_message", confidence: 0.99, params: [
                "contact":  a["contact"] ?? "",
                "body":     a["message"] ?? a["body"] ?? "",
                "platform": "whatsapp",
            ])

        case "send_message":
            return GigiIntent(label: "send_message", confidence: 0.99, params: [
                "contact":  a["contact"] ?? "",
                "body":     a["message"] ?? a["body"] ?? "",
                "platform": a["platform"] ?? "imessage",
            ])

        case "navigate":
            return GigiIntent(label: "navigation", confidence: 0.99, params: ["destination": a["destination"] ?? ""])

        case "set_timer":
            let dur = a["duration"] ?? a["text"] ?? ""
            return GigiIntent(label: "set_timer", confidence: 0.99, params: ["text": dur, "raw": dur])

        case "set_alarm":
            return GigiIntent(label: "set_alarm", confidence: 0.99, params: [
                "time": a["time"] ?? "",
                "date": a["date"] ?? "today",
            ])

        case "set_reminder":
            return GigiIntent(label: "set_reminder", confidence: 0.99, params: [
                "text": a["text"] ?? a["raw"] ?? "",
                "raw":  a["text"] ?? "",
            ])

        case "play_music":
            return GigiIntent(label: "play_music", confidence: 0.99, params: [
                "query": a["query"] ?? "",
                "app":   a["app"]   ?? "",
            ])

        case "open_app":
            return GigiIntent(label: "open_app", confidence: 0.99, params: ["app": a["app"] ?? ""])

        case "torch_on", "torch_off":
            return GigiIntent(label: call.name, confidence: 0.99, params: ["raw": ""])

        case "weather":
            let loc = a["location"] ?? a["query"] ?? ""
            return GigiIntent(label: "weather", confidence: 0.99, params: ["destination": loc, "query": loc])

        case "read_calendar":
            return GigiIntent(label: "read_calendar", confidence: 0.99, params: ["raw": ""])

        case "create_event":
            return GigiIntent(label: "create_event", confidence: 0.99, params: [
                "title": a["title"] ?? "",
                "date":  a["date"]  ?? "today",
                "time":  a["time"]  ?? "12:00",
            ])

        case "web_action":
            let parts = [a["site"], a["action"], a["params"]].compactMap { s -> String? in
                guard let s, !s.isEmpty else { return nil }; return s
            }
            let q = parts.joined(separator: " ")
            return GigiIntent(label: "search_web", confidence: 0.9, params: ["query": q, "raw": q])

        case "remember":
            return GigiIntent(label: "remember", confidence: 0.99, params: [
                "contact": a["key"]   ?? "",
                "body":    a["value"] ?? "",
            ])

        case "recall":
            return GigiIntent(label: "recall", confidence: 0.99, params: ["query": a["key"] ?? ""])

        case "ask_time":
            return GigiIntent(label: "ask_time", confidence: 0.99, params: ["raw": ""])

        case "ask_date":
            return GigiIntent(label: "ask_date", confidence: 0.99, params: ["raw": ""])

        case "homekit_on", "homekit_off":
            return GigiIntent(label: call.name, confidence: 0.99, params: ["accessory": a["accessory"] ?? ""])

        case "homekit_dim":
            return GigiIntent(label: "homekit_dim", confidence: 0.99, params: [
                "accessory":  a["accessory"]  ?? "",
                "brightness": a["brightness"] ?? "50",
            ])

        case "homekit_temp":
            return GigiIntent(label: "homekit_temp", confidence: 0.99, params: ["temperature": a["temperature"] ?? "21"])

        case "homekit_lock", "homekit_unlock":
            return GigiIntent(label: call.name, confidence: 0.99, params: ["accessory": a["accessory"] ?? ""])

        case "homekit_scene":
            return GigiIntent(label: "homekit_scene", confidence: 0.99, params: [
                "scene": a["scene"] ?? "",
                "raw":   a["scene"] ?? "",
            ])

        case "toggle_wifi":
            return GigiIntent(label: "toggle_wifi", confidence: 0.99, params: ["raw": ""])

        case "toggle_bluetooth":
            return GigiIntent(label: "toggle_bluetooth", confidence: 0.99, params: ["raw": ""])

        case "read_week_calendar":
            return GigiIntent(label: "read_week_calendar", confidence: 0.99, params: ["raw": ""])

        case "find_free_slot":
            return GigiIntent(label: "find_free_slot", confidence: 0.99, params: [
                "duration":  a["duration"]       ?? "60",
                "preferred": a["preferred_time"] ?? a["time"] ?? "",
            ])

        default:
            return GigiIntent(label: call.name, confidence: 0.5, params: a)
        }
    }
}
