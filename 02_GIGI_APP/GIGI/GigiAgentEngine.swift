import Foundation
import UIKit

// MARK: - AgentResult

struct AgentResult {
    let speech: String
    let executedTools: [String]
    let isFollowUp: Bool
    let costEstimate: Double       // USD estimate for this turn
    let requiresConfirm: ConfirmRequest?
    let isError: Bool
}

// MARK: - InterimEvent

enum InterimEvent {
    case thinking(iteration: Int)
    case toolStarted(name: String)
    case toolCompleted(name: String, result: String)
    case waitingForConfirmation(ConfirmRequest)
}

// MARK: - GigiAgentEngine

@MainActor
final class GigiAgentEngine {
    static let shared = GigiAgentEngine()

    // MARK: - Config

    private let maxIterations  = 8
    private let fastTimeout: TimeInterval  = 20.0   // native iOS tools
    private let slowTimeout: TimeInterval  = 90.0   // web / harness tools
    // Groq llama-3.3-70b pricing (USD): ~$0.059/1M input tokens, ~$0.079/1M output tokens.
    // We use a blended rate for the simplified estimate.
    private let costPerToken = 0.00000015

    // Context cache removed — Groq has no cache API

    // MARK: - Pending confirmation state
    // Kept on the singleton so it survives the audio turn and brief backgrounding.
    // The app process staying alive is sufficient — if the app is killed, the user
    // must re-issue the command anyway.
    private(set) var pendingConfirmRequest: ConfirmRequest?
    private var pendingConfirmTool: (any GigiTool)?
    private var pendingConfirmArgs: [String: Any] = [:]

    // MARK: - Callbacks

    var onInterimEvent: ((InterimEvent) -> Void)?

    private init() {}

    // MARK: - Public API

    /// Entry point: processes one user utterance end-to-end.
    func process(text: String) async -> AgentResult {
        let mem = GigiConversationMemory.shared

        // Record user turn in persistent multi-turn history
        mem.addUserTurn(text)

        // Build initial contents from pruned history (user turn already appended above)
        let history = mem.contents(pruningIfNeeded: true)

        // Inject relevant long-term memories into system instruction.
        // Use agent-tool prompt (not the legacy JSON orchestrator prompt) so Llama
        // on Groq produces either a real tool call or plain text — never a fake
        // `respond` tool call that would be rejected with 400.
        let memoryBlock = await buildMemoryBlock(for: text)
        var systemInstruction = GigiFoundationAgent.agentToolPrompt
        if !memoryBlock.isEmpty {
            systemInstruction += "\n\nUser memory (relevant):\n\(memoryBlock)"
        }

        return await agentLoop(
            initialContents:   history,
            userText:          text,
            systemInstruction: systemInstruction
        )
    }

    // MARK: - Agent Loop

    private func agentLoop(
        initialContents: [GigiContent],
        userText: String,
        systemInstruction: String
    ) async -> AgentResult {
        var contents    = initialContents
        var executedTools: [String] = []
        var totalCost: Double = 0

        // Tool selection: base on current utterance + every prior user turn in history
        // so follow-ups like "procedi" / "margarita" don't strip out tools the model
        // already sees in its own history (Llama will re-emit them → Groq 400).
        let registry = GigiToolRegistry.shared
        var relevantByName: [String: any GigiTool] = [:]
        let seed = (pastUserUtterances(in: initialContents) + [userText]).joined(separator: " ")
        for t in registry.selectRelevant(for: seed) { relevantByName[t.name] = t }

        // Carry-forward: any tool the model already called in history must stay visible.
        for name in pastToolCallNames(in: initialContents) where relevantByName[name] == nil {
            if let t = registry.tool(named: name) { relevantByName[name] = t }
        }

        let relevantTools = Array(relevantByName.values)
        var toolDeclarations = registry.declarations(for: relevantTools)

        // Slow tools need extra time; native-only requests use a tight timeout
        // so a hanging Groq call doesn't block the user for 90s on "what time is it".
        let slowToolNames: Set<String> = [
            "web_order_food", "web_book_restaurant", "web_vision_task",
            "web_whatsapp", "web_search_and_read", "ask_harness", "computer_use"
        ]
        let hasSlow = relevantTools.contains { slowToolNames.contains($0.name) }
        let deadline = Date().addingTimeInterval(hasSlow ? slowTimeout : fastTimeout)

        for iteration in 0..<maxIterations {

            // Global timeout check
            guard Date() < deadline else {
                return safetyLock(tools: executedTools, cost: totalCost)
            }

            // Emit thinking event every iteration so UI/audio layer can react
            onInterimEvent?(.thinking(iteration: iteration))

            // If loop has been running > 3s total, user needs audio reassurance.
            // The SoundEngine wiring is in GigiSmartOrchestrator (Phase 1.7).

            let response: GigiLLMResponse
            do {
                response = try await callWithToolRecovery(
                    systemInstruction: systemInstruction,
                    contents:          contents,
                    toolDeclarations:  &toolDeclarations,
                    registry:          registry
                )
            } catch {
                let detail = String(describing: error)
                print("GIGI AgentEngine iter \(iteration): \(detail)")
                GigiDebugLogger.log("Groq call failed (iter \(iteration)): \(detail)")
                let speech: String
                switch error {
                case GigiCloudError.httpError(let status, let body):
                    let snippet = body.prefix(160)
                    speech = "Groq error \(status). \(snippet)"
                case GigiCloudError.missingAPIKey:
                    speech = "Groq API key missing — add it in Settings."
                case GigiCloudError.timeout:
                    speech = "Groq timed out — try again."
                case GigiCloudError.emptyResponse:
                    speech = "Groq returned an empty response."
                default:
                    speech = "Network error: \(error.localizedDescription)"
                }
                return AgentResult(
                    speech:          speech,
                    executedTools:   executedTools,
                    isFollowUp:      false,
                    costEstimate:    totalCost,
                    requiresConfirm: nil,
                    isError:         true
                )
            }

            let mem = GigiConversationMemory.shared

            if response.hasFunctionCalls {
                // Record model function-call turn in persistent history
                mem.addModelTurn(calls: response.functionCalls)
                contents.append(.model(functionCalls: response.functionCalls))

                // Notify UI of each tool starting
                for call in response.functionCalls {
                    onInterimEvent?(.toolStarted(name: call.name))
                }

                // Execute all tools concurrently (order-preserving)
                let results = await executeParallel(response.functionCalls)

                executedTools.append(contentsOf: response.functionCalls.map(\.name))
                totalCost += results.reduce(0) { $0 + Double($1.tokenEstimate) * costPerToken }

                // Notify UI of each completed tool
                for (call, result) in zip(response.functionCalls, results) {
                    onInterimEvent?(.toolCompleted(name: call.name, result: result.error ?? result.value))
                }

                // Check for required confirmation (payment / destructive)
                if let confirmNeeded = results.first(where: { $0.requiresConfirm != nil })?.requiresConfirm,
                   let toolName = response.functionCalls.first(where: { _ in true })?.name,
                   let tool = GigiToolRegistry.shared.tool(named: toolName) {

                    pendingConfirmRequest = confirmNeeded
                    pendingConfirmTool    = tool
                    pendingConfirmArgs    = confirmNeeded.args

                    onInterimEvent?(.waitingForConfirmation(confirmNeeded))

                    return AgentResult(
                        speech:          confirmNeeded.summary,
                        executedTools:   executedTools,
                        isFollowUp:      true,
                        costEstimate:    totalCost,
                        requiresConfirm: confirmNeeded,
                        isError:         false
                    )
                }

                // Record tool results in persistent history
                let toolResultPairs = zip(response.functionCalls, results)
                    .map { (call, r) in (name: call.name, result: r.error.map { "ERROR: \($0)" } ?? r.value) }
                mem.addToolResults(toolResultPairs)

                // Build tool results content for next LLM turn
                let toolResultTuples: [(name: String, value: String, error: String?)] =
                    zip(response.functionCalls, results).map { (call, r) in
                        (name: call.name, value: r.value, error: r.error)
                    }
                contents.append(.toolResults(toolResultTuples))

            } else if let text = response.text, !text.isEmpty {
                // Record final model speech in persistent history (also triggers saveSession)
                mem.addModelSpeech(text)
                return AgentResult(
                    speech:          text,
                    executedTools:   executedTools,
                    isFollowUp:      false,
                    costEstimate:    totalCost,
                    requiresConfirm: nil,
                    isError:         false
                )

            } else {
                // LLM returned neither text nor function calls — break and use safety lock
                break
            }
        }

        return safetyLock(tools: executedTools, cost: totalCost)
    }

    // MARK: - Parallel tool execution

    func executeParallel(_ calls: [FunctionCallBlock]) async -> [ToolResult] {
        guard !calls.isEmpty else { return [] }

        // Index-preserving withTaskGroup: tasks complete in arbitrary order,
        // results are placed back at their original indices.
        var results = [ToolResult](
            repeating: .failure("Execution error"),
            count: calls.count
        )

        await withTaskGroup(of: (Int, ToolResult).self) { group in
            for (i, call) in calls.enumerated() {
                group.addTask { [weak self] in
                    guard let self else { return (i, .failure("Engine deallocated")) }
                    return (i, await self.executeToolCall(call))
                }
            }
            for await (i, result) in group {
                results[i] = result
            }
        }

        return results
    }

    func executeToolCall(_ call: FunctionCallBlock) async -> ToolResult {
        guard let tool = GigiToolRegistry.shared.tool(named: call.name) else {
            return .failure("Unknown tool: \(call.name)")
        }
        return await tool.execute(args: call.asArgs)
    }

    // MARK: - Confirmation flow

    /// Called when user confirms a pending payment/destructive action ("Sì / Vai / Procedi").
    func confirmAndContinue() async -> AgentResult {
        guard let request = pendingConfirmRequest,
              let tool    = pendingConfirmTool else {
            return AgentResult(
                speech:          "Nothing pending confirmation.",
                executedTools:   [],
                isFollowUp:      false,
                costEstimate:    0,
                requiresConfirm: nil,
                isError:         false
            )
        }

        // Clear pending state before execution to prevent double-confirm
        let argsSnapshot = pendingConfirmArgs
        pendingConfirmRequest = nil
        pendingConfirmTool    = nil
        pendingConfirmArgs    = [:]

        let result = await tool.execute(args: argsSnapshot)
        let speech = result.error.map { "Couldn't complete that: \($0)" } ?? result.value

        // Save to memory before returning (addModelSpeech internally calls saveSession)
        GigiConversationMemory.shared.addModelSpeech(speech)

        return AgentResult(
            speech:          speech,
            executedTools:   [request.action],
            isFollowUp:      false,
            costEstimate:    Double(result.tokenEstimate) * costPerToken,
            requiresConfirm: nil,
            isError:         result.error != nil
        )
    }

    /// Called when user says "No / Annulla" to a pending confirmation.
    func cancelConfirmation() {
        pendingConfirmRequest = nil
        pendingConfirmTool    = nil
        pendingConfirmArgs    = [:]
    }

    // MARK: - Helpers

    private func buildMemoryBlock(for text: String) async -> String {
        // Use fuzzy recall to find relevant memories (top 5)
        let memories = await GigiMemory.shared.recallFuzzy(text)
        guard !memories.isEmpty else { return "" }
        return memories.prefix(5).map { "- \($0.key) = \($0.value)" }.joined(separator: "\n")
    }

    private func safetyLock(tools: [String], cost: Double) -> AgentResult {
        AgentResult(
            speech:          "I ran into trouble with that — want me to try a different approach?",
            executedTools:   tools,
            isFollowUp:      false,
            costEstimate:    cost,
            requiresConfirm: nil,
            isError:         true
        )
    }

    // MARK: - Groq call with tool-hallucination recovery

    /// Defensive retry for `tool_use_failed` (Llama hallucinated a tool not in request.tools).
    /// Step 1: retry with the full registry — often the hallucination names a real tool that
    /// our tag-matcher failed to include. Step 2: strip tools entirely so the model falls back
    /// to plain text. Mutates `toolDeclarations` so subsequent iterations keep the wider list.
    private func callWithToolRecovery(
        systemInstruction: String,
        contents: [GigiContent],
        toolDeclarations: inout [FunctionDeclaration],
        registry: GigiToolRegistry
    ) async throws -> GigiLLMResponse {
        do {
            return try await GigiCloudService.shared.callWithFunctions(
                systemInstruction: systemInstruction,
                contents:          contents,
                tools:             toolDeclarations
            )
        } catch GigiCloudError.httpError(400, let body) where body.contains("tool_use_failed") {
            if toolDeclarations.count < registry.all.count {
                GigiDebugLogger.log("Groq 400 tool_use_failed — retrying with full tool list")
                toolDeclarations = registry.declarations(for: registry.all)
            } else {
                GigiDebugLogger.log("Groq 400 tool_use_failed with full list — retrying without tools")
                toolDeclarations = []
            }
            return try await GigiCloudService.shared.callWithFunctions(
                systemInstruction: systemInstruction,
                contents:          contents,
                tools:             toolDeclarations
            )
        } catch GigiCloudError.httpError(429, _) {
            // Token rate limit on llama-3.3-70b — wait 3s then retry with fast model (30k TPM)
            GigiDebugLogger.log("Groq 429 rate limit — waiting 3s, falling back to llama-3.1-8b-instant")
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            return try await GigiCloudService.shared.callWithFunctions(
                systemInstruction: systemInstruction,
                contents:          contents,
                tools:             toolDeclarations,
                model:             "llama-3.1-8b-instant"
            )
        }
    }

    // MARK: - History scanning (for tool carry-forward)

    private func pastToolCallNames(in contents: [GigiContent]) -> [String] {
        contents.flatMap { c in
            c.parts.compactMap { $0.functionCall?.name }
        }
    }

    private func pastUserUtterances(in contents: [GigiContent]) -> [String] {
        contents.filter { $0.role == "user" }.flatMap { c in
            c.parts.compactMap { $0.text }
        }
    }
}
