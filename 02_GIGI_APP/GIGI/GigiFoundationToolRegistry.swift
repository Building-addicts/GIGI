import Foundation

// MARK: - GigiFoundationToolRegistry (stub — Phase 2)
//
// Exposes a *curated subset of 15 tools* to Apple Foundation Models via the
// `Tool` protocol (iOS 26+) — replaces the 47-tool brittle `selectRelevant`
// scoring in `GigiToolRegistry`. Apple FM constrained decoding picks the
// right tool without keyword heuristics, with parallel/serial call graphs
// handled by the runtime.
//
// **Proposed 15 tools** (Q2 decision pending, see plan §3.6 + §7.Q2):
//   set_timer, set_alarm, set_reminder, send_message, make_call, facetime,
//   navigate, play_music, open_app, weather, read_calendar, find_free_slot,
//   read_email, homekit_on, homekit_off, delegate_to_claude
//   (15 = 4 homekit collapsed to homekit_on/off, plus the explicit
//   delegate_to_claude escape valve)
//
// Each tool wraps the corresponding `GigiActionDispatcher` handler — no
// new behavior, just a thinner Apple FM-facing surface.
//
// Reference: docs/plans/frolicking-stargazing-pancake.md §3.6
// ADR-0008 (TBD) — Apple FM Tool calling vs scored tool registry (closes TD-001)
// Blocker: Q2 decision (final 15 list) + Q11 (iOS 26.3 pin) + Spike A
// (Apple FM 26.4 regression test)

#if canImport(FoundationModels)
import FoundationModels

@available(iOS 26.0, *)
@MainActor
enum GigiFoundationToolRegistry {

    // TODO Phase 2: declare 15 structs conforming to `Tool` protocol:
    //
    //   @available(iOS 26, *)
    //   struct SetTimerTool: Tool {
    //       let name = "set_timer"
    //       let description = "Set a countdown timer for the user."
    //       @Generable struct Arguments { ... }
    //       func call(arguments: Arguments) async -> String {
    //           await GigiActionDispatcher.shared.bridge.executeRaw(
    //               label: "set_timer",
    //               params: [...]
    //           )
    //       }
    //   }
    //
    // Each tool delegates to GigiActionDispatcher to keep one source of
    // truth for action execution. See plan §3.6 for the code template.

    // static var all: [any Tool] {
    //     // Returns the 15-tool array, gated on iOS 26 availability.
    //     // Falls back to empty array on earlier OS — GigiFallbackRouter
    //     // takes over.
    // }
}

#endif
