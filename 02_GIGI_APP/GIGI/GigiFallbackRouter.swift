import Foundation

// MARK: - GigiFallbackRouter (stub — Phase 2)
//
// Rule-based router for devices that cannot run Apple Foundation Models
// (iPhone <15 Pro, iOS <26, Apple Intelligence disabled or model assets
// not yet downloaded). Replaces Apple FM Gate 2 with deterministic
// regex+keyword routing, then delegates to the same Path 3 / Path 4 as
// the main router.
//
// **Why it matters**: per Statista 2025 data referenced in the plan, ~90%
// of installed iPhones do not have Apple FM-capable hardware. Without a
// fallback, the demo collapses to Path 1 (NLU rules) + Path 4 (Claude
// Code) only — losing Path 3 (Ollama offline reasoning) entirely for the
// majority of users. This file is the bridge.
//
// Reference: docs/plans/frolicking-stargazing-pancake.md §3.8 + §9 Risks
// ADR-0009 (TBD) — Hardware target iPhone 15 Pro+ + fallback degradation

@MainActor
final class GigiFallbackRouter {
    static let shared = GigiFallbackRouter()

    private init() {}

    // TODO Phase 2: implement `route(text: String) async -> AgentResult`
    // - NLU classification via existing `GigiNLUEngine` (same as Gate 1)
    // - For non-NLU misses, decide path heuristically:
    //   * complexity keywords ("explain", "summarize", "search") → Ollama
    //     if harness reachable, else degraded message
    //   * browser/web keywords → Claude Code (Path 4) if subscription OK
    //   * otherwise → "Apple Intelligence not available, can't help with that"
    // - Cost-aware NOT needed here — already a degraded path.
    //
    // When `GigiFoundationAgent.isSupported == false`, `GigiAgentEngine`
    // delegates to this router instead of the main `GigiRequestRouter`.
}
