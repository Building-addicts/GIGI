import ActivityKit
import Foundation

// MARK: - GigiActivityAttributes
//
// Struttura dati condivisa tra il main app target e il Widget Extension.
// Quando si aggiunge il Widget Extension (Task 3), questo file va aggiunto
// anche a quel target tramite File Inspector > Target Membership.
//
// Attributi statici: dati che non cambiano durante la Live Activity.
// ContentState: dati dinamici aggiornati da GigiSmartOrchestrator.

struct GigiActivityAttributes: ActivityAttributes {

    // Attributi statici (impostati all'avvio, non aggiornabili)
    let sessionID: String   // UUID della sessione, per debug

    // MARK: - ContentState (aggiornabile in tempo reale)

    struct ContentState: Codable, Hashable {
        var phase: GigiPhase
        var message: String     // "Chiamo Marco...", "Elaborazione...", "Fatto."
        var lastTranscript: String? = nil
        var sessionId: String? = nil
        var wakePulseId: String? = nil
    }
}

// MARK: - GigiPhase

/// Fasi del ciclo di vita di un'azione GIGI.
/// Guida le animazioni della Dynamic Island e della Lock Screen Live Activity.
enum GigiPhase: String, Codable, Hashable, CaseIterable {
    case listening   // Microfono attivo, in ascolto
    case thinking    // Pipeline NLU in elaborazione
    case executing   // Azione in esecuzione (chiamata, messaggio, ecc.)
    case done        // Completato — Live Activity si chiuderà dopo 3s
    // Presence Mode phases
    case sleeping    // Wake word attiva, nessuna attività
    case speaking    // TTS in riproduzione
    case followUp    // Finestra post-risposta: ascolto senza wake word
    case muted       // Sessione silenziata dall'utente
    case error       // Errore recuperabile

    var displayName: String {
        switch self {
        case .listening:  return "Listening…"
        case .thinking:   return "Thinking…"
        case .executing:  return "Working…"
        case .done:       return "Done"
        case .sleeping:   return "Ready"
        case .speaking:   return "Speaking…"
        case .followUp:   return "Follow-up"
        case .muted:      return "Muted"
        case .error:      return "Needs attention"
        }
    }

    var systemImage: String {
        switch self {
        case .listening:  return "waveform.circle.fill"
        case .thinking:   return "brain"
        case .executing:  return "bolt.fill"
        case .done:       return "checkmark.circle.fill"
        case .sleeping:   return "moon.circle.fill"
        case .speaking:   return "speaker.wave.2.fill"
        case .followUp:   return "arrow.turn.down.left.circle.fill"
        case .muted:      return "mic.slash.circle.fill"
        case .error:      return "exclamationmark.circle.fill"
        }
    }
}
