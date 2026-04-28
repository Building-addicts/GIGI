import Foundation

class GigiDebugLogger {
    static let sessionId = UUID().uuidString.prefix(8).description

    /// HARDCODED debug ingest endpoint for STEP 1 crash investigation.
    /// Step 1 verified — disabled to silence Local Network -1009 floods that
    /// can starve the URLSession pool and starve the main actor on cold launch.
    /// Re-enable by setting a non-nil URL string.
    static let remoteIngestURL: String? = nil

    static func log(_ msg: String, location: String = #file, function: String = #function, line: Int = #line) {
        let file = (location as NSString).lastPathComponent
        let entry = "\(file):\(line) \(function) — \(msg)"
        print("DEBUG LOG: \(entry)")

        // Save to UserDefaults for crash recovery
        var logs = UserDefaults.standard.stringArray(forKey: "gigi_crash_logs") ?? []
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        logs.append("[\(formatter.string(from: Date()))] \(entry)")
        if logs.count > 200 { logs.removeFirst(logs.count - 200) }
        UserDefaults.standard.set(logs, forKey: "gigi_crash_logs")
        UserDefaults.standard.synchronize()

        // Fire-and-forget remote ingest (best effort, no blocking)
        sendRemote(message: entry, location: file, recovery: false)
    }

    static func voiceEvent(
        _ name: String,
        turnId: String? = nil,
        _ data: [String: String] = [:],
        location: String = #file,
        function: String = #function,
        line: Int = #line
    ) {
        var fields = data
        if let turnId { fields["turnId"] = turnId }
        let suffix = fields.isEmpty
            ? ""
            : " " + fields
                .sorted { $0.key < $1.key }
                .map { "\($0.key)=\($0.value)" }
                .joined(separator: " ")
        log("VOICE \(name)\(suffix)", location: location, function: function, line: line)
    }

    static func flushCrashLogs() async {
        let logs = UserDefaults.standard.stringArray(forKey: "gigi_crash_logs") ?? []
        guard !logs.isEmpty else { return }

        print("--- PREVIOUS CRASH LOGS ---")
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let fileURL = docs.appendingPathComponent("gigi_crash_logs.txt")
        try? logs.joined(separator: "\n").write(to: fileURL, atomically: true, encoding: .utf8)

        for log in logs {
            print(log)
            sendRemote(message: log, location: "CRASH_RECOVERY", recovery: true)
        }
        print("---------------------------")
        UserDefaults.standard.removeObject(forKey: "gigi_crash_logs")
        UserDefaults.standard.synchronize()
    }

    private static func sendRemote(message: String, location: String, recovery: Bool) {
        guard let urlStr = remoteIngestURL, !urlStr.isEmpty,
              let url = URL(string: urlStr) else { return }
        // Bearer comes from the harness Keychain entry written during pairing.
        // For pre-pair crash logs we send anyway with a placeholder bearer;
        // server can be configured to accept best-effort logs without strict
        // bearer match (see ios-auth.js options).
        let bearer = GigiKeychain.load(forKey: GigiKeychain.Key.harnessSecret) ?? "unpaired"

        let payload: [String: Any] = [
            "sessionId": sessionId,
            "timestamp": Int(Date().timeIntervalSince1970 * 1000),
            "location": location,
            "message": message,
            "runId": recovery ? "run_crash_recovery" : "run_live",
            "hypothesisId": recovery ? "CRASH_RECOVERY" : "LIVE_TRACE",
            "data": ["bundle": Bundle.main.bundleIdentifier ?? "unknown"]
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload) else { return }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        req.timeoutInterval = 1.5
        req.httpBody = data

        // Fire-and-forget
        let task = URLSession.shared.dataTask(with: req) { _, _, _ in }
        task.resume()
    }
}
