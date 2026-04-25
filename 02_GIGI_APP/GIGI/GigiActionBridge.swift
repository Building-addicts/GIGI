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
        print("GIGI Bridge: \(intent.label)")

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

        case "homekit_scene":
            let scene = intent.params["scene"] ?? intent.params["raw"] ?? ""
            GigiSmartOrchestrator.shared.showBanner("🏠 Activating scene...")
            return await GigiHomeKit.shared.activateScene(scene)

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
        print("GIGI Gateway: payload → \(input)")
        let parts = input.split(separator: "|", maxSplits: 2).map(String.init)
        guard let cmd = parts.first else { return false }
        switch cmd {
        case "CALL":
            guard parts.count >= 2 else { return false }
            let number = parts[1]
            let shortcutOpened = await openGatewayXCallbackFallback(input: input)
            if shortcutOpened { return true }
            guard let telURL = URL(string: "tel://\(number)") else { return false }
            print("GIGI Gateway: tel:// fallback → \(number)")
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
                print("GIGI Gateway: WhatsApp non installato")
                return false
            }
            print("GIGI Gateway: WhatsApp diretto → \(digits)")
            return await MainActor.run(resultType: Bool.self) {
                UIApplication.shared.open(url)
                return true
            }
        case "URL":
            guard parts.count >= 2, let url = URL(string: parts[1]) else { return false }
            print("GIGI Gateway: URL diretto → \(url)")
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
        print("GIGI Gateway: fallback Shortcuts → \(input)")
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

    // MARK: - Call

    private func sanitizePhoneNumber(_ raw: String) -> String {
        raw.filter { "0123456789+*#".contains($0) }
    }

    func makeCallAutomatic(to contact: String) async -> String {
        guard !contact.isEmpty else { return "Who do you want to call?" }
        guard await ensureContactsAccess() else {
            return "Turn on Contacts for GIGI in Settings → Privacy → Contacts."
        }
        let resolved = await resolveContact(contact)
        guard let number = resolved.number, !number.isEmpty else {
            return "Couldn't find \(contact) in your contacts."
        }
        let digits = gatewayPhoneDigits(sanitizePhoneNumber(number))
        guard !digits.isEmpty else { return "Invalid phone number for \(contact)." }

        await MainActor.run {
            GigiSmartOrchestrator.shared.stopMicCapture()
            GigiSmartOrchestrator.shared.showBanner("📞 Calling \(contact)...")
            GigiSpeechService.shared.speak("Calling \(contact).")
        }
        try? await Task.sleep(nanoseconds: 650_000_000)

        // Direct tel:// — no Shortcuts indirection needed for calls
        guard let telURL = URL(string: "tel://\(digits)") else { return "Invalid phone number." }
        let opened = await MainActor.run(resultType: Bool.self) {
            UIApplication.shared.open(telURL)
            return true
        }
        return opened ? "Tap Call to confirm — iOS requires your approval before dialing \(contact)." : "Couldn't start the call."
    }

    // MARK: - Messages

    func sendMessageAutomatic(to contact: String, body: String, platform: String) async -> String {
        guard !contact.isEmpty else { return "Who should I message?" }
        let resolved = await resolveContact(contact)
        guard let number = resolved.number, !number.isEmpty else {
            return "Couldn't find \(contact)."
        }
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
        return "Timer set for \(timerLabel(seconds: seconds))."
    }

    private func parseTimerDuration(_ text: String) -> Int {
        let lower = text.lowercased()
        var total = 0
        let patterns: [(String, Int)] = [
            ("(\\d+)\\s*(?:hour|ora|ore|hr|h)(?:[^a-z]|$)", 3600),
            ("(\\d+)\\s*(?:minute|minuto|minuti|min|m)(?:[^a-z]|$)", 60),
            ("(\\d+)\\s*(?:second|secondo|secondi|sec|s)(?:[^a-z]|$)", 1)
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
        return "Alarm set for \(f.string(from: fireDate))."
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
        let resolved = await resolveContact(contact)
        guard let number = resolved.number, !number.isEmpty else {
            return "Couldn't find \(contact) in your contacts."
        }
        let scheme = audio ? "facetime-audio" : "facetime"
        let digits = gatewayPhoneDigits(sanitizePhoneNumber(number))
        guard let url = URL(string: "\(scheme)://\(digits)") else {
            return "Couldn't build FaceTime URL."
        }
        GigiSmartOrchestrator.shared.showBanner(audio ? "📞 FaceTime audio..." : "📹 FaceTime video...")
        await UIApplication.shared.open(url)
        return audio ? "Starting FaceTime audio with \(contact)." : "Starting FaceTime with \(contact)."
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
            let q = "I don't see any delivery apps installed. Want me to call \(restaurant) directly?"
            GigiSmartOrchestrator.shared.setPendingCallAction(contact: restaurant, prompt: q)
            return q
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
        let q = "I couldn't book online at \(restaurant). Want me to call them?"
        GigiSmartOrchestrator.shared.setPendingCallAction(contact: restaurant, prompt: q)
        return q
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
