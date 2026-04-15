import Foundation
import Combine
import UIKit

// MARK: - Stato del dialogo
enum DialogueState: Equatable {
    case idle
    // Messaggi
    case awaitingChannel(contact: String, message: String)
    case awaitingMessage(contact: String, via: String)
    case awaitingConfirmSend(contact: String, via: String, message: String)
    // Chiamate
    case awaitingCallConfirm(contact: String)
    // Navigazione
    case awaitingDestination
    // Generico
    case awaitingYesNo(action: String, onYes: String, onNo: String)
}

// MARK: - Risposta del dialogo
struct DialogueResponse {
    let text: String           // Cosa GIGI dice
    let action: DialogueAction // Cosa GIGI fa
}

enum DialogueAction {
    case none
    case execute(GigiIntent)   // Esegui intent
    case speak(String)         // Solo parla
    case askFollowUp(String)   // Chiedi all'utente
}

// MARK: - GigiDialogueEngine
@MainActor
class GigiDialogueEngine: ObservableObject {
    static let shared = GigiDialogueEngine()

    @Published var isInDialogue = false
    @Published var currentPrompt = ""

    private var state: DialogueState = .idle
    private var conversationHistory: [(role: String, text: String)] = []

    // MARK: - Entry point principale
    // Chiamato da GigiOrchestrator per ogni input utente
    func process(text: String, intent: GigiIntent) async -> DialogueResponse {
        let input = text.lowercased().trimmingCharacters(in: .whitespaces)

        // Se siamo in un dialogo attivo, gestisci la risposta
        if state != .idle {
            return await handleDialogueResponse(input: input, originalText: text)
        }

        // Altrimenti analizza il nuovo input
        return await handleNewInput(text: text, intent: intent)
    }

    // MARK: - Nuovo input
    private func handleNewInput(text: String, intent: GigiIntent) async -> DialogueResponse {
        let input = text.lowercased()

        // ── Caso 1: Intent chiari → esegui direttamente ──────────────────────
        let directIntents = [
            "torch_on", "torch_off", "set_brightness_up", "set_brightness_down",
            "toggle_wifi", "toggle_bluetooth", "toggle_do_not_disturb",
            "open_settings", "open_settings_vpn", "take_photo",
            "read_calendar", "read_email", "read_messages",
            "weather", "music_control", "phone_system"
        ]

        if directIntents.contains(intent.label) && intent.confidence > 0.7 {
            return DialogueResponse(
                text: "",
                action: .execute(intent)
            )
        }

        // ── Caso 2: Messaggi — capisce la piattaforma? ───────────────────────
        if intent.label == "send_message" {
            let contact = intent.params["contact"] ?? extractContact(from: text)
            let message = intent.params["body"] ?? ""
            let platform = extractPlatform(from: input)

            if let platform = platform, !contact.isEmpty {
                // Ha tutto — esegui direttamente
                if !message.isEmpty {
                    return await confirmAndSend(contact: contact, via: platform, message: message)
                } else {
                    // Manca il messaggio
                    state = .awaitingMessage(contact: contact, via: platform)
                    isInDialogue = true
                    currentPrompt = "What do you want to say to \(contact)?"
                    return DialogueResponse(
                        text: "What do you want to say to \(contact)?",
                        action: .askFollowUp("What do you want to say?")
                    )
                }
            } else if !contact.isEmpty && platform == nil {
                // Ha il contatto ma non la piattaforma
                state = .awaitingChannel(contact: contact, message: message)
                isInDialogue = true
                currentPrompt = "iMessage or WhatsApp?"
                return DialogueResponse(
                    text: "Sure! Do you want to message \(contact) on iMessage or WhatsApp?",
                    action: .askFollowUp("iMessage or WhatsApp?")
                )
            } else {
                // Manca il contatto
                state = .awaitingChannel(contact: "", message: message)
                isInDialogue = true
                return DialogueResponse(
                    text: "Who do you want to message?",
                    action: .askFollowUp("Who?")
                )
            }
        }

        // ── Caso 3: Chiamata ─────────────────────────────────────────────────
        if intent.label == "make_call" {
            let contact = intent.params["contact"] ?? extractContact(from: text)
            if contact.isEmpty {
                state = .awaitingCallConfirm(contact: "")
                isInDialogue = true
                return DialogueResponse(
                    text: "Who do you want to call?",
                    action: .askFollowUp("Who?")
                )
            }
            // Ha il contatto — chiede conferma
            state = .awaitingCallConfirm(contact: contact)
            isInDialogue = true
            return DialogueResponse(
                text: "Calling \(contact). Say yes to confirm.",
                action: .askFollowUp("Say yes to call")
            )
        }

        // ── Caso 4: Frasi contestuali ("how is mom doing?") ─────────────────
        if isContextualQuery(input) {
            let response = handleContextualQuery(input: input, text: text)
            return response
        }

        // ── Caso 5: App aperta — vuole interagire? ───────────────────────────
        if intent.label == "open_app" {
            let app = intent.params["app"] ?? intent.params["raw"] ?? ""
            let action = extractActionForApp(input: input, app: app)

            if let action = action {
                // Es: "open WhatsApp and message mom" → esegui direttamente
                return DialogueResponse(text: "", action: .execute(action))
            }

            // Solo apri l'app
            return DialogueResponse(text: "", action: .execute(intent))
        }

        // ── Caso 6: Intent con bassa confidenza → chiedi chiarimento ─────────
        if intent.confidence < 0.6 {
            return await handleLowConfidence(text: text)
        }

        // ── Default: esegui l'intent ─────────────────────────────────────────
        return DialogueResponse(text: "", action: .execute(intent))
    }

    // MARK: - Gestione risposta durante dialogo
    private func handleDialogueResponse(input: String, originalText: String) async -> DialogueResponse {
        switch state {

        // ── Attende canale (iMessage / WhatsApp) ─────────────────────────────
        case .awaitingChannel(let contact, let message):
            let platform = extractPlatform(from: input) ?? detectPlatformFromInput(input)

            if let platform = platform {
                if message.isEmpty {
                    state = .awaitingMessage(contact: contact, via: platform)
                    currentPrompt = "What do you want to say?"
                    return DialogueResponse(
                        text: "Got it, \(platform). What do you want to say to \(contact.isEmpty ? "them" : contact)?",
                        action: .askFollowUp("What's the message?")
                    )
                } else {
                    return await confirmAndSend(contact: contact, via: platform, message: message)
                }
            }

            // Non ha capito la piattaforma
            return DialogueResponse(
                text: "iMessage or WhatsApp?",
                action: .askFollowUp("Say iMessage or WhatsApp")
            )

        // ── Attende messaggio ─────────────────────────────────────────────────
        case .awaitingMessage(let contact, let via):
            let message = originalText.trimmingCharacters(in: .whitespaces)
            if message.isEmpty {
                return DialogueResponse(
                    text: "What do you want to say?",
                    action: .askFollowUp("What's the message?")
                )
            }
            return await confirmAndSend(contact: contact, via: via, message: message)

        // ── Attende conferma invio ────────────────────────────────────────────
        case .awaitingConfirmSend(let contact, let via, let message):
            if isYes(input) {
                resetDialogue()
                let intent = GigiIntent(
                    label: "send_message",
                    confidence: 1.0,
                    params: ["contact": contact, "body": message, "platform": via]
                )
                return DialogueResponse(
                    text: "Sending to \(contact) on \(via).",
                    action: .execute(intent)
                )
            } else if isNo(input) {
                resetDialogue()
                return DialogueResponse(
                    text: "Message cancelled.",
                    action: .speak("Cancelled.")
                )
            }
            return DialogueResponse(
                text: "Say yes to send or no to cancel.",
                action: .askFollowUp("Yes or no?")
            )

        // ── Attende conferma chiamata ─────────────────────────────────────────
        case .awaitingCallConfirm(let contact):
            if contact.isEmpty {
                // Stava aspettando il nome
                let name = originalText.trimmingCharacters(in: .whitespaces)
                resetDialogue()
                let intent = GigiIntent(
                    label: "make_call",
                    confidence: 1.0,
                    params: ["contact": name]
                )
                return DialogueResponse(
                    text: "Calling \(name).",
                    action: .execute(intent)
                )
            }
            if isYes(input) {
                resetDialogue()
                let intent = GigiIntent(
                    label: "make_call",
                    confidence: 1.0,
                    params: ["contact": contact]
                )
                return DialogueResponse(
                    text: "Calling \(contact).",
                    action: .execute(intent)
                )
            } else if isNo(input) {
                resetDialogue()
                return DialogueResponse(
                    text: "Call cancelled.",
                    action: .speak("Cancelled.")
                )
            }
            return DialogueResponse(
                text: "Say yes to call \(contact) or no to cancel.",
                action: .askFollowUp("Yes or no?")
            )

        // ── Attende yes/no generico ───────────────────────────────────────────
        case .awaitingYesNo(_, let onYes, let onNo):
            if isYes(input) {
                resetDialogue()
                return DialogueResponse(text: onYes, action: .speak(onYes))
            } else {
                resetDialogue()
                return DialogueResponse(text: onNo, action: .speak(onNo))
            }

        default:
            resetDialogue()
            return DialogueResponse(text: "", action: .none)
        }
    }

    // MARK: - Conferma e invia
    private func confirmAndSend(contact: String, via: String, message: String) async -> DialogueResponse {
        state = .awaitingConfirmSend(contact: contact, via: via, message: message)
        currentPrompt = "Say yes to send"

        let preview = message.count > 40 ? String(message.prefix(40)) + "..." : message
        return DialogueResponse(
            text: "Ready to send \"\(preview)\" to \(contact) on \(via). Say yes to send.",
            action: .askFollowUp("Say yes to confirm")
        )
    }

    // MARK: - Query contestuali
    private func isContextualQuery(_ input: String) -> Bool {
        let patterns = [
            "how is", "how's", "what's up with", "what about",
            "is my", "can you check", "do you know",
            "what happened to", "where is my", "did my"
        ]
        return patterns.contains(where: { input.contains($0) })
    }

    private func handleContextualQuery(input: String, text: String) -> DialogueResponse {
        // Estrai contatto dalla frase
        let contact = extractContact(from: text)

        if !contact.isEmpty {
            // "how is mom doing?" → proponi azioni
            state = .awaitingChannel(contact: contact, message: "")
            isInDialogue = true
            return DialogueResponse(
                text: "I don't know how \(contact) is doing, but I can call them or send a message. Which do you prefer?",
                action: .askFollowUp("Call or message?")
            )
        }

        // Non ha capito — manda al cloud
        let intent = GigiIntent(label: "ask_cloud", confidence: 1.0, params: ["raw": text])
        return DialogueResponse(text: "", action: .execute(intent))
    }

    // MARK: - Bassa confidenza
    private func handleLowConfidence(text: String) async -> DialogueResponse {
        // Manda al cloud invece di chiedere chiarimento
        let intent = GigiIntent(label: "ask_cloud", confidence: 1.0, params: ["raw": text])
        return DialogueResponse(text: "", action: .execute(intent))
    }

    // MARK: - Helpers

    private func extractContact(from text: String) -> String {
        let triggers = ["to ", "call ", "message ", "text ", "for ", "with "]
        let lower = text.lowercased()
        for trigger in triggers {
            if let range = lower.range(of: trigger) {
                var remainder = String(text[range.upperBound...])
                    .trimmingCharacters(in: .whitespaces)
                // Rimuovi suffissi
                for suffix in ["on whatsapp","on telegram","on imessage","please","now","about","that"] {
                    if let r = remainder.lowercased().range(of: " " + suffix) {
                        remainder = String(remainder[..<r.lowerBound])
                    }
                }
                let name = remainder.components(separatedBy: " ").prefix(2).joined(separator: " ")
                if !name.isEmpty && name.count > 1 { return name }
            }
        }
        // Cerca nomi comuni
        let relatives = ["mom","dad","mother","father","brother","sister","wife","husband",
                        "girlfriend","boyfriend","grandma","grandpa","boss","friend"]
        for rel in relatives {
            if lower.contains(rel) { return rel }
        }
        return ""
    }

    private func extractPlatform(from text: String) -> String? {
        let lower = text.lowercased()
        if lower.contains("whatsapp") || lower.contains("wa") || lower.contains("wapp") { return "WhatsApp" }
        if lower.contains("telegram") { return "Telegram" }
        if lower.contains("imessage") || lower.contains("sms") || lower.contains("text message") { return "iMessage" }
        if lower.contains("signal") { return "Signal" }
        if lower.contains("messenger") { return "Messenger" }
        return nil
    }

    private func detectPlatformFromInput(_ input: String) -> String? {
        if input.contains("whats") || input.contains("wapp") || input.contains("wa") { return "WhatsApp" }
        if input.contains("tele") { return "Telegram" }
        if input.contains("imess") || input.contains("apple") { return "iMessage" }
        return nil
    }

    private func extractActionForApp(input: String, app: String) -> GigiIntent? {
        // "open WhatsApp and message mom" → intent send_message
        if (input.contains("message") || input.contains("text") || input.contains("send")) {
            let contact = extractContact(from: input)
            if !contact.isEmpty {
                return GigiIntent(
                    label: "send_message",
                    confidence: 0.9,
                    params: ["contact": contact, "platform": app]
                )
            }
        }
        if input.contains("call") {
            let contact = extractContact(from: input)
            if !contact.isEmpty {
                return GigiIntent(
                    label: "make_call",
                    confidence: 0.9,
                    params: ["contact": contact]
                )
            }
        }
        return nil
    }

    private func isYes(_ input: String) -> Bool {
        let yes = ["yes","yep","yeah","yup","sure","ok","okay","do it","send it",
                   "confirm","go ahead","absolutely","of course","definitely","affirmative"]
        return yes.contains(where: { input.contains($0) })
    }

    private func isNo(_ input: String) -> Bool {
        let no = ["no","nope","cancel","stop","don't","abort","never mind","nah","negative"]
        return no.contains(where: { input.contains($0) })
    }

    func resetDialogue() {
        state = .idle
        isInDialogue = false
        currentPrompt = ""
    }
}
