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
    private var lockedVisualState: GigiActivityAttributes.ContentState?
    private var lastRenderedState: GigiActivityAttributes.ContentState?
    @Published private(set) var isIslandLocked = false

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
            "isIslandLocked": "\(isIslandLocked)",
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
            state: contentState(
                phase: .listening,
                message: message,
                transcript: transcript
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
            state: contentState(
                phase: .listening,
                message: message,
                transcript: transcript,
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

    /// First-wake consent prompt. Surfaces the always-listening question on whichever
    /// activity already owns the island (presence > monitoring) — never requests a new
    /// `Activity` here, which would race the existing pill and produce a double island.
    /// `AlertConfiguration` forces iOS to expand so the Allow / Decline buttons are
    /// visible (without it the prompt stays compact and the buttons never render).
    @MainActor
    func presentConsentRequest() async {
        guard enabled else {
            print("GIGI LiveActivity: presentConsentRequest FAILED — activities disabled")
            return
        }

        let host = activity ?? presenceActivity ?? monitoringActivity
        guard let target = host else {
            // No existing activity to host the prompt — request one. Keeps a fallback
            // path so the prompt is never silently dropped at first wake.
            let state = contentState(
                phase: .sleeping,
                message: "Keep GIGI always listening?",
                consentPending: true
            )
            let content = ActivityContent(state: state, staleDate: Date().addingTimeInterval(120), relevanceScore: 100)
            let alert = AlertConfiguration(title: "GIGI", body: "Keep GIGI always listening?", sound: .default)
            do {
                let attrs = GigiActivityAttributes(sessionID: UUID().uuidString)
                let act = try Activity.request(attributes: attrs, content: content, pushType: nil)
                activity = act
                lastPhase = .sleeping
                await act.update(content, alertConfiguration: alert)
                print("GIGI LiveActivity: consent prompt activity requested (no host)")
            } catch {
                print("GIGI LiveActivity: consent prompt request FAILED — \(error)")
            }
            return
        }

        let state = contentState(
            phase: .sleeping,
            message: "Keep GIGI always listening?",
            consentPending: true
        )
        let content = ActivityContent(state: state, staleDate: Date().addingTimeInterval(120), relevanceScore: 100)
        let alert = AlertConfiguration(title: "GIGI", body: "Keep GIGI always listening?", sound: .default)
        await target.update(content, alertConfiguration: alert)
        print("GIGI LiveActivity: consent prompt presented on existing activity id=\(target.id)")
    }

    /// Clears `consentPending` on whichever activity is currently visible. Called by
    /// the Allow / Decline session handlers right after the user picks, BEFORE any
    /// follow-up state change (lock or descendForListening) so the next snapshot the
    /// island captures is clean.
    @MainActor
    func clearConsentPending() async {
        let host = activity ?? presenceActivity ?? monitoringActivity
        guard let target = host else { return }
        var state = lastRenderedState ?? GigiActivityAttributes.ContentState(
            phase: lastPhase,
            message: phaseMessage(for: lastPhase)
        )
        state.consentPending = false
        lastRenderedState = state
        let content = ActivityContent(state: state, staleDate: Date().addingTimeInterval(3600), relevanceScore: 50)
        await target.update(content)
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
        let state = contentState(
            phase: phase,
            message: message,
            transcript: transcript
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
        let cs = endState()
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
        let renderedState = contentState(
            phase: normalizedState,
            message: displayMessage,
            transcript: transcript
        )
        lastPhase = renderedState.phase
        let content = ActivityContent(
            state: renderedState,
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
        let state = contentState(phase: .listening, message: phaseMessage(for: .listening))
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

    @MainActor
    func transitionToThinking(transcript: String? = nil) async {
        lastPhase = .thinking
        let message = phaseMessage(for: .thinking)
        let content = ActivityContent(
            state: contentState(
                phase: .thinking,
                message: message,
                transcript: transcript
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
            state: contentState(phase: .executing, message: message),
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
        print("GIGI LiveActivity: transitionToSpeaking ENTER lastPhase=\(lastPhase) activity=\(activity != nil) monitoring=\(monitoringActivity != nil)")
        lastPhase = .speaking
        let displayMessage = normalizedMessage(message, for: .speaking)
        let content = ActivityContent(
            state: contentState(phase: .speaking, message: displayMessage),
            staleDate: Date().addingTimeInterval(60)
        )
        if let activity {
            await activity.update(content)
            print("GIGI LiveActivity: transitionToSpeaking EXIT phase=\(lastPhase) activityId=\(activity.id)")
            return
        }
        if monitoringActivity != nil || isMonitoringModeActive {
            await updateMonitoringPill(state: .speaking, message: displayMessage, staleAfter: 60)
            print("GIGI LiveActivity: transitionToSpeaking EXIT phase=\(lastPhase) activityId=monitoring")
            return
        }
        guard enabled, let activity else {
            print("GIGI LiveActivity: transitionToSpeaking EXIT phase=\(lastPhase) activityId=nil")
            return
        }
        await activity.update(content)
        print("GIGI LiveActivity: transitionToSpeaking EXIT phase=\(lastPhase) activityId=\(activity.id)")
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
        if isIslandLocked {
            // User explicitly pinned the Island; keep the current visual state instead
            // of auto-dismissing/returning to Ready until the unlock control is tapped.
            if let snapshot = lockedVisualState ?? lastRenderedState {
                await updateVisibleActivities(with: snapshot, staleAfter: 3600)
            }
            return
        }
        if let activity {
            lastPhase = .done
            let doneState = endState(message: message)
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
                state: contentState(phase: .done, message: message),
                staleDate: Date().addingTimeInterval(30)
            )
            await mon.update(doneContent)
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            lastPhase = .sleeping
            let sleepContent = ActivityContent(
                state: contentState(phase: .sleeping, message: phaseMessage(for: .sleeping)),
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
        if isIslandLocked {
            if let snapshot = lockedVisualState ?? lastRenderedState {
                await updateVisibleActivities(with: snapshot, staleAfter: 3600)
            }
            return
        }
        if let activity {
            let content = ActivityContent(
                state: endState(),
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
                state: contentState(phase: .sleeping, message: phaseMessage(for: .sleeping)),
                staleDate: Date().addingTimeInterval(3600)
            )
            await mon.update(content)
            return
        }
        guard let activity else { return }
        let content = ActivityContent(
            state: endState(),
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
        let cs = endState()
        let content = ActivityContent(state: cs, staleDate: nil)
        await act.end(content, dismissalPolicy: .immediate)
    }

    @MainActor
    func stopWakeWordMonitoring() async { await stopPersistentPill() }

    // MARK: - Presence Mode session activity

    private var presenceActivity: Activity<GigiActivityAttributes>?
    // GIGI issue #88: periodic refresh keeps the Live Activity banner from being
    // silently dismissed by iOS after the original staleDate elapses. We push a
    // fresh staleDate (Date()+1h) every 30 minutes for the lifetime of the
    // presenceActivity. Cancelled in `endPresenceActivity()`.
    private var refreshTask: Task<Void, Never>?

    @MainActor
    func startPresenceActivity(sessionId: String) async {
        guard enabled else { return }
        await endPresenceActivity()   // clean up any stale
        let attrs = GigiActivityAttributes(sessionID: sessionId)
        let state = contentState(
            phase: .sleeping,
            message: phaseMessage(for: .sleeping),
            sessionId: sessionId
        )
        let content = ActivityContent(state: state, staleDate: Date().addingTimeInterval(3600))
        do {
            presenceActivity = try Activity.request(attributes: attrs, content: content, pushType: nil)
            lastPhase = .sleeping
            lastActivityError = nil
            print("GIGI LiveActivity: presence Activity.request SUCCESS id=\(presenceActivity?.id ?? "nil")")
            // GIGI issue #88: start periodic staleDate refresh so the pill persists
            // across long-idle days. 30-min cadence is well below iOS' typical
            // stale-dismissal window once `staleDate` has elapsed.
            refreshTask?.cancel()
            refreshTask = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 30 * 60 * 1_000_000_000)
                    if Task.isCancelled { break }
                    await self?.refreshPresenceStaleDate()
                }
            }
        } catch {
            print("GIGI Live Activity: presence start failed — \(error)")
            lastActivityError = "Failed to start Presence Live Activity: \(error.localizedDescription)"
        }
    }

    /// GIGI issue #88: refresh the presence Live Activity content with a new staleDate
    /// so iOS does not silently dismiss the pill after the original stale window.
    /// No-op when there is no active presence Live Activity.
    @MainActor
    private func refreshPresenceStaleDate() async {
        guard let act = presenceActivity else { return }
        let cs = GigiActivityAttributes.ContentState(
            phase: lastPhase,
            message: phaseMessage(for: lastPhase),
            lastTranscript: nil,
            sessionId: act.attributes.sessionID
        )
        let content = ActivityContent(state: cs, staleDate: Date().addingTimeInterval(3600))
        await act.update(content)
        print("GIGI LiveActivity: presence staleDate refreshed id=\(act.id)")
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
        let cs = contentState(
            phase: normalizedState, message: displayMessage,
            transcript: transcript, sessionId: nil,
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
        lastPhase = cs.phase
    }

    @MainActor
    func endPresenceActivity() async {
        // GIGI issue #88: stop the periodic refresh whenever the presence
        // activity is torn down (explicit stop OR cleanup-before-restart in
        // `startPresenceActivity`). startPresenceActivity will spin up a new
        // task on success.
        refreshTask?.cancel()
        refreshTask = nil
        guard let act = presenceActivity else { return }
        let cs = endState(message: "Session ended")
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
        let state = contentState(phase: .listening, message: initialMessage)
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
        let content = ActivityContent(
            state: contentState(phase: normalizedState, message: displayMessage),
            staleDate: Date().addingTimeInterval(30)
        )
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

    private func contentState(
        phase: GigiPhase,
        message: String,
        transcript: String? = nil,
        sessionId: String? = nil,
        wakePulseId: String? = nil,
        consentPending: Bool = false
    ) -> GigiActivityAttributes.ContentState {
        var desired = GigiActivityAttributes.ContentState(
            phase: phase,
            message: message,
            lastTranscript: transcript,
            sessionId: sessionId,
            wakePulseId: wakePulseId,
            isIslandLocked: false,
            consentPending: consentPending
        )

        if isIslandLocked {
            if isIdleDemotion(phase), var locked = lockedVisualState ?? lastRenderedState {
                locked.isIslandLocked = true
                locked.consentPending = consentPending
                lastRenderedState = locked
                return locked
            }
            desired.isIslandLocked = true
            lockedVisualState = desired
        }

        lastRenderedState = desired
        return desired
    }

    private func endState(phase: GigiPhase = .done, message: String = "") -> GigiActivityAttributes.ContentState {
        var state = GigiActivityAttributes.ContentState(phase: phase, message: message)
        state.isIslandLocked = isIslandLocked
        return state
    }

    private func isIdleDemotion(_ phase: GigiPhase) -> Bool {
        phase == .sleeping || phase == .done
    }

    @MainActor
    func setIslandLocked(_ locked: Bool) async {
        guard isIslandLocked != locked else { return }
        isIslandLocked = locked

        if locked {
            var snapshot = lastRenderedState ?? GigiActivityAttributes.ContentState(
                phase: lastPhase,
                message: phaseMessage(for: lastPhase)
            )
            snapshot.isIslandLocked = true
            lockedVisualState = snapshot
            lastRenderedState = snapshot
            await updateVisibleActivities(with: snapshot, staleAfter: 3600)
            return
        }

        lockedVisualState = nil
        if let turn = activity, GigiSmartOrchestrator.shared.isPresenceActive {
            let releaseState = endState(message: "Released")
            let releaseContent = ActivityContent(state: releaseState, staleDate: nil)
            await turn.end(releaseContent, dismissalPolicy: .immediate)
            activity = nil
            await restorePresenceIfNeeded()
            return
        }
        if var snapshot = lastRenderedState {
            snapshot.isIslandLocked = false
            lastRenderedState = snapshot
            await updateVisibleActivities(with: snapshot, staleAfter: 3600)
        }
    }

    @MainActor
    private func updateVisibleActivities(
        with state: GigiActivityAttributes.ContentState,
        staleAfter: TimeInterval
    ) async {
        let content = ActivityContent(state: state, staleDate: Date().addingTimeInterval(staleAfter))
        if let activity { await activity.update(content) }
        if let presenceActivity { await presenceActivity.update(content) }
        if let monitoringActivity { await monitoringActivity.update(content) }
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
