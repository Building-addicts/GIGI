import Foundation

// MARK: - GigiActionDispatcher v3 web path
//
// handleWeb centralizes all web-automation routing:
//   web_whatsapp       → GigiWebAgent (WKWebView, on-device, free)
//   web_book_restaurant→ GigiWebAgent → ComputerUse fallback, requires confirm
//   web_order_food     → ComputerUse (Playwright backend), requires confirm
//   web_search_and_read→ GigiWebAgent.searchAndRead (Phase 4) / ComputerUse fallback
//   computer_use       → GigiComputerUse (LAST RESORT, ~$0.20/exec)

extension GigiActionDispatcher {

    // MARK: - Web router (called from executeNative)

    func handleWeb(_ toolName: String, args: [String: Any]) async -> ToolResult {
        switch toolName {
        case "web_whatsapp":         return await handleWebWhatsApp(args)
        case "web_book_restaurant":  return await handleWebBookRestaurant(args)
        case "web_order_food":       return await handleWebOrderFood(args)
        case "web_search_and_read":  return await handleWebSearchAndRead(args)
        case "web_vision_task":      return await handleWebVisionTask(args)
        case "computer_use":         return await handleComputerUse(args)
        default:                     return .failure("Unknown web tool: \(toolName)")
        }
    }

    // MARK: - WhatsApp Web

    private func handleWebWhatsApp(_ args: [String: Any]) async -> ToolResult {
        let contact = webStr(args, "contact")
        let message = webStr(args, "message")

        guard !contact.isEmpty else { return .failure("contact parameter required for web_whatsapp") }
        guard !message.isEmpty else { return .failure("message parameter required for web_whatsapp") }

        let result = await GigiWebAgent.shared.sendWhatsAppResult(contact: contact, message: message)
        switch result {
        case .success:
            return .success("Message sent to \(contact) via WhatsApp.", tokenEstimate: 20)

        case .needsQR:
            // Structured error so GigiAgentEngine can surface actionable guidance
            return ToolResult(
                value: "",
                error: "session_expired: WhatsApp Web needs QR scan. Open GIGI Settings → WhatsApp Web and scan with your phone.",
                requiresConfirm: nil,
                tokenEstimate: 10
            )

        case .failed(let reason):
            // Try ComputerUse fallback before giving up
            let fallback = await GigiComputerUse.shared.execute(
                task: "Send WhatsApp message to \(contact): \(message)"
            )
            if !fallback.hasPrefix("Computer Use not yet implemented") {
                return .success(fallback, tokenEstimate: 50)
            }
            return .failure("WhatsApp Web failed: \(reason)")
        }
    }

    // MARK: - Restaurant booking

    private func handleWebBookRestaurant(_ args: [String: Any]) async -> ToolResult {
        let restaurant = webStr(args, "restaurant")
        let time       = webStr(args, "time")
        let date       = webStr(args, "date", fallback: "today")
        let guests     = Int(webStr(args, "guests", fallback: "2")) ?? 2

        guard !restaurant.isEmpty else { return .failure("restaurant parameter required") }
        guard !time.isEmpty       else { return .failure("time parameter required") }

        let ok = await GigiWebAgent.shared.bookRestaurant(name: restaurant, time: time, guests: guests)
        if ok {
            let gLabel  = guests == 1 ? "person" : "people"
            let summary = "Book \(restaurant) for \(guests) \(gLabel) at \(time) on \(date). Confirm?"
            return .confirm(ConfirmRequest(type: .payment, summary: summary, action: "web_book_restaurant", args: args))
        }

        // WebAgent failed → try ComputerUse
        let cuTask  = "Book a table at \(restaurant) for \(guests) people at \(time) on \(date)"
        let cuResult = await GigiComputerUse.shared.execute(task: cuTask)
        if cuResult.hasPrefix("CONFIRM_REQUIRED:") {
            let summary = cuResult.replacingOccurrences(of: "CONFIRM_REQUIRED: ", with: "")
            return .confirm(ConfirmRequest(type: .payment, summary: summary, action: "web_book_restaurant", args: args))
        }
        if !cuResult.hasPrefix("Computer Use not yet implemented") {
            return .success(cuResult, tokenEstimate: 60)
        }

        return .failure("Could not book \(restaurant) online. Try a different time or call them directly.")
    }

    // MARK: - Food ordering (vision-driven)

    private func handleWebOrderFood(_ args: [String: Any]) async -> ToolResult {
        let restaurant = webStr(args, "restaurant")
        let items      = webStr(args, "items", fallback: "food")
        let platform   = webStr(args, "platform", fallback: "ubereats")

        guard !restaurant.isEmpty else { return .failure("restaurant parameter required for web_order_food") }

        // Require confirmation before placing a real order
        let summary = "Order \(items) from \(restaurant) via \(platform). Confirm?"
        return .confirm(ConfirmRequest(type: .payment, summary: summary, action: "web_order_food", args: args))
    }

    /// Called after user confirms web_order_food.
    func executeWebOrderFood(_ args: [String: Any]) async -> ToolResult {
        let restaurant = webStr(args, "restaurant")
        let items      = webStr(args, "items", fallback: "food")
        let platform   = webStr(args, "platform", fallback: "ubereats")

        // Choose platform URL
        var searchURL: URL? {
            var c = CharacterSet.urlQueryAllowed; c.remove(charactersIn: "&+?=#")
            let q = restaurant.addingPercentEncoding(withAllowedCharacters: c) ?? restaurant
            switch platform.lowercased() {
            case "doordash":  return URL(string: "https://www.doordash.com/search/store/\(q)")
            case "grubhub":   return URL(string: "https://www.grubhub.com/search?query=\(q)")
            default:          return URL(string: "https://www.ubereats.com/search?q=\(q)")
            }
        }

        let task = "Find '\(restaurant)' in the search results, open it, add '\(items)' to cart, proceed to checkout, fill in the delivery address and payment, and place the order."
        let result = await GigiWebAgent.shared.executeWithVision(url: searchURL, task: task, maxSteps: 12)
        return .success(result, tokenEstimate: 60)
    }

    // MARK: - Search and read (vision-driven)

    private func handleWebSearchAndRead(_ args: [String: Any]) async -> ToolResult {
        let query = webStr(args, "query")
        guard !query.isEmpty else { return .failure("query parameter required for web_search_and_read") }

        var c = CharacterSet.urlQueryAllowed; c.remove(charactersIn: "&+?=#")
        let q = query.addingPercentEncoding(withAllowedCharacters: c) ?? query
        guard let url = URL(string: "https://www.google.com/search?q=\(q)") else {
            return .failure("Could not build search URL")
        }

        let task = "Read the search results for '\(query)' and return a concise summary of the key information. When you have enough information, return done with a summary."
        let result = await GigiWebAgent.shared.executeWithVision(url: url, task: task, maxSteps: 4)
        return .success(result, tokenEstimate: 80)
    }

    // MARK: - Generic vision task

    private func handleWebVisionTask(_ args: [String: Any]) async -> ToolResult {
        let task    = webStr(args, "task")
        let urlStr  = webStr(args, "url")
        guard !task.isEmpty else { return .failure("task parameter required for web_vision_task") }

        let url = urlStr.isEmpty ? nil : URL(string: urlStr)
        let steps = Int(webStr(args, "max_steps", fallback: "8")) ?? 8
        let result = await GigiWebAgent.shared.executeWithVision(url: url, task: task, maxSteps: steps)
        return .success(result, tokenEstimate: 60)
    }

    // MARK: - Computer Use (last resort)

    private func handleComputerUse(_ args: [String: Any]) async -> ToolResult {
        let task = webStr(args, "task")
        guard !task.isEmpty else { return .failure("task parameter required for computer_use") }

        let result = await GigiComputerUse.shared.execute(task: task)
        if result.hasPrefix("CONFIRM_REQUIRED:") {
            let summary = result.replacingOccurrences(of: "CONFIRM_REQUIRED: ", with: "")
            return .confirm(ConfirmRequest(type: .payment, summary: summary, action: "computer_use", args: args))
        }
        return .success(result, tokenEstimate: 60)
    }

    // MARK: - Arg helper (scoped to web path)

    private func webStr(_ args: [String: Any], _ key: String, fallback: String = "") -> String {
        (args[key] as? String) ?? fallback
    }
}
