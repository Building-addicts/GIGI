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

// MARK: - Sources (sub #58)
//
// Protocollo + Live impl per disaccoppiare l'engine da #13 (Preferences) e
// #14 (Task Extraction): la sub 3/4 può mergiare anche prima che quelle epic
// chiudano. Live impl legge da UserDefaults come fallback "leggero" in attesa
// del wiring real-source via TODO.

protocol DayPlanPreferenceSource {
    func currentPreferences() -> [String]
}

protocol DayPlanTaskSource {
    func currentSessionTasks() -> [String]
}

struct LivePreferenceSource: DayPlanPreferenceSource {
    static let userDefaultsKey = "mvp.preferences.array"

    func currentPreferences() -> [String] {
        // TODO(#13): sostituire con `await GigiUserProfile.shared.loadMVPPreferences()`
        // serializzata a frasi quando il parent #13 mergia. Per ora UserDefaults
        // come seed leggero non-async (il source è chiamato da contesti sync).
        return UserDefaults.standard.stringArray(forKey: Self.userDefaultsKey) ?? []
    }
}

struct LiveTaskSource: DayPlanTaskSource {
    static let userDefaultsKey = "mvp.tasks.array"

    func currentSessionTasks() -> [String] {
        // TODO(#14): sostituire con `GigiConversationMemory.recentExtractedTasks()`
        // quando il parent #14 mergia il task store della session corrente.
        return UserDefaults.standard.stringArray(forKey: Self.userDefaultsKey) ?? []
    }
}

@MainActor
final class GigiDayPlanReasoner {
    static let shared = GigiDayPlanReasoner()
    private init() {}

    // MARK: - Public entry point (sub #57: real calendar)

    /// Compone un piano per OGGI usando il calendario utente reale via tool
    /// `read_week_calendar` (preferito) o `read_calendar` (fallback). Il
    /// caller passa pref + task espliciti.
    func reasonForToday(preferences: [String], tasks: [String]) async -> DayPlanOutput? {
        let events = await loadCalendarEvents()
        let nowISO = ISO8601DateFormatter().string(from: Date())
        let input = DayPlanInput(events: events, preferences: preferences, tasks: tasks, nowISO: nowISO)
        return await reason(input: input)
    }

    /// Sub #58 (3/4): variant che usa Live sources per pref + task. Equivalente
    /// a `reasonForToday(preferences: live.prefs, tasks: live.tasks)` — chiave
    /// per il path runtime una volta che la sub 4/4 (#59) registrerà il tool.
    func reasonForTodayLive(
        preferenceSource: DayPlanPreferenceSource = LivePreferenceSource(),
        taskSource: DayPlanTaskSource = LiveTaskSource()
    ) async -> DayPlanOutput? {
        let prefs = preferenceSource.currentPreferences()
        let tasks = taskSource.currentSessionTasks()
        return await reasonForToday(preferences: prefs, tasks: tasks)
    }

    private func loadCalendarEvents() async -> [String] {
        // 1. Prova read_week_calendar (output già compatto sul payload del tool)
        let weekResult = await ReadWeekCalendarTool().execute(args: [:])
        if weekResult.error == nil, !weekResult.value.isEmpty {
            let normalized = Self.normalizeCalendarLines(weekResult.value)
            GigiDebugLogger.log("DayPlanReasoner: loaded \(normalized.count) events via read_week_calendar")
            return normalized
        }
        // 2. Fallback su read_calendar (solo oggi)
        let dayResult = await ReadCalendarTool().execute(args: [:])
        if dayResult.error == nil, !dayResult.value.isEmpty {
            let normalized = Self.normalizeCalendarLines(dayResult.value)
            GigiDebugLogger.log("DayPlanReasoner: loaded \(normalized.count) events via read_calendar (fallback)")
            return normalized
        }
        let firstErr = weekResult.error ?? dayResult.error ?? "empty"
        GigiDebugLogger.log("DayPlanReasoner: no calendar events (week err=\(firstErr))")
        return []
    }

    /// Normalizza il payload testuale dei tool calendar in righe singole.
    /// Max 12 eventi per non far esplodere il prompt; tronca >80 char.
    static func normalizeCalendarLines(_ raw: String) -> [String] {
        let lines = raw
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .map { line -> String in
                if line.count > 80 {
                    return String(line.prefix(77)) + "..."
                }
                return line
            }
        return Array(lines.prefix(12))
    }

    // MARK: - Engine (sub #56)

    func reason(input: DayPlanInput) async -> DayPlanOutput? {
        let prompt = Self.buildSystemPrompt(input: input)
        let t0 = Date()

        do {
            // Usa il default `agentModel` di GigiCloudService (llama-3.3-70b-versatile).
            let resp = try await GigiCloudService.shared.callWithFunctions(
                systemInstruction: prompt,
                contents: [.user("Proponi un piano per oggi.")],
                tools: []
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
        - Cita TUTTI gli eventi della sezione <events> con il loro ORARIO (riprendi orario e titolo letterali — sono impegni reali, non opzionali).
        - Cita esplicitamente almeno 2 preferenze utente e almeno 1 task quando disponibili (riprendi le parole esatte usate negli input).
        - Se mancano dati in una sezione, proponi comunque un piano onesto basato su ciò che c'è.

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

    /// Sub #58: seed UserDefaults con pref + task demo, poi invoca
    /// reasonForTodayLive(). Valida AC2-AC5.
    @discardableResult
    static func debugRunWithLiveSources() async -> DayPlanOutput? {
        UserDefaults.standard.set(
            ["Preferisce deep-work la mattina", "Pranzo veloce alle 13"],
            forKey: LivePreferenceSource.userDefaultsKey
        )
        UserDefaults.standard.set(
            ["Finire pitch deck"],
            forKey: LiveTaskSource.userDefaultsKey
        )
        let output = await GigiDayPlanReasoner.shared.reasonForTodayLive()
        if let o = output {
            GigiDebugLogger.log("DayPlanReasoner live: latency=\(o.latencyMs)ms · citedPrefs=\(o.citedPreferences.count) · citedTasks=\(o.citedTasks.count)")
            GigiDebugLogger.log("DayPlanReasoner live spokenText: \(o.spokenText)")
        } else {
            GigiDebugLogger.log("DayPlanReasoner live: nil output (LLM empty/error)")
        }
        return output
    }

    /// Sub #57: piano basato sul calendario REALE dell'utente. Permission
    /// gate è gestito dal tool sottostante; se denied o vuoto, events=[]
    /// e il prompt fa il best-effort senza eventi.
    @discardableResult
    static func debugRunWithRealCalendar() async -> DayPlanOutput? {
        let output = await GigiDayPlanReasoner.shared.reasonForToday(
            preferences: [
                "Preferisce deep-work la mattina",
                "Buffer di 20 minuti tra spostamenti",
                "Pausa pranzo alle 13:00"
            ],
            tasks: [
                "Finire il pitch deck",
                "Rispondere a email cliente"
            ]
        )
        if let o = output {
            GigiDebugLogger.log("DayPlanReasoner real-cal: latency=\(o.latencyMs)ms · citedPrefs=\(o.citedPreferences.count) · citedTasks=\(o.citedTasks.count)")
            GigiDebugLogger.log("DayPlanReasoner real-cal spokenText: \(o.spokenText)")
        } else {
            GigiDebugLogger.log("DayPlanReasoner real-cal: nil output (LLM empty/error or no calendar permission)")
        }
        return output
    }
}
#endif
