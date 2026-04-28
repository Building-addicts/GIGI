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

    // Whitelist of NLU labels eligible for the deterministic fast-path.
    // High-confidence (>=0.95) classifications skip the Groq round-trip and
    // dispatch straight to GigiActionBridge after the Force Claude gate.
    private static let fastPathIntents: Set<String> = [
        "ask_time", "ask_date", "torch_on", "torch_off", "make_call", "send_message",
        "navigate", "navigation", "set_timer", "set_alarm", "set_reminder",
        "toggle_wifi", "toggle_bluetooth", "media_play_pause", "media_next", "media_previous",
        "play_music", "open_app", "read_calendar", "read_week_calendar", "find_free_slot",
        "remember", "respond", "facetime", "facetime_audio"
    ]

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

    private init() {
        // Wire GigiClaudeBridge to conversation memory so stream events
        // can append `.thinking` / `.toolEvent` bubbles while Claude runs.
        // Both objects are singletons (@MainActor) so this reference is
        // stable for the process lifetime.
        GigiClaudeBridge.shared.memory = GigiConversationMemory.shared
    }

    // MARK: - Public API

    /// Entry point: processes one user utterance end-to-end.
    func process(text: String) async -> AgentResult {
        print("GIGI agentEngine.process ENTRY: text='\(text.prefix(60))'")
        let mem = GigiConversationMemory.shared
        mem.addUserTurn(text)

        let forceClaudeEnabled = GigiKeychain.loadBool(forKey: GigiKeychain.Key.forceClaude)

        // === Gate 1: Force Claude (Phase 2 — D4.a = YES, takes precedence over planner) ===
        // When Brain Mode → Force Claude is on, route the entire request to Claude
        // via the harness streaming bridge. The harness streams Claude's thoughts
        // as `.thinking`/`.toolEvent` bubbles directly into conversation memory.
        // If autoFallback is ON and Force Claude fails, fall through to Gate 2 (planner).
        if forceClaudeEnabled {
            let autoFallback = GigiKeychain.loadBool(forKey: GigiKeychain.Key.autoFallback)
            if GigiHarnessClient.shared.isConfigured {
                let result = await GigiClaudeBridge.shared.run(task: text, context: nil)
                if let err = result.error {
                    if !autoFallback {
                        return AgentResult(
                            speech: err,
                            executedTools: [],
                            isFollowUp: false,
                            costEstimate: 0,
                            requiresConfirm: nil,
                            isError: true
                        )
                    }
                    // else: silent fallback to Gate 2 (planner) below
                } else {
                    return AgentResult(
                        speech: result.value,
                        executedTools: ["ask_claude"],
                        isFollowUp: false,
                        costEstimate: Double(result.tokenEstimate) * costPerToken,
                        requiresConfirm: nil,
                        isError: false
                    )
                }
            } else if !autoFallback {
                return AgentResult(
                    speech: "Force Claude is on but harness is not paired. Pair it from Settings or enable Auto Fallback.",
                    executedTools: [],
                    isFollowUp: false,
                    costEstimate: 0,
                    requiresConfirm: nil,
                    isError: true
                )
            }
            // else: fall through to Gate 2 (planner) — D4.b = A
        }

        // === Gate 2: deterministic NLU fast-path ===
        // Force Claude deliberately bypasses this gate, even when autoFallback later routes to Groq.
        if !forceClaudeEnabled, let fastPath = await deterministicFastPath(for: text) {
            return fastPath
        }

        // === Gate 3: Multi-agent planner (Leo lane, identical to harness-pre-armando-integration) ===
        // Build initial contents from pruned history (user turn already appended above)
        let history = mem.contents(pruningIfNeeded: true)
        let memoryBlock = await buildMemoryBlock(for: text)
        var systemInstruction = GigiFoundationAgent.agentToolPrompt
        if !memoryBlock.isEmpty {
            systemInstruction += "\n\nUser memory (relevant):\n\(memoryBlock)"
        }

        // Planner gate: ~200ms fast call to decide if decomposition is needed.
        // Falls back to simple react loop on any planner failure — zero regression risk.
        let plan = await GigiPlannerEngine.shared.decompose(userText: text)
        // Single non-iOS task: route to harness with domain (gives real browser tools).
        // Multi-task: orchestrated execution respecting dependsOn DAG.
        let hasNonIos = plan.tasks.contains { $0.domain != .ios && $0.domain != .unknown }
        if !plan.isSimple && (plan.tasks.count >= 2 || (plan.tasks.count == 1 && hasNonIos)) {
            return await orchestratedExecution(plan: plan, userText: text)
        }

        return await agentLoop(
            initialContents:   history,
            userText:          text,
            systemInstruction: systemInstruction
        )
    }


    // MARK: - Deterministic NLU fast-path

    private func deterministicFastPath(for text: String) async -> AgentResult? {
        let intent = GigiNLUEngine.shared.classify(text)
        guard intent.confidence >= 0.95,
              Self.fastPathIntents.contains(intent.label) else {
            return nil
        }

        GigiDebugLogger.log("GIGI fast-path: \(intent.label) (\(String(format: "%.2f", intent.confidence)))")

        let speech: String
        var executedTools: [String] = []
        if intent.label == "respond" {
            speech = GigiBrainPipeline.localSpeech(for: intent)
        } else {
            let bridgeResult = await GigiActionDispatcher.shared.bridge.execute(intent)
            if intent.label == "make_call", bridgeResult.hasPrefix("Calling ") {
                let contact = intent.params["contact"] ?? ""
                if !contact.isEmpty { await GigiMemory.shared.touchContactIfKnown(contact) }
            }
            speech = bridgeResult.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? GigiBrainPipeline.localSpeech(for: intent)
                : bridgeResult
            executedTools = [intent.label]
        }

        GigiConversationMemory.shared.addModelSpeech(speech)
        return AgentResult(
            speech:          speech,
            executedTools:   executedTools,
            isFollowUp:      false,
            costEstimate:    0,
            requiresConfirm: nil,
            isError:         false
        )
    }

    // MARK: - Orchestrated multi-task execution

    private func orchestratedExecution(plan: TaskPlan, userText: String) async -> AgentResult {
        var results: [String: String] = [:]
        var executedDomains: [String] = []
        var remaining = plan.tasks
        let deadline = Date().addingTimeInterval(120.0)

        // Topological execution: tasks whose dependsOn are all resolved run concurrently.
        while !remaining.isEmpty, Date() < deadline {
            let ready = remaining.filter { task in
                task.dependsOn.allSatisfy { results[$0] != nil }
            }
            guard !ready.isEmpty else { break }

            await withTaskGroup(of: (String, String).self) { group in
                for task in ready {
                    group.addTask { [weak self] in
                        guard let self else { return (task.id, "engine deallocated") }
                        let result = await self.executeSubTask(task, priorResults: results)
                        return (task.id, result)
                    }
                }
                for await (taskId, result) in group {
                    results[taskId] = result
                }
            }

            executedDomains.append(contentsOf: ready.map(\.domain.rawValue))
            remaining.removeAll { ready.map(\.id).contains($0.id) }
        }

        // Synthesize: final fast Groq call to combine all results into spoken response
        let speech = await synthesizeResults(userText: userText, results: results)
        GigiConversationMemory.shared.addModelSpeech(speech)

        return AgentResult(
            speech:          speech,
            executedTools:   executedDomains,
            isFollowUp:      false,
            costEstimate:    0,
            requiresConfirm: nil,
            isError:         false
        )
    }

    private func executeSubTask(_ task: SubTask, priorResults: [String: String]) async -> String {
        // Enrich with outputs of dependency tasks
        var desc = task.description
        for depId in task.dependsOn {
            if let depResult = priorResults[depId] {
                desc += "\n\nContext from step \(depId): \(depResult)"
            }
        }

        switch task.domain {
        case .ios:
            // Route through single react-loop iteration (no planner recursion)
            let r = await agentLoop(
                initialContents:   [GigiContent.user(desc)],
                userText:          desc,
                systemInstruction: GigiFoundationAgent.agentToolPrompt
            )
            return r.speech

        case .browser, .research, .calendar, .messaging:
            guard GigiHarnessClient.shared.isConfigured else {
                return "Harness not configured — skipping \(task.domain.rawValue) task."
            }
            switch await GigiHarnessClient.shared.agentRun(
                text:   desc,
                domain: task.domain.rawValue,
                schema: task.schema,
                stream: false
            ) {
            case .success(let r): return r.result
            case .failure(let e): return "Error (\(task.domain.rawValue)): \(e.description)"
            }

        case .unknown:
            return "Unknown domain for task \(task.id)"
        }
    }

    private func synthesizeResults(userText: String, results: [String: String]) async -> String {
        guard !results.isEmpty else {
            return "I ran into trouble completing that — some steps didn't finish."
        }
        let summary = results.map { "[\($0.key)] \($0.value)" }.joined(separator: "\n")
        let prompt = "User asked: \"\(userText)\"\n\nTask results:\n\(summary)\n\nSummarize what was accomplished in 1-2 spoken sentences. Be direct and specific. No filler."
        guard let r = try? await GigiCloudService.shared.callWithFunctions(
            systemInstruction: "You are GIGI. Summarize completed tasks in 1-2 spoken sentences. No markdown, no filler.",
            contents: [GigiContent.user(prompt)],
            tools: [],
            model: "llama-3.1-8b-instant"
        ), let text = r.text, !text.isEmpty else {
            return results.values.first ?? "Done."
        }
        return text
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
                if let confirmIndex = results.firstIndex(where: { $0.requiresConfirm != nil }),
                   let confirmNeeded = results[confirmIndex].requiresConfirm,
                   response.functionCalls.indices.contains(confirmIndex),
                   let toolName = Optional(response.functionCalls[confirmIndex].name),
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
        if let jobId = pendingConfirmArgs["computerUseJobId"] as? String, !jobId.isEmpty {
            Task { await GigiComputerUse.shared.reject(jobId: jobId) }
        }
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
