import Foundation
import SwiftUI

// MARK: - GigiOnboardingFlow (GATE 9.D — Discovery Layer A)
//
// Coordinator for the conversational mini-tour shown AFTER the existing
// `OnboardingView` (which handles permissions + pairing). Layer A is a
// 3-step in-chat tour that teaches new users what GIGI can do:
//
//   Step 0  → "Hi, I'm GIGI. Try saying 'set a timer for 5 minutes'."
//   Step 1  → user tries something, GIGI celebrates
//   Step 2  → "I can also help with calendar, contacts, smart home, and more."
//   Step 3  → done (flag persisted, never shown again)
//
// Trigger: UserDefaults flag `gigi.onboarding.layer_a_complete` == false.
// Skip: if user already has ≥5 turns logged (upgrade user — already
//       familiar with GIGI, no need to baby them).
//
// Mount: `MainTabView` evaluates onLaunch via `evaluateOnLaunch()` and
// presents `OnboardingTourView` if `shouldShowTour == true`.
//
// All user-facing strings in this coordinator are English (CLAUDE.md
// §Lingua hard rule). Italian is allowed only in code comments and logs.

@MainActor
final class GigiOnboardingFlow: ObservableObject {

    static let shared = GigiOnboardingFlow()

    // MARK: - Persistence keys

    private let completeKey  = "gigi.onboarding.layer_a_complete"
    private let turnCountKey = "gigi.usage.turn_count"

    /// Skip the tour if the user already had >= this many turns logged.
    /// Conservative — only counts as "experienced" after meaningful usage.
    private let upgradeSkipThreshold = 5

    // MARK: - Published state

    @Published var shouldShowTour: Bool = false
    @Published var currentStep: Int = 0

    /// Total steps the tour walks through (intro / try / enumerate).
    let totalSteps = 3

    // MARK: - Lifecycle

    func evaluateOnLaunch() {
        let completed = UserDefaults.standard.bool(forKey: completeKey)
        let turns = UserDefaults.standard.integer(forKey: turnCountKey)

        if completed {
            GigiDebugLogger.log("OnboardingFlow: Layer A already complete, skip")
            shouldShowTour = false
            return
        }

        if turns >= upgradeSkipThreshold {
            // Upgrade user — auto-complete without showing the tour.
            GigiDebugLogger.log("OnboardingFlow: \(turns) turns >= threshold, auto-skip")
            markComplete()
            shouldShowTour = false
            return
        }

        GigiDebugLogger.log("OnboardingFlow: starting Layer A tour")
        currentStep = 0
        shouldShowTour = true
    }

    func advance() {
        currentStep += 1
        if currentStep >= totalSteps {
            markComplete()
            shouldShowTour = false
        }
    }

    func skip() {
        GigiDebugLogger.log("OnboardingFlow: user skipped Layer A at step \(currentStep)")
        markComplete()
        shouldShowTour = false
    }

    func resetForDebug() {
        // Debug-only: clear the flag so the tour shows again on next launch.
        // Wired to a debug button in Settings (GATE 9.D test harness).
        UserDefaults.standard.removeObject(forKey: completeKey)
        currentStep = 0
        shouldShowTour = true
        GigiDebugLogger.log("OnboardingFlow: reset (debug)")
    }

    // MARK: - Private

    private func markComplete() {
        UserDefaults.standard.set(true, forKey: completeKey)
        GigiDebugLogger.log("OnboardingFlow: Layer A marked complete")
    }

    /// Called by the chat orchestrator on each completed user turn so we
    /// can detect "upgrade" users on next launch.
    func recordUserTurn() {
        let current = UserDefaults.standard.integer(forKey: turnCountKey)
        UserDefaults.standard.set(current + 1, forKey: turnCountKey)
    }
}
