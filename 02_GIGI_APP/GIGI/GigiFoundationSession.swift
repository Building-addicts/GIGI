import Foundation

// MARK: - GigiFoundationSession
// Implementazione concreta Apple Foundation Models (iOS 18.1+).
// Questo file DEVE essere compilato con Xcode 16+ (iOS 18.1 SDK).
// Su device non compatibili, isAvailable = false → nessuna chiamata.

#if canImport(FoundationModels)
import FoundationModels

// FoundationAgentOutput @Generable schema moved to GigiFoundationContracts.swift
// (2026-05-11, pre-Phase 2 refactor): makes room for FoundationRouterDecision
// without bloating this file. No behavior change.

// MARK: - Session manager

@available(iOS 18.1, *)
@MainActor
final class GigiFoundationSession {
    static let shared = GigiFoundationSession()

    private var session: LanguageModelSession?
    private(set) var isAvailable: Bool = false
    private var permanentlyDisabled = false  // true after model catalog failure

    private init() {
        setupSession()
    }

    private func setupSession() {
        guard !permanentlyDisabled else { return }
        let model = SystemLanguageModel.default
        guard model.availability == .available else {
            print("GIGI Foundation: optional Apple Intelligence unavailable — using Groq/local fallback.")
            isAvailable = false
            return
        }
        session = LanguageModelSession(instructions: GigiFoundationAgent.systemPrompt)
        isAvailable = true
        print("GIGI Foundation: Apple Intelligence ready ✓")
    }

    // MARK: - Main entry point

    func respond(text: String, history: String) async -> GigiAgentResponse? {
        guard let session, isAvailable else { return nil }

        let prompt: String
        if history.isEmpty {
            prompt = "Classify and fill slots for this utterance (one structured action):\n\(text)"
        } else {
            prompt = """
            Recent conversation:
            \(history)

            Latest utterance — use context to resolve pronouns (him/her/it/there/that place) and implied slots, then output one structured action:
            \(text)
            """
        }

        do {
            let result = try await session.respond(to: prompt, generating: FoundationAgentOutput.self)
            let out    = result.content
            let merged = GigiAgentResponse(
                action:   out.action,
                contact:  out.contact,
                body:     out.body,
                platform: out.platform,
                dest:     out.destination,
                query:    out.query,
                app:      out.app,
                taskText: out.taskText,
                date:     out.date,
                time:     out.time,
                speech:   out.speech,
                followUp: out.followUp
            )
            let normalized = GigiFoundationAgent.normalizedResponse(merged)
            print("GIGI Foundation: '\(text)' → \(normalized.action) | speech: \(normalized.speech.prefix(60))")

            return normalized

        } catch {
            let desc = error.localizedDescription + "\(error)"
            print("GIGI Foundation error: \(error)")
            // Model catalog missing — Apple Intelligence not fully downloaded yet
            if desc.contains("modelcatalog") || desc.contains("5000") || desc.contains("SensitiveContentAnalysis") {
                permanentlyDisabled = true
                isAvailable = false
                self.session = nil
                print("GIGI Foundation: model assets not downloaded. Go to Settings → Apple Intelligence & Siri → enable and wait for download.")
            }
            return nil
        }
    }

    // MARK: - Reset

    func resetContext() {
        setupSession()
        print("GIGI Foundation: session reset.")
    }
}

#else

// MARK: - Stub per SDK < iOS 18.1 (compila ma non fa nulla)

@MainActor
final class GigiFoundationSession {
    static let shared = GigiFoundationSession()
    let isAvailable: Bool = false
    private init() {
        print("GIGI Foundation: FoundationModels not available in this SDK.")
    }
    func respond(text: String, history: String) async -> GigiAgentResponse? { nil }
    func resetContext() {}
}

#endif
