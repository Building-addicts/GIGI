import Foundation

// MARK: - GigiPlannerEngine
//
// Single fast Groq call (llama-3.1-8b-instant, ~200ms) that decides:
//   isSimple=true  → one native iOS action, go straight to AgentEngine react loop
//   isSimple=false → 2+ coordinated tasks, decompose and hand to GigiOrchestrationEngine
//
// Falls back to isSimple=true on any failure — the existing react loop is the safe default.

enum TaskDomain: String {
    case ios        = "ios"
    case browser    = "browser"
    case research   = "research"
    case calendar   = "calendar"
    case messaging  = "messaging"
    case unknown    = "unknown"

    init(raw: String) {
        self = TaskDomain(rawValue: raw.lowercased()) ?? .unknown
    }
}

struct SubTask {
    let id: String
    let domain: TaskDomain
    let description: String
    let dependsOn: [String]
    let schema: String?
}

struct TaskPlan {
    let isSimple: Bool
    let tasks: [SubTask]
}

@MainActor
final class GigiPlannerEngine {
    static let shared = GigiPlannerEngine()
    private init() {}

    private let plannerSystemPrompt = """
        You are a task decomposer for GIGI, an autonomous iPhone assistant.
        Given a user request, output a JSON task plan.

        RULE 1 — Output {"isSimple":true,"tasks":[]} if the request is:
        • A single native iOS action: call, text/message, navigate, play music, set alarm/timer/reminder, open app, HomeKit, torch, FaceTime, media controls, weather, tell time/date.
        • Simple calendar read (read_calendar, check schedule).
        • Casual conversation, trivia, definitions.
        • Order food / book restaurant / web search (these use native iOS tools, no harness needed).

        RULE 2 — ONLY output a task plan if the request requires ALL of:
        • Live web data that cannot be found via a basic web search (stock quotes, flight prices), OR
        • Multi-site automation with login + form fill + payment, OR
        • Two or more COORDINATED actions where step 2 depends on step 1's output.
        • Simple "order from X" or "book a table at Y" requests → isSimple=true (native web tools).

        DOMAINS:
        • ios        — native iPhone actions (call, message, alarm, HomeKit, calendar create, etc.)
        • browser    — web forms, booking, checkout, login flows
        • research   — web search + data extraction, price comparison, live info
        • calendar   — schedule analysis, conflict detection, free-slot finding
        • messaging  — drafting messages/emails/notifications

        dependsOn: array of task ids that must complete first. Empty = runs in parallel.
        schema: optional JSON schema string if downstream tasks need structured output.

        OUTPUT JSON ONLY. No explanation. Examples:

        "Book the cheapest flight to NYC next Tuesday and add it to my calendar"
        {"isSimple":false,"tasks":[
          {"id":"t1","domain":"research","description":"Find cheapest flight to NYC next Tuesday. Return JSON: {price, airline, departure, arrival, link}","dependsOn":[],"schema":"{price:string,airline:string,departure:string,arrival:string,link:string}"},
          {"id":"t2","domain":"ios","description":"Create calendar event: flight to NYC, use departure time from t1","dependsOn":["t1"],"schema":null}
        ]}

        "Remind me to call John after my last meeting today"
        {"isSimple":false,"tasks":[
          {"id":"t1","domain":"calendar","description":"Find the end time of the last meeting today","dependsOn":[],"schema":"{end_time:string}"},
          {"id":"t2","domain":"ios","description":"Set reminder: call John, at end_time from t1","dependsOn":["t1"],"schema":null}
        ]}

        "Call mom"
        {"isSimple":true,"tasks":[]}

        "Order sushi from Yang"
        {"isSimple":true,"tasks":[]}
        """

    func decompose(userText: String) async -> TaskPlan {
        guard !userText.isEmpty else { return .simple }

        // Use fast 8b model — planner only needs to classify, not reason deeply
        guard let response = try? await GigiCloudService.shared.callWithFunctions(
            systemInstruction: plannerSystemPrompt,
            contents: [GigiContent.user(userText)],
            tools: [],
            model: "llama-3.1-8b-instant"
        ), let text = response.text else {
            GigiDebugLogger.log("GigiPlannerEngine: no response — fallback to simple")
            return .simple
        }

        guard let start = text.firstIndex(of: "{"),
              let end   = text.lastIndex(of: "}") else { return .simple }
        let jsonStr = String(text[start...end])
        guard let data = jsonStr.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .simple
        }

        let isSimple = json["isSimple"] as? Bool ?? true
        if isSimple { return .simple }

        let rawTasks = json["tasks"] as? [[String: Any]] ?? []
        if rawTasks.isEmpty { return .simple }

        let tasks: [SubTask] = rawTasks.compactMap { t in
            guard let id   = t["id"]     as? String, !id.isEmpty,
                  let dom  = t["domain"] as? String,
                  let desc = t["description"] as? String, !desc.isEmpty
            else { return nil }
            return SubTask(
                id:         id,
                domain:     TaskDomain(raw: dom),
                description: desc,
                dependsOn:  t["dependsOn"] as? [String] ?? [],
                schema:     t["schema"] as? String
            )
        }

        if tasks.isEmpty { return .simple }
        GigiDebugLogger.log("GigiPlannerEngine: \(tasks.count) tasks — \(tasks.map { "\($0.id):\($0.domain.rawValue)" }.joined(separator: ", "))")
        return TaskPlan(isSimple: false, tasks: tasks)
    }
}

extension TaskPlan {
    static let simple = TaskPlan(isSimple: true, tasks: [])
}
