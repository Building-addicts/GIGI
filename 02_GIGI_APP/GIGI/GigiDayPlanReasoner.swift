import Foundation

// MARK: - GigiDayPlanReasoner
// Sub #56 (1/4 di parent #15). Engine isolato che, dato un input di eventi
// calendario, preferenze utente e task estratti, produce un piano giornata
// in italiano vocale-friendly via LLM call (Groq di default).
//
// SCOPO DIVERSO da `GigiPlannerEngine.swift` — quello è un task decomposer
// (spezza un goal in sotto-task), questo è un day planner (propone l'ordine
// con cui affrontare oggi). I due coesistono di proposito.
//
// In questa sub-issue: solo engine + tipi + system prompt + debug runner.
// Le sub 2/4 (#57) e 3/4 (#58) wireranno calendar + preferences reali; la
// sub 4/4 (#59) farà voice delivery + tool registration `propose_day_plan`.

struct DayPlanInput {
    let events: [String]        // formato: "10:00 - 11:00 Riunione team"
    let preferences: [String]   // formato: "Preferisce deep-work la mattina"
    let tasks: [String]         // task estratti dalla session corrente
    let nowISO: String          // contesto temporale (ISO8601)
}

struct DayPlanOutput {
    let spokenText: String           // testo vocale-friendly italiano
    let citedPreferences: [String]   // pref riconosciute nel testo (substring match)
    let citedTasks: [String]
    let latencyMs: Int
}

@MainActor
final class GigiDayPlanReasoner {
    static let shared = GigiDayPlanReasoner()
    private init() {}

    /// Modello Groq di default. Allineato a `GigiCloudService.agentModel`.
    private static let plannerModel = "openai/gpt-oss-120b"

    func reason(input: DayPlanInput) async -> DayPlanOutput? {
        let prompt = Self.buildSystemPrompt(input: input)
        let t0 = Date()

        do {
            let resp = try await GigiCloudService.shared.callWithFunctions(
                systemInstruction: prompt,
                contents: [.user("Proponi un piano per oggi.")],
                tools: [],
                model: Self.plannerModel
            )
            let elapsed = Int(Date().timeIntervalSince(t0) * 1000)
            guard let raw = resp.text, !raw.isEmpty else {
                GigiDebugLogger.log("DayPlanReasoner: LLM returned empty text after \(elapsed)ms")
                return nil
            }
            let cleaned = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            return DayPlanOutput(
                spokenText: cleaned,
                citedPreferences: Self.extractCitations(from: cleaned, candidates: input.preferences),
                citedTasks: Self.extractCitations(from: cleaned, candidates: input.tasks),
                latencyMs: elapsed
            )
        } catch {
            GigiDebugLogger.log("DayPlanReasoner: LLM error — \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: - System prompt

    private static func buildSystemPrompt(input: DayPlanInput) -> String {
        let events  = input.events.isEmpty      ? "(nessun evento in agenda)"   : input.events.joined(separator: "\n- ")
        let prefs   = input.preferences.isEmpty ? "(nessuna preferenza nota)"   : input.preferences.joined(separator: "\n- ")
        let tasks   = input.tasks.isEmpty       ? "(nessun task estratto)"      : input.tasks.joined(separator: "\n- ")

        return """
        Sei il day planner personale di GIGI. Aiuti l'utente a organizzare la giornata in modo conversazionale.

        REGOLE DI OUTPUT (obbligatorie):
        - Rispondi in ITALIANO, tono caldo e diretto, frasi brevi.
        - Massimo ~80 parole TOTALI.
        - NO JSON, NO bullet markdown (niente `-`, `*`, `1.`), NO emoji, NO heading.
        - È una risposta VOCALE: deve suonare naturale letta ad alta voce.
        - Cita esplicitamente almeno 2 preferenze utente e almeno 1 task quando disponibili (riprendi le parole esatte usate negli input).
        - Se mancano dati, proponi comunque un piano onesto basato su ciò che c'è.

        DATI:

        <events>
        - \(events)
        </events>

        <preferences>
        - \(prefs)
        </preferences>

        <tasks>
        - \(tasks)
        </tasks>

        <now>\(input.nowISO)</now>
        """
    }

    // MARK: - Citation matching

    /// Substring match case-insensitive: per ogni candidato, ritorna quelli
    /// che compaiono almeno parzialmente nel testo. Non perfetto (gli LLM
    /// possono parafrasare), ma sufficiente come segnale qualitativo.
    private static func extractCitations(from text: String, candidates: [String]) -> [String] {
        let lower = text.lowercased()
        return candidates.filter { candidate in
            // Per pref/task lunghi, basta che almeno una parola "significativa"
            // (>3 char) compaia nel testo.
            let words = candidate
                .lowercased()
                .components(separatedBy: .whitespacesAndNewlines)
                .filter { $0.count > 3 }
            guard !words.isEmpty else { return lower.contains(candidate.lowercased()) }
            return words.contains { lower.contains($0) }
        }
    }
}

// MARK: - Debug runner

#if DEBUG
extension GigiDayPlanReasoner {
    /// Esegue l'engine con dati mock per validare AC5 senza pipeline.
    /// Logga su `GigiDebugLogger` lo `spokenText` e le citazioni risultanti.
    @discardableResult
    static func debugRunWithMockData() async -> DayPlanOutput? {
        let input = DayPlanInput(
            events: [
                "09:00 - 10:00 Stand-up team",
                "11:30 - 12:00 Call con Marco",
                "16:00 - 17:00 Review metriche"
            ],
            preferences: [
                "Preferisce deep-work la mattina",
                "Buffer di 20 minuti tra spostamenti",
                "Pausa pranzo alle 13:00"
            ],
            tasks: [
                "Finire il pitch deck",
                "Rispondere a email cliente"
            ],
            nowISO: ISO8601DateFormatter().string(from: Date())
        )
        let output = await GigiDayPlanReasoner.shared.reason(input: input)
        if let o = output {
            GigiDebugLogger.log("DayPlanReasoner mock: latency=\(o.latencyMs)ms · citedPrefs=\(o.citedPreferences.count) · citedTasks=\(o.citedTasks.count)")
            GigiDebugLogger.log("DayPlanReasoner mock spokenText: \(o.spokenText)")
        } else {
            GigiDebugLogger.log("DayPlanReasoner mock: nil output (LLM empty or error)")
        }
        return output
    }
}
#endif
