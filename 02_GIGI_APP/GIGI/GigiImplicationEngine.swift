import Foundation

// MARK: - Azione implicita
struct ImpliedAction {
    let type:     String            // "set_alarm", "set_reminder", "create_event"
    let params:   [String: String]  // parametri dell'azione
    let priority: Int               // ordine di esecuzione (1 = prima)
    let reason:   String            // perché è stata dedotta
}

// MARK: - GigiImplicationEngine
// Knowledge graph: dato un contesto, deduce le azioni implicite
// Es: "dentist tomorrow at 8" → sveglia 7:30 + promemoria sera prima
class GigiImplicationEngine {
    static let shared = GigiImplicationEngine()

    // MARK: - Entry point principale
    func inferActions(from entities: GigiEntities, intent: GigiIntent) -> [ImpliedAction] {
        var implied: [ImpliedAction] = []
        let topics  = entities.topics
        let dates   = entities.dates
        let times   = entities.times
        let text    = entities.rawText.lowercased()

        // ── Regole per topic MEDICAL ────────────────────────────────────────
        if topics.contains("medical") || text.contains("dentist") || text.contains("doctor") {
            // Alarm 30 min prima
            if let time = times.first {
                let alarmTime = subtractMinutes(from: time, minutes: 30)
                implied.append(ImpliedAction(
                    type: "set_alarm",
                    params: ["time": alarmTime, "label": "Before appointment"],
                    priority: 1,
                    reason: "Medical appointment — alarm 30min before"
                ))
            }
            // Reminder sera prima
            if let date = dates.first, date != "today" {
                implied.append(ImpliedAction(
                    type: "set_reminder",
                    params: [
                        "text": "Reminder: \(extractAppointmentTitle(text)) tomorrow",
                        "time": "21:00",
                        "date": "day_before"
                    ],
                    priority: 2,
                    reason: "Medical appointment — reminder evening before"
                ))
            }
        }

        // ── Regole per topic TRAVEL ──────────────────────────────────────────
        if topics.contains("travel") {
            // Sveglia 3h prima per voli
            if text.contains("flight") || text.contains("plane") {
                if let time = times.first {
                    let alarmTime = subtractMinutes(from: time, minutes: 180)
                    implied.append(ImpliedAction(
                        type: "set_alarm",
                        params: ["time": alarmTime, "label": "Flight preparation"],
                        priority: 1,
                        reason: "Flight — alarm 3 hours before"
                    ))
                }
                // Reminder check-in 24h prima
                implied.append(ImpliedAction(
                    type: "set_reminder",
                    params: ["text": "Check in online for your flight", "time": "09:00", "date": "day_before"],
                    priority: 3,
                    reason: "Flight — online check-in reminder"
                ))
            }

            // Navigazione all'aeroporto
            if text.contains("airport") || text.contains("flight") {
                implied.append(ImpliedAction(
                    type: "navigation",
                    params: ["destination": "airport", "timing": "deferred"],
                    priority: 4,
                    reason: "Travel — navigation to airport when needed"
                ))
            }
        }

        // ── Regole per topic MEETING/WORK ────────────────────────────────────
        if topics.contains("work") || text.contains("meeting") {
            // Reminder 15 min prima
            if let time = times.first {
                let reminderTime = subtractMinutes(from: time, minutes: 15)
                implied.append(ImpliedAction(
                    type: "set_reminder",
                    params: ["text": "Meeting starts in 15 minutes", "time": reminderTime],
                    priority: 2,
                    reason: "Meeting — 15min warning"
                ))
            }
            // Se ha location, navigazione
            if !entities.places.isEmpty {
                implied.append(ImpliedAction(
                    type: "navigation",
                    params: ["destination": entities.places.first ?? ""],
                    priority: 3,
                    reason: "Meeting has location — navigation available"
                ))
            }
        }

        // ── Regole per BIRTHDAY ───────────────────────────────────────────────
        if text.contains("birthday") {
            // Reminder 3 giorni prima
            implied.append(ImpliedAction(
                type: "set_reminder",
                params: ["text": "Birthday coming up — don't forget!", "date": "3_days_before"],
                priority: 2,
                reason: "Birthday — early reminder"
            ))
            // Suggerisci messaggio
            if !entities.contacts.isEmpty {
                implied.append(ImpliedAction(
                    type: "suggest_message",
                    params: [
                        "contact": entities.contacts.first ?? "",
                        "template": "Happy Birthday! 🎉"
                    ],
                    priority: 3,
                    reason: "Birthday — suggest congratulations message"
                ))
            }
        }

        // ── Regole per FITNESS/GYM ────────────────────────────────────────────
        if topics.contains("fitness") || text.contains("gym") || text.contains("workout") {
            // Sveglia se mattina presto
            if let time = times.first, isEarlyMorning(time) {
                implied.append(ImpliedAction(
                    type: "set_alarm",
                    params: ["time": time, "label": "Gym time 💪"],
                    priority: 1,
                    reason: "Early morning workout — alarm"
                ))
            }
            // Timer workout
            implied.append(ImpliedAction(
                type: "set_timer",
                params: ["seconds": "3600", "label": "Workout"],
                priority: 4,
                reason: "Workout — 1 hour timer available"
            ))
        }

        // ── Regole per FOOD/RESTAURANT ────────────────────────────────────────
        if topics.contains("food") && (text.contains("restaurant") || text.contains("dinner") || text.contains("lunch")) {
            // Navigazione al ristorante
            if !entities.places.isEmpty || entities.contacts.contains(where: { $0.lowercased() != "" }) {
                implied.append(ImpliedAction(
                    type: "find_nearby",
                    params: ["query": extractFoodQuery(text)],
                    priority: 3,
                    reason: "Food — find nearby restaurants"
                ))
            }
            // Reminder se ha orario
            if let time = times.first {
                let reminderTime = subtractMinutes(from: time, minutes: 30)
                implied.append(ImpliedAction(
                    type: "set_reminder",
                    params: ["text": "Reservation reminder", "time": reminderTime],
                    priority: 2,
                    reason: "Dinner/lunch — 30min reminder"
                ))
            }
        }

        // ── Regola URGENZA ────────────────────────────────────────────────────
        if entities.sentiment == "urgent" {
            // Metti tutte le azioni come priority 0
            return implied.map {
                ImpliedAction(type: $0.type, params: $0.params, priority: 0, reason: $0.reason + " [URGENT]")
            }
        }

        return implied.sorted { $0.priority < $1.priority }
    }

    // MARK: - Helper: sottrai minuti da orario
    func subtractMinutes(from timeString: String, minutes: Int) -> String {
        let lower = timeString.lowercased()
            .replacingOccurrences(of: "am", with: "")
            .replacingOccurrences(of: "pm", with: "")
            .trimmingCharacters(in: .whitespaces)

        var hour   = 0
        var minute = 0
        let isPM = timeString.lowercased().contains("pm")

        if lower.contains(":") {
            let parts = lower.components(separatedBy: ":")
            hour   = Int(parts[0].filter { $0.isNumber }) ?? 0
            minute = Int(parts[1].filter { $0.isNumber }) ?? 0
        } else {
            hour = Int(lower.filter { $0.isNumber }) ?? 0
        }

        if isPM && hour < 12 { hour += 12 }

        // Sottrai minuti
        var totalMinutes = hour * 60 + minute - minutes
        if totalMinutes < 0 { totalMinutes += 24 * 60 }

        let newHour   = totalMinutes / 60
        let newMinute = totalMinutes % 60

        return String(format: "%d:%02d", newHour, newMinute)
    }

    // MARK: - Helper: è mattina presto?
    private func isEarlyMorning(_ time: String) -> Bool {
        let lower = time.lowercased()
        if lower.contains("am") { return true }
        if let hour = Int(lower.filter { $0.isNumber }.prefix(2)) {
            return hour < 10
        }
        return false
    }

    // MARK: - Helper: estrai titolo appuntamento
    private func extractAppointmentTitle(_ text: String) -> String {
        let keywords = ["dentist","doctor","checkup","appointment","meeting","interview"]
        return keywords.first(where: { text.contains($0) })?.capitalized ?? "Appointment"
    }

    // MARK: - Helper: estrai query food
    private func extractFoodQuery(_ text: String) -> String {
        let foods = ["pizza","sushi","burger","chinese","italian","mexican","indian","thai","japanese"]
        return foods.first(where: { text.contains($0) }) ?? "restaurant"
    }
}
