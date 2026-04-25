import Foundation
import UIKit
import WebKit

// MARK: - VisionAction
// JSON schema returned by the Groq vision model each step.

struct VisionAction: Decodable {
    let action:    String          // click | type | scroll | navigate | fill_form | done | error
    let selector:  String?
    let text:      String?
    let url:       String?
    let direction: String?         // up | down (for scroll)
    let reason:    String?
    let message:   String?
}

// MARK: - GigiWebAgent + Vision loop

@MainActor
extension GigiWebAgent {

    // MARK: - Public API

    /// Navigate to `url` (optional — skip if nil to operate on current page),
    /// then drive the page autonomously using Groq vision until the task is done
    /// or `maxSteps` is reached.
    ///
    /// Returns a human-readable result string (success message or error).
    @discardableResult
    func executeWithVision(url: URL? = nil, task: String, maxSteps: Int = 8) async -> String {
        if let url {
            do {
                print("GIGI Vision: navigating to \(url.host ?? url.absoluteString)")
                try await navigate(to: url, timeout: 20)
            } catch {
                return "Navigation failed: \(error.localizedDescription)"
            }
            try? await Task.sleep(nanoseconds: 1_500_000_000)
        }

        let profileCtx = await GigiUserProfile.shared.formContext()
        var lastActionSignature = ""
        var repeatedActionCount = 0

        for step in 1...maxSteps {
            // Screenshot
            guard let img = await snapshotWebView() else {
                return "Screenshot unavailable at step \(step)"
            }

            // Simplified DOM for selector grounding
            let dom = (try? await js(domExtractionScript)) as? String ?? "[]"

            // Ask vision model
            let action: VisionAction
            do {
                action = try await groqVisionAction(
                    screenshot: img,
                    task: task,
                    step: step,
                    domJSON: dom,
                    profileContext: profileCtx
                )
            } catch {
                print("GIGI Vision: model error at step \(step) — \(error)")
                return "Vision model error: \(error.localizedDescription)"
            }

            print("GIGI Vision step \(step)/\(maxSteps): \(action.action) — \(action.reason ?? action.message ?? "")")

            let signature = actionSignature(action)
            repeatedActionCount = signature == lastActionSignature ? repeatedActionCount + 1 : 0
            lastActionSignature = signature

            if repeatedActionCount >= 2 {
                print("GIGI Vision: repeated action loop detected — trying recovery")
                if action.action == "type", let selector = action.selector {
                    try? await pressEnter(in: selector)
                } else {
                    _ = try? await js("window.scrollBy(0, 450)")
                }
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                continue
            }

            switch action.action {

            case "done":
                return action.message ?? "Task completed successfully"

            case "error":
                return action.message ?? "Task failed"

            case "click":
                guard let sel = action.selector else { continue }
                try? await click(sel)

            case "type":
                guard let sel = action.selector, let text = action.text else { continue }
                try? await type(text, into: sel)
                if shouldSubmitTypedSearch(action: action, task: task) {
                    try? await Task.sleep(nanoseconds: 250_000_000)
                    try? await pressEnter(in: sel)
                }

            case "scroll":
                let delta = action.direction == "up" ? -500 : 500
                _ = try? await js("window.scrollBy(0, \(delta))")

            case "navigate":
                guard let urlStr = action.url, let dest = URL(string: urlStr) else { continue }
                do { try await navigate(to: dest, timeout: 15) } catch { continue }

            case "fill_form":
                await injectProfileIntoForm()

            default:
                print("GIGI Vision: unknown action '\(action.action)'")
                continue
            }

            // Let the page settle before next screenshot
            try? await Task.sleep(nanoseconds: 1_200_000_000)
        }

        return "Reached step limit (\(maxSteps)) without completing: \(task)"
    }

    private func actionSignature(_ action: VisionAction) -> String {
        [
            action.action,
            action.selector ?? "",
            action.text ?? "",
            action.url ?? "",
            action.direction ?? ""
        ].joined(separator: "|").lowercased()
    }

    private func shouldSubmitTypedSearch(action: VisionAction, task: String) -> Bool {
        let haystack = [
            action.reason ?? "",
            action.selector ?? "",
            action.text ?? "",
            task
        ].joined(separator: " ").lowercased()

        return haystack.contains("search")
            || haystack.contains("cerca")
            || haystack.contains("pizza")
            || haystack.contains("restaurant")
            || haystack.contains("ristorante")
    }

    // MARK: - Screenshot

    func snapshotWebView() async -> UIImage? {
        await withCheckedContinuation { cont in
            let cfg = WKSnapshotConfiguration()
            webView.takeSnapshot(with: cfg) { image, _ in cont.resume(returning: image) }
        }
    }

    // MARK: - Form auto-fill

    func injectProfileIntoForm() async {
        let p = await GigiUserProfile.shared.load()
        let fields: [(String, String)] = [
            // First name
            (
                "input[name='firstName' i],input[id='firstName' i]," +
                "input[name='first_name' i],input[placeholder*='first name' i]," +
                "input[placeholder*='nome' i]:not([placeholder*='cognome' i])",
                p.firstName
            ),
            // Last name
            (
                "input[name='lastName' i],input[id='lastName' i]," +
                "input[name='last_name' i],input[placeholder*='last name' i]," +
                "input[placeholder*='cognome' i]",
                p.lastName
            ),
            // Full name (if no first/last split)
            (
                "input[name='name' i]:not([name*='first' i]):not([name*='last' i])," +
                "input[id='name' i],input[placeholder='Name']",
                p.name
            ),
            // Email
            ("input[type='email'],input[name*='email' i]", p.email),
            // Phone
            ("input[type='tel'],input[name*='phone' i],input[name*='mobile' i]", p.phone),
            // Street address
            (
                "input[name*='address' i]:not([name*='2' i]):not([name*='line2' i])," +
                "input[name*='street' i],input[id*='address1' i]",
                p.deliveryAddress
            ),
            // City
            ("input[name*='city' i],input[id*='city' i]", p.city),
            // Zip / postal
            ("input[name*='zip' i],input[name*='postal' i],input[name*='cap' i]", p.zip),
            // State
            ("input[name*='state' i],input[id*='state' i]", p.state),
        ]
        for (sel, val) in fields where !val.isEmpty {
            try? await type(val, into: sel)
            try? await Task.sleep(nanoseconds: 150_000_000)
        }
    }

    // MARK: - DOM extraction (selector grounding)

    private var domExtractionScript: String {
        """
        (function(){
          const els=[];
          document.querySelectorAll(
            'a[href],button,input,select,textarea,[role="button"],[data-testid],[data-id]'
          ).forEach(function(el){
            const text=(el.textContent||el.value||el.placeholder||'').trim()
              .replace(/\\s+/g,' ').slice(0,40);
            const testid=el.getAttribute('data-testid')||'';
            const id=el.id?'#'+el.id:'';
            const tag=el.tagName.toLowerCase();
            const type=el.type||'';
            const name=el.name||'';
            const href=tag==='a'?(el.getAttribute('href')||'').slice(0,60):'';
            if(text||id||testid)
              els.push({tag,text,id,testid,type,name,href});
          });
          return JSON.stringify(els.slice(0,35));
        })()
        """
    }

    // MARK: - Groq vision call

    private func groqVisionAction(
        screenshot: UIImage,
        task: String,
        step: Int,
        domJSON: String,
        profileContext: String
    ) async throws -> VisionAction {
        let compactScreenshot = screenshot.resizedForVision(maxSide: 720)
        guard let jpeg = compactScreenshot.jpegData(compressionQuality: 0.28) else {
            throw GigiWebAgentError.jsError("JPEG encoding failed")
        }
        let apiKey = GigiConfig.groqAPIKey
        guard !apiKey.isEmpty else { throw GigiWebAgentError.jsError("Groq API key not set") }

        let b64 = jpeg.base64EncodedString()

        let systemPrompt = buildVisionSystemPrompt(domJSON: domJSON, profileContext: profileContext)
        let userText = "Step \(step). Task: \(task)\nWhat is the single next action to take?"

        let messages: [[String: Any]] = [
            ["role": "system", "content": systemPrompt],
            ["role": "user", "content": [
                ["type": "text", "text": userText],
                ["type": "image_url", "image_url": ["url": "data:image/jpeg;base64,\(b64)"]]
            ]]
        ]

        let body: [String: Any] = [
            "model":       "meta-llama/llama-4-scout-17b-16e-instruct",
            "messages":    messages,
            "max_tokens":  180,
            "temperature": 0.05
        ]

        var req = URLRequest(url: URL(string: "https://api.groq.com/openai/v1/chat/completions")!)
        req.httpMethod = "POST"
        req.setValue("application/json",  forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.timeoutInterval = 25
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        var lastRateLimitBody = ""
        for attempt in 0..<3 {
            let (data, response) = try await URLSession.shared.data(for: req)
            if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                let raw = String(data: data, encoding: .utf8) ?? ""
                if http.statusCode == 429, attempt < 2 {
                    lastRateLimitBody = raw
                    let waitSeconds = retryDelaySeconds(from: raw)
                    print("GIGI Vision: Groq 429 — retrying in \(String(format: "%.1f", waitSeconds))s")
                    try? await Task.sleep(nanoseconds: UInt64(waitSeconds * 1_000_000_000))
                    continue
                }
                throw GigiWebAgentError.jsError("HTTP \(http.statusCode): \(raw.prefix(300))")
            }
            recordGroqVisionUsage(from: data)
            return try parseVisionResponse(data: data)
        }

        throw GigiWebAgentError.jsError("HTTP 429: \(lastRateLimitBody.prefix(300))")
    }

    private func retryDelaySeconds(from raw: String) -> Double {
        let pattern = #"try again in ([0-9]+(?:\.[0-9]+)?)s"#
        if let range = raw.range(of: pattern, options: .regularExpression) {
            let match = String(raw[range])
            if let valueRange = match.range(of: #"[0-9]+(?:\.[0-9]+)?"#, options: .regularExpression),
               let seconds = Double(match[valueRange]) {
                return min(max(seconds + 0.75, 1.5), 8.0)
            }
        }
        return 4.0
    }

    private func recordGroqVisionUsage(from data: Data) {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let usage = json["usage"] as? [String: Any] else {
            GigiAPIKeyUsageStore.record(provider: "groq")
            return
        }
        let input = (usage["prompt_tokens"] as? Int)
            ?? (usage["input_tokens"] as? Int)
            ?? 0
        let output = (usage["completion_tokens"] as? Int)
            ?? (usage["output_tokens"] as? Int)
            ?? 0
        GigiAPIKeyUsageStore.record(provider: "groq", inputTokens: input, outputTokens: output)
    }

    private func buildVisionSystemPrompt(domJSON: String, profileContext: String) -> String {
        var prompt = """
        You are a web automation agent operating a hidden browser. Analyze the screenshot and \
        return exactly ONE JSON action to progress toward the task. Return ONLY valid JSON — \
        no markdown fences, no explanation.

        Available actions:
        {"action":"click","selector":"CSS_SELECTOR","reason":"..."}
        {"action":"type","selector":"CSS_SELECTOR","text":"TEXT","reason":"..."}
        {"action":"scroll","direction":"down","reason":"..."}
        {"action":"navigate","url":"FULL_URL","reason":"..."}
        {"action":"fill_form","reason":"fill all visible form fields with user profile data"}
        {"action":"done","message":"what was accomplished"}
        {"action":"error","message":"why the task cannot be completed"}

        Use exact CSS selectors from the DOM list below when possible.
        Do not repeat the same type action if text is already present. If a search field has
        been filled, click the matching result/button or continue with the next step.
        For checkout/order/payment tasks, stop before final payment or final order submission
        and return {"action":"done","message":"CONFIRM_REQUIRED: ..."} with a concise summary.
        DOM elements (up to 35): \(domJSON)
        """
        if !profileContext.isEmpty {
            prompt += "\n\n\(profileContext)"
        }
        return prompt
    }

    private func parseVisionResponse(data: Data) throws -> VisionAction {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let first = choices.first,
              let message = first["message"] as? [String: Any],
              let content = message["content"] as? String
        else { throw GigiWebAgentError.jsError("Malformed Groq response") }

        // Strip markdown fences the model occasionally adds
        var raw = content.trimmingCharacters(in: .whitespacesAndNewlines)
        if raw.hasPrefix("```") {
            raw = raw
                .replacingOccurrences(of: "^```(?:json)?\\n?", with: "", options: .regularExpression)
                .replacingOccurrences(of: "\\n?```$",           with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        guard let actionData = raw.data(using: .utf8),
              let action = try? JSONDecoder().decode(VisionAction.self, from: actionData)
        else {
            // Heuristic salvage
            let lower = raw.lowercased()
            if lower.contains("done") || lower.contains("complet") || lower.contains("success") {
                return VisionAction(action: "done", selector: nil, text: nil,
                                    url: nil, direction: nil, reason: nil, message: raw)
            }
            throw GigiWebAgentError.jsError("Cannot parse vision action: \(raw.prefix(120))")
        }

        return action
    }
}

private extension UIImage {
    func resizedForVision(maxSide: CGFloat) -> UIImage {
        let longest = max(size.width, size.height)
        guard longest > maxSide, longest > 0 else { return self }

        let scale = maxSide / longest
        let newSize = CGSize(width: size.width * scale, height: size.height * scale)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: newSize, format: format).image { _ in
            draw(in: CGRect(origin: .zero, size: newSize))
        }
    }
}
