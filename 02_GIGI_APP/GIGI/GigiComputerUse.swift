import Foundation

// MARK: - GigiComputerUse
//
// Client iOS → backend harness /api/ios/computer-use (Claude Opus 4.7 + Playwright).
// Loop polling: start → attende status=done|awaiting_confirm|failed|cancelled.
// Timeout polling: 3 minuti. Se awaiting_confirm arriva, il caller deve
// chiamare `confirm(jobId:approved:)` per sbloccare il loop server-side.

@MainActor
final class GigiComputerUse {
    static let shared = GigiComputerUse()
    private init() {}

    /// Avvia un task computer-use e attende il completamento (o confirm_required).
    /// Ritorna: "result string", oppure "CONFIRM_REQUIRED: <reason>" quando il loop
    /// backend si ferma per approvazione, oppure "ERROR: <reason>".
    func execute(task: String) async -> String {
        guard GigiHarnessClient.shared.isConfigured else {
            return "ERROR: Harness non configurato (Impostazioni → Harness)"
        }
        switch await GigiHarnessClient.shared.computerUseStart(task: task) {
        case .failure(let e): return "ERROR: \(e)"
        case .success(let jobId):
            return await poll(jobId: jobId, timeoutSec: 180)
        }
    }

    /// Conferma o rifiuta un job awaiting_confirm. Ritorna true se accettato dal server.
    func confirm(jobId: String, approved: Bool) async -> Bool {
        switch await GigiHarnessClient.shared.computerUseConfirm(jobId: jobId, approved: approved) {
        case .success(let b): return b == approved
        case .failure: return false
        }
    }

    /// Conferma un job già in `awaiting_confirm` e continua a fare polling
    /// sullo stesso job backend. Non rilancia il task da zero.
    func approveAndWait(jobId: String) async -> String {
        let ok = await confirm(jobId: jobId, approved: true)
        guard ok else { return "ERROR: conferma non accettata dal backend" }
        return await poll(jobId: jobId, timeoutSec: 180)
    }

    /// Rifiuta un job in attesa, così il backend non resta bloccato.
    func reject(jobId: String) async {
        _ = await confirm(jobId: jobId, approved: false)
    }

    /// Poll status fino a stato terminale o confirm.
    private func poll(jobId: String, timeoutSec: Int) async -> String {
        let deadline = Date().addingTimeInterval(TimeInterval(timeoutSec))
        var intervalMs: UInt64 = 800
        while Date() < deadline {
            try? await Task.sleep(nanoseconds: intervalMs * 1_000_000)
            intervalMs = min(intervalMs + 200, 2_500)
            switch await GigiHarnessClient.shared.computerUseStatus(jobId: jobId) {
            case .failure(let e): return "ERROR: polling \(e)"
            case .success(let job):
                switch job.status {
                case "done":
                    return job.result ?? "(nessun output)"
                case "failed":
                    return "ERROR: \(job.error ?? "sconosciuto")"
                case "cancelled":
                    return "ERROR: cancellato"
                case "awaiting_confirm":
                    let reason = job.confirm_required?.reason ?? "conferma richiesta"
                    return "CONFIRM_REQUIRED:\(jobId):\(reason)"
                default:
                    break // pending / running → continua polling
                }
            }
        }
        return "ERROR: timeout \(timeoutSec)s"
    }
}
