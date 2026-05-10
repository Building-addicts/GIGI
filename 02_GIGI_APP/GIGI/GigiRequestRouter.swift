import Foundation

// MARK: - GigiRequestRouter (stub — Phase 2)
//
// Replaces the 3-Gate flat in `GigiAgentEngine.process()` (Force Claude →
// NLU fast-path → Groq planner/agent loop) with the upfront router from the
// 5-path plan:
//
//   Gate 0: Mode operative (Settings → Minimal / Privacy Max / Apple
//           Optimized / Full Power) — filters which paths are enabled.
//   Gate 1: NLU rule-based fast-path (unchanged from current `deterministicFastPath`).
//   Gate 2: Apple FM router → FoundationRouterDecision (§3.4)
//           - native_tool       → Path 2 (iOS native Tool calling)
//           - delegate_local    → Path 3 (Ollama harness)
//           - delegate_cloud    → Path 4 (Claude Code subprocess + MCP)
//           - ask_clarification → speak directly
//           - reject            → graceful refusal
//
// Cost-aware routing: complexity ≤40 + non-browser → Ollama, else Claude Code.
//
// Reference: docs/plans/frolicking-stargazing-pancake.md §3
// ADR-0007 (TBD) — Hybrid 5-path router pattern
// Blocker: Q2 decision (subset 15 Apple FM Tool list)

@MainActor
final class GigiRequestRouter {
    static let shared = GigiRequestRouter()

    private init() {}

    // TODO Phase 2: implement `route(text: String) async -> AgentResult`
    // - Read Gate 0 mode from Keychain (`gigi.mode` key)
    // - Call NLU Gate 1 (existing `GigiNLUEngine.shared.classify`)
    // - On miss, call Apple FM Gate 2 with new `FoundationRouterDecision`
    //   schema (see GigiFoundationContracts.swift placeholder)
    // - Dispatch by decision.path with cost-aware logic
    // - Mirror DEBUG `BrainPathOverride` picker for path testing
    //
    // Until implemented, GigiAgentEngine.process() remains the entry point.
}
