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

            case "scroll":
                let delta = action.direction == "up" ? -500 : 500
                try? await js("window.scrollBy(0, \(delta))")

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
              .replace(/\\s+/g,' ').slice(0,50);
            const testid=el.getAttribute('data-testid')||'';
            const id=el.id?'#'+el.id:'';
            const tag=el.tagName.toLowerCase();
            const type=el.type||'';
            const name=el.name||'';
            const href=tag==='a'?(el.getAttribute('href')||'').slice(0,60):'';
            if(text||id||testid)
              els.push({tag,text,id,testid,type,name,href});
          });
          return JSON.stringify(els.slice(0,60));
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
        guard let jpeg = screenshot.jpegData(compressionQuality: 0.45) else {
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
            "max_tokens":  300,
            "temperature": 0.05
        ]

        var req = URLRequest(url: URL(string: "https://api.groq.com/openai/v1/chat/completions")!)
        req.httpMethod = "POST"
        req.setValue("application/json",  forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.timeoutInterval = 25
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: req)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            let raw = String(data: data, encoding: .utf8) ?? ""
            throw GigiWebAgentError.jsError("HTTP \(http.statusCode): \(raw.prefix(300))")
        }

        return try parseVisionResponse(data: data)
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
        DOM elements (up to 60): \(domJSON)
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
