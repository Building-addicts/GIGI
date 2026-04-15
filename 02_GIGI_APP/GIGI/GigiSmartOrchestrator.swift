import Foundation
import SwiftUI
import Combine

// MARK: - GigiSmartOrchestrator
// Il vero cervello di GIGI — capisce linguaggio naturale,
// deduce azioni implicite, esegue tutto in sequenza
@MainActor
class GigiSmartOrchestrator: ObservableObject {
    static let shared = GigiSmartOrchestrator()

    @Published var status       = "GIGI: Ready"
    @Published var lastResponse = ""
    @Published var isListening  = false
    @Published var isThinking   = false
    @Published var executedActions: [String] = []

    private let nlu        = GigiNLUEngine.shared
    private let extractor  = GigiEntityExtractor.shared
    private let implication = GigiImplicationEngine.shared
    private let bridge     = GigiActionBridge.shared
    private let dialogue   = GigiDialogueEngine.shared

    // Soglia confidenza per esecuzione diretta
    private let directThreshold = 0.70

    // MARK: - Entry point
    func process(text: String) async {
        guard !text.isEmpty else { return }
        isListening  = false
        isThinking   = true
        status       = "GIGI: Understanding..."
        executedActions = []

        // ── Step 1: Classifica intent ──────────────────────────────────────
        let intent = nlu.classify(text)
        print("GIGI Smart: '\(text)' → \(intent.label) (\(Int(intent.confidence * 100))%)")

        // ── Step 2: Estrai entità ──────────────────────────────────────────
        let entities = extractor.extract(from: text)

        // ── Step 3: Dialogo se necessario ─────────────────────────────────
        if dialogue.isInDialogue {
            let response = await dialogue.process(text: text, intent: intent)
            await handleDialogueResponse(response)
            isThinking = false
            return
        }

        // ── Step 4: Domanda al cloud? ──────────────────────────────────────
        if shouldAskCloud(text: text, intent: intent, entities: entities) {
            isThinking = false
            await GigiOrchestrator.shared.process(text: text)
            return
        }

        // ── Step 5: Azioni implicite dal contesto ──────────────────────────
        let impliedActions = implication.inferActions(from: entities, intent: intent)

        // ── Step 6: Costruisci piano di esecuzione ─────────────────────────
        let plan = buildExecutionPlan(
            primaryIntent: intent,
            entities: entities,
            impliedActions: impliedActions,
            originalText: text
        )

        // ── Step 7: Esegui il piano ────────────────────────────────────────
        await executePlan(plan, originalText: text)
        isThinking = false
    }

    // MARK: - Costruisci piano
    private func buildExecutionPlan(
        primaryIntent: GigiIntent,
        entities: GigiEntities,
        impliedActions: [ImpliedAction],
        originalText: String
    ) -> [GigiIntent] {

        var plan: [GigiIntent] = []

        // Azione primaria
        let primary = enrichIntent(primaryIntent, with: entities, text: originalText)
        plan.append(primary)

        // Azioni implicite → converti in GigiIntent
        for implied in impliedActions {
            let impliedIntent = GigiIntent(
                label: implied.type,
                confidence: 0.95,
                params: implied.params
            )
            plan.append(impliedIntent)
            print("GIGI Smart: Implied action → \(implied.type) [\(implied.reason)]")
        }

        return plan
    }

    // MARK: - Esegui piano
    private func executePlan(_ plan: [GigiIntent], originalText: String) async {
        var responses: [String] = []

        for (index, intent) in plan.enumerated() {
            status = index == 0
                ? "GIGI: Executing..."
                : "GIGI: Also doing \(intent.label.replacingOccurrences(of: "_", with: " "))..."

            // Gestione dialogo per azioni che richiedono conferma
            if requiresDialogue(intent) {
                let response = await dialogue.process(text: originalText, intent: intent)
                if case .execute(let execIntent) = response.action {
                    let result = await bridge.execute(execIntent)
                    if !result.isEmpty { responses.append(result) }
                } else if case .askFollowUp(_) = response.action {
                    // Interrompi il piano — aspetta risposta utente
                    lastResponse = response.text
                    GigiOrchestrator.shared.speak(response.text)
                    executedActions = responses
                    status = "GIGI: Waiting..."
                    return
                }
                continue
            }

            // Esegui direttamente
            let result = await bridge.execute(intent)

            if !result.isEmpty && result != "Connecting to AI..." {
                responses.append(formatResult(result, for: intent))
                executedActions.append(intent.label)
            }

            // Pausa tra azioni per non sovraccaricare iOS
            if plan.count > 1 && index < plan.count - 1 {
                try? await Task.sleep(nanoseconds: 300_000_000) // 0.3s
            }
        }

        // Componi risposta finale
        let finalResponse = composeFinalResponse(responses, plan: plan)
        lastResponse = finalResponse
        GigiOrchestrator.shared.speak(finalResponse)
        status = "GIGI: Ready"
    }

    // MARK: - Arricchisci intent con entità
    private func enrichIntent(_ intent: GigiIntent, with entities: GigiEntities, text: String) -> GigiIntent {
        var params = intent.params
        params["raw"] = text

        // Aggiungi contatto se trovato
        if params["contact"] == nil, let contact = entities.contacts.first {
            params["contact"] = contact
        }

        // Aggiungi data
        if params["date"] == nil, let date = entities.dates.first {
            params["date"] = date
        }

        // Aggiungi ora
        if params["time"] == nil, let time = entities.times.first {
            params["time"] = time
        }

        // Aggiungi app
        if params["app"] == nil, let app = entities.apps.first {
            params["app"] = app
        }

        // Aggiungi destinazione
        if params["destination"] == nil, let place = entities.places.first {
            params["destination"] = place
        }

        // Aggiungi titolo evento per calendario
        if intent.label == "create_event" && params["title"] == nil {
            let topic = entities.topics.first ?? "Event"
            params["title"] = topic.capitalized
        }

        return GigiIntent(label: intent.label, confidence: intent.confidence, params: params)
    }

    // MARK: - Deve andare al cloud?
    private func shouldAskCloud(text: String, intent: GigiIntent, entities: GigiEntities) -> Bool {
        // Domande fattuali → cloud
        if intent.label == "ask_cloud" { return true }

        let factualPatterns = [
            "what happened", "who is", "what is", "explain",
            "tell me about", "history of", "why did", "when did",
            "how many", "what year", "who won", "what was",
            "news about", "latest on", "what's the score"
        ]
        let lower = text.lowercased()
        return factualPatterns.contains(where: { lower.contains($0) })
    }

    // MARK: - Richiede dialogo?
    private func requiresDialogue(_ intent: GigiIntent) -> Bool {
        // Solo send_message senza body completo richiede dialogo
        if intent.label == "send_message" {
            let hasContact = !(intent.params["contact"]?.isEmpty ?? true)
            let hasBody    = !(intent.params["body"]?.isEmpty ?? true)
            let hasPlatform = !(intent.params["platform"]?.isEmpty ?? true)
            return !hasContact || !hasBody || !hasPlatform
        }
        return false
    }

    // MARK: - Formatta risultato
    private func formatResult(_ result: String, for intent: GigiIntent) -> String {
        // Rimuovi risposte banali
        let banalities = ["Done.", "Opening", "Got it"]
        if banalities.contains(where: { result.hasPrefix($0) }) && result.count < 15 {
            return ""
        }
        return result
    }

    // MARK: - Componi risposta finale intelligente
    private func composeFinalResponse(_ responses: [String], plan: [GigiIntent]) -> String {
        let filtered = responses.filter { !$0.isEmpty }

        if filtered.isEmpty {
            return "Done."
        }

        if filtered.count == 1 {
            return filtered[0]
        }

        // Multiple azioni → risposta composta
        let actionNames = plan.map { intentToReadable($0.label) }

        if plan.count == 2 {
            return "\(filtered[0]) I've also \(intentToVerb(plan[1].label))."
        }

        if plan.count == 3 {
            return "\(filtered[0]) I've also set a reminder and an alarm for you."
        }

        // Più di 3 azioni
        let count = plan.count
        return "\(filtered[0]) Done \(count) things for you: \(actionNames.prefix(3).joined(separator: ", "))."
    }

    // MARK: - Gestisci risposta dialogo
    private func handleDialogueResponse(_ response: DialogueResponse) async {
        switch response.action {
        case .execute(let intent):
            if !response.text.isEmpty {
                lastResponse = response.text
                GigiOrchestrator.shared.speak(response.text)
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
            if intent.label == "ask_cloud" {
                await GigiOrchestrator.shared.process(text: intent.params["raw"] ?? "")
            } else {
                let result = await bridge.execute(intent)
                lastResponse = result
                GigiOrchestrator.shared.speak(result)
            }
        case .speak(let text):
            lastResponse = text
            GigiOrchestrator.shared.speak(text)
        case .askFollowUp(let prompt):
            let full = response.text.isEmpty ? prompt : response.text
            lastResponse = full
            GigiOrchestrator.shared.speak(full)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                GigiOrchestrator.shared.startListening()
            }
        case .none:
            break
        }
        status = "GIGI: Ready"
    }

    // MARK: - Helpers
    private func intentToReadable(_ label: String) -> String {
        let map: [String: String] = [
            "create_event": "added event",
            "set_alarm": "set alarm",
            "set_reminder": "set reminder",
            "set_timer": "started timer",
            "make_call": "calling",
            "send_message": "sending message",
            "navigation": "navigation ready",
            "open_app": "opened app",
            "play_music": "playing music"
        ]
        return map[label] ?? label.replacingOccurrences(of: "_", with: " ")
    }

    private func intentToVerb(_ label: String) -> String {
        let map: [String: String] = [
            "set_alarm": "set an alarm for you",
            "set_reminder": "set a reminder",
            "create_event": "added it to your calendar",
            "navigation": "set up navigation",
            "set_timer": "started a timer"
        ]
        return map[label] ?? "done \(label.replacingOccurrences(of: "_", with: " "))"
    }

    // MARK: - VAD passthrough
    func startListening() {
        GigiOrchestrator.shared.startListening()
        isListening = true
        status = "GIGI: Listening..."
    }

    func stopListening() {
        GigiOrchestrator.shared.stopListening()
        isListening = false
    }
}
