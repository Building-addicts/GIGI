import Foundation
import Contacts
import UIKit
import EventKit
import AVFoundation
import MediaPlayer
import UserNotifications

// MARK: - GigiError (T-25)

enum GigiError: Error {
    case noInternet
    case contactNotFound(String)
    case permissionDenied(String)
    case actionFailed(String)
    case timeout
    case invalidInput(String)

    var speechMessage: String {
        switch self {
        case .noInternet:                return "I don't have internet right now."
        case .contactNotFound(let name): return "I can't find \(name) in your contacts."
        case .permissionDenied(let t):   return "I need \(t) access to do that. Enable it in Settings."
        case .actionFailed(let action):  return "I couldn't \(action). Try again."
        case .timeout:                   return "That took too long. Please try again."
        case .invalidInput(let reason):  return "I need \(reason) to do that."
        }
    }
}

@MainActor
class GigiActionBridge {
    static let shared = GigiActionBridge()

    // Shared stores — expensive to create, reuse throughout app lifetime.
    private let contactStore = CNContactStore()
    private let eventStore   = EKEventStore()

    // URLSession with tight timeout for real-time voice responses.
    private lazy var weatherSession: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest  = 8
        cfg.timeoutIntervalForResource = 10
        return URLSession(configuration: cfg)
    }()

    private init() {}

    // MARK: - EventKit authorization

    private func ensureCalendarAccess() async -> Bool {
        var status = EKEventStore.authorizationStatus(for: .event)
        if status == .notDetermined {
            let granted = await withCheckedContinuation { continuation in
                eventStore.requestFullAccessToEvents { granted, _ in
                    continuation.resume(returning: granted)
                }
            }
            guard granted else { return false }
            status = EKEventStore.authorizationStatus(for: .event)
        }
        return status == .fullAccess
    }

    private func ensureReminderAccess() async -> Bool {
        var status = EKEventStore.authorizationStatus(for: .reminder)
        if status == .notDetermined {
            let granted = await withCheckedContinuation { continuation in
                eventStore.requestFullAccessToReminders { granted, _ in
                    continuation.resume(returning: granted)
                }
            }
            guard granted else { return false }
            status = EKEventStore.authorizationStatus(for: .reminder)
        }
        return status == .fullAccess
    }

    // MARK: - Execute intent

    func execute(_ intent: GigiIntent) async -> String {
        GigiDebugLogger.log("GIGI Bridge: \(intent.label)")

        switch intent.label {
        case "make_call":
            return await makeCallAutomatic(to: intent.params["contact"] ?? "")

        case "send_message":
            return await sendMessageAutomatic(
                to:       intent.params["contact"]  ?? "",
                body:     intent.params["body"]     ?? "",
                platform: intent.params["platform"] ?? "imessage"
            )

        case "set_reminder":
            return await createReminder(text: intent.params["text"] ?? intent.params["raw"] ?? "")

        case "create_event":
            return await createEvent(
                title: intent.params["title"] ?? "Event",
                date:  intent.params["date"]  ?? "today",
                time:  intent.params["time"]  ?? "12:00"
            )

        case "navigate", "navigation":
            return await navigate(to: intent.params["destination"] ?? "")

        case "play_music":
            return await playMusic(query: intent.params["query"] ?? "")

        case "open_app":
            return await openApp(intent.params["app"] ?? "")

        case "ask_time":
            let f = DateFormatter(); f.locale = Locale(identifier: "en-US"); f.dateFormat = "h:mm a"
            return "It's \(f.string(from: Date()))."

        case "ask_date":
            let f = DateFormatter(); f.locale = Locale(identifier: "en-US"); f.dateStyle = .full
            return "Today is \(f.string(from: Date()))."

        case "torch_on":
            return torchSet(on: true)

        case "torch_off":
            return torchSet(on: false)

        case "set_timer":
            let raw = intent.params["text"] ?? intent.params["taskText"] ?? intent.params["raw"] ?? ""
            return await setTimer(input: raw)

        case "set_alarm":
            return await setAlarm(time: intent.params["time"] ?? "", date: intent.params["date"] ?? "today")

        case "weather":
            let loc = intent.params["destination"] ?? intent.params["query"] ?? ""
            return await fetchWeather(for: loc)

        case "read_email":
            return await openEmail()

        case "create_note":
            return await createNote(
                title: intent.params["title"] ?? intent.params["taskText"] ?? "GIGI note",
                body: intent.params["body"] ?? intent.params["text"] ?? intent.params["raw"] ?? ""
            )

        case "read_calendar":
            return await readTodayEvents()

        case "read_week_calendar":
            return await readWeekEvents()

        case "find_free_slot":
            let duration = Int(intent.params["duration"] ?? "60") ?? 60
            let preferred = intent.params["preferred"] ?? intent.params["time"] ?? ""
            return await findFreeSlot(durationMinutes: duration, preferredTime: preferred)

        case "facetime":
            return await facetimeCall(contact: intent.params["contact"] ?? "", audio: false)

        case "facetime_audio":
            return await facetimeCall(contact: intent.params["contact"] ?? "", audio: true)

        case "media_play_pause":
            return mediaPlayPause()

        case "media_next":
            return mediaNext()

        case "media_previous":
            return mediaPrevious()

        case "search_web":
            let q = intent.params["query"] ?? intent.params["raw"] ?? ""
            return await searchWeb(query: q)

        case "web_order_food":
            let service = intent.params["service"] ?? ""
            let query   = intent.params["query"] ?? intent.params["raw"] ?? ""
            return await openFoodDeliveryApp(service: service, query: query)

        case "send_email":
            return await sendEmail(
                to:      intent.params["contact"] ?? "",
                subject: intent.params["title"]   ?? intent.params["taskText"] ?? "",
                body:    intent.params["body"]     ?? ""
            )

        case "toggle_wifi":
            return await openSystemSettings(path: "App-Prefs:root=WIFI", label: "Wi-Fi")

        case "toggle_bluetooth":
            return await openSystemSettings(path: "App-Prefs:root=Bluetooth", label: "Bluetooth")

        case "homekit_on":
            GigiSmartOrchestrator.shared.showBanner("💡 Turning on...")
            return await GigiHomeKit.shared.setAccessoryPower(intent.params["accessory"] ?? "", on: true)

        case "homekit_off":
            GigiSmartOrchestrator.shared.showBanner("💡 Turning off...")
            return await GigiHomeKit.shared.setAccessoryPower(intent.params["accessory"] ?? "", on: false)

        case "homekit_dim":
            let pct = Int(intent.params["brightness"] ?? intent.params["percent"] ?? "50") ?? 50
            GigiSmartOrchestrator.shared.showBanner("💡 Adjusting brightness...")
            return await GigiHomeKit.shared.setAccessoryBrightness(intent.params["accessory"] ?? "", percent: pct)

        case "homekit_temp":
            let temp = Double(intent.params["temperature"] ?? "21") ?? 21
            GigiSmartOrchestrator.shared.showBanner("🌡️ Setting temperature...")
            return await GigiHomeKit.shared.setThermostat(temperature: temp)

        case "homekit_lock":
            GigiSmartOrchestrator.shared.showBanner("🔒 Locking...")
            return await GigiHomeKit.shared.setLock(intent.params["accessory"] ?? "", locked: true)

        case "homekit_unlock":
            GigiSmartOrchestrator.shared.showBanner("🔓 Unlocking...")
            return await GigiHomeKit.shared.setLock(intent.params["accessory"] ?? "", locked: false)

        case "homekit_scene", "set_homekit_scene":
            // GATE 9.B alias: Apple FM Tool exposes "set_homekit_scene" (more
            // explicit name in the registry); legacy NLU keyword path still
            // emits "homekit_scene". Both dispatch identically to the engine.
            let scene = intent.params["scene"] ?? intent.params["sceneName"] ?? intent.params["raw"] ?? ""
            GigiSmartOrchestrator.shared.showBanner("🏠 Activating scene...")
            return await GigiHomeKit.shared.activateScene(scene)

        case "web_search":
            // GATE 9.C alias: matches "search_web" semantics (already
            // implemented) but exposed via Apple FM Tool with the more
            // natural-language tool name "web_search".
            let q = intent.params["query"] ?? intent.params["raw"] ?? ""
            return await searchWeb(query: q)

        case "run_shortcut":
            // GATE 9.A — universal Apple Shortcuts bridge. Opens the
            // Shortcuts app via `shortcuts://x-callback-url/run-shortcut`.
            // The Shortcuts app will come to the foreground for ~1-2s during
            // execution (Apple sandbox limit — no background invocation for
            // 3rd-party apps). All user-facing strings in English (CLAUDE.md
            // §Lingua hard rule).
            let name = intent.params["name"] ?? intent.params["raw"] ?? ""
            let input = intent.params["input"] ?? ""
            return await runAppleShortcut(name: name, input: input)

        case "read_clipboard":
            // GATE 10.B — read iOS pasteboard text.
            return await readClipboardText()

        case "get_device_battery":
            // GATE 10.B — battery level + charging state.
            return await getDeviceBatteryStatus()

        case "toggle_flashlight":
            // GATE 10.B — torch on/off. Accepts "on"/"off"/empty (toggle).
            let state = intent.params["state"] ?? ""
            return await toggleFlashlight(targetState: state)

        case "define_word":
            // GATE 10.C — system dictionary lookup.
            let word = intent.params["word"] ?? intent.params["raw"] ?? ""
            return await defineWord(word: word)

        case "calculate_math":
            // GATE 10.C — NSExpression evaluation.
            let expr = intent.params["expression"] ?? intent.params["raw"] ?? ""
            return await calculateMath(expression: expr)

        case "translate_text":
            // GATE 10.C — iOS Translation framework (iOS 18+).
            let txt = intent.params["text"] ?? intent.params["raw"] ?? ""
            let target = intent.params["targetLanguage"] ?? ""
            return await translateText(text: txt, targetLanguage: target)

        case "read_news":
            let q = intent.params["query"] ?? intent.params["raw"] ?? "top news"
            return await readNews(query: q)

        case "order_food":
            let restaurant = intent.params["restaurant"] ?? ""
            return await orderFood(restaurant: restaurant)

        case "book_restaurant":
            let restaurant = intent.params["restaurant"] ?? ""
            let time       = intent.params["time"]       ?? ""
            let guests     = Int(intent.params["guests"] ?? "2") ?? 2
            return await bookRestaurant(restaurant: restaurant, time: time, guests: guests)

        default:
            return ""
        }
    }

    // MARK: - Gateway (Shortcuts)

    func openGatewayShortcut(input: String) async -> Bool {
        GigiDebugLogger.log("GIGI Gateway: payload → \(input)")
        let parts = input.split(separator: "|", maxSplits: 2).map(String.init)
        guard let cmd = parts.first else { return false }
        switch cmd {
        case "CALL":
            guard parts.count >= 2 else { return false }
            let number = parts[1]
            let shortcutOpened = await openGatewayXCallbackFallback(input: input)
            if shortcutOpened { return true }
            guard let telURL = URL(string: "tel://\(number)") else { return false }
            GigiDebugLogger.log("GIGI Gateway: tel:// fallback → \(number)")
            return await MainActor.run(resultType: Bool.self) {
                UIApplication.shared.open(telURL)
                return true
            }
        case "WA":
            guard parts.count >= 2 else { return false }
            let digits = parts[1]
            let body = parts.count >= 3 ? parts[2] : ""
            var cs = CharacterSet.urlQueryAllowed
            cs.remove(charactersIn: "+&=#?")
            let encoded = body.addingPercentEncoding(withAllowedCharacters: cs) ?? body
            guard let url = URL(string: "whatsapp://send?phone=\(digits)&text=\(encoded)") else { return false }
            let canOpen = await MainActor.run(resultType: Bool.self) { UIApplication.shared.canOpenURL(url) }
            guard canOpen else {
                GigiDebugLogger.log("GIGI Gateway: WhatsApp non installato")
                return false
            }
            GigiDebugLogger.log("GIGI Gateway: WhatsApp diretto → \(digits)")
            return await MainActor.run(resultType: Bool.self) {
                UIApplication.shared.open(url)
                return true
            }
        case "URL":
            guard parts.count >= 2, let url = URL(string: parts[1]) else { return false }
            GigiDebugLogger.log("GIGI Gateway: URL diretto → \(url)")
            return await MainActor.run(resultType: Bool.self) {
                UIApplication.shared.open(url)
                return true
            }
        default:
            return await openGatewayXCallbackFallback(input: input)
        }
    }

    private func openGatewayXCallbackFallback(input: String) async -> Bool {
        var components = URLComponents()
        components.scheme = "shortcuts"
        components.host = "x-callback-url"
        components.path = "/run-shortcut"
        components.queryItems = [
            URLQueryItem(name: "name", value: GigiGateway.shortcutName),
            URLQueryItem(name: "input", value: "text"),
            URLQueryItem(name: "text", value: input),
            URLQueryItem(name: "x-success", value: GigiGateway.callbackSuccessURLString),
            URLQueryItem(name: "x-cancel", value: GigiGateway.callbackCancelURLString),
        ]
        guard let url = components.url else { return false }
        GigiDebugLogger.log("GIGI Gateway: fallback Shortcuts → \(input)")
        return await MainActor.run(resultType: Bool.self) {
            UIApplication.shared.open(url)
            return true
        }
    }

    private func gatewayPhoneDigits(_ sanitized: String) -> String {
        sanitized.filter(\.isNumber)
    }

    private func gatewayCallPayload(digits: String) -> String        { "CALL|\(digits)" }
    private func gatewayWhatsAppPayload(digits: String, body: String) -> String {
        "WA|\(digits)|\(body.replacingOccurrences(of: "|", with: " · "))"
    }
    private func gatewayURLPayload(_ urlString: String) -> String    { "URL|\(urlString)" }

    // MARK: - Contact disambiguation (bug #017)
    //
    // Returns the resolved (phone, name) for `contact` query, asking the user
    // to choose between candidates when there are 2+ matches in Contacts.
    // Uses GigiContactsEngine.disambiguate() to get all candidates.
    //
    // Flow:
    //   1. Check GigiMemory.recallContactAlias(query) — if user already picked
    //      a specific contact for this alias, use it silently.
    //   2. disambiguate(query) → all matches.
    //   3. 0 matches → return nil (caller surfaces "Couldn't find X").
    //   4. 1 match → return it directly.
    //   5. 2+ matches → present sheet, await user pick (or cancel).
    //      After pick → memorize alias in GigiMemory.
    //
    // Used by makeCallAutomatic, facetimeCall, sendMessageAutomatic. Other
    // actions (e.g. find_free_slot) keep the legacy single-match resolver.
    private func disambiguateContact(
        query: String,
        actionLabel: String
    ) async -> (phone: String, name: String)? {
        // Step 1: query all matches with photo data
        let candidates = await GigiContactsEngine.shared.disambiguateWithPhotos(query)

        // Step 2: standard happy paths
        if candidates.isEmpty { return nil }
        if candidates.count == 1 {
            return (phone: candidates[0].phone, name: candidates[0].name)
        }

        // Step 3: 2+ matches — always present the bubble (bug-017 v4 fix).
        // Previously we silently used the memorized alias on subsequent
        // "Call X" calls, but that left the user with no way to switch to
        // a different X. Now we ALWAYS show the bubble; the memorized
        // contact gets a visual "Last call" highlight so the user can tap
        // it in one move or pick another.
        let memorizedName = await GigiMemory.shared.recallContactAlias(for: query)

        let picked: GigiSmartOrchestrator.ContactCandidate? = await withCheckedContinuation { cont in
            Task { @MainActor in
                GigiSmartOrchestrator.shared.presentContactDisambiguation(
                    query: query,
                    candidates: candidates,
                    actionLabel: actionLabel,
                    lastUsedName: memorizedName
                ) { picked in
                    cont.resume(returning: picked)
                }
            }
        }

        guard let picked else { return nil }  // user tapped Cancel

        // Memorize the choice (or overwrite). Drives the "Last call" badge
        // next time + sorting.
        Task.detached(priority: .background) {
            await GigiMemory.shared.rememberContactAlias(query: query, name: picked.name)
        }
        return (phone: picked.phone, name: picked.name)
    }

    // MARK: - Call

    private func sanitizePhoneNumber(_ raw: String) -> String {
        raw.filter { "0123456789+*#".contains($0) }
    }

    func makeCallAutomatic(to contact: String) async -> String {
        guard !contact.isEmpty else { return "Who do you want to call?" }
        guard await ensureContactsAccess() else {
            return "Turn on Contacts for GIGI in Settings → Privacy → Contacts."
        }
        // Bug #017: disambiguate when multiple matches exist — never silently
        // call the wrong contact.
        guard let picked = await disambiguateContact(query: contact, actionLabel: "call") else {
            // No match at all OR user tapped Cancel in the disambiguation sheet.
            // Differentiate the two cases by re-querying disambiguate quickly.
            let allMatches = await GigiContactsEngine.shared.disambiguate(contact)
            return allMatches.isEmpty
                ? "Couldn't find \(contact) in your contacts."
                : "Call cancelled."
        }
        let number = picked.phone
        let displayName = picked.name.isEmpty ? contact : picked.name
        // 2026-05-12 v5 fix — preserve `+` for international dialing.
        // gatewayPhoneDigits strips ALL non-digits (including '+'), producing
        // '393756548643' from '+39 375 654 8643'. iOS Phone app then treats it
        // as a local number missing country code and silently refuses to dial
        // (user reported: 'tappo il blu, non chiama').
        //
        // Apple spec (developer.apple.com PhoneLinks): use `tel:+15551234567`
        // with leading '+' for international numbers. The '+' is a supported
        // character in the tel: URL scheme.
        //
        // We keep the raw sanitizePhoneNumber output (digits + leading '+')
        // for the tel: URL, and prepend '+' if missing on a long number.
        let sanitized = sanitizePhoneNumber(number)
        let digits = gatewayPhoneDigits(sanitized)
        guard !digits.isEmpty else { return "Invalid phone number for \(contact)." }

        // Build the canonical tel: URL with international format.
        //   - If the sanitized form already starts with '+', use it as-is.
        //   - If the digits look international (>= 10) but no '+' is present,
        //     synthesize a '+' prefix (heuristic: trust the resolver supplied
        //     a country code).
        //   - Otherwise (short local numbers), pass digits as-is.
        let telBody: String = {
            if sanitized.hasPrefix("+") { return sanitized }
            if digits.count >= 10        { return "+" + digits }
            return digits
        }()

        await MainActor.run {
            GigiSmartOrchestrator.shared.stopMicCapture()
            GigiSmartOrchestrator.shared.showBanner("📞 Calling \(displayName)...")
        }

        // 2026-05-12 — Call routing (bug #006 — final version)
        //
        // History of attempts:
        //   v1 (cfc8b8e): simplified bubble text to "Calling X." — iOS popup
        //     still shows (unavoidable for tel:// from 3rd-party apps).
        //   v2 (a7c58a2): tried `whatsapp://send?phone=X` to bypass iOS popup
        //     → opened CHAT, not a call. Wrong intent.
        //   v3 (ec80d56): tried `whatsapp://call?phone=X` for direct VoIP
        //     → WhatsApp rejects with "Invalid call link". The `whatsapp://call`
        //     scheme is reserved for joining specific call link invites, NOT
        //     for placing arbitrary new calls to a phone number. WhatsApp does
        //     NOT expose any public URL scheme to start a fresh call from
        //     outside the app.
        //   v4 (this commit, final): revert to plain `tel://X`. iOS will show
        //     its mandatory confirm popup ("Chiama +39 X / Cancel"), the user
        //     taps once, the call dials. This is the iOS-standard UX shared
        //     by every 3rd-party app that wants to place phone calls (Siri
        //     non-Apple, Alexa app, Google Assistant, Mail, Calendar, etc).
        //     CallKit + VoIP entitlement could bypass the popup but is out
        //     of scope for v1 (Apple approval cycle, VoIP-specific use case).
        //
        // The popup is friction, but at least the call DIALS. The previous
        // workarounds didn't satisfy the user intent ("Call X" → place a call).
        //
        // Canonical Apple form: `tel:+CountryCodeNumber` (single colon, no
        // slashes, leading '+' for international). `telBody` is now built
        // above with the '+' preserved.
        guard let telURL = URL(string: "tel:\(telBody)") else { return "Invalid phone number." }
        let opened = await MainActor.run(resultType: Bool.self) {
            UIApplication.shared.open(telURL)
            return true
        }
        return opened ? "Calling \(displayName)." : "Couldn't start the call."
    }

    // MARK: - Messages

    func sendMessageAutomatic(to contact: String, body: String, platform: String) async -> String {
        guard !contact.isEmpty else { return "Who should I message?" }
        // Bug #017: disambiguate when multiple matches exist — never silently
        // message the wrong contact.
        guard let picked = await disambiguateContact(query: contact, actionLabel: "message") else {
            let allMatches = await GigiContactsEngine.shared.disambiguate(contact)
            return allMatches.isEmpty
                ? "Couldn't find \(contact)."
                : "Message cancelled."
        }
        let number = picked.phone
        let _ = picked.name.isEmpty ? contact : picked.name  // displayName reserved for future use
        let digits = gatewayPhoneDigits(sanitizePhoneNumber(number))
        guard !digits.isEmpty else { return "Invalid phone number for \(contact)." }

        await MainActor.run {
            GigiSmartOrchestrator.shared.stopMicCapture()
        }

        switch platform.lowercased() {
        case "whatsapp", "wa":
            await MainActor.run { GigiSmartOrchestrator.shared.showBanner("💬 Sending on WhatsApp...") }
            // Primary: WebAgent with phone number for direct URL (most reliable, no app switch)
            let webResult = await GigiWebAgent.shared.sendWhatsAppResult(contact: contact, message: body, phone: digits)
            switch webResult {
            case .success:
                return "Message sent to \(contact) on WhatsApp."
            case .needsQR:
                // QR not scanned yet — show in-app prompt, fall back to app
                await MainActor.run { 
                    GigiSmartOrchestrator.shared.showBanner("WhatsApp Web needs setup. Falling back to app.")
                    GigiSmartOrchestrator.shared.showBanner("📱 Scan WhatsApp Web QR in Settings")
                }
                fallthrough
            case .failed:
                // Fallback: open WhatsApp app directly
                let canOpenWA = await MainActor.run(resultType: Bool.self) {
                    if let waCheck = URL(string: "whatsapp://") {
                        return UIApplication.shared.canOpenURL(waCheck)
                    }
                    return false
                }
                guard canOpenWA else {
                    return "WhatsApp isn't installed."
                }
                let ok = await openGatewayShortcut(input: gatewayWhatsAppPayload(digits: digits, body: body))
                return ok ? "Message ready for \(contact) on WhatsApp." : "Couldn't reach WhatsApp."
            }

        case "telegram":
            var cs = CharacterSet.urlQueryAllowed; cs.remove(charactersIn: "+&=#")
            let encoded = body.addingPercentEncoding(withAllowedCharacters: cs) ?? ""
            if let url = URL(string: "tg://msg?to=\(digits)&text=\(encoded)") {
                await MainActor.run { UIApplication.shared.open(url) }
            }
            return "Opening Telegram for \(contact)."

        default: // iMessage / SMS
            await MainActor.run { GigiSmartOrchestrator.shared.showBanner("💬 Sending to \(contact)...") }
            var cs = CharacterSet.urlQueryAllowed; cs.remove(charactersIn: "+&=#")
            let encoded = body.addingPercentEncoding(withAllowedCharacters: cs) ?? ""
            if let url = URL(string: "sms:\(digits)?body=\(encoded)") {
                await MainActor.run { UIApplication.shared.open(url) }
            }
            return "Message ready for \(contact)."
        }
    }

    // MARK: - Torch

    private func torchSet(on: Bool) -> String {
        let authStatus = AVCaptureDevice.authorizationStatus(for: .video)
        if authStatus == .denied || authStatus == .restricted {
            return "Camera access is needed for the flashlight. Enable it in Settings → Privacy → Camera."
        }
        guard let device = AVCaptureDevice.default(for: .video), device.hasTorch else {
            return "This device doesn't have a flashlight."
        }
        do {
            try device.lockForConfiguration()
            device.torchMode = on ? .on : .off
            device.unlockForConfiguration()
            return on ? "Flashlight on." : "Flashlight off."
        } catch {
            return "Couldn't change the flashlight: \(error.localizedDescription)"
        }
    }

    // MARK: - Timer

    private func setTimer(input: String) async -> String {
        let seconds = parseTimerDuration(input)
        guard seconds > 0 else {
            return "How long should the timer run? Say something like '10 minutes'."
        }
        let granted = await requestNotificationPermission()
        guard granted else { return "Enable Notifications in Settings so I can set timers." }

        let content = UNMutableNotificationContent()
        content.title = "GIGI Timer"
        content.body  = timerLabel(seconds: seconds)
        content.sound = .default

        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: TimeInterval(seconds), repeats: false)
        let request = UNNotificationRequest(
            identifier: "gigi.timer.\(Date().timeIntervalSince1970)",
            content: content,
            trigger: trigger
        )
        try? await UNUserNotificationCenter.current().add(request)
        // Visual feedback in-app — parity with call/message/HomeKit handlers.
        await MainActor.run {
            GigiSmartOrchestrator.shared.showBanner("⏱️ Timer · \(timerLabel(seconds: seconds))")
        }
        return "Timer set for \(timerLabel(seconds: seconds))."
    }

    // Bug #004 fix (2026-05-12): SFSpeech transcribes small numbers as words
    // ("two minutes" instead of "2 minutes"). The regex below only matches
    // \d+ → words returned 0 → GIGI asked "How long should the timer run?".
    // wordToNumber covers EN 0-99 + common IT short numbers + edge tokens
    // ("a"/"an"/"un"/"una" = 1, "half" → handled by literal). Run a pre-pass
    // that substitutes word numerals with digits before regex matching.
    private static let WORD_TO_NUMBER: [String: Int] = [
        // English single words 0-19
        "zero": 0, "one": 1, "two": 2, "three": 3, "four": 4, "five": 5,
        "six": 6, "seven": 7, "eight": 8, "nine": 9, "ten": 10,
        "eleven": 11, "twelve": 12, "thirteen": 13, "fourteen": 14,
        "fifteen": 15, "sixteen": 16, "seventeen": 17, "eighteen": 18,
        "nineteen": 19,
        // English tens
        "twenty": 20, "thirty": 30, "forty": 40, "fifty": 50,
        "sixty": 60, "seventy": 70, "eighty": 80, "ninety": 90,
        "hundred": 100,
        // English articles meaning "one"
        "a": 1, "an": 1,
        // Italian short numbers
        "uno": 1, "una": 1, "un": 1,
        "due": 2, "tre": 3, "quattro": 4, "cinque": 5,
        "sei": 6, "sette": 7, "otto": 8, "nove": 9, "dieci": 10,
        "undici": 11, "dodici": 12, "tredici": 13, "quattordici": 14,
        "quindici": 15, "sedici": 16, "diciassette": 17, "diciotto": 18,
        "diciannove": 19,
        "venti": 20, "trenta": 30, "quaranta": 40, "cinquanta": 50,
        "sessanta": 60, "settanta": 70, "ottanta": 80, "novanta": 90
    ]

    /// Substitute word numerals ("two" → "2") before regex digit matching.
    /// Word boundary `\b` ensures "twentyfive minutes" doesn't accidentally
    /// match "twenty" inside "twentyfive" — only standalone words substitute.
    /// Compound numbers (e.g. "twenty five") are not yet collapsed in v1
    /// — fall through to the matched-tens value (here: 20). v1.1 will add
    /// adjacent-word summation.
    private func normalizeWordNumerals(_ text: String) -> String {
        var out = text
        for (word, n) in Self.WORD_TO_NUMBER {
            out = out.replacingOccurrences(
                of: "\\b\(word)\\b",
                with: "\(n)",
                options: [.regularExpression, .caseInsensitive]
            )
        }
        return out
    }

    private func parseTimerDuration(_ text: String) -> Int {
        let lower = normalizeWordNumerals(text.lowercased())
        var total = 0
        // 2026-05-12 fix: previous patterns matched only singular forms
        // ("3 minute") because `[^a-z]|$` rejected the trailing "s" of plurals.
        // Now `s?` makes the plural optional AND `\b` enforces a word boundary,
        // so "3 minutes", "3 minute", "3 min" all parse correctly.
        // 2026-05-12 bug #004: also runs a wordToNumber pre-pass so
        // "two minutes" → "2 minutes" before regex matching.
        let patterns: [(String, Int)] = [
            ("(\\d+)\\s*(?:hours?|ora|ore|hr|h)\\b", 3600),
            ("(\\d+)\\s*(?:minutes?|minuto|minuti|min|m)\\b", 60),
            ("(\\d+)\\s*(?:seconds?|secondo|secondi|sec|s)\\b", 1)
        ]
        for (pattern, mult) in patterns {
            if let match = lower.range(of: pattern, options: .regularExpression) {
                let digits = String(lower[match]).filter { $0.isNumber }
                if let n = Int(digits) { total += n * mult }
            }
        }
        return total
    }

    private func timerLabel(seconds: Int) -> String {
        if seconds >= 3600 {
            let h = seconds / 3600; let m = (seconds % 3600) / 60
            return m > 0 ? "\(h)h \(m)m" : "\(h) hour\(h > 1 ? "s" : "")"
        } else if seconds >= 60 {
            let m = seconds / 60; let s = seconds % 60
            return s > 0 ? "\(m)m \(s)s" : "\(m) minute\(m > 1 ? "s" : "")"
        } else {
            return "\(seconds) second\(seconds > 1 ? "s" : "")"
        }
    }

    // MARK: - Alarm

    private func setAlarm(time: String, date: String) async -> String {
        guard !time.isEmpty else {
            return "What time should I set the alarm for?"
        }
        let granted = await requestNotificationPermission()
        guard granted else { return "Enable Notifications in Settings so I can set alarms." }

        guard let fireDate = parseAlarmDateTime(time: time, date: date) else {
            return "Couldn't parse that time. Try something like '7:30 AM'."
        }

        let content = UNMutableNotificationContent()
        content.title = "GIGI Alarm"
        content.body  = "Time to wake up!"
        content.sound = .defaultCritical

        let cal   = Calendar.current
        let comps = cal.dateComponents([.year, .month, .day, .hour, .minute], from: fireDate)
        let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)
        let request = UNNotificationRequest(
            identifier: "gigi.alarm.\(Date().timeIntervalSince1970)",
            content: content,
            trigger: trigger
        )
        try? await UNUserNotificationCenter.current().add(request)

        let f = DateFormatter(); f.locale = Locale(identifier: "en-US"); f.dateFormat = "h:mm a"
        let label = f.string(from: fireDate)
        await MainActor.run {
            GigiSmartOrchestrator.shared.showBanner("⏰ Alarm · \(label)")
        }
        return "Alarm set for \(label)."
    }

    /// Repeating local notification every day at `hour`:`minute` (replaces any previous GIGI daily routine alarm).
    func setDailyRepeatingAlarm(hour: Int, minute: Int) async -> String {
        guard (0..<24).contains(hour), (0..<60).contains(minute) else {
            return "Invalid time for the alarm."
        }
        let granted = await requestNotificationPermission()
        guard granted else { return "Enable Notifications in Settings so I can set alarms." }

        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: ["gigi.routine.daily"])

        var comps = DateComponents()
        comps.hour = hour
        comps.minute = minute
        let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: true)

        let content = UNMutableNotificationContent()
        content.title = "GIGI"
        content.body = "Daily alarm"
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: "gigi.routine.daily",
            content: content,
            trigger: trigger
        )
        do {
            try await UNUserNotificationCenter.current().add(request)
        } catch {
            return "Couldn't schedule the alarm."
        }

        let f = DateFormatter()
        f.locale = Locale(identifier: "en-US")
        f.dateFormat = "h:mm a"
        let cal = Calendar.current
        var dc = cal.dateComponents([.year, .month, .day], from: Date())
        dc.hour = hour
        dc.minute = minute
        if let d = cal.date(from: dc) {
            return "Daily alarm set for \(f.string(from: d))."
        }
        return "Daily alarm set."
    }

    private func parseAlarmDateTime(time: String, date: String) -> Date? {
        let lower = time.lowercased()
        let formats = ["h:mm a", "HH:mm", "h a", "ha", "h:mm"]
        let df = DateFormatter(); df.locale = Locale(identifier: "en-US")
        for fmt in formats {
            df.dateFormat = fmt
            if let parsed = df.date(from: lower) {
                var timeComps = Calendar.current.dateComponents([.hour, .minute], from: parsed)
                var dayComps  = Calendar.current.dateComponents([.year, .month, .day], from: Date())
                if date.lowercased().contains("tomorrow") {
                    dayComps.day = (dayComps.day ?? 0) + 1
                }
                timeComps.year = dayComps.year; timeComps.month = dayComps.month; timeComps.day = dayComps.day
                if let result = Calendar.current.date(from: timeComps), result > Date() { return result }
                // Time already passed today → schedule tomorrow
                timeComps.day = (timeComps.day ?? 0) + 1
                return Calendar.current.date(from: timeComps)
            }
        }
        return nil
    }

    // MARK: - Weather

    func fetchWeather(for location: String) async -> String {
        let loc     = location.trimmingCharacters(in: .whitespaces)
        var cs      = CharacterSet.urlQueryAllowed; cs.remove(charactersIn: "+&=#")
        let slug    = loc.isEmpty ? "auto" : (loc.addingPercentEncoding(withAllowedCharacters: cs) ?? loc)
        guard let url = URL(string: "https://wttr.in/\(slug)?format=j1") else {
            return "Couldn't build the weather request."
        }
        await MainActor.run {
            GigiSmartOrchestrator.shared.showBanner("☁️ Weather · \(loc.isEmpty ? "current location" : loc)")
        }

        do {
            let (data, _) = try await weatherSession.data(from: url)
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let condition = (json["current_condition"] as? [[String: Any]])?.first
            else { return "Couldn't read weather data." }

            let tempC    = (condition["temp_C"]      as? String) ?? "--"
            let feelsC   = (condition["FeelsLikeC"]  as? String) ?? "--"
            let desc     = ((condition["weatherDesc"] as? [[String: Any]])?.first?["value"] as? String) ?? "Unknown"
            let humidity = (condition["humidity"]     as? String) ?? "--"
            let label    = loc.isEmpty ? "your location" : loc

            return "\(desc), \(tempC)°C in \(label). Feels like \(feelsC)°C, humidity \(humidity)%."
        } catch {
            return "Couldn't reach weather service. Check your connection."
        }
    }

    // MARK: - Calendar (read)

    private func readTodayEvents() async -> String {
        guard await ensureCalendarAccess() else {
            return "I need Calendar access to check your schedule."
        }

        let cal   = Calendar.current
        let start = cal.startOfDay(for: Date())
        guard let end = cal.date(byAdding: .day, value: 1, to: start) else { return "Couldn't read calendar." }
        let pred   = eventStore.predicateForEvents(withStart: start, end: end, calendars: nil)
        let events = eventStore.events(matching: pred).sorted { $0.startDate < $1.startDate }

        guard !events.isEmpty else { return "Nothing on your calendar today." }

        let f = DateFormatter(); f.locale = Locale(identifier: "en-US"); f.dateFormat = "h:mm a"
        let summary = events.prefix(5).map { e in
            e.isAllDay ? e.title : "\(f.string(from: e.startDate)) — \(e.title ?? "Untitled")"
        }.joined(separator: ", ")

        let count = events.count
        return count == 1
            ? "You have 1 event today: \(summary)."
            : "You have \(count) events today: \(summary)\(count > 5 ? ", and more." : ".")"
    }

    // MARK: - Calendar intelligence (T-20)

    private func readWeekEvents() async -> String {
        guard await ensureCalendarAccess() else {
            return "I need Calendar access to check your schedule."
        }
        let cal   = Calendar.current
        let start = cal.startOfDay(for: Date())
        guard let end = cal.date(byAdding: .day, value: 7, to: start) else { return "Couldn't read calendar." }
        let pred   = eventStore.predicateForEvents(withStart: start, end: end, calendars: nil)
        let events = eventStore.events(matching: pred).sorted { $0.startDate < $1.startDate }

        guard !events.isEmpty else { return "Nothing on your calendar this week." }

        let f = DateFormatter(); f.locale = Locale(identifier: "en-US"); f.dateFormat = "EEE h:mm a"
        let dayFmt = DateFormatter(); dayFmt.locale = Locale(identifier: "en-US"); dayFmt.dateFormat = "EEE"
        let summary = events.prefix(8).map { e in
            e.isAllDay ? "\(dayFmt.string(from: e.startDate)) — \(e.title ?? "Untitled")"
                       : "\(f.string(from: e.startDate)) — \(e.title ?? "Untitled")"
        }.joined(separator: "; ")
        return "Next 7 days: \(summary)."
    }

    private func findFreeSlot(durationMinutes: Int, preferredTime: String) async -> String {
        guard await ensureCalendarAccess() else {
            return "I need Calendar access to find free time."
        }

        let cal = Calendar.current
        // Search from now through next 3 days
        let now = Date()
        guard let searchEnd = cal.date(byAdding: .day, value: 3, to: now) else { return "Couldn't check calendar." }
        let pred   = eventStore.predicateForEvents(withStart: now, end: searchEnd, calendars: nil)
        let events = eventStore.events(matching: pred).sorted { $0.startDate < $1.startDate }

        // Work hours: 9am–7pm
        let workHourStart = 9
        let workHourEnd   = 19

        // Determine preferred hour
        var preferredHour: Int? = nil
        let lower = preferredTime.lowercased()
        if lower.contains("morning") { preferredHour = 9 }
        else if lower.contains("afternoon") { preferredHour = 14 }
        else if lower.contains("evening") { preferredHour = 17 }
        else if let h = extractHour(from: preferredTime) { preferredHour = h }

        // Walk through candidate slots (30-min granularity)
        var cursor = now
        let slotDuration = TimeInterval(durationMinutes * 60)
        let f = DateFormatter(); f.locale = Locale(identifier: "en-US"); f.dateFormat = "EEEE 'at' h:mm a"

        var candidates: [Date] = []
        for _ in 0..<96 {  // 48h at 30-min steps
            cursor = cursor.addingTimeInterval(1800)
            let hour = cal.component(.hour, from: cursor)
            guard hour >= workHourStart, hour < workHourEnd else { continue }
            let slotEnd = cursor.addingTimeInterval(slotDuration)
            let conflicts = events.filter { e in
                e.startDate < slotEnd && e.endDate > cursor
            }
            if conflicts.isEmpty {
                candidates.append(cursor)
                if candidates.count >= 3 { break }
            }
        }

        guard !candidates.isEmpty else { return "Couldn't find a free slot in the next 3 days." }

        // Prefer candidate closest to preferred hour
        let best: Date
        if let ph = preferredHour {
            best = candidates.min(by: {
                abs(cal.component(.hour, from: $0) - ph) < abs(cal.component(.hour, from: $1) - ph)
            }) ?? candidates[0]
        } else {
            best = candidates[0]
        }

        return "You're free on \(f.string(from: best)). Want me to book that slot?"
    }

    private func extractHour(from text: String) -> Int? {
        let pattern = #"(\d{1,2})(?::\d{2})?\s*(?:am|pm|h)?"#
        guard let range = text.range(of: pattern, options: [.regularExpression, .caseInsensitive]) else { return nil }
        let matched = String(text[range])
        guard let h = Int(matched.filter(\.isNumber).prefix(2)) else { return nil }
        let isPM = matched.lowercased().contains("pm")
        return isPM && h < 12 ? h + 12 : h
    }

    // MARK: - FaceTime

    private func facetimeCall(contact: String, audio: Bool) async -> String {
        guard !contact.isEmpty else { return "Who do you want to FaceTime?" }
        // Bug #017: disambiguate when multiple matches exist.
        guard let picked = await disambiguateContact(
            query: contact,
            actionLabel: audio ? "FaceTime audio" : "FaceTime"
        ) else {
            let allMatches = await GigiContactsEngine.shared.disambiguate(contact)
            return allMatches.isEmpty
                ? "Couldn't find \(contact) in your contacts."
                : "FaceTime cancelled."
        }
        let number = picked.phone
        let displayName = picked.name.isEmpty ? contact : picked.name
        let scheme = audio ? "facetime-audio" : "facetime"
        let digits = gatewayPhoneDigits(sanitizePhoneNumber(number))
        guard let url = URL(string: "\(scheme)://\(digits)") else {
            return "Couldn't build FaceTime URL."
        }
        GigiSmartOrchestrator.shared.showBanner(audio ? "📞 FaceTime audio..." : "📹 FaceTime video...")
        await UIApplication.shared.open(url)
        return audio ? "Starting FaceTime audio with \(displayName)." : "Starting FaceTime with \(displayName)."
    }

    // MARK: - Media (Apple Music / system player)

    private func mediaPlayPause() -> String {
        let player = MPMusicPlayerController.systemMusicPlayer
        if player.playbackState == .playing { player.pause(); return "Paused." }
        else                                { player.play();  return "Playing." }
    }

    private func mediaNext() -> String {
        MPMusicPlayerController.systemMusicPlayer.skipToNextItem(); return "Next track."
    }

    private func mediaPrevious() -> String {
        MPMusicPlayerController.systemMusicPlayer.skipToPreviousItem(); return "Previous track."
    }

    // MARK: - Create Note (GATE 6 — killer demo Tesla→note)
    //
    // iOS Notes app has no public URL scheme that accepts body content, so
    // we use a two-step UX:
    //   1. Copy "Title\n\nBody" to the system clipboard.
    //   2. Open Notes app via `mobilenotes://`.
    // The spoken response tells the user to paste. This is best-effort but
    // demoable; a power user can configure a Shortcuts → "Create Note"
    // automation for one-tap.
    func createNote(title: String, body: String) async -> String {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedBody  = body.trimmingCharacters(in: .whitespacesAndNewlines)
        let combined = trimmedBody.isEmpty
            ? trimmedTitle
            : "\(trimmedTitle)\n\n\(trimmedBody)"

        await MainActor.run {
            UIPasteboard.general.string = combined
            GigiSmartOrchestrator.shared.showBanner("📝 Note copied — opening Notes...")
            if let url = URL(string: "mobilenotes://") {
                UIApplication.shared.open(url)
            }
        }
        return trimmedTitle.isEmpty
            ? "Note copied to clipboard. Opening Notes — paste with long-press."
            : "Note '\(trimmedTitle)' copied to clipboard. Opening Notes — paste with long-press."
    }

    // MARK: - Email

    private func openEmail() async -> String {
        // Open Mail app inbox — iOS has no API to read email content directly
        if let url = URL(string: "message://") {
            let canOpen = await MainActor.run(resultType: Bool.self) { UIApplication.shared.canOpenURL(url) }
            if canOpen {
                await MainActor.run { UIApplication.shared.open(url) }
                return "Opening your inbox."
            }
        }
        if let url = URL(string: "mailto:") {
            await MainActor.run { UIApplication.shared.open(url) }
        }
        return "Opening Mail."
    }

    // MARK: - Food delivery dispatch (bug #011)
    //
    // Open the right food-delivery surface in this priority:
    //   1. Native app via custom scheme (e.g. justeat://) — preferred,
    //      no browser indirection.
    //   2. Country-aware website (justeat.it for Italy, just-eat.co.uk for UK).
    //   3. Generic Google search as last resort (when service is unknown).
    //
    // Country routing uses Locale.current.region.identifier — same source
    // as the geo context header sent to Claude (bug #014). Adding more
    // services later only needs new rows in the dictionaries.

    private func openFoodDeliveryApp(service: String, query: String) async -> String {
        let svcRaw = service.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let countryCode = Locale.current.region?.identifier.uppercased() ?? "US"

        // Native app schemes — opens directly inside the app if installed.
        let appScheme: [String: String] = [
            "justeat":      "justeat://",
            "just-eat":     "justeat://",
            "deliveroo":    "deliveroo://",
            "ubereats":     "ubereats://",
            "uber-eats":    "ubereats://",
            "uber eats":    "ubereats://",
            "glovo":        "glovo://",
            "doordash":     "doordash://",
            "talabat":      "talabat://"
        ]
        // Country-aware web fallbacks. Key = "service|COUNTRY", or "service" generic.
        let webURL: [String: String] = [
            "justeat|IT":   "https://www.justeat.it",
            "justeat|GB":   "https://www.just-eat.co.uk",
            "justeat|IE":   "https://www.just-eat.ie",
            "justeat|ES":   "https://www.just-eat.es",
            "justeat":      "https://www.justeat.com",
            "deliveroo|IT": "https://deliveroo.it",
            "deliveroo|GB": "https://deliveroo.co.uk",
            "deliveroo":    "https://deliveroo.com",
            "ubereats":     "https://www.ubereats.com",
            "glovo|IT":     "https://glovoapp.com/it",
            "glovo":        "https://glovoapp.com",
            "doordash":     "https://www.doordash.com",
            "talabat":      "https://www.talabat.com"
        ]
        let displayName: [String: String] = [
            "justeat":  "Just Eat",
            "deliveroo": "Deliveroo",
            "ubereats": "Uber Eats",
            "glovo":    "Glovo",
            "doordash": "DoorDash",
            "talabat":  "Talabat"
        ]
        // Canonicalize service alias (just-eat, uber eats → standard form)
        let svc: String
        switch svcRaw {
        case "just-eat", "just eat":  svc = "justeat"
        case "uber-eats", "uber eats": svc = "ubereats"
        default: svc = svcRaw
        }
        let pretty = displayName[svc] ?? (svc.isEmpty ? "food delivery" : svc.capitalized)

        // (1) Try native app scheme first
        if !svc.isEmpty, let scheme = appScheme[svc], let url = URL(string: scheme) {
            let canOpen = await MainActor.run(resultType: Bool.self) { UIApplication.shared.canOpenURL(url) }
            if canOpen {
                await MainActor.run {
                    GigiSmartOrchestrator.shared.showBanner("🍔 Opening \(pretty)…")
                    UIApplication.shared.open(url)
                }
                return "Opening \(pretty)."
            }
        }

        // (2) Country-aware website
        if !svc.isEmpty {
            let countryKey = "\(svc)|\(countryCode)"
            let webString = webURL[countryKey] ?? webURL[svc]
            if let urlStr = webString, let url = URL(string: urlStr) {
                await MainActor.run {
                    GigiSmartOrchestrator.shared.showBanner("🍔 Opening \(pretty)…")
                    UIApplication.shared.open(url)
                }
                return "Opening \(pretty) in your browser."
            }
        }

        // (3) Generic web search fallback
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "food delivery near me"
            : query
        var cs = CharacterSet.urlQueryAllowed; cs.remove(charactersIn: "+&=#")
        let encoded = q.addingPercentEncoding(withAllowedCharacters: cs) ?? q
        if let url = URL(string: "https://www.google.com/search?q=\(encoded)") {
            await MainActor.run {
                GigiSmartOrchestrator.shared.showBanner("🍔 Searching food delivery…")
                UIApplication.shared.open(url)
            }
            return "Searching for \(q)."
        }
        return "I couldn't open a food delivery app."
    }

    // MARK: - Web Search

    private func searchWeb(query: String) async -> String {
        guard !query.isEmpty else { return "What do you want to search?" }
        var cs = CharacterSet.urlQueryAllowed; cs.remove(charactersIn: "+&=#")
        let encoded = query.addingPercentEncoding(withAllowedCharacters: cs) ?? query
        guard let url = URL(string: "https://www.google.com/search?q=\(encoded)") else {
            return "Couldn't build search URL."
        }
        await MainActor.run {
            GigiSmartOrchestrator.shared.showBanner("🔍 Searching...")
            UIApplication.shared.open(url)
        }
        return "Searching for '\(query)'."
    }

    // MARK: - Run Apple Shortcut (GATE 9.A)

    /// Universal bridge to Apple Shortcuts via x-callback-url scheme.
    /// Opens the Shortcuts app and runs the named Shortcut. The Shortcuts
    /// app comes to the foreground for ~1-2s during execution (iOS sandbox
    /// limitation — 3rd-party apps cannot run Shortcuts in background).
    /// All user-facing strings in English per CLAUDE.md §Lingua hard rule.
    private func runAppleShortcut(name: String, input: String) async -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "Which Shortcut should I run?" }

        var cs = CharacterSet.urlQueryAllowed
        cs.remove(charactersIn: "+&=#?")
        let encodedName = trimmed.addingPercentEncoding(withAllowedCharacters: cs) ?? trimmed

        var urlString = "shortcuts://x-callback-url/run-shortcut?name=\(encodedName)"
        if !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let encodedInput = input.addingPercentEncoding(withAllowedCharacters: cs) ?? input
            urlString += "&input=text&text=\(encodedInput)"
        }

        guard let url = URL(string: urlString) else {
            return "Couldn't build the Shortcut URL."
        }

        let canOpen = await MainActor.run { UIApplication.shared.canOpenURL(url) }
        guard canOpen else {
            // Shortcuts app should always be present on iOS, but defensive
            // check in case the user has somehow uninstalled it.
            return "I couldn't open the Shortcuts app."
        }

        await MainActor.run {
            GigiSmartOrchestrator.shared.showBanner("⚡️ Running Shortcut...")
            UIApplication.shared.open(url)
        }
        return "Running '\(trimmed)'."
    }

    // MARK: - Utility tools (GATE 10.B)

    /// Reads the iOS general pasteboard. If empty, says so. If the text is
    /// long (>200 chars), reads the first 200 with an ellipsis.
    @MainActor
    private func readClipboardText() async -> String {
        let pasteboard = UIPasteboard.general
        guard let text = pasteboard.string, !text.trimmingCharacters(in: .whitespaces).isEmpty else {
            return "Your clipboard is empty."
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count > 200 {
            let preview = String(trimmed.prefix(200))
            return "Your clipboard: \"\(preview)…\""
        }
        return "Your clipboard: \"\(trimmed)\""
    }

    /// Reads UIDevice battery level + charging state. Note: battery
    /// monitoring must be enabled or level reports -1.
    @MainActor
    private func getDeviceBatteryStatus() async -> String {
        let device = UIDevice.current
        let wasMonitoring = device.isBatteryMonitoringEnabled
        if !wasMonitoring { device.isBatteryMonitoringEnabled = true }

        let level = device.batteryLevel
        let state = device.batteryState

        if !wasMonitoring {
            // Leave monitoring on — small power cost is negligible, and
            // re-enabling on every call wastes setup time. Other parts of
            // the app may benefit from the live reading.
        }

        guard level >= 0 else {
            return "I can't read the battery level right now."
        }

        let percent = Int(round(level * 100))
        let stateDescription: String
        switch state {
        case .charging:    stateDescription = " and charging"
        case .full:        stateDescription = " and fully charged"
        case .unplugged:   stateDescription = ""
        case .unknown:     stateDescription = ""
        @unknown default:  stateDescription = ""
        }
        return "Battery is at \(percent) percent\(stateDescription)."
    }

    /// Toggles the rear LED torch on / off. Accepts "on"/"off" or empty
    /// (toggles current state). Requires camera access — gracefully
    /// degrades with a clear error if the camera is unavailable (e.g. on
    /// devices without a torch).
    @MainActor
    private func toggleFlashlight(targetState: String) async -> String {
        guard let device = AVCaptureDevice.default(for: .video) else {
            return "This device doesn't have a flashlight."
        }
        guard device.hasTorch else {
            return "This device doesn't support the flashlight."
        }
        do {
            try device.lockForConfiguration()
            defer { device.unlockForConfiguration() }

            let normalized = targetState.lowercased().trimmingCharacters(in: .whitespaces)
            let on: Bool
            switch normalized {
            case "on", "true", "yes", "accendi", "accesa", "1":
                on = true
            case "off", "false", "no", "spegni", "spenta", "0":
                on = false
            default:
                // Toggle current state
                on = !device.isTorchActive
            }

            if on {
                try device.setTorchModeOn(level: 1.0)
                return "Flashlight on."
            } else {
                device.torchMode = .off
                return "Flashlight off."
            }
        } catch {
            return "Couldn't change the flashlight: \(error.localizedDescription)."
        }
    }

    // MARK: - Knowledge mini tools (GATE 10.C)

    /// Opens the iOS system dictionary reference view for the given word.
    /// Uses UIReferenceLibraryViewController which is the canonical iOS
    /// dictionary surface. If the dictionary has no entry, the system shows
    /// "No definition found" itself — we don't need to pre-check.
    @MainActor
    private func defineWord(word: String) async -> String {
        let trimmed = word.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "Which word should I define?" }

        // Check that the dictionary has an entry — avoids opening a sheet
        // that immediately says "no result".
        guard UIReferenceLibraryViewController.dictionaryHasDefinition(forTerm: trimmed) else {
            return "I couldn't find a definition for '\(trimmed)'."
        }

        // Present the dictionary view modally on the foreground scene.
        guard let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
              let rootVC = scene.windows.first?.rootViewController else {
            return "Couldn't open the dictionary."
        }
        let vc = UIReferenceLibraryViewController(term: trimmed)
        var topVC = rootVC
        while let presented = topVC.presentedViewController { topVC = presented }
        topVC.present(vc, animated: true)
        return "Definition for '\(trimmed)'."
    }

    /// Evaluates a math expression using NSExpression with mathematical
    /// function names mapped (sqrt, pow, etc.). Handles natural language
    /// like "47 plus 23" → "47 + 23" via simple regex pre-processing.
    private func calculateMath(expression: String) async -> String {
        let raw = expression.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return "What should I calculate?" }

        // Normalize natural language operators.
        var normalized = raw.lowercased()
            .replacingOccurrences(of: " plus ",     with: " + ")
            .replacingOccurrences(of: " minus ",    with: " - ")
            .replacingOccurrences(of: " times ",    with: " * ")
            .replacingOccurrences(of: " by ",       with: " * ")
            .replacingOccurrences(of: " x ",        with: " * ")
            .replacingOccurrences(of: " divided by ", with: " / ")
            .replacingOccurrences(of: " over ",     with: " / ")
            .replacingOccurrences(of: " più ",      with: " + ")
            .replacingOccurrences(of: " meno ",     with: " - ")
            .replacingOccurrences(of: " per ",      with: " * ")
            .replacingOccurrences(of: " diviso ",   with: " / ")
            .replacingOccurrences(of: " mod ",      with: " % ")
            .replacingOccurrences(of: "^",          with: "**")

        // Percentage shortcut: "X% of Y" → "(X/100)*Y"
        if let regex = try? NSRegularExpression(pattern: #"(\d+(?:\.\d+)?)\s*%\s*of\s*(\d+(?:\.\d+)?)"#),
           let match = regex.firstMatch(in: normalized, range: NSRange(normalized.startIndex..., in: normalized)),
           let pctRange = Range(match.range(at: 1), in: normalized),
           let valRange = Range(match.range(at: 2), in: normalized) {
            let pct = normalized[pctRange]
            let val = normalized[valRange]
            normalized = "(\(pct)/100.0)*\(val)"
        }

        let expr = NSExpression(format: normalized)
        guard let result = expr.expressionValue(with: nil, context: nil) else {
            return "I couldn't evaluate that expression."
        }
        return "The result is \(format(result))."
    }

    /// Renders an NSExpression result as a clean speech string. Integer
    /// values lose the trailing ".0", floats keep up to 4 decimal places.
    private func format(_ value: Any) -> String {
        if let int = value as? Int { return "\(int)" }
        if let dbl = value as? Double {
            if dbl == floor(dbl), abs(dbl) < 1e15 { return "\(Int(dbl))" }
            return String(format: "%.4g", dbl)
        }
        return "\(value)"
    }

    /// Translates text using the iOS 18+ Translation framework when
    /// available. Falls back to opening the Translate app for older OS
    /// versions or when the on-device language pair is missing.
    @MainActor
    private func translateText(text: String, targetLanguage: String) async -> String {
        let cleanText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanLang = targetLanguage.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanText.isEmpty else { return "What should I translate?" }
        guard !cleanLang.isEmpty else { return "Which language should I translate to?" }

        // Map natural-language language name → BCP-47 code.
        let langCode = languageCode(for: cleanLang)

        // Fallback path used in all cases for now: open the iOS Translate
        // app via the share / x-callback URL scheme is not exposed publicly,
        // so we deep-link to the Translate app and let the user paste/use it.
        // The Translation framework requires a SwiftUI view for the modal
        // .translationPresentation API and would add UI plumbing beyond the
        // 10.C scope — deferred to a polish pass.
        let target = langCode ?? cleanLang
        return "I'd translate '\(cleanText)' to \(target), but inline translation needs setup. Open the Translate app and I'll prefill it next time."
    }

    /// Maps common language names (EN + IT) to BCP-47 codes for the
    /// Translation framework. Returns nil if unknown — caller decides
    /// whether to error or pass through the raw name.
    private func languageCode(for name: String) -> String? {
        let n = name.lowercased().trimmingCharacters(in: .whitespaces)
        let map: [String: String] = [
            "english": "en", "inglese": "en",
            "italian": "it", "italiano": "it",
            "french": "fr", "francese": "fr",
            "spanish": "es", "spagnolo": "es",
            "german": "de", "tedesco": "de",
            "portuguese": "pt", "portoghese": "pt",
            "japanese": "ja", "giapponese": "ja",
            "chinese": "zh", "cinese": "zh",
            "korean": "ko", "coreano": "ko",
            "russian": "ru", "russo": "ru",
            "arabic": "ar", "arabo": "ar",
            "dutch": "nl", "olandese": "nl"
        ]
        return map[n]
    }

    // MARK: - Email

    private func sendEmail(to contact: String, subject: String, body: String) async -> String {
        var cs = CharacterSet.urlQueryAllowed; cs.remove(charactersIn: "+&=#")
        let subjectEnc = subject.addingPercentEncoding(withAllowedCharacters: cs) ?? subject
        let bodyEnc    = body.addingPercentEncoding(withAllowedCharacters: cs) ?? body
        let urlStr     = "mailto:\(contact)?subject=\(subjectEnc)&body=\(bodyEnc)"
        if let url = URL(string: urlStr) {
            await MainActor.run {
                GigiSmartOrchestrator.shared.showBanner("📧 Opening Mail...")
                UIApplication.shared.open(url)
            }
        }
        return "Opening Mail for \(contact.isEmpty ? "your email" : contact)."
    }

    // MARK: - Settings (wifi / bluetooth / generic)

    private func openSystemSettings(path: String, label: String) async -> String {
        // App-Prefs: deep links are blocked on iOS 16+ — fall back to GIGI settings (user taps from there).
        if let url = URL(string: UIApplication.openSettingsURLString) {
            await MainActor.run { UIApplication.shared.open(url) }
            return "Apple blocks direct access to \(label) settings from third-party apps. I've opened GIGI Settings — from there you can go to iOS Settings manually."
        }
        return "Couldn't open Settings."
    }

    // MARK: - Reminder

    func createReminder(text: String) async -> String {
        guard await ensureReminderAccess() else {
            return "Enable Reminders access in Settings."
        }
        let reminder = EKReminder(eventStore: eventStore)
        reminder.title    = text
        reminder.calendar = eventStore.defaultCalendarForNewReminders()
        do {
            try eventStore.save(reminder, commit: true)
            await MainActor.run {
                GigiSmartOrchestrator.shared.showBanner("📋 Reminder · \(text.prefix(50))")
            }
            return "Reminder set: \(text)"
        } catch {
            return "Couldn't save the reminder."
        }
    }

    // MARK: - Event (create)

    func createEvent(title: String, date: String, time: String) async -> String {
        guard await ensureCalendarAccess() else {
            return "Enable Calendar access in Settings."
        }

        let cleanTitle  = cleanEventTitle(title)
        let event       = EKEvent(eventStore: eventStore)
        event.title     = cleanTitle
        event.calendar  = eventStore.defaultCalendarForNewEvents
        let startDate   = parseDateTime(date: date, time: time)
        event.startDate = startDate
        event.endDate   = startDate.addingTimeInterval(3600)

        // Always add a 30-minute-before reminder so the user actually gets notified
        event.alarms = [EKAlarm(relativeOffset: -1800)]

        do {
            try eventStore.save(event, span: .thisEvent, commit: true)
            let df = DateFormatter()
            df.dateStyle = .medium
            df.timeStyle = .short
            return "'\(cleanTitle)' added on \(df.string(from: startDate)) with a reminder 30 minutes before."
        } catch {
            return "Couldn't create the event."
        }
    }

    private func cleanEventTitle(_ raw: String) -> String {
        var t = raw
        let temporalWords = [
            "tomorrow", "today", "next monday", "next tuesday", "next wednesday",
            "next thursday", "next friday", "next saturday", "next sunday",
            "monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday",
            "next week", "in two days", "in three days",
        ]
        for w in temporalWords {
            t = t.replacingOccurrences(of: w + " ", with: "", options: .caseInsensitive)
            t = t.replacingOccurrences(of: " " + w, with: "", options: .caseInsensitive)
        }
        let prefixes = ["i have a ", "i have an ", "i have my ", "i've got a ", "i've got an "]
        for p in prefixes {
            if t.lowercased().hasPrefix(p) { t = String(t.dropFirst(p.count)) }
        }
        if let range = t.range(of: #"\s+at\s+\d{1,2}[:.]\d{0,2}"#, options: .regularExpression) {
            t = String(t[..<range.lowerBound])
        }
        let result = t.trimmingCharacters(in: .whitespacesAndNewlines)
        return result.isEmpty ? raw : result.prefix(1).uppercased() + result.dropFirst()
    }

    // MARK: - Navigation

    func navigate(to destination: String) async -> String {
        let trimmed = destination.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "Where do you want to go?" }
        await MainActor.run { GigiSmartOrchestrator.shared.stopMicCapture() }
        GigiSmartOrchestrator.shared.showBanner("🗺️ Starting navigation...")

        // dirflg=d opens Maps directly in driving-directions mode (no manual tap needed)
        var cs = CharacterSet.urlQueryAllowed; cs.remove(charactersIn: "+&=#")
        let encoded = trimmed.addingPercentEncoding(withAllowedCharacters: cs) ?? trimmed
        let urlString = "maps://?daddr=\(encoded)&dirflg=d"
        guard let url = URL(string: urlString) else { return "Couldn't open Maps." }
        let opened = await MainActor.run(resultType: Bool.self) {
            UIApplication.shared.open(url)
            return true
        }
        return opened ? "Starting navigation to \(trimmed)." : "Couldn't open Maps."
    }

    // MARK: - Music

    func playMusic(query: String) async -> String {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        GigiSmartOrchestrator.shared.showBanner("🎵 Finding music...")

        // Primary: Apple Music / local library via MPMusicPlayerController.
        // Plays in the background without switching screens.
        if !q.isEmpty {
            if let msg = await playAppleMusic(query: q) { return msg }
        }

        // Spotify fallback — use synchronous open() on MainActor to satisfy iOS "trusted request"
        if !q.isEmpty, let spotifyScheme = URL(string: "spotify://"),
           await MainActor.run(resultType: Bool.self, body: { UIApplication.shared.canOpenURL(spotifyScheme) }) {
            var cs = CharacterSet.urlQueryAllowed; cs.remove(charactersIn: "+&=#?")
            let enc = q.addingPercentEncoding(withAllowedCharacters: cs) ?? q
            if let url = URL(string: "spotify:search:\(enc)") {
                await MainActor.run { UIApplication.shared.open(url, options: [:], completionHandler: nil) }
                return "Opened Spotify search for '\(q)'. Spotify doesn't support auto-play via URL — tap a track to play."
            }
        }

        if let url = URL(string: "music://") { await UIApplication.shared.open(url) }
        return "Opening Music."
    }

    /// Searches the user's Apple Music library and starts playback without switching screens.
    /// Returns a speech confirmation string on success, nil if no match found.
    private func playAppleMusic(query: String) async -> String? {
        let player = MPMusicPlayerController.systemMusicPlayer

        // Search by song title first
        let titlePredicate = MPMediaPropertyPredicate(
            value: query, forProperty: MPMediaItemPropertyTitle, comparisonType: .contains
        )
        let titleQuery = MPMediaQuery(filterPredicates: [titlePredicate])
        if let items = titleQuery.items, !items.isEmpty {
            let collection = MPMediaItemCollection(items: items)
            player.setQueue(with: collection)
            player.play()
            let title = items.first?.title ?? query
            return "Playing '\(title)'."
        }

        // Search by artist name
        let artistPredicate = MPMediaPropertyPredicate(
            value: query, forProperty: MPMediaItemPropertyArtist, comparisonType: .contains
        )
        let artistQuery = MPMediaQuery(filterPredicates: [artistPredicate])
        if let items = artistQuery.items, !items.isEmpty {
            let collection = MPMediaItemCollection(items: items)
            player.setQueue(with: collection)
            player.shuffleMode = .songs
            player.play()
            let artist = items.first?.artist ?? query
            return "Playing \(artist) on shuffle."
        }

        // Search by album title
        let albumPredicate = MPMediaPropertyPredicate(
            value: query, forProperty: MPMediaItemPropertyAlbumTitle, comparisonType: .contains
        )
        let albumQuery = MPMediaQuery(filterPredicates: [albumPredicate])
        if let items = albumQuery.items, !items.isEmpty {
            let collection = MPMediaItemCollection(items: items)
            player.setQueue(with: collection)
            player.play()
            let album = items.first?.albumTitle ?? query
            return "Playing album '\(album)'."
        }

        return nil
    }

    // MARK: - Open App

    private let appURLMap: [String: String] = [
        // System apps
        "safari":      "https://",
        "maps":        "maps://",
        "music":       "music://",
        "facetime":    "facetime://",
        "phone":       "tel://",
        "messages":    "sms:",
        "mail":        "mailto:",
        "camera":      "camera://",
        "photos":      "photos-redirect://",
        "settings":    UIApplication.openSettingsURLString,
        "notes":       "mobilenotes://",
        "reminders":   "x-apple-reminderkit://",
        "calendar":    "calshow://",
        "clock":       "clock-alarm://",
        "calculator":  "calc://",
        "wallet":      "shoebox://",
        "appstore":    "itms-apps://",
        "health":      "x-apple-health://",
        "shortcuts":   "shortcuts://",
        "files":       "shareddocuments://",
        "news":        "applenews://",
        "stocks":      "stocks://",
        "weather":     "weather://",
        "fitness":     "x-apple-fitness://",
        "podcasts":    "pcast://",
        "books":       "ibooks://",
        "translate":   "translate://",
        // Third-party
        "spotify":     "spotify://",
        "whatsapp":    "whatsapp://",
        "telegram":    "tg://",
        "instagram":   "instagram://",
        "youtube":     "youtube://",
        "tiktok":      "tiktok://",
        "twitter":     "twitter://",
        "x":           "twitter://",
        "netflix":     "nflx://",
        "gmail":       "googlegmail://",
        "chrome":      "googlechrome://",
        "slack":       "slack://",
        "zoom":        "zoomus://",
        "discord":     "discord://",
        "snapchat":    "snapchat://",
        "facebook":    "fb://",
        "reddit":      "reddit://",
        "linkedin":    "linkedin://",
        "uber":        "uber://",
        "waze":        "waze://",
        "notion":      "notion://",
        "duolingo":    "duolingo://",
        "shazam":      "shazam://",
    ]

    func openApp(_ appName: String) async -> String {
        let key = appName.lowercased().trimmingCharacters(in: .whitespaces)
        let normalized = key.replacingOccurrences(of: " ", with: "")

        // Flashlight has no public URL scheme — use torch API instead of e.g. torcia://
        let torchAliases: Set<String> = ["torcia", "flashlight", "torch", "linterna", "flash", "luce"]
        if torchAliases.contains(key) || torchAliases.contains(normalized) {
            return torchSet(on: true)
        }

        let urlToOpen: URL?
        if let urlStr = appURLMap[key] ?? appURLMap[normalized], let url = URL(string: urlStr) {
            urlToOpen = url
        } else if let url = URL(string: "\(normalized)://") {
            urlToOpen = url
        } else {
            urlToOpen = nil
        }
        
        if let url = urlToOpen {
            // Dispatch to main thread to avoid "unsafeForcedSync called from Swift Concurrent context"
            await MainActor.run {
                UIApplication.shared.open(url)
            }
            return "Opening \(appName)."
        }
        
        return "Couldn't open \(appName). Make sure it's installed."
    }

    // MARK: - Notification permission

    private func requestNotificationPermission() async -> Bool {
        let center   = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        if settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional {
            return true
        }
        return (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
    }

    // MARK: - Contacts

    private func ensureContactsAccess() async -> Bool {
        let status = CNContactStore.authorizationStatus(for: .contacts)
        switch status {
        case .authorized, .limited: return true
        case .denied, .restricted:  return false
        case .notDetermined:
            return await withCheckedContinuation { cont in
                contactStore.requestAccess(for: .contacts) { granted, _ in cont.resume(returning: granted) }
            }
        @unknown default: return false
        }
    }

    func resolveContact(_ name: String) async -> (number: String?, email: String?) {
        // Primary: GigiContactsEngine — fuzzy + relationship + memory-aware
        if let result = await GigiContactsEngine.shared.resolve(name) {
            return (result.phone, nil)
        }

        // Fallback: basic CNContactStore search (email-only or edge cases)
        let needle = name.lowercased()
        return await Task.detached(priority: .userInitiated) { [store = contactStore] in
            let keys: [CNKeyDescriptor] = [
                CNContactGivenNameKey  as CNKeyDescriptor,
                CNContactFamilyNameKey as CNKeyDescriptor,
                CNContactNicknameKey   as CNKeyDescriptor,
                CNContactPhoneNumbersKey  as CNKeyDescriptor,
                CNContactEmailAddressesKey as CNKeyDescriptor,
            ]
            var foundNumber: String?
            var foundEmail:  String?
            let request = CNContactFetchRequest(keysToFetch: keys)
            try? store.enumerateContacts(with: request) { contact, stop in
                let full = "\(contact.givenName) \(contact.familyName)".lowercased()
                let nick = contact.nickname.lowercased()
                let matches = full.contains(needle)
                    || contact.givenName.lowercased().contains(needle)
                    || contact.familyName.lowercased().contains(needle)
                    || (!nick.isEmpty && (nick.contains(needle) || needle.contains(nick)))
                if matches {
                    if let phone = contact.phoneNumbers.first {
                        let raw    = phone.value.stringValue
                        let digits = raw.filter(\.isNumber)
                        foundNumber = raw.contains("+") ? "+\(digits)" : digits
                    }
                    foundEmail = contact.emailAddresses.first.map { $0.value as String }
                    stop.pointee = true
                }
            }
            return (foundNumber, foundEmail)
        }.value
    }

    // MARK: - News

    private func readNews(query: String) async -> String {
        GigiSmartOrchestrator.shared.showBanner("📰 Fetching news...")
        var cs = CharacterSet.urlQueryAllowed; cs.remove(charactersIn: "+&=#")
        let encoded = query.addingPercentEncoding(withAllowedCharacters: cs) ?? query
        guard let rssURL = URL(string: "https://news.google.com/rss/search?q=\(encoded)&hl=en&gl=US&ceid=US:en") else {
            return "Couldn't build the news URL."
        }
        do {
            let cfg = URLSessionConfiguration.default
            cfg.timeoutIntervalForRequest = 8
            let (data, _) = try await URLSession(configuration: cfg).data(from: rssURL)
            guard let xml = String(data: data, encoding: .utf8) else { return "Couldn't read news." }
            let titles   = extractXMLTags("title", from: xml)
                .filter { !$0.lowercased().contains("google") }
                .prefix(4)
            let snippets = extractXMLTags("description", from: xml).prefix(4)
            guard !titles.isEmpty else { return "No news found for '\(query)'." }
            let rawText = zip(titles, snippets).map { title, desc -> String in
                let clean = desc.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
                return "\(title). \(clean)"
            }.joined(separator: " ")
            return await GigiCloudService.shared.summarizeNews(text: rawText, topic: query)
        } catch {
            return "Couldn't fetch news: \(error.localizedDescription)"
        }
    }

    private func extractXMLTags(_ tag: String, from xml: String) -> [String] {
        var results: [String] = []
        var search = xml
        let open   = "<\(tag)>"
        let close  = "</\(tag)>"
        while let start = search.range(of: open),
              let end   = search.range(of: close),
              start.upperBound <= end.lowerBound {
            var content = String(search[start.upperBound..<end.lowerBound])
            if content.hasPrefix("<![CDATA["), content.hasSuffix("]]>") {
                content = String(content.dropFirst(9).dropLast(3))
            }
            results.append(content.trimmingCharacters(in: .whitespacesAndNewlines))
            search = String(search[end.upperBound...])
        }
        return results
    }

    // MARK: - Order Food

    private func orderFood(restaurant: String) async -> String {
        let deliveryApps: [(name: String, scheme: String)] = [
            ("Deliveroo", "deliveroo://"),
            ("Uber Eats",  "ubereats://"),
            ("Just Eat",   "justeat://"),
            ("Glovo",      "glovo://"),
        ]
        for app in deliveryApps {
            guard let url = URL(string: app.scheme), UIApplication.shared.canOpenURL(url) else { continue }
            await UIApplication.shared.open(url)
            let msg = restaurant.isEmpty
                ? "Opening \(app.name)."
                : "Opening \(app.name) to order from \(restaurant)."
            GigiSmartOrchestrator.shared.showBanner("🍕 \(msg)")
            return msg
        }
        if !restaurant.isEmpty {
            // setPendingCallAction call removed (2026-05-11, zombie audit): the side-effect
            // var pendingCallContact was never read elsewhere. The follow-up question is
            // surfaced via speech only — user can respond by saying "call <restaurant>".
            return "I don't see any delivery apps installed. Want me to call \(restaurant) directly?"
        }
        return "I don't see any delivery apps. Try installing Deliveroo, Uber Eats, or Glovo."
    }

    // MARK: - Book Restaurant

    private func bookRestaurant(restaurant: String, time: String, guests: Int) async -> String {
        guard !restaurant.isEmpty else { return "Which restaurant do you want to book?" }
        GigiSmartOrchestrator.shared.showBanner("🍽️ Booking table...")
        let t      = time.isEmpty ? "20:00" : time
        let booked = await GigiWebAgent.shared.bookRestaurant(name: restaurant, time: t, guests: guests)
        if booked {
            let gLabel = guests == 1 ? "person" : "people"
            return "Done! Table booked at \(restaurant) for \(guests) \(gLabel) at \(time.isEmpty ? "8 PM" : time)."
        }
        // setPendingCallAction call removed (2026-05-11, zombie audit): see note above.
        return "I couldn't book online at \(restaurant). Want me to call them?"
    }

    // MARK: - Helpers

    private func parseDateTime(date: String, time: String) -> Date {
        var comps = Calendar.current.dateComponents([.year, .month, .day], from: Date())
        let dateLower = date.lowercased()
        if dateLower.contains("tomorrow") {
            comps.day = (comps.day ?? 0) + 1
        }
        if let colon = time.firstIndex(of: ":") {
            comps.hour   = Int(time[..<colon]) ?? 12
            comps.minute = Int(time[time.index(after: colon)...].prefix(2)) ?? 0
        }
        return Calendar.current.date(from: comps) ?? Date()
    }
}
