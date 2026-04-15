import Contacts
import EventKit
import Foundation
import Intents
import UIKit

@MainActor
class GigiActionBridge {
    static let shared = GigiActionBridge()

    func execute(_ intent: GigiIntent) async -> String {
        print("GIGI Bridge: Executing \(intent.label)")

        switch intent.label {
        case "make_call":
            return await makeCallAutomatic(to: intent.params["contact"] ?? "")

        case "send_message":
            let contact = intent.params["contact"] ?? ""
            let body = intent.params["body"] ?? ""
            let platform = intent.params["platform"] ?? "imessage"
            return await sendMessageAutomatic(to: contact, body: body, platform: platform)

        case "set_reminder":
            return await createReminder(text: intent.params["text"] ?? intent.params["raw"] ?? "")

        case "create_event":
            let title = intent.params["title"] ?? "Event"
            let date = intent.params["date"] ?? "today"
            let time = intent.params["time"] ?? "12:00"
            return await createEvent(title: title, date: date, time: time)

        case "navigation":
            return await navigate(to: intent.params["destination"] ?? "")

        case "play_music":
            return await playMusic(query: intent.params["query"] ?? "")

        case "open_app":
            return await openApp(intent.params["app"] ?? "")

        default:
            return "I don't know how to do that yet."
        }
    }

    func makeCallAutomatic(to contact: String) async -> String {
        guard !contact.isEmpty else {
            return "I need a contact name to call."
        }

        let resolved = await resolveContact(contact)
        let number = resolved.number ?? ""

        guard !number.isEmpty else {
            return "Couldn't find \(contact) in your contacts."
        }

        let cleaned = number.components(separatedBy: CharacterSet.decimalDigits.inverted).joined()

        do {
            try await GigiCallKitManager.shared.makeCall(to: cleaned, contactName: contact)
            return "Calling \(contact)."
        } catch {
            print("GIGI CallKit: Failed — \(error)")
            await UIApplication.shared.open(URL(string: "tel://\(cleaned)")!)
            return "Opening Phone for \(contact)."
        }
    }

    func makeCallWithIntent(to contact: String) async -> String {
        await makeCallAutomatic(to: contact)
    }

    func sendMessageAutomatic(to contact: String, body: String, platform: String) async -> String {
        guard !contact.isEmpty else {
            return "I need a contact name."
        }

        let resolved = await resolveContact(contact)
        let number = resolved.number ?? ""

        guard !number.isEmpty else {
            return "Couldn't find \(contact)."
        }

        let encoded = body.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        let url: URL?
        switch platform.lowercased() {
        case "whatsapp", "wa":
            url = URL(string: "whatsapp://send?phone=\(number)&text=\(encoded)")
        case "telegram":
            url = URL(string: "tg://msg?text=\(encoded)")
        default:
            url = URL(string: "sms:\(number)&body=\(encoded)")
        }

        guard let messageURL = url else {
            return "Invalid message URL."
        }

        await UIApplication.shared.open(messageURL)

        try? await Task.sleep(nanoseconds: 2_000_000_000)

        do {
            let action = VisionAction(type: .send, targetText: "Send")
            let success = try await GigiVisionAgent.shared.execute(action: action)
            if success {
                return "Message sent to \(contact) automatically."
            }
            return "Message ready for \(contact). Tap Send."
        } catch {
            print("GIGI Vision: Failed — \(error)")
            return "Message ready. Tap Send."
        }
    }

    func createReminder(text: String) async -> String {
        let eventStore = EKEventStore()

        let status = EKEventStore.authorizationStatus(for: .reminder)
        if status == .notDetermined {
            do {
                let granted = try await eventStore.requestAccess(to: .reminder)
                guard granted else {
                    await UIApplication.shared.open(URL(string: "x-apple-reminderkit://")!)
                    return "Please grant Reminders access."
                }
            } catch {
                await UIApplication.shared.open(URL(string: "x-apple-reminderkit://")!)
                return "Opening Reminders."
            }
        }

        guard status == .authorized || status == .fullAccess else {
            await UIApplication.shared.open(URL(string: "x-apple-reminderkit://")!)
            return "Enable Reminders access in Settings."
        }

        let reminder = EKReminder(eventStore: eventStore)
        reminder.title = text
        reminder.calendar = eventStore.defaultCalendarForNewReminders()

        do {
            try eventStore.save(reminder, commit: true)
            return "Reminder created: \(text)"
        } catch {
            await UIApplication.shared.open(URL(string: "x-apple-reminderkit://")!)
            return "Opening Reminders."
        }
    }

    func createEvent(title: String, date: String, time: String) async -> String {
        let eventStore = EKEventStore()

        let status = EKEventStore.authorizationStatus(for: .event)
        if status == .notDetermined {
            do {
                let granted = try await eventStore.requestAccess(to: .event)
                guard granted else { return "Calendar access required." }
            } catch {
                return "Calendar access error."
            }
        }

        guard status == .authorized || status == .fullAccess else {
            return "Enable Calendar access in Settings."
        }

        let event = EKEvent(eventStore: eventStore)
        event.title = title
        event.calendar = eventStore.defaultCalendarForNewEvents

        let startDate = parseDateTime(date: date, time: time)
        event.startDate = startDate
        event.endDate = startDate.addingTimeInterval(3600)

        do {
            try eventStore.save(event, span: .thisEvent, commit: true)
            return "Event created: \(title)"
        } catch {
            return "Couldn't create event."
        }
    }

    func navigate(to destination: String) async -> String {
        let encoded = destination.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        await UIApplication.shared.open(URL(string: "maps://?daddr=\(encoded)")!)
        return "Navigating to \(destination)."
    }

    func playMusic(query: String) async -> String {
        if UIApplication.shared.canOpenURL(URL(string: "spotify://")!) {
            let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
            await UIApplication.shared.open(URL(string: "spotify://search/\(encoded)")!)
            return "Searching '\(query)' on Spotify."
        }
        await UIApplication.shared.open(URL(string: "music://")!)
        return "Opening Music."
    }

    func openApp(_ appName: String) async -> String {
        let scheme = appName.lowercased().replacingOccurrences(of: " ", with: "")
        if let url = URL(string: "\(scheme)://"),
           UIApplication.shared.canOpenURL(url) {
            await UIApplication.shared.open(url)
            return "Opening \(appName)."
        }
        return "Couldn't open \(appName)."
    }

    func resolveContact(_ name: String) async -> (number: String?, email: String?) {
        let store = CNContactStore()
        let keys: [CNKeyDescriptor] = [
            CNContactGivenNameKey as CNKeyDescriptor,
            CNContactFamilyNameKey as CNKeyDescriptor,
            CNContactPhoneNumbersKey as CNKeyDescriptor,
            CNContactEmailAddressesKey as CNKeyDescriptor
        ]

        let request = CNContactFetchRequest(keysToFetch: keys)
        var foundNumber: String?
        var foundEmail: String?

        do {
            try store.enumerateContacts(with: request) { contact, stop in
                let fullName = "\(contact.givenName) \(contact.familyName)".lowercased()
                let givenName = contact.givenName.lowercased()

                if fullName.contains(name.lowercased()) || givenName.contains(name.lowercased()) {
                    if let phone = contact.phoneNumbers.first {
                        foundNumber = phone.value.stringValue
                            .components(separatedBy: CharacterSet.decimalDigits.inverted)
                            .joined()
                    }
                    if let email = contact.emailAddresses.first {
                        foundEmail = email.value as String
                    }
                    stop.pointee = true
                }
            }
        } catch {
            print("GIGI: Contact error — \(error)")
        }

        return (foundNumber, foundEmail)
    }

    private func parseDateTime(date: String, time: String) -> Date {
        let calendar = Calendar.current
        var components = calendar.dateComponents([.year, .month, .day], from: Date())

        if date.lowercased() == "tomorrow" {
            components.day = (components.day ?? 0) + 1
        }

        if let colonIndex = time.firstIndex(of: ":") {
            let hour = Int(time[..<colonIndex]) ?? 12
            let minute = Int(time[time.index(after: colonIndex)...].prefix(2)) ?? 0
            components.hour = hour
            components.minute = minute
        }

        return calendar.date(from: components) ?? Date()
    }
}
