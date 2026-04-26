import ActivityKit
import Foundation

/// Gestisce una singola Live Activity per sessione (Dynamic Island + Lock Screen).
final class GigiLiveActivityController {
    static let shared = GigiLiveActivityController()

    private var activity: Activity<GigiActivityAttributes>?
    private(set) var lastPhase: GigiPhase = .listening

    // Persistent wake-word monitoring activity (Shazam-style pill).
    // Stays alive as long as wake word is enabled — phases transition through the
    // full turn lifecycle instead of creating/ending a new activity each time.
    // Mutually exclusive with presenceActivity: starts only if presenceActivity is nil.
    private var monitoringActivity: Activity<GigiActivityAttributes>?
    private(set) var isMonitoringModeActive = false

    private var enabled: Bool {
        let info = ActivityAuthorizationInfo()
        if !info.areActivitiesEnabled {
            print("GIGI LiveActivity: disabled — check Settings → Face ID & Passcode → Live Activities")
        }
        return info.areActivitiesEnabled
    }

    // MARK: - Lifecycle

    @MainActor
    func beginListening() async {
        guard enabled else { return }
        // When monitoring activity is live, update its phase instead of creating a new activity.
        // Called twice per wake detection (handleWakeDetection + startListening) — idempotent.
        if let mon = monitoringActivity {
            guard lastPhase != .listening else { return }
            let content = ActivityContent(
                state: GigiActivityAttributes.ContentState(phase: .listening, message: "Listening…"),
                staleDate: Date().addingTimeInterval(120)
            )
            await mon.update(content)
            lastPhase = .listening
            return
        }
        let attrs = GigiActivityAttributes(sessionID: UUID().uuidString)
        let state = GigiActivityAttributes.ContentState(phase: .listening, message: "Listening…")
        let content = ActivityContent(state: state, staleDate: Date().addingTimeInterval(120))
        if let existing = activity {
            await existing.update(content)
            lastPhase = .listening
            return
        }
        do {
            activity = try Activity.request(attributes: attrs, content: content, pushType: nil)
            lastPhase = .listening
        } catch {
            print("GIGI Live Activity: request failed — \(error)")
        }
    }

    func transitionToThinking() async {
        lastPhase = .thinking
        let content = ActivityContent(
            state: GigiActivityAttributes.ContentState(phase: .thinking, message: "Thinking…"),
            staleDate: Date().addingTimeInterval(90)
        )
        if let mon = monitoringActivity { await mon.update(content); return }
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
        if let mon = monitoringActivity { await mon.update(content); return }
        guard enabled, let activity else { return }
        await activity.update(content)
    }

    /// Mostra "Fatto" e chiude dopo `delay` secondi.
    /// Quando monitoring è attivo: mostra brevemente .done poi torna a .sleeping — non termina l'activity.
    @MainActor
    func completeWithDone(message: String, dismissAfter delay: TimeInterval = 3) async {
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
                state: GigiActivityAttributes.ContentState(phase: .sleeping, message: "Ready"),
                staleDate: Date().addingTimeInterval(3600)
            )
            await mon.update(sleepContent)
            return
        }
        guard enabled, let activity else { return }
        lastPhase = .done
        let doneState = GigiActivityAttributes.ContentState(phase: .done, message: message)
        let endContent = ActivityContent(state: doneState, staleDate: nil)
        let dismissAt = Date.now.addingTimeInterval(delay)
        await activity.end(endContent, dismissalPolicy: .after(dismissAt))
        self.activity = nil
    }

    /// Interruzione immediata (es. stop utente, errore).
    /// Quando monitoring è attivo: torna a .sleeping invece di terminare.
    @MainActor
    func endImmediately() async {
        if let mon = monitoringActivity {
            lastPhase = .sleeping
            let content = ActivityContent(
                state: GigiActivityAttributes.ContentState(phase: .sleeping, message: "Ready"),
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
    func startWakeWordMonitoring() async {
        guard enabled else { return }
        // Presence Mode owns the island — don't fight it.
        guard presenceActivity == nil else { return }
        guard monitoringActivity == nil else { return }
        isMonitoringModeActive = true
        let attrs = GigiActivityAttributes(sessionID: UUID().uuidString)
        let state = GigiActivityAttributes.ContentState(phase: .sleeping, message: "Ready")
        let content = ActivityContent(state: state, staleDate: Date().addingTimeInterval(3600))
        do {
            monitoringActivity = try Activity.request(attributes: attrs, content: content, pushType: nil)
            lastPhase = .sleeping
        } catch {
            print("GIGI Live Activity: monitoring start failed — \(error)")
            isMonitoringModeActive = false
        }
    }

    /// End monitoring pill. Called only when user disables wake word — NOT on per-turn stops.
    @MainActor
    func stopWakeWordMonitoring() async {
        isMonitoringModeActive = false
        guard let act = monitoringActivity else { return }
        monitoringActivity = nil
        let cs = GigiActivityAttributes.ContentState(phase: .done, message: "")
        let content = ActivityContent(state: cs, staleDate: nil)
        await act.end(content, dismissalPolicy: .immediate)
    }

    // MARK: - Presence Mode session activity

    private var presenceActivity: Activity<GigiActivityAttributes>?

    @MainActor
    func startPresenceActivity(sessionId: String) async {
        guard enabled else { return }
        await endPresenceActivity()   // clean up any stale
        let attrs = GigiActivityAttributes(sessionID: sessionId)
        let state = GigiActivityAttributes.ContentState(
            phase: .sleeping, message: "Ready", lastTranscript: nil, sessionId: sessionId
        )
        let content = ActivityContent(state: state, staleDate: Date().addingTimeInterval(3600))
        do {
            presenceActivity = try Activity.request(attributes: attrs, content: content, pushType: nil)
        } catch {
            print("GIGI Live Activity: presence start failed — \(error)")
        }
    }

    @MainActor
    func updatePresence(state: GigiPhase, message: String, transcript: String? = nil) async {
        guard enabled, let act = presenceActivity else { return }
        let cs = GigiActivityAttributes.ContentState(
            phase: state, message: message,
            lastTranscript: transcript, sessionId: nil
        )
        let content = ActivityContent(state: cs, staleDate: Date().addingTimeInterval(3600))
        await act.update(content)
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
        lastPhase = phase
        let content = ActivityContent(state: GigiActivityAttributes.ContentState(phase: phase, message: message), staleDate: Date().addingTimeInterval(30))
        await activity.update(content)
    }
}
