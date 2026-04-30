import ActivityKit
import Combine
import Foundation

/// Gestisce una singola Live Activity per sessione (Dynamic Island + Lock Screen).
final class GigiLiveActivityController: ObservableObject {
    static let shared = GigiLiveActivityController()

    private var activity: Activity<GigiActivityAttributes>?
    private(set) var lastPhase: GigiPhase = .sleeping
    private var wakePulseCounter = 0
    private var suspendedPresenceSessionId: String?

    // Persistent "Shazam-style" pill. Stays alive across the full turn lifecycle
    // (sleeping→listening→thinking→executing→done→sleeping) without ever ending,
    // so the Dynamic Island shows GIGI is reachable while the app is backgrounded.
    // Mutually exclusive with presenceActivity: starts only if presenceActivity is nil.
    private var monitoringActivity: Activity<GigiActivityAttributes>?
    private(set) var isMonitoringModeActive = false

    // Surfaced to the UI so users can be told if Live Activities are disabled
    // at the OS level (Settings → Face ID & Passcode → Live Activities).
    @Published private(set) var lastActivityError: String?
    @Published private(set) var areActivitiesEnabled: Bool = ActivityAuthorizationInfo().areActivitiesEnabled

    var debugSnapshot: [String: String] {
        [
            "turnActivity": activity?.id ?? "none",
            "turnActivityState": activity.map { "\($0.activityState)" } ?? "none",
            "presenceActivity": presenceActivity?.id ?? "none",
            "presenceActivityState": presenceActivity.map { "\($0.activityState)" } ?? "none",
            "monitoringActivity": monitoringActivity?.id ?? "none",
            "monitoringActivityState": monitoringActivity.map { "\($0.activityState)" } ?? "none",
            "lastPhase": "\(lastPhase)",
            "monitoringModeActive": "\(isMonitoringModeActive)",
            "activitiesEnabled": "\(areActivitiesEnabled)",
            "lastActivityError": lastActivityError ?? "none"
        ]
    }

    private var enabled: Bool {
        let info = ActivityAuthorizationInfo()
        let on = info.areActivitiesEnabled
        if areActivitiesEnabled != on {
            DispatchQueue.main.async { [weak self] in self?.areActivitiesEnabled = on }
        }
        if !on {
            print("GIGI LiveActivity: disabled — check Settings → Face ID & Passcode → Live Activities")
            DispatchQueue.main.async { [weak self] in
                self?.lastActivityError = "Live Activities are off — enable in Settings → Face ID & Passcode."
            }
        }
        return on
    }

    // MARK: - Lifecycle

    @MainActor
    private func nextWakePulseId() -> String {
        wakePulseCounter += 1
        return "\(Date().timeIntervalSince1970)-\(wakePulseCounter)"
    }

    @MainActor
    func beginListening(transcript: String? = nil) async {
        guard enabled else { return }
        let message = phaseMessage(for: .listening)
        guard let target = await ensureIslandActivity(
            phase: .listening,
            message: message,
            transcript: transcript,
            staleAfter: 120
        ) else { return }

        if lastPhase == .listening { return }
        let content = ActivityContent(
            state: GigiActivityAttributes.ContentState(
                phase: .listening,
                message: message,
                lastTranscript: transcript
            ),
            staleDate: Date().addingTimeInterval(120)
        )
        await target.update(content)
        lastPhase = .listening
    }

    /// Wake-triggered Dynamic Island descent. The standby Presence/monitoring pill is
    /// ended first, then a fresh turn-scoped Live Activity is requested in `.listening`.
    /// That gives iOS a new important activity to present instead of a silent update to
    /// an already-compact pill.
    @MainActor
    func descendForListening(transcript: String? = nil) async {
        print("GIGI LiveActivity: descendForListening ENTER — monitoring=\(monitoringActivity != nil) presence=\(presenceActivity != nil) lastPhase=\(lastPhase)")
        guard enabled else {
            print("GIGI LiveActivity: descendForListening FAILED — activities disabled")
            return
        }

        let message = phaseMessage(for: .listening)
        let pulseId = nextWakePulseId()
        let content = ActivityContent(
            state: GigiActivityAttributes.ContentState(
                phase: .listening,
                message: message,
                lastTranscript: transcript,
                wakePulseId: pulseId
            ),
            staleDate: Date().addingTimeInterval(120),
            relevanceScore: 100
        )

        let alert = AlertConfiguration(
            title: "GIGI",
            body: "I heard you",
            sound: .default
        )

        if let presenceActivity {
            suspendedPresenceSessionId = presenceActivity.attributes.sessionID
            await endPresenceActivity()
        }
        await stopPersistentPill()
        if let existing = activity {
            await existing.end(content, dismissalPolicy: .immediate)
            activity = nil
        }

        do {
            let attrs = GigiActivityAttributes(sessionID: UUID().uuidString)
            let turn = try Activity.request(attributes: attrs, content: content, pushType: nil)
            activity = turn
            lastPhase = .listening
            lastActivityError = nil
            await turn.update(content, alertConfiguration: alert)
            print("GIGI LiveActivity: turn Activity.request SUCCESS id=\(turn.id) pulse=\(pulseId)")
        } catch {
            lastActivityError = "Failed to start listening Live Activity: \(error.localizedDescription)"
            print("GIGI LiveActivity: turn Activity.request FAILED — \(error)")
            await restorePresenceIfNeeded()
        }
    }

    @MainActor
    private func ensureIslandActivity(
        phase: GigiPhase,
        message: String,
        transcript: String? = nil,
        staleAfter: TimeInterval
    ) async -> Activity<GigiActivityAttributes>? {
        guard enabled else { return nil }

        if let activity, activity.activityState == .active || activity.activityState == .pending {
            return activity
        }

        if let presence = presenceActivity {
            if presence.activityState == .stale {
                print("GIGI LiveActivity: presence activity is stale — recreating")
                await endPresenceActivity()
                await startPresenceActivity(sessionId: presence.attributes.sessionID)
                return presenceActivity
            }
            if presence.activityState == .active || presence.activityState == .pending {
                return presence
            }
            print("GIGI LiveActivity: presence activity not active (\(presence.activityState)) — clearing")
            presenceActivity = nil
        }

        if let mon = monitoringActivity {
            switch mon.activityState {
            case .active, .pending:
                return mon
            case .stale:
                print("GIGI LiveActivity: monitoring activity stale — recreating")
                await endMonitoringActivity(mon)
            case .ended, .dismissed:
                print("GIGI LiveActivity: monitoring activity \(mon.activityState) — recreating")
                monitoringActivity = nil
            @unknown default:
                print("GIGI LiveActivity: monitoring activity unknown state — recreating")
                await endMonitoringActivity(mon)
            }
        }

        if let recovered = Activity<GigiActivityAttributes>.activities.first(where: { activity in
            activity.activityState == .active || activity.activityState == .pending
        }) {
            monitoringActivity = recovered
            isMonitoringModeActive = true
            print("GIGI LiveActivity: recovered existing activity id=\(recovered.id)")
            return recovered
        }

        return await requestMonitoringActivity(
            phase: phase,
            message: message,
            transcript: transcript,
            staleAfter: staleAfter
        )
    }

    @MainActor
    private func requestMonitoringActivity(
        phase: GigiPhase,
        message: String,
        transcript: String? = nil,
        staleAfter: TimeInterval = 3600
    ) async -> Activity<GigiActivityAttributes>? {
        guard enabled else { return nil }
        let attrs = GigiActivityAttributes(sessionID: UUID().uuidString)
        let state = GigiActivityAttributes.ContentState(
            phase: phase,
            message: message,
            lastTranscript: transcript
        )
        let content = ActivityContent(state: state, staleDate: Date().addingTimeInterval(staleAfter))
        do {
            let act = try Activity.request(attributes: attrs, content: content, pushType: nil)
            monitoringActivity = act
            isMonitoringModeActive = true
            lastPhase = phase
            lastActivityError = nil
            print("GIGI LiveActivity: monitoring Activity.request SUCCESS id=\(act.id) phase=\(phase)")
            return act
        } catch {
            print("GIGI LiveActivity: monitoring Activity.request FAILED — \(error)")
            isMonitoringModeActive = false
            lastActivityError = "Failed to start Live Activity: \(error.localizedDescription)"
            return nil
        }
    }

    @MainActor
    private func endMonitoringActivity(_ act: Activity<GigiActivityAttributes>) async {
        monitoringActivity = nil
        let cs = GigiActivityAttributes.ContentState(phase: .done, message: "")
        let content = ActivityContent(state: cs, staleDate: nil)
        await act.end(content, dismissalPolicy: .immediate)
    }

    @MainActor
    private func restorePresenceIfNeeded() async {
        guard GigiSmartOrchestrator.shared.isPresenceActive else { return }
        let sessionId = suspendedPresenceSessionId ?? UUID().uuidString
        suspendedPresenceSessionId = nil
        guard presenceActivity == nil else { return }
        await startPresenceActivity(sessionId: sessionId)
    }

    @MainActor
    func updateMonitoringPill(
        state phase: GigiPhase,
        message: String,
        transcript: String? = nil,
        staleAfter: TimeInterval = 3600
    ) async {
        let normalizedState = normalizedPhase(phase, message: message)
        let displayMessage = normalizedMessage(message, for: normalizedState)
        guard let target = await ensureIslandActivity(
            phase: normalizedState,
            message: displayMessage,
            transcript: transcript,
            staleAfter: staleAfter
        ) else { return }
        lastPhase = normalizedState
        let content = ActivityContent(
            state: GigiActivityAttributes.ContentState(
                phase: normalizedState,
                message: displayMessage,
                lastTranscript: transcript
            ),
            staleDate: Date().addingTimeInterval(staleAfter)
        )
        await target.update(content)
    }

    @MainActor
    func showError(message: String, transcript: String? = nil) async {
        await updateMonitoringPill(
            state: .error,
            message: message,
            transcript: transcript,
            staleAfter: 300
        )
    }

    @MainActor
    private func requestNewListeningActivity() async {
        guard enabled else { return }
        let attrs = GigiActivityAttributes(sessionID: UUID().uuidString)
        let state = GigiActivityAttributes.ContentState(phase: .listening, message: phaseMessage(for: .listening))
        let content = ActivityContent(state: state, staleDate: Date().addingTimeInterval(120))
        if let existing = activity {
            await existing.update(content)
            lastPhase = .listening
            return
        }
        do {
            activity = try Activity.request(attributes: attrs, content: content, pushType: nil)
            lastPhase = .listening
            lastActivityError = nil
        } catch {
            print("GIGI Live Activity: request failed — \(error)")
            lastActivityError = "Failed to start Live Activity: \(error.localizedDescription)"
        }
    }

    /// Push the latest mic input level (0.0–1.0) into the live `.listening`
    /// activity so the Dynamic Island waveform animates with the user's
    /// voice. No-op if no activity is running or the level is unchanged
    /// at the encoded precision (avoids redundant ActivityKit churn).
    @MainActor
    func updateAudioLevel(_ level: Float) async {
        guard enabled, lastPhase == .listening else { return }
        guard let activity else { return }
        let clamped = max(0.0, min(1.0, level))
        // Quantize to 0.05 steps so we don't burn ActivityKit budget on noise.
        let bucketed = (clamped * 20).rounded() / 20
        let message = phaseMessage(for: .listening)
        let content = ActivityContent(
            state: GigiActivityAttributes.ContentState(
                phase: .listening,
                message: message,
                audioLevel: bucketed
            ),
            staleDate: Date().addingTimeInterval(60)
        )
        await activity.update(content)
    }

    @MainActor
    func transitionToThinking(transcript: String? = nil) async {
        lastPhase = .thinking
        let message = phaseMessage(for: .thinking)
        let content = ActivityContent(
            state: GigiActivityAttributes.ContentState(
                phase: .thinking,
                message: message,
                lastTranscript: transcript
            ),
            staleDate: Date().addingTimeInterval(90)
        )
        if let activity {
            await activity.update(content)
            return
        }
        if monitoringActivity != nil || isMonitoringModeActive {
            await updateMonitoringPill(
                state: .thinking,
                message: message,
                transcript: transcript,
                staleAfter: 90
            )
            return
        }
        guard enabled, let activity else { return }
        await activity.update(content)
    }

    @MainActor
    func transitionToExecuting(message: String) async {
        lastPhase = .executing
        let content = ActivityContent(
            state: GigiActivityAttributes.ContentState(phase: .executing, message: message),
            staleDate: Date().addingTimeInterval(120)
        )
        if let activity {
            await activity.update(content)
            return
        }
        if monitoringActivity != nil || isMonitoringModeActive {
            await updateMonitoringPill(state: .executing, message: message, staleAfter: 120)
            return
        }
        guard enabled, let activity else { return }
        await activity.update(content)
    }

    /// Pill in `.speaking` while TTS plays. Banner = full response (truncated upstream).
    @MainActor
    func transitionToSpeaking(message: String) async {
        lastPhase = .speaking
        let displayMessage = normalizedMessage(message, for: .speaking)
        let content = ActivityContent(
            state: GigiActivityAttributes.ContentState(phase: .speaking, message: displayMessage),
            staleDate: Date().addingTimeInterval(60)
        )
        if let activity {
            await activity.update(content)
            return
        }
        if monitoringActivity != nil || isMonitoringModeActive {
            await updateMonitoringPill(state: .speaking, message: displayMessage, staleAfter: 60)
            return
        }
        guard enabled, let activity else { return }
        await activity.update(content)
    }

    @MainActor
    func transitionToFollowUp(transcript: String? = nil) async {
        await updatePresence(
            state: .followUp,
            message: phaseMessage(for: .followUp),
            transcript: transcript
        )
    }

    /// Mostra "Fatto" e chiude dopo `delay` secondi.
    /// Quando monitoring è attivo: mostra brevemente .done poi torna a .sleeping — non termina l'activity.
    @MainActor
    func completeWithDone(message: String, dismissAfter delay: TimeInterval = 3) async {
        if let activity {
            lastPhase = .done
            let doneState = GigiActivityAttributes.ContentState(phase: .done, message: message)
            let endContent = ActivityContent(state: doneState, staleDate: nil)
            let dismissAt = Date.now.addingTimeInterval(delay)
            await activity.end(endContent, dismissalPolicy: .after(dismissAt))
            self.activity = nil
            if delay > 0 {
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
            await restorePresenceIfNeeded()
            return
        }
        if let mon = monitoringActivity {
            // Briefly show done, then return pill to sleeping so user sees turn completed.
            lastPhase = .done
            let doneContent = ActivityContent(
                state: GigiActivityAttributes.ContentState(phase: .done, message: message),
                staleDate: Date().addingTimeInterval(30)
            )
            await mon.update(doneContent)
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            lastPhase = .sleeping
            let sleepContent = ActivityContent(
                state: GigiActivityAttributes.ContentState(phase: .sleeping, message: phaseMessage(for: .sleeping)),
                staleDate: Date().addingTimeInterval(3600)
            )
            await mon.update(sleepContent)
            return
        }
        await restorePresenceIfNeeded()
    }

    /// Interruzione immediata (es. stop utente, errore).
    /// Quando monitoring è attivo: torna a .sleeping invece di terminare.
    @MainActor
    func endImmediately() async {
        if let activity {
            let content = ActivityContent(
                state: GigiActivityAttributes.ContentState(phase: .done, message: ""),
                staleDate: nil
            )
            await activity.end(content, dismissalPolicy: .immediate)
            self.activity = nil
            lastPhase = .sleeping
            await restorePresenceIfNeeded()
            return
        }
        if let mon = monitoringActivity {
            lastPhase = .sleeping
            let content = ActivityContent(
                state: GigiActivityAttributes.ContentState(phase: .sleeping, message: phaseMessage(for: .sleeping)),
                staleDate: Date().addingTimeInterval(3600)
            )
            await mon.update(content)
            return
        }
        guard let activity else { return }
        let content = ActivityContent(
            state: GigiActivityAttributes.ContentState(phase: .done, message: ""),
            staleDate: nil
        )
        await activity.end(content, dismissalPolicy: .immediate)
        self.activity = nil
        lastPhase = .listening
    }

    // MARK: - Wake Word Monitoring activity (Shazam-style persistent pill)

    /// Start persistent pill. Idempotent — no-op if already active or if presenceActivity owns the island.
    @MainActor
    func startPersistentPill() async {
        print("GIGI LiveActivity: startPersistentPill ENTER")
        let info = ActivityAuthorizationInfo()
        print("GIGI LiveActivity: areActivitiesEnabled=\(info.areActivitiesEnabled) frequentPushesEnabled=\(info.frequentPushesEnabled)")
        guard enabled else {
            print("GIGI LiveActivity: startPersistentPill ABORT — activities disabled at OS level")
            return
        }
        guard !GigiSmartOrchestrator.shared.isPresenceActive else {
            print("GIGI LiveActivity: startPersistentPill SKIP — Presence owns island")
            return
        }
        guard presenceActivity == nil else {
            print("GIGI LiveActivity: startPersistentPill SKIP — presenceActivity already owns island")
            return
        }
        _ = await ensureIslandActivity(
            phase: .sleeping,
            message: phaseMessage(for: .sleeping),
            staleAfter: 3600
        )
    }

    /// Compatibility shim retained for older call sites.
    @MainActor
    func startWakeWordMonitoring() async { await startPersistentPill() }

    /// End persistent pill. Called only on explicit teardown (e.g. user disables wake word AND no Presence).
    @MainActor
    func stopPersistentPill() async {
        isMonitoringModeActive = false
        guard let act = monitoringActivity else { return }
        monitoringActivity = nil
        let cs = GigiActivityAttributes.ContentState(phase: .done, message: "")
        let content = ActivityContent(state: cs, staleDate: nil)
        await act.end(content, dismissalPolicy: .immediate)
    }

    @MainActor
    func stopWakeWordMonitoring() async { await stopPersistentPill() }

    // MARK: - Presence Mode session activity

    private var presenceActivity: Activity<GigiActivityAttributes>?

    @MainActor
    func startPresenceActivity(sessionId: String) async {
        guard enabled else { return }
        await endPresenceActivity()   // clean up any stale
        let attrs = GigiActivityAttributes(sessionID: sessionId)
        let state = GigiActivityAttributes.ContentState(
            phase: .sleeping, message: phaseMessage(for: .sleeping), lastTranscript: nil, sessionId: sessionId
        )
        let content = ActivityContent(state: state, staleDate: Date().addingTimeInterval(3600))
        do {
            presenceActivity = try Activity.request(attributes: attrs, content: content, pushType: nil)
            lastPhase = .sleeping
            lastActivityError = nil
            print("GIGI LiveActivity: presence Activity.request SUCCESS id=\(presenceActivity?.id ?? "nil")")
        } catch {
            print("GIGI Live Activity: presence start failed — \(error)")
            lastActivityError = "Failed to start Presence Live Activity: \(error.localizedDescription)"
        }
    }

    @MainActor
    func updatePresence(
        state: GigiPhase,
        message: String,
        transcript: String? = nil,
        requestAttention: Bool = false
    ) async {
        guard enabled else { return }
        let normalizedState = normalizedPhase(state, message: message)
        let displayMessage = normalizedMessage(message, for: normalizedState)
        guard let act = presenceActivity else {
            if requestAttention {
                await descendForListening(transcript: transcript)
            }
            return
        }
        let pulseId = requestAttention ? nextWakePulseId() : nil
        let cs = GigiActivityAttributes.ContentState(
            phase: normalizedState, message: displayMessage,
            lastTranscript: transcript, sessionId: nil,
            wakePulseId: pulseId
        )
        let content = ActivityContent(state: cs, staleDate: Date().addingTimeInterval(3600))
        if requestAttention {
            let alert = AlertConfiguration(
                title: "GIGI",
                body: "I heard you",
                sound: .default
            )
            await act.update(content, alertConfiguration: alert)
            print("GIGI LiveActivity: presence attention update sent id=\(act.id) pulse=\(pulseId ?? "nil")")
        } else {
            await act.update(content)
        }
        lastPhase = normalizedState
    }

    @MainActor
    func endPresenceActivity() async {
        guard let act = presenceActivity else { return }
        let cs = GigiActivityAttributes.ContentState(
            phase: .done, message: "Session ended", lastTranscript: nil, sessionId: nil
        )
        let content = ActivityContent(state: cs, staleDate: nil)
        await act.end(content, dismissalPolicy: .immediate)
        presenceActivity = nil
    }

    // MARK: - Live Activity snapshot

    /// Snapshot dell’activity corrente per aggiornamenti inline.
    @MainActor
    func requestForShortcut(initialMessage: String) async throws -> Activity<GigiActivityAttributes>? {
        guard enabled else { return nil }
        await endImmediately()
        let attrs = GigiActivityAttributes(sessionID: UUID().uuidString)
        let state = GigiActivityAttributes.ContentState(phase: .listening, message: initialMessage)
        let content = ActivityContent(state: state, staleDate: Date().addingTimeInterval(120))
        activity = try Activity.request(attributes: attrs, content: content, pushType: nil)
        lastPhase = .listening
        return activity
    }

    @MainActor
    func updateActivity(
        _ activity: Activity<GigiActivityAttributes>?,
        phase: GigiPhase,
        message: String
    ) async {
        guard let activity else { return }
        let normalizedState = normalizedPhase(phase, message: message)
        let displayMessage = normalizedMessage(message, for: normalizedState)
        lastPhase = normalizedState
        let content = ActivityContent(state: GigiActivityAttributes.ContentState(phase: normalizedState, message: displayMessage), staleDate: Date().addingTimeInterval(30))
        await activity.update(content)
    }

    private func normalizedPhase(_ phase: GigiPhase, message: String) -> GigiPhase {
        guard phase == .listening else { return phase }
        let text = message.lowercased()
        return text.contains("follow-up") || text.contains("follow up") ? .followUp : .listening
    }

    private func normalizedMessage(_ message: String, for phase: GigiPhase) -> String {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? phaseMessage(for: phase) : trimmed
    }

    private func phaseMessage(for phase: GigiPhase) -> String {
        switch phase {
        case .listening:
            return "Speak now"
        case .thinking:
            return "Working on your request"
        case .executing:
            return "Running the action"
        case .done:
            return "Finished"
        case .sleeping:
            return "Ready — say Hey GIGI"
        case .speaking:
            return "Say GIGI or tap to interrupt"
        case .followUp:
            return "Answer now — no wake word needed"
        case .muted:
            return "Muted — tap Unmute to resume"
        case .error:
            return "Tap to recover"
        }
    }
}
