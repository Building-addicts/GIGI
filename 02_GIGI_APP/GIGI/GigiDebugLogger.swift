import Foundation

class GigiDebugLogger {
    static func log(_ msg: String, location: String = #file) {
        print("DEBUG LOG: \(msg)")
        
        // Save to UserDefaults for crash recovery
        var logs = UserDefaults.standard.stringArray(forKey: "gigi_crash_logs") ?? []
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        logs.append("[\(formatter.string(from: Date()))] \(location): \(msg)")
        if logs.count > 50 { logs.removeFirst(logs.count - 50) }
        UserDefaults.standard.set(logs, forKey: "gigi_crash_logs")
        UserDefaults.standard.synchronize()
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
            // Optional remote ingest (off by default — avoids connection spam when no debug server is running)
            guard UserDefaults.standard.bool(forKey: "gigi_remote_debug_ingest") else { continue }
            let logDict: [String: Any] = [
                "sessionId": "9db571",
                "id": UUID().uuidString,
                "timestamp": Int(Date().timeIntervalSince1970 * 1000),
                "location": "CRASH_RECOVERY",
                "message": log,
                "data": [:],
                "runId": "run_crash",
                "hypothesisId": "CRASH_TRACE"
            ]
            if let data = try? JSONSerialization.data(withJSONObject: logDict),
               let reqUrl = URL(string: "http://192.168.1.45:7701/ingest/8f52b01a-d1d3-4394-8440-d47affbb3939") {
                var req = URLRequest(url: reqUrl)
                req.httpMethod = "POST"
                req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                req.setValue("9db571", forHTTPHeaderField: "X-Debug-Session-Id")
                req.httpBody = data
                _ = try? await URLSession.shared.data(for: req)
            }
        }
        print("---------------------------")
        UserDefaults.standard.removeObject(forKey: "gigi_crash_logs")
        UserDefaults.standard.synchronize()
    }
}
