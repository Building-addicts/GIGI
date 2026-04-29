import Foundation
import UIKit

// MARK: - GigiActionDispatcher v3 native path
//
// executeNative is the entry point for all GigiToolRegistry tool structs.
// It adds: parameter validation, contact disambiguation, foreground guard,
// then delegates to GigiActionBridge via the existing mapToolCall path.

extension GigiActionDispatcher {

    // MARK: - Main entry

    func executeNative(_ toolName: String, args: [String: Any]) async -> ToolResult {

        // 1. Foreground guard for tools that open UI / Settings
        if requiresForeground(toolName), !isAppInForeground() {
            return .failure("App must be in foreground to use \(toolName). Open GIGI first.")
        }

        // 2. Contact disambiguation for communication tools
        if let disambig = await disambiguationResult(toolName: toolName, args: args) {
            return disambig
        }

        // 3. Route by category
        switch category(for: toolName) {
        case .communication:  return await handleCommunication(toolName, args: args)
        case .calendar:       return await handleCalendar(toolName, args: args)
        case .media:          return await handleMedia(toolName, args: args)
        case .memory:         return await handleMemory(toolName, args: args)
        case .system:         return await handleSystem(toolName, args: args)
        case .homeKit:        return await handleHomeKit(toolName, args: args)
        case .web:            return await handleWeb(toolName, args: args)
        case .unknown:        return await handleFallback(toolName, args: args)
        }
    }

    // MARK: - Category

    enum ToolCategory {
        case communication, calendar, media, memory, system, homeKit, web, unknown
    }

    func category(for name: String) -> ToolCategory {
        switch name {
        case "make_call", "send_message", "send_whatsapp", "send_email",
             "facetime", "facetime_audio", "navigate", "open_app":
            return .communication
        case "create_event", "set_reminder", "set_alarm", "set_timer",
             "read_calendar", "read_week_calendar", "find_free_slot":
            return .calendar
        case "play_music", "media_play_pause", "media_next", "media_previous":
            return .media
        case "remember", "recall":
            return .memory
        case "torch_on", "torch_off", "toggle_wifi", "toggle_bluetooth",
             "weather", "search_web", "ask_time", "ask_date":
            return .system
        case "homekit_on", "homekit_off", "homekit_dim", "homekit_temp",
             "homekit_lock", "homekit_unlock", "homekit_scene":
            return .homeKit
        case "web_whatsapp", "web_book_restaurant", "web_order_food",
             "web_search_and_read", "web_vision_task", "computer_use":
            return .web
        default:
            return .unknown
        }
    }

    // MARK: - Category handlers

    private func handleCommunication(_ name: String, args: [String: Any]) async -> ToolResult {
        let contact = string(args, "contact")

        switch name {
        case "make_call":
            guard !contact.isEmpty else { return .failure("contact parameter required") }
            let result = await bridge.makeCallAutomatic(to: contact)
            return .success(result)

        case "send_message":
            guard !contact.isEmpty else { return .failure("contact parameter required") }
            let body = string(args, "message", fallback: string(args, "body"))
            guard !body.isEmpty else { return .failure("message parameter required") }
            let platform = string(args, "platform", fallback: "imessage")
            let result = await bridge.sendMessageAutomatic(to: contact, body: body, platform: platform)
            return .success(result)

        case "send_whatsapp":
            guard !contact.isEmpty else { return .failure("contact parameter required") }
            let body = string(args, "message", fallback: string(args, "body"))
            guard !body.isEmpty else { return .failure("message parameter required") }
            let result = await bridge.sendMessageAutomatic(to: contact, body: body, platform: "whatsapp")
            return .success(result)

        case "send_email":
            guard !contact.isEmpty else { return .failure("contact parameter required") }
            let subject = string(args, "subject", fallback: string(args, "title"))
            let body    = string(args, "body")
            let intent  = GigiIntent(label: "send_email", confidence: 0.99, params: [
                "contact": contact, "title": subject, "body": body
            ])
            let result = await bridge.execute(intent)
            return .success(result)

        case "facetime":
            guard !contact.isEmpty else { return .failure("contact parameter required") }
            let intent = GigiIntent(label: "facetime", confidence: 0.99, params: ["contact": contact])
            let result = await bridge.execute(intent)
            return .success(result)

        case "facetime_audio":
            guard !contact.isEmpty else { return .failure("contact parameter required") }
            let intent = GigiIntent(label: "facetime_audio", confidence: 0.99, params: ["contact": contact])
            let result = await bridge.execute(intent)
            return .success(result)

        case "navigate":
            let destination = string(args, "destination")
            guard !destination.isEmpty else { return .failure("destination parameter required") }
            let result = await bridge.navigate(to: destination)
            return .success(result)

        case "open_app":
            let app = string(args, "app")
            guard !app.isEmpty else { return .failure("app parameter required") }
            let result = await bridge.openApp(app)
            return .success(result)

        default:
            return await handleFallback(name, args: args)
        }
    }

    private func handleCalendar(_ name: String, args: [String: Any]) async -> ToolResult {
        switch name {
        case "create_event":
            let title = string(args, "title")
            guard !title.isEmpty else { return .failure("title parameter required") }
            let date  = string(args, "date", fallback: "today")
            let time  = string(args, "time", fallback: "12:00")
            if string(args, "confirmation_source") == "permission_sheet" {
                let result = await bridge.execute(GigiIntent(
                    label: "create_event",
                    confidence: 0.99,
                    params: [
                        "title": title,
                        "date": date,
                        "time": time,
                        "confirmation_source": "permission_sheet",
                    ]
                ))
                return .success(result)
            }
            let result = await bridge.createEvent(title: title, date: date, time: time)
            return .success(result)

        case "set_reminder":
            let text = string(args, "text", fallback: string(args, "raw"))
            guard !text.isEmpty else { return .failure("text parameter required") }
            let result = await bridge.createReminder(text: text)
            return .success(result)

        case "set_alarm":
            let time = string(args, "time")
            guard !time.isEmpty else { return .failure("time parameter required") }
            let date = string(args, "date", fallback: "today")
            let call = GigiToolCall(name: name, args: ["time": time, "date": date], callId: "")
            return await bridgeToolCall(call)

        case "set_timer":
            let duration = string(args, "duration", fallback: string(args, "text"))
            guard !duration.isEmpty else { return .failure("duration parameter required") }
            let call = GigiToolCall(name: name, args: ["text": duration], callId: "")
            return await bridgeToolCall(call)

        case "read_calendar":
            let call = GigiToolCall(name: name, args: [:], callId: "")
            return await bridgeToolCall(call)

        case "read_week_calendar":
            let call = GigiToolCall(name: name, args: [:], callId: "")
            return await bridgeToolCall(call)

        case "find_free_slot":
            let duration  = string(args, "duration_minutes", fallback: string(args, "duration", fallback: "60"))
            let preferred = string(args, "preferred_time", fallback: string(args, "time"))
            let call = GigiToolCall(name: name, args: ["duration": duration, "preferred_time": preferred], callId: "")
            return await bridgeToolCall(call)

        default:
            return await handleFallback(name, args: args)
        }
    }

    private func handleMedia(_ name: String, args: [String: Any]) async -> ToolResult {
        let call = GigiToolCall(name: name, args: stringDict(args), callId: "")
        return await bridgeToolCall(call)
    }

    private func handleMemory(_ name: String, args: [String: Any]) async -> ToolResult {
        switch name {
        case "remember":
            let key   = string(args, "key")
            let value = string(args, "value")
            guard !key.isEmpty, !value.isEmpty else { return .failure("key and value parameters required") }
            await GigiMemory.shared.remember(key: key, value: value)
            return .success("Saved: \(key) = \(value)")

        case "recall":
            let key = string(args, "key", fallback: string(args, "query"))
            guard !key.isEmpty else { return .failure("key parameter required") }
            if let value = await GigiMemory.shared.recallResolving(key) {
                return .success(value)
            }
            return .success("Nothing saved for '\(key)'.")

        default:
            return await handleFallback(name, args: args)
        }
    }

    private func handleSystem(_ name: String, args: [String: Any]) async -> ToolResult {
        let call = GigiToolCall(name: name, args: stringDict(args), callId: "")
        return await bridgeToolCall(call)
    }

    private func handleHomeKit(_ name: String, args: [String: Any]) async -> ToolResult {
        let call = GigiToolCall(name: name, args: stringDict(args), callId: "")
        return await bridgeToolCall(call)
    }

    private func handleFallback(_ name: String, args: [String: Any]) async -> ToolResult {
        let call   = GigiToolCall(name: name, args: stringDict(args), callId: "")
        let intent = GigiActionDispatcher.mapToolCall(call)
        let result = await bridge.execute(intent)
        return result.isEmpty ? .failure("Tool '\(name)' returned no output.") : .success(result)
    }

    // MARK: - Disambiguation

    private static let contactTools: Set<String> = [
        "make_call", "send_message", "send_whatsapp", "send_email", "facetime", "facetime_audio"
    ]

    /// Returns a ToolResult with disambiguation JSON if multiple contacts match, nil otherwise.
    private func disambiguationResult(toolName: String, args: [String: Any]) async -> ToolResult? {
        guard Self.contactTools.contains(toolName) else { return nil }
        let query = string(args, "contact")
        guard !query.isEmpty else { return nil }

        let matches = await GigiContactsEngine.shared.disambiguate(query)
        guard matches.count > 1 else { return nil }

        let options = matches.map { ["name": $0.name, "phone": $0.phone] }
        let payload: [String: Any] = [
            "error":   "multiple_contacts",
            "query":   query,
            "matches": options,
        ]
        guard let data   = try? JSONSerialization.data(withJSONObject: payload),
              let jsonStr = String(data: data, encoding: .utf8) else {
            return .failure("Multiple contacts found for '\(query)'. Please be more specific.")
        }
        return ToolResult(value: jsonStr, error: "multiple_contacts", requiresConfirm: nil, tokenEstimate: 30)
    }

    // MARK: - Foreground guard

    private static let deepLinkTools: Set<String> = ["toggle_wifi", "toggle_bluetooth"]

    private func requiresForeground(_ name: String) -> Bool {
        Self.deepLinkTools.contains(name)
    }

    private func isAppInForeground() -> Bool {
        UIApplication.shared.applicationState == .active
    }

    // MARK: - Bridge helper

    private func bridgeToolCall(_ call: GigiToolCall) async -> ToolResult {
        let intent = GigiActionDispatcher.mapToolCall(call)
        let result = await bridge.execute(intent)
        return result.isEmpty ? .failure("No result from \(call.name).") : .success(result)
    }

    // MARK: - Arg helpers

    private func string(_ args: [String: Any], _ key: String, fallback: String = "") -> String {
        (args[key] as? String) ?? fallback
    }

    private func stringDict(_ args: [String: Any]) -> [String: String] {
        args.compactMapValues { $0 as? String }
    }
}
