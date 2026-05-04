import AppIntents
import CoreLocation
import EventKit
import Foundation
import UserNotifications

// MARK: - GigiExecuteSystemCommandIntent
//
// Escape hatch for system commands whose native Shortcut action mappings are
// not available in shortcuts-py yet. The generated Shortcut still owns the
// branch and explicitly calls this AppIntent only for those blocked families,
// keeping GIGI as the orchestrator and avoiding fake TODO branches.

@available(iOS 16.0, *)
struct GigiExecuteSystemCommandIntent: AppIntent {
    static var title: LocalizedStringResource = "Execute GIGI system command"
    static var description = IntentDescription(
        "Execute a GIGI system command that does not have a reliable generated Shortcut action mapping yet."
    )
    static var openAppWhenRun: Bool = false

    @Parameter(title: "Command marker", description: "A SYS marker returned by GIGI, such as SYS:timer:10.")
    var marker: String

    @Parameter(title: "Session ID", description: "The GIGI session token from Begin GIGI session.")
    var sessionID: String?

    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let speech = await GigiSystemCommandExecutor.execute(marker: marker)
        if let sessionID, !sessionID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            await GigiOrchestratorSessionStore.shared.confirm(
                sessionID: sessionID,
                result: marker,
                confirmation: speech
            )
        }
        return .result(value: speech)
    }
}

// MARK: - GigiSystemCommandExecutor

enum GigiSystemCommandExecutor {
    static func execute(marker rawMarker: String) async -> String {
        let marker = rawMarker.trimmingCharacters(in: .whitespacesAndNewlines)
        guard marker.hasPrefix("SYS:") else { return "I can't execute that command." }

        if marker.hasPrefix("SYS:alarm:") {
            return await setAlarm(payload(marker, prefix: "SYS:alarm:").replacingOccurrences(of: "-", with: ":"))
        }
        if marker.hasPrefix("SYS:timer:") {
            return await setTimer(payload(marker, prefix: "SYS:timer:"))
        }
        if marker.hasPrefix("SYS:reminder:") {
            return await createReminder(payload(marker, prefix: "SYS:reminder:"))
        }
        if marker.hasPrefix("SYS:weather:") {
            return await fetchWeather(payload(marker, prefix: "SYS:weather:"))
        }
        if marker.hasPrefix("SYS:location:") {
            return await currentLocationSpeech()
        }
        if marker.hasPrefix("SYS:event:") {
            return await createEvent(payload(marker, prefix: "SYS:event:"))
        }
        return "That GIGI system command is not available yet."
    }

    private static func payload(_ marker: String, prefix: String) -> String {
        String(marker.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: Notifications

    private static func requestNotificationPermission() async -> Bool {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        if settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional {
            return true
        }
        return (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
    }

    private static func setTimer(_ minutesPayload: String) async -> String {
        guard let minutes = Int(minutesPayload), (1...600).contains(minutes) else {
            return "How long should the timer run?"
        }
        guard await requestNotificationPermission() else {
            return "Enable Notifications in Settings so I can set timers."
        }

        let content = UNMutableNotificationContent()
        content.title = "GIGI Timer"
        content.body = "Timer expired."
        content.sound = .default

        let seconds = TimeInterval(minutes * 60)
        let request = UNNotificationRequest(
            identifier: "gigi.shortcut.timer.\(Date().timeIntervalSince1970)",
            content: content,
            trigger: UNTimeIntervalNotificationTrigger(timeInterval: seconds, repeats: false)
        )
        do {
            try await UNUserNotificationCenter.current().add(request)
            return "Timer set for \(minutes) minute\(minutes == 1 ? "" : "s")."
        } catch {
            return "Couldn't set the timer."
        }
    }

    private static func setAlarm(_ time: String) async -> String {
        guard !time.isEmpty else { return "What time should I set the alarm for?" }
        guard await requestNotificationPermission() else {
            return "Enable Notifications in Settings so I can set alarms."
        }
        guard let fireDate = parseAlarmDate(time) else {
            return "Couldn't parse that time. Try something like 7:30 AM."
        }

        let content = UNMutableNotificationContent()
        content.title = "GIGI Alarm"
        content.body = "Time to wake up!"
        content.sound = .default

        let comps = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: fireDate)
        let request = UNNotificationRequest(
            identifier: "gigi.shortcut.alarm.\(Date().timeIntervalSince1970)",
            content: content,
            trigger: UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)
        )
        do {
            try await UNUserNotificationCenter.current().add(request)
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en-US")
            formatter.dateFormat = "h:mm a"
            return "Alarm set for \(formatter.string(from: fireDate))."
        } catch {
            return "Couldn't schedule the alarm."
        }
    }

    private static func parseAlarmDate(_ raw: String) -> Date? {
        let lower = raw.lowercased()
        let formats = ["h:mm a", "h:mma", "HH:mm", "h a", "ha", "h:mm", "H:mm"]
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en-US")
        for format in formats {
            formatter.dateFormat = format
            if let parsed = formatter.date(from: lower) {
                var timeComps = Calendar.current.dateComponents([.hour, .minute], from: parsed)
                let dayComps = Calendar.current.dateComponents([.year, .month, .day], from: Date())
                timeComps.year = dayComps.year
                timeComps.month = dayComps.month
                timeComps.day = dayComps.day
                if let today = Calendar.current.date(from: timeComps), today > Date() { return today }
                timeComps.day = (timeComps.day ?? 0) + 1
                return Calendar.current.date(from: timeComps)
            }
        }
        return nil
    }

    // MARK: EventKit

    private static func createReminder(_ body: String) async -> String {
        let text = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return "What should I remind you about?" }

        let store = EKEventStore()
        guard await requestReminderAccess(store: store) else {
            return "Enable Reminders access in Settings."
        }
        let reminder = EKReminder(eventStore: store)
        reminder.title = text
        reminder.calendar = store.defaultCalendarForNewReminders()
        do {
            try store.save(reminder, commit: true)
            return "Reminder created: \(text)."
        } catch {
            return "Couldn't create the reminder."
        }
    }

    private static func createEvent(_ body: String) async -> String {
        let title = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return "What should I add to your calendar?" }

        let store = EKEventStore()
        guard await requestCalendarAccess(store: store) else {
            return "Enable Calendar access in Settings."
        }
        let start = parseEventDate(from: title)
        let event = EKEvent(eventStore: store)
        event.title = cleanEventTitle(title)
        event.calendar = store.defaultCalendarForNewEvents
        event.startDate = start
        event.endDate = start.addingTimeInterval(3600)
        event.alarms = [EKAlarm(relativeOffset: -1800)]
        do {
            try store.save(event, span: .thisEvent, commit: true)
            let formatter = DateFormatter()
            formatter.dateStyle = .medium
            formatter.timeStyle = .short
            return "Calendar event created for \(formatter.string(from: start))."
        } catch {
            return "Couldn't create the calendar event."
        }
    }

    private static func requestReminderAccess(store: EKEventStore) async -> Bool {
        var status = EKEventStore.authorizationStatus(for: .reminder)
        if status == .notDetermined {
            let granted = await withCheckedContinuation { continuation in
                store.requestFullAccessToReminders { granted, _ in continuation.resume(returning: granted) }
            }
            guard granted else { return false }
            status = EKEventStore.authorizationStatus(for: .reminder)
        }
        return status == .fullAccess || status == .writeOnly
    }

    private static func requestCalendarAccess(store: EKEventStore) async -> Bool {
        var status = EKEventStore.authorizationStatus(for: .event)
        if status == .notDetermined {
            let granted = await withCheckedContinuation { continuation in
                store.requestFullAccessToEvents { granted, _ in continuation.resume(returning: granted) }
            }
            guard granted else { return false }
            status = EKEventStore.authorizationStatus(for: .event)
        }
        return status == .fullAccess || status == .writeOnly
    }

    private static func parseEventDate(from text: String) -> Date {
        var comps = Calendar.current.dateComponents([.year, .month, .day], from: Date())
        let lower = text.lowercased()
        if lower.contains("tomorrow") || lower.contains("domani") {
            comps.day = (comps.day ?? 0) + 1
        }
        if let range = lower.range(of: "\\b\\d{1,2}:\\d{2}\\b", options: .regularExpression) {
            let time = lower[range].split(separator: ":")
            comps.hour = Int(time.first ?? "12") ?? 12
            comps.minute = Int(time.dropFirst().first ?? "0") ?? 0
        } else if let range = lower.range(of: "\\b\\d{1,2}\\s*(?:am|pm)\\b", options: .regularExpression) {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en-US")
            formatter.dateFormat = "ha"
            let compact = lower[range].replacingOccurrences(of: " ", with: "")
            if let date = formatter.date(from: compact) {
                let parsed = Calendar.current.dateComponents([.hour, .minute], from: date)
                comps.hour = parsed.hour
                comps.minute = parsed.minute
            }
        } else {
            comps.hour = 12
            comps.minute = 0
        }
        return Calendar.current.date(from: comps) ?? Date()
    }

    private static func cleanEventTitle(_ raw: String) -> String {
        var title = raw
        for word in ["tomorrow", "today", "domani", "oggi"] {
            title = title.replacingOccurrences(of: word, with: "", options: [.caseInsensitive])
        }
        title = title.replacingOccurrences(of: "\\b\\d{1,2}:\\d{2}\\b", with: "", options: .regularExpression)
        title = title.replacingOccurrences(of: "\\b\\d{1,2}\\s*(?:am|pm)\\b", with: "", options: [.regularExpression, .caseInsensitive])
        let cleaned = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "GIGI event" : cleaned
    }

    // MARK: Weather / Location

    private static func fetchWeather(_ location: String) async -> String {
        let loc = location.trimmingCharacters(in: .whitespacesAndNewlines)
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "+&=#")
        let slug = loc.isEmpty ? "auto" : (loc.addingPercentEncoding(withAllowedCharacters: allowed) ?? loc)
        guard let url = URL(string: "https://wttr.in/\(slug)?format=j1") else {
            return "Couldn't build the weather request."
        }
        do {
            let config = URLSessionConfiguration.default
            config.timeoutIntervalForRequest = 8
            config.timeoutIntervalForResource = 10
            let session = URLSession(configuration: config)
            let (data, _) = try await session.data(from: url)
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let condition = (json["current_condition"] as? [[String: Any]])?.first
            else { return "Couldn't read weather data." }
            let tempC = (condition["temp_C"] as? String) ?? "--"
            let feelsC = (condition["FeelsLikeC"] as? String) ?? "--"
            let desc = ((condition["weatherDesc"] as? [[String: Any]])?.first?["value"] as? String) ?? "Unknown"
            let humidity = (condition["humidity"] as? String) ?? "--"
            let label = loc.isEmpty ? "your location" : loc
            return "\(desc), \(tempC)°C in \(label). Feels like \(feelsC)°C, humidity \(humidity)%."
        } catch {
            return "Couldn't reach weather service. Check your connection."
        }
    }

    private static func currentLocationSpeech() async -> String {
        let reader = await MainActor.run { GigiCurrentLocationReader() }
        let result = await reader.read()
        switch result {
        case .success(let location):
            return "Your location is \(String(format: "%.5f", location.coordinate.latitude)), \(String(format: "%.5f", location.coordinate.longitude))."
        case .failure:
            return "Enable Location access in Settings so I can check where you are."
        }
    }
}

// MARK: - GigiCurrentLocationReader

@MainActor
private final class GigiCurrentLocationReader: NSObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private var continuation: CheckedContinuation<Result<CLLocation, Error>, Never>?

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
    }

    func read() async -> Result<CLLocation, Error> {
        if manager.authorizationStatus == .notDetermined {
            return .failure(CLError(.denied))
        }

        return await withCheckedContinuation { continuation in
            self.continuation = continuation
            let status = manager.authorizationStatus
            switch status {
            case .authorizedAlways, .authorizedWhenInUse:
                manager.requestLocation()
            default:
                finish(.failure(CLError(.denied)))
            }
        }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        switch manager.authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse:
            manager.requestLocation()
        case .denied, .restricted:
            finish(.failure(CLError(.denied)))
        default:
            break
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        if let location = locations.last {
            finish(.success(location))
        } else {
            finish(.failure(CLError(.locationUnknown)))
        }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        finish(.failure(error))
    }

    private func finish(_ result: Result<CLLocation, Error>) {
        guard let continuation else { return }
        self.continuation = nil
        continuation.resume(returning: result)
    }
}
