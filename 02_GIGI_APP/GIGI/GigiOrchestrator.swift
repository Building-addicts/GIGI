import Foundation
import Combine
import SwiftUI
import AVFoundation

@MainActor
class GigiOrchestrator: ObservableObject {
    static let shared = GigiOrchestrator()

    @Published var status = "GIGI: Ready"
    @Published var lastResponse = ""
    @Published var isListening = false
    @Published var isInDialogue = false
    @Published var dialoguePrompt = ""

    private let nlu        = GigiNLUEngine.shared
    private let bridge     = GigiActionBridge.shared
    private let dialogue   = GigiDialogueEngine.shared
    private let synthesizer = AVSpeechSynthesizer()

    private let confidenceThreshold = 0.55

    // MARK: - Entry point
    func process(text: String) async {
        guard !text.isEmpty else { return }
        isListening = false
        status = "GIGI: Thinking..."

        // Classifica intent
        let intent = nlu.classify(text)
        print("GIGI: '\(text)' → \(intent.label) (\(Int(intent.confidence * 100))%)")

        // Passa al dialogue engine
        let response = await dialogue.process(text: text, intent: intent)

        // Aggiorna stato dialogo UI
        isInDialogue   = dialogue.isInDialogue
        dialoguePrompt = dialogue.currentPrompt

        // Gestisci azione
        switch response.action {

        case .execute(let executionIntent):
            // Parla prima se c'è testo
            if !response.text.isEmpty {
                lastResponse = response.text
                speak(response.text)
                try? await Task.sleep(nanoseconds: 500_000_000)
            }

            if executionIntent.label == "ask_cloud" {
                await handleCloud(text: executionIntent.params["raw"] ?? text)
            } else {
                let result = await bridge.execute(executionIntent)
                if !result.isEmpty && result != "Connecting to AI..." {
                    lastResponse = result
                    speak(result)
                }
                status = "GIGI: Ready"
            }

        case .speak(let text):
            lastResponse = text
            speak(text)
            status = "GIGI: Ready"

        case .askFollowUp(let prompt):
            let fullText = response.text.isEmpty ? prompt : response.text
            lastResponse = fullText
            speak(fullText)
            status = "GIGI: Listening..."
            // Rimani in ascolto per la risposta
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                self.startListening()
            }

        case .none:
            status = "GIGI: Ready"
        }
    }

    // MARK: - Cloud (Gemini)
    private func handleCloud(text: String) async {
        status = "GIGI: Asking Gemini..."
        do {
            let token = try await GigiAuthManager.shared.freshAccessToken()
            let response = try await callGemini(
                systemInstruction: "You are GIGI, a concise voice assistant on iPhone. Reply in 1-3 short sentences. No markdown. Be direct and helpful.",
                userPrompt: text,
                token: token,
                prefixUserLabel: true,
                maxOutputTokens: 200,
                temperature: 0.7
            )
            lastResponse = response
            status = "GIGI: Ready"
            speak(response)
        } catch {
            let fallback = "Connect your Google account in Dashboard to enable AI responses."
            lastResponse = fallback
            status = "GIGI: Ready"
            speak(fallback)
        }
    }

    private func callGemini(
        systemInstruction: String,
        userPrompt: String,
        token: String,
        prefixUserLabel: Bool,
        maxOutputTokens: Int,
        temperature: Double
    ) async throws -> String {
        let urlString = "https://generativelanguage.googleapis.com/v1beta/models/gemini-1.5-flash:generateContent"
        var request = URLRequest(url: URL(string: urlString)!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let combined: String
        if prefixUserLabel {
            combined = "\(systemInstruction)\n\nUser: \(userPrompt)"
        } else {
            combined = "\(systemInstruction)\n\n\(userPrompt)"
        }
        let body: [String: Any] = [
            "contents": [["parts": [["text": combined]]]],
            "generationConfig": ["maxOutputTokens": maxOutputTokens, "temperature": temperature]
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, _) = try await URLSession.shared.data(for: request)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let text = (((json?["candidates"] as? [[String: Any]])?.first?["content"] as? [String: Any])?["parts"] as? [[String: Any]])?.first?["text"] as? String
        return text ?? "I didn't get a response."
    }

    // MARK: - TTS
    func speak(_ text: String) {
        guard !text.isEmpty else { return }
        synthesizer.stopSpeaking(at: .immediate)
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
        utterance.rate = 0.52
        utterance.pitchMultiplier = 1.0
        utterance.volume = 1.0
        synthesizer.speak(utterance)
    }

    // MARK: - VAD
    func startListening() {
        isListening = true
        status = isInDialogue ? "GIGI: \(dialoguePrompt)" : "GIGI: Listening..."
        GigiAudioSequestrator.shared.seizeControl()
        GigiVADEngine.shared.startListening()
    }

    func stopListening() {
        isListening = false
        GigiVADEngine.shared.stopListening()
    }
}
