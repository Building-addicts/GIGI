import AVFoundation
import Accelerate
import Foundation

// MARK: - GigiToolCall
//
// Tool / function call ricevuto dal modello Live (Gemini) prima dell’esecuzione su device.

struct GigiToolCall: Sendable {
    let name: String
    let args: [String: String]
    let callId: String
}

// MARK: - GigiRealtimeEngine
//
// WebSocket verso Gemini Live API (`BidiGenerateContent`).
// Architettura: `ARCHITETTURA.md` — Real-Time AI Engine.
// Task plan: T-01 WebSocket; T-02 AVAudioEngine + PCM 16 kHz + chunk 100 ms + VAD send gate.

final class GigiRealtimeEngine: @unchecked Sendable {

    static let shared = GigiRealtimeEngine()

    /// Trascrizione / testo in uscita dal modello.
    var onTranscript: ((String) -> Void)?

    /// Function calling strutturato → orchestrator.
    var onToolCall: ((GigiToolCall) -> Void)?

    /// Audio TTS dal modello (PCM o container — dipende dalla risposta server).
    var onAudioOut: ((Data) -> Void)?

    /// Fired when server signals barge-in (user spoke while model was talking).
    var onBargein: (() -> Void)?

    /// Dopo silenzio VAD in modalità streaming: testo accumulato da `onTranscript` → pipeline (come STT finale).
    var onStreamingUtteranceComplete: ((String) -> Void)?

    // Jitter-buffered audio player for server TTS output
    private let audioPlayer = RealtimeAudioPlayer()

    private let queue = DispatchQueue(label: "com.gigi.realtime.ws", qos: .userInitiated)

    private var urlSession: URLSession?
    private var webSocket: URLSessionWebSocketTask?
    private var isReceiveLoopRunning = false

    private var reconnectAttemptCount = 0
    private let maxReconnectAttempts = 3
    private let backoffSeconds: [TimeInterval] = [1, 2, 4]

    // NSLock instead of queue.sync — DispatchQueue.sync from Swift Concurrency context
    // triggers "unsafeForcedSync" warnings and can cause thread starvation.
    private let stateLock = NSLock()
    private var isConnectedFlag = false

    // Auto-disconnect after 30s of no activity (saves battery)
    private var idleDisconnectWorkItem: DispatchWorkItem?
    private let idleDisconnectSeconds: TimeInterval = 30

    var isConnected: Bool {
        stateLock.withLock { isConnectedFlag }
    }

    // MARK: - T-02 Streaming mic

    private var streamingEngine: AVAudioEngine?
    private var streamingConverter: AVAudioConverter?
    private var isStreamingMic = false
    private let streamingStateLock = NSLock()
    private var pcmAccum = Data()
    private var vadSilenceSeconds: TimeInterval = 0
    private var vadAllowsSend = true
    private var streamingTranscriptAccum = ""
    private var lastFinalizeUtteranceWorkItem: DispatchWorkItem?

    private let targetSampleRate: Double = 16_000
    private let chunkSeconds: TimeInterval = 0.1
    private var bytesPerChunk: Int { Int(targetSampleRate * chunkSeconds) * 2 } // mono int16

    private let vadSilenceThresholdDB: Float = -45
    private let vadRequiredSilenceSeconds: TimeInterval = 0.6

    // MARK: - T-04 Livello 0 — risposta testuale (Chat) con timeout

    private var pendingChatReplyContinuation: CheckedContinuation<String?, Never>?
    private var pendingChatReplyTimer: DispatchWorkItem?

    private init() {}

    // MARK: - Public API

    /// Apre il WebSocket, invia `setup` (system prompt + tool declarations), avvia receive loop.
    func connect() {
        queue.async { [weak self] in
            self?.connectLocked()
        }
    }

    func disconnect() {
        queue.async { [weak self] in
            self?.disconnectLocked(clearReconnect: true)
        }
    }

    /// Alternativa a `GigiVADEngine.startListening`: microfono → PCM 16 kHz → chunk ~100 ms → WebSocket (solo se `vadAllowsSend`).
    func startStreaming() {
        // Reconnect if idle timeout fired
        if !isConnected { connect() }
        queue.async { [weak self] in self?.resetIdleTimer() }
        DispatchQueue.main.async { [weak self] in
            self?.startStreamingOnMain()
        }
    }

    func stopStreaming() {
        DispatchQueue.main.async { [weak self] in
            self?.stopStreamingOnMain()
        }
    }

    /// Invia chunk PCM int16 mono 16 kHz (base64 in `realtime_input`).
    func sendAudioChunk(_ data: Data) {
        queue.async { [weak self] in
            self?.sendAudioChunkLocked(data)
        }
    }

    /// Invia testo utente come turno completo.
    func sendText(_ text: String) {
        queue.async { [weak self] in
            self?.sendTextClientContentLocked(text)
        }
    }

    /// Livello 0 orchestrator: invia testo al modello Live e attende la prima risposta testuale, oppure `nil` dopo timeout (fallback pipeline).
    func sendTextAwaitingReply(userText: String, timeoutSeconds: TimeInterval = 15) async -> String? {
        await withCheckedContinuation { continuation in
            queue.async { [weak self] in
                guard let self else {
                    continuation.resume(returning: nil)
                    return
                }
                guard self.isConnectedFlag else {
                    continuation.resume(returning: nil)
                    return
                }
                self.cancelPendingChatReplyLocked()
                self.pendingChatReplyContinuation = continuation

                let timerWork = DispatchWorkItem { [weak self] in
                    self?.queue.async {
                        self?.completePendingChatReplyLocked(result: nil)
                    }
                }
                self.pendingChatReplyTimer = timerWork
                self.queue.asyncAfter(deadline: .now() + timeoutSeconds, execute: timerWork)

                self.sendTextClientContentLocked(userText)
                self.resetIdleTimer()
            }
        }
    }

    // MARK: - Idle auto-disconnect (T-26)

    private func resetIdleTimer() {
        idleDisconnectWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            print("GIGI Realtime: idle \(Int(idleDisconnectSeconds))s — disconnecting to save battery")
            self.disconnectLocked(clearReconnect: true)
        }
        idleDisconnectWorkItem = work
        queue.asyncAfter(deadline: .now() + idleDisconnectSeconds, execute: work)
    }

    private func sendTextClientContentLocked(_ text: String) {
        let payload: [String: Any] = [
            "clientContent": [
                "turns": [
                    [
                        "role": "user",
                        "parts": [["text": text]],
                    ],
                ],
                "turnComplete": true,
            ],
        ]
        sendJSONDictionary(payload)
    }

    private func cancelPendingChatReplyLocked() {
        pendingChatReplyTimer?.cancel()
        pendingChatReplyTimer = nil
        if let cont = pendingChatReplyContinuation {
            pendingChatReplyContinuation = nil
            cont.resume(returning: nil)
        }
    }

    private func completePendingChatReplyLocked(result: String?) {
        pendingChatReplyTimer?.cancel()
        pendingChatReplyTimer = nil
        guard let cont = pendingChatReplyContinuation else { return }
        pendingChatReplyContinuation = nil
        cont.resume(returning: result)
    }

    private func handleTurnComplete() {
        queue.async { [weak self] in
            guard let self else { return }
            let text = self.streamingTranscriptAccum.trimmingCharacters(in: .whitespacesAndNewlines)
            self.streamingTranscriptAccum = ""
            
            if self.pendingChatReplyContinuation != nil {
                self.completePendingChatReplyLocked(result: text)
            } else if !text.isEmpty {
                print("GIGI Realtime: turnComplete → pipeline (\(text.prefix(80))…)")
                DispatchQueue.main.async {
                    self.onStreamingUtteranceComplete?(text)
                }
            }
        }
    }

    // MARK: - Connection (locked)

    private func connectLocked() {
        let apiKey = GigiConfig.geminiAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !apiKey.isEmpty, apiKey != "$(GEMINI_API_KEY)" else {
            print("GIGI Realtime: skip connect — GEMINI_API_KEY mancante")
            return
        }

        guard let url = Self.liveWebSocketURL(apiKey: apiKey) else {
            print("GIGI Realtime: URL WebSocket non valido")
            return
        }

        disconnectLocked(clearReconnect: false)

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 0
        let session = URLSession(configuration: config, delegate: nil, delegateQueue: nil)
        urlSession = session

        let task = session.webSocketTask(with: url)
        webSocket = task
        task.resume()

        sendSetupMessage()
        startReceiveLoop()

        isConnectedFlag = true
        reconnectAttemptCount = 0
        print("GIGI Realtime: connected")
    }

    private func disconnectLocked(clearReconnect: Bool) {
        cancelPendingChatReplyLocked()
        stopStreamingLocked()
        isReceiveLoopRunning = false
        webSocket?.cancel(with: .goingAway, reason: nil)
        webSocket = nil
        urlSession?.invalidateAndCancel()
        urlSession = nil
        isConnectedFlag = false
        if clearReconnect {
            reconnectAttemptCount = 0
        }
        print("GIGI Realtime: disconnected")
    }

    private func scheduleReconnectIfNeeded() {
        guard reconnectAttemptCount < maxReconnectAttempts else {
            print("GIGI Realtime: reconnect aborted (max \(maxReconnectAttempts) tentativi)")
            reconnectAttemptCount = 0
            return
        }

        let delay = backoffSeconds[min(reconnectAttemptCount, backoffSeconds.count - 1)]
        reconnectAttemptCount += 1
        print("GIGI Realtime: reconnect in \(delay)s (tentativo \(reconnectAttemptCount)/\(maxReconnectAttempts))")

        queue.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.connectLocked()
        }
    }

    // MARK: - WebSocket URL

    /// Endpoint Live API (v1alpha). Se Google aggiorna il path, aggiornare qui.
    private static func liveWebSocketURL(apiKey: String) -> URL? {
        var components = URLComponents()
        components.scheme = "wss"
        components.host = "generativelanguage.googleapis.com"
        components.path = "/ws/google.ai.generativelanguage.v1alpha.GenerativeService.BidiGenerateContent"
        components.queryItems = [
            URLQueryItem(name: "key", value: apiKey),
        ]
        let url = components.url
        
        return url
    }

    // MARK: - Setup message (T-03 tool declarations → GigiActionBridge)

    private func sendSetupMessage() {
        let modelName = "models/gemini-2.5-flash-native-audio-latest"

        let tools: [[String: Any]] = [
            [
                "functionDeclarations": Self.liveToolDeclarations(),
            ],
        ]

        let setup: [String: Any] = [
            "setup": [
                "model": modelName,
                "generation_config": [
                    "response_modalities": ["AUDIO"],
                ],
                "system_instruction": [
                    "parts": [
                        ["text": GigiFoundationAgent.systemPrompt],
                    ],
                ],
                "tools": tools,
                "output_audio_transcription": [String: Any]()
            ],
        ]

        sendJSONDictionary(setup)
    }

    /// Tool declarations aligned with `GigiActionBridge` / orchestrator intents.
    private static func liveToolDeclarations() -> [[String: Any]] {
        func decl(_ name: String, _ description: String, _ properties: [String: Any], required: [String] = []) -> [String: Any] {
            var params: [String: Any] = [
                "type": "object",
                "properties": properties,
            ]
            if !required.isEmpty {
                params["required"] = required
            }
            return [
                "name": name,
                "description": description,
                "parameters": params,
            ]
        }

        func propString(_ description: String) -> [String: Any] {
            ["type": "string", "description": description]
        }

        return [
            decl("make_call", "Call a contact by name or number.", ["contact": propString("Contact name or reference")], required: ["contact"]),
            decl("send_whatsapp", "Send a WhatsApp message.", [
                "contact": propString("Recipient name"),
                "message": propString("Message text"),
            ], required: ["contact", "message"]),
            decl("send_message", "Send an SMS or iMessage.", [
                "contact": propString("Recipient name"),
                "message": propString("Message text"),
                "platform": propString("imessage, sms, or telegram"),
            ], required: ["contact", "message"]),
            decl("navigate", "Open Maps navigation to an address or place.", ["destination": propString("Destination address or place name")], required: ["destination"]),
            decl("set_timer", "Set a countdown timer (e.g. 10 minutes).", ["duration": propString("Duration in natural language, e.g. '10 minutes'")], required: ["duration"]),
            decl("set_alarm", "Set an alarm clock.", [
                "time": propString("Time like 7:30 or 19:00"),
                "date": propString("Day: today, tomorrow, or weekday name"),
            ], required: ["time"]),
            decl("set_reminder", "Create a reminder.", ["text": propString("What to remember")], required: ["text"]),
            decl("play_music", "Play music.", [
                "query": propString("Artist, song, or genre"),
                "app": propString("Optional app: Spotify, Apple Music"),
            ], required: ["query"]),
            decl("open_app", "Open an installed app.", ["app": propString("App name")], required: ["app"]),
            decl("torch_on", "Turn on the flashlight.", [:], required: []),
            decl("torch_off", "Turn off the flashlight.", [:], required: []),
            decl("weather", "Get weather for a location.", ["location": propString("City or place; empty = current location")], required: []),
            decl("read_calendar", "Read today's calendar events aloud.", [:], required: []),
            decl("create_event", "Add an event to the calendar.", [
                "title": propString("Event title"),
                "date": propString("Date"),
                "time": propString("Time"),
            ], required: ["title"]),
            decl("web_action", "Generic web action (search, open site).", [
                "site": propString("Site or domain"),
                "action": propString("What to do"),
                "params": propString("Extra parameters"),
            ], required: []),
            decl("remember", "Save a fact to long-term memory.", [
                "key": propString("Short key or topic"),
                "value": propString("Value to remember"),
            ], required: ["key", "value"]),
            decl("recall", "Retrieve a fact from memory.", ["key": propString("Key or topic to look up")], required: ["key"]),
            decl("ask_time", "Reply with the current device time.", [:], required: []),
            decl("ask_date", "Reply with today's date.", [:], required: []),
            decl("homekit_on", "Turn on a HomeKit accessory (light, outlet, fan).", [
                "accessory": propString("Accessory name, e.g. 'living room light'"),
            ], required: []),
            decl("homekit_off", "Turn off a HomeKit accessory.", [
                "accessory": propString("Accessory name"),
            ], required: []),
            decl("homekit_dim", "Set brightness of a HomeKit light.", [
                "accessory": propString("Light name"),
                "brightness": propString("Percentage 0-100"),
            ], required: ["brightness"]),
            decl("homekit_temp", "Set HomeKit thermostat temperature.", [
                "temperature": propString("Temperature in degrees Celsius"),
            ], required: ["temperature"]),
            decl("homekit_lock", "Lock a HomeKit door lock.", [
                "accessory": propString("Lock or door name, optional"),
            ], required: []),
            decl("homekit_unlock", "Unlock a HomeKit door lock.", [
                "accessory": propString("Lock or door name"),
            ], required: []),
            decl("homekit_scene", "Activate a HomeKit or GIGI scene (goodnight, cinema, work, relax).", [
                "scene": propString("Scene name"),
            ], required: ["scene"]),
            decl("toggle_wifi", "Open Wi-Fi settings.", [:], required: []),
            decl("toggle_bluetooth", "Open Bluetooth settings.", [:], required: []),
            decl("read_week_calendar", "Read calendar events for the next 7 days.", [:], required: []),
            decl("find_free_slot", "Find the next free time slot in the calendar.", [
                "duration": propString("Duration in minutes (e.g. 60) or text (e.g. '1 hour')"),
                "preferred_time": propString("Preferred time: morning, afternoon, evening, or specific time"),
            ], required: []),
        ]
    }

    /// Invia la risposta tool al modello Live (dopo `executeRealtimeToolCall` sull’orchestrator).
    func deliverToolResponse(callId: String, toolName: String, result: String) {
        queue.async { [weak self] in
            self?.sendToolResponseLocked(callId: callId, toolName: toolName, result: result)
        }
    }

    private func sendToolResponseLocked(callId: String, toolName: String, result: String) {
        // Formato tipico Gemini Live / BidiGenerateContent (aggiustare se il server risponde con errore di schema).
        let payload: [String: Any] = [
            "toolResponse": [
                "functionResponses": [
                    [
                        "id": callId,
                        "name": toolName,
                        "response": [
                            "output": result,
                        ],
                    ],
                ],
            ],
        ]
        sendJSONDictionary(payload)
        print("GIGI Realtime: toolResponse → \(toolName) id=\(callId.prefix(8))…")
    }

    // MARK: - Send / receive

    private func sendJSONDictionary(_ dict: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: dict, options: []),
              let text = String(data: data, encoding: .utf8)
        else { return }

        webSocket?.send(.string(text)) { error in
            if let error {
                print("GIGI Realtime: send error — \(error.localizedDescription)")
            }
        }
    }

    private func startReceiveLoop() {
        guard let ws = webSocket else { return }
        if isReceiveLoopRunning { return }
        isReceiveLoopRunning = true

        func receiveNext() {
            ws.receive { [weak self] result in
                guard let self else { return }
                self.queue.async {
                    switch result {
                    case .success(let message):
                        self.handleIncoming(message)
                        if self.isReceiveLoopRunning, self.webSocket != nil {
                            receiveNext()
                        }
                    case .failure(let error):
                        print("GIGI Realtime: receive error — \(error.localizedDescription)")
                        self.disconnectLocked(clearReconnect: false)
                        self.scheduleReconnectIfNeeded()
                    }
                }
            }
        }

        receiveNext()
    }

    private func handleIncoming(_ message: URLSessionWebSocketTask.Message) {
        let text: String?
        switch message {
        case .string(let s):
            text = s
        case .data(let d):
            text = String(data: d, encoding: .utf8)
        @unknown default:
            text = nil
        }
        guard let text, let data = text.data(using: .utf8) else { return }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return
        }

        parseServerJSON(json, raw: text)
    }

    /// Estrae testo, tool call e audio inline dalla risposta Live (formato può variare tra revisioni API).
    private func parseServerJSON(_ json: [String: Any], raw: String) {
        let toolCalls = extractAllToolCalls(from: json)
        if !toolCalls.isEmpty {
            handleIncomingToolCalls(toolCalls)
        }

        if let transcript = extractTranscript(from: json), !transcript.isEmpty {
            streamingTranscriptAccum += transcript
            onTranscript?(transcript)
        }

        if let server = json["serverContent"] as? [String: Any] {
            if server["turnComplete"] as? Bool == true {
                handleTurnComplete()
            }
            // 2.4.3 — server signals user spoke while model was talking
            if server["interrupted"] as? Bool == true {
                handleBargein()
            }
        }

        if let audio = extractInlineAudio(from: json) {
            onAudioOut?(audio)   // external consumers (kept for compat)
            DispatchQueue.main.async { [weak self] in
                self?.audioPlayer.enqueue(audio)   // 2.4.4 jitter-buffered playback
            }
        }

        if json["error"] != nil {
            print("GIGI Realtime: server error payload — \(raw.prefix(500))")
        }
    }

    private func handleIncomingToolCalls(_ calls: [GigiToolCall]) {
        for c in calls {
            onToolCall?(c)
        }
        Task { @MainActor [weak self] in
            guard let self else { return }
            for call in calls {
                let result = await GigiSmartOrchestrator.shared.executeRealtimeToolCall(call)
                self.deliverToolResponse(callId: call.callId, toolName: call.name, result: result)
            }
        }
    }

    /// Raccoglie tutti i function call presenti nel payload (path multipli usati da Gemini Live).
    private func extractAllToolCalls(from json: [String: Any]) -> [GigiToolCall] {
        var byId: [String: GigiToolCall] = [:]

        func add(_ c: GigiToolCall?) {
            guard let c else { return }
            byId[c.callId] = c
        }

        add(extractToolCall(from: json))

        if let sc = json["serverContent"] as? [String: Any] {
            if let mt = sc["modelTurn"] as? [String: Any],
               let parts = mt["parts"] as? [[String: Any]] {
                for part in parts {
                    if let fc = part["functionCall"] as? [String: Any] {
                        add(parseFunctionCallDict(fc))
                    }
                    if let fcs = part["functionCalls"] as? [[String: Any]] {
                        for fc in fcs { add(parseFunctionCallDict(fc)) }
                    }
                    if let fc = part["function_call"] as? [String: Any] {
                        add(parseFunctionCallDict(fc))
                    }
                }
            }
            if let tc = sc["toolCall"] as? [String: Any] {
                add(parseToolCallDict(tc))
                if let fcs = tc["functionCalls"] as? [[String: Any]] {
                    for fc in fcs { add(parseFunctionCallDict(fc)) }
                }
            }
        }

        return Array(byId.values)
    }

    private func extractTranscript(from json: [String: Any]) -> String? {
        if let server = json["serverContent"] as? [String: Any] {
            if let outputTranscription = server["outputTranscription"] as? [String: Any],
               let text = outputTranscription["text"] as? String {
                return text
            }
            if let modelTurn = server["modelTurn"] as? [String: Any],
               let parts = modelTurn["parts"] as? [[String: Any]] {
                var chunks: [String] = []
                for part in parts {
                    if let t = part["text"] as? String, part["thought"] == nil { chunks.append(t) }
                }
                if !chunks.isEmpty { return chunks.joined() }
            }
        }
        if let text = json["text"] as? String { return text }
        return nil
    }

    private func extractToolCall(from json: [String: Any]) -> GigiToolCall? {
        if let server = json["serverContent"] as? [String: Any],
           let toolCall = server["toolCall"] as? [String: Any] {
            return parseToolCallDict(toolCall)
        }
        if let toolCalls = json["toolCalls"] as? [[String: Any]],
           let first = toolCalls.first {
            return parseToolCallDict(first)
        }
        if let fc = json["functionCall"] as? [String: Any] {
            return parseFunctionCallDict(fc)
        }
        return nil
    }

    private func parseToolCallDict(_ dict: [String: Any]) -> GigiToolCall? {
        let name = (dict["name"] as? String) ?? (dict["functionName"] as? String) ?? ""
        let id = (dict["id"] as? String) ?? (dict["callId"] as? String) ?? UUID().uuidString
        let args = extractArgs(from: dict)
        guard !name.isEmpty else { return nil }
        return GigiToolCall(name: name, args: args, callId: id)
    }

    private func parseFunctionCallDict(_ dict: [String: Any]) -> GigiToolCall? {
        let name = dict["name"] as? String ?? ""
        let id = dict["id"] as? String ?? dict["callId"] as? String ?? UUID().uuidString
        let args = extractArgs(from: dict)
        guard !name.isEmpty else { return nil }
        return GigiToolCall(name: name, args: args, callId: id)
    }

    private func extractArgs(from dict: [String: Any]) -> [String: String] {
        var args: [String: String] = [:]
        if let argsObj = dict["args"] as? [String: Any] {
            for (k, v) in argsObj { args[k] = "\(v)" }
        } else if let argsObj = dict["arguments"] as? [String: Any] {
            for (k, v) in argsObj { args[k] = "\(v)" }
        } else if let s = dict["args"] as? String, let d = s.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
            for (k, v) in obj { args[k] = "\(v)" }
        }
        return args
    }

    private func extractInlineAudio(from json: [String: Any]) -> Data? {
        guard let server = json["serverContent"] as? [String: Any],
              let modelTurn = server["modelTurn"] as? [String: Any],
              let parts = modelTurn["parts"] as? [[String: Any]] else {
            return nil
        }
        for part in parts {
            if let inline = part["inlineData"] as? [String: Any],
               let b64 = inline["data"] as? String,
               let data = Data(base64Encoded: b64) {
                return data
            }
        }
        return nil
    }

    // MARK: - T-02 Mic streaming / VAD / chunking

    private func stopStreamingLocked() {
        DispatchQueue.main.async { [weak self] in
            self?.stopStreamingOnMain()
        }
    }

    private func startStreamingOnMain() {
        guard isStreamingMic == false else { return }
        guard isConnectedFlag else {
            print("GIGI Realtime: startStreaming — socket non pronto")
            return
        }

        GigiAudioSequestrator.shared.seizeControl()

        let engine = AVAudioEngine()
        let input = engine.inputNode
        let inFormat = input.outputFormat(forBus: 0)
        
        guard inFormat.channelCount > 0 else {
            print("GIGI Realtime: errore — formato audio non valido (permesso microfono negato?)")
            GigiAudioSequestrator.shared.releaseControl()
            return
        }

        guard let outFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: targetSampleRate,
            channels: 1,
            interleaved: true
        ),
        let converter = AVAudioConverter(from: inFormat, to: outFormat) else {
            print("GIGI Realtime: impossibile creare AVAudioConverter 16 kHz int16")
            GigiAudioSequestrator.shared.releaseControl()
            return
        }

        streamingEngine = engine
        streamingConverter = converter
        pcmAccum.removeAll(keepingCapacity: true)
        vadSilenceSeconds = 0
        vadAllowsSend = true
        streamingTranscriptAccum = ""

        input.removeTap(onBus: 0)
        let bufferFrames: AVAudioFrameCount = 4096
        input.installTap(onBus: 0, bufferSize: bufferFrames, format: inFormat) { [weak self] buffer, _ in
            self?.handleStreamingTap(buffer: buffer)
        }

        do {
            engine.prepare()
            try engine.start()
            isStreamingMic = true
            print("GIGI Realtime: streaming mic avviato (16 kHz int16, chunk \(Int(chunkSeconds * 1000)) ms)")
        } catch {
            print("GIGI Realtime: AudioEngine start — \(error.localizedDescription)")
            input.removeTap(onBus: 0)
            streamingEngine = nil
            streamingConverter = nil
            GigiAudioSequestrator.shared.releaseControl()
        }
    }

    private func stopStreamingOnMain() {
        guard isStreamingMic else { return }
        isStreamingMic = false
        lastFinalizeUtteranceWorkItem?.cancel()
        lastFinalizeUtteranceWorkItem = nil

        streamingEngine?.inputNode.removeTap(onBus: 0)
        if streamingEngine?.isRunning == true {
            streamingEngine?.stop()
        }
        streamingEngine = nil
        streamingConverter = nil

        streamingStateLock.lock()
        pcmAccum.removeAll(keepingCapacity: false)
        vadSilenceSeconds = 0
        vadAllowsSend = true
        streamingTranscriptAccum = ""
        streamingStateLock.unlock()

        GigiAudioSequestrator.shared.releaseControl()
        print("GIGI Realtime: streaming mic fermato")
    }

    private func handleStreamingTap(buffer: AVAudioPCMBuffer) {
        streamingStateLock.lock()
        updateVADLocked(buffer: buffer)
        let allow = vadAllowsSend
        streamingStateLock.unlock()

        guard allow else { return }

        // 2.4.2 — use cached-converter downsample path
        guard let pcmData = downsample(buffer) else { return }

        streamingStateLock.lock()
        pcmAccum.append(pcmData)
        while pcmAccum.count >= bytesPerChunk {
            let chunk = pcmAccum.prefix(bytesPerChunk)
            pcmAccum.removeFirst(bytesPerChunk)
            streamingStateLock.unlock()
            sendAudioChunk(Data(chunk))
            streamingStateLock.lock()
        }
        streamingStateLock.unlock()
    }

    private func updateVADLocked(buffer: AVAudioPCMBuffer) {
        guard let ch = buffer.floatChannelData?[0] else { return }
        let n = Int(buffer.frameLength)
        let samples = Array(UnsafeBufferPointer(start: ch, count: n))

        var rms: Float = 0
        vDSP_rmsqv(samples, 1, &rms, vDSP_Length(n))
        let db = rms > 0 ? 20 * log10(rms) : -100

        let frameDur = Double(n) / buffer.format.sampleRate

        if db >= vadSilenceThresholdDB {
            vadSilenceSeconds = 0
            if !vadAllowsSend {
                vadAllowsSend = true
                print("GIGI Realtime VAD: voce — invio audio ripreso")
            }
            lastFinalizeUtteranceWorkItem?.cancel()
            lastFinalizeUtteranceWorkItem = nil
        } else {
            vadSilenceSeconds += frameDur
            if vadSilenceSeconds >= vadRequiredSilenceSeconds, vadAllowsSend {
                vadAllowsSend = false
                print("GIGI Realtime VAD: silenzio — invio audio sospeso")
                scheduleFinalizeUtterance()
            }
        }
    }

    private func scheduleFinalizeUtterance() {
        lastFinalizeUtteranceWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.finalizeStreamingUtterance()
        }
        lastFinalizeUtteranceWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: work)
    }

    private func finalizeStreamingUtterance() {
        queue.async { [weak self] in
            guard let self else { return }
            let text = self.streamingTranscriptAccum.trimmingCharacters(in: .whitespacesAndNewlines)
            self.streamingTranscriptAccum = ""
            self.vadSilenceSeconds = 0
            if !text.isEmpty {
                print("GIGI Realtime: utterance → pipeline (\(text.prefix(80))…)")
                self.onStreamingUtteranceComplete?(text)
            }
        }
    }

    // MARK: - 2.4.1 Downsampling (cached converter, rebuilt only on format change)

    /// PCM buffer → PCM Int16, 16 kHz, mono Data. Reuses `streamingConverter`; recreates on format change.
    private func downsample(_ buffer: AVAudioPCMBuffer) -> Data? {
        if streamingConverter == nil || streamingConverter?.inputFormat != buffer.format {
            guard let outFormat = AVAudioFormat(
                commonFormat: .pcmFormatInt16,
                sampleRate: targetSampleRate,
                channels: 1,
                interleaved: true
            ),
            let conv = AVAudioConverter(from: buffer.format, to: outFormat) else {
                return nil
            }
            streamingConverter = conv
            print("GIGI Realtime: downsample converter (re)built for format \(buffer.format.sampleRate) Hz")
        }
        guard let converter = streamingConverter else { return nil }
        return convertBufferToInt16PCM(buffer: buffer, converter: converter)
    }

    // MARK: - 2.4.3 Barge-in

    private func handleBargein() {
        // Reset VAD so the mic isn't suppressed while model audio stops (AEC-safe)
        streamingStateLock.lock()
        vadAllowsSend = true
        vadSilenceSeconds = 0
        streamingStateLock.unlock()

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.audioPlayer.stop()
            self.onBargein?()
        }
    }

    private func convertBufferToInt16PCM(buffer: AVAudioPCMBuffer, converter: AVAudioConverter) -> Data? {
        let ratio = targetSampleRate / buffer.format.sampleRate
        let outCapacity = AVAudioFrameCount(max(8, ceil(Double(buffer.frameLength) * ratio)))
        guard let outBuffer = AVAudioPCMBuffer(pcmFormat: converter.outputFormat, frameCapacity: outCapacity) else {
            return nil
        }

        var copyConsumed = false
        let inputBlock: AVAudioConverterInputBlock = { _, outStatus in
            if copyConsumed {
                outStatus.pointee = .noDataNow
                return nil
            }
            copyConsumed = true
            outStatus.pointee = .haveData
            return buffer
        }

        var err: NSError?
        converter.convert(to: outBuffer, error: &err, withInputFrom: inputBlock)
        if let err {
            print("GIGI Realtime: convert — \(err.localizedDescription)")
            return nil
        }

        let frames = Int(outBuffer.frameLength)
        guard frames > 0, let int16 = outBuffer.int16ChannelData?[0] else { return nil }
        return Data(bytes: int16, count: frames * MemoryLayout<Int16>.size)
    }

    private func sendAudioChunkLocked(_ data: Data) {
        guard isConnectedFlag, !data.isEmpty else { return }
        let b64 = data.base64EncodedString()
        let payload: [String: Any] = [
            "realtimeInput": [
                "mediaChunks": [
                    [
                        "mimeType": "audio/pcm;rate=16000",
                        "data": b64,
                    ],
                ],
            ],
        ]
        sendJSONDictionary(payload)
    }
}

// MARK: - RealtimeAudioPlayer (2.4.4 — jitter buffer + catch-up)
//
// Accepts raw PCM Int16 24 kHz mono Data from Gemini Live server,
// converts to Float32, accumulates until ≥80 ms (jitter target),
// then schedules on AVAudioPlayerNode.
// If backlog exceeds 200 ms, plays at 1.1× to catch up.
// Session management is left to GigiAudioSequestrator — no category changes here.

private final class RealtimeAudioPlayer {

    // Gemini Live default output: 24 kHz PCM Int16 mono
    private let serverSampleRate: Double = 24_000

    private lazy var playFormat: AVAudioFormat = {
        AVAudioFormat(commonFormat: .pcmFormatFloat32,
                      sampleRate: serverSampleRate,
                      channels: 1,
                      interleaved: false)!
    }()

    private let engine     = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    private let pitchNode  = AVAudioUnitTimePitch()

    private var jitterQueue:    [AVAudioPCMBuffer] = []
    private var jitterMs:       Double = 0
    private let jitterTargetMs: Double = 80
    private let catchupMs:      Double = 200

    private var engineRunning = false

    init() {
        engine.attach(playerNode)
        engine.attach(pitchNode)
        let fmt = playFormat
        engine.connect(playerNode, to: pitchNode,          format: fmt)
        engine.connect(pitchNode,  to: engine.mainMixerNode, format: fmt)
    }

    /// Call on main thread. Enqueue server audio; flush when jitter target reached.
    func enqueue(_ data: Data) {
        guard let buf = int16DataToFloat32Buffer(data) else { return }
        let durationMs = Double(buf.frameLength) / serverSampleRate * 1000
        jitterMs += durationMs
        jitterQueue.append(buf)

        // Catch-up: if backlog > 200 ms, play at 1.1× to drain
        pitchNode.rate = Float(jitterMs > catchupMs ? 1.1 : 1.0)

        if jitterMs >= jitterTargetMs {
            flush()
        }
    }

    /// Stop playback immediately (barge-in). Call on main thread.
    func stop() {
        playerNode.stop()
        jitterQueue.removeAll()
        jitterMs = 0
        pitchNode.rate = 1.0
        if engineRunning {
            engine.pause()
            engineRunning = false
        }
    }

    // MARK: - Private

    private func flush() {
        guard !jitterQueue.isEmpty else { return }

        if !engineRunning {
            do {
                try engine.start()
                engineRunning = true
            } catch {
                print("RealtimeAudioPlayer: engine start — \(error)")
                jitterQueue.removeAll(); jitterMs = 0
                return
            }
        }

        playerNode.play()
        for buf in jitterQueue {
            playerNode.scheduleBuffer(buf, completionHandler: nil)
        }
        jitterQueue.removeAll()
        jitterMs = 0
    }

    /// PCM Int16 Data → Float32 AVAudioPCMBuffer using vDSP (zero heap alloc per sample).
    private func int16DataToFloat32Buffer(_ data: Data) -> AVAudioPCMBuffer? {
        let frameCount = data.count / MemoryLayout<Int16>.size
        guard frameCount > 0,
              let buf = AVAudioPCMBuffer(pcmFormat: playFormat,
                                        frameCapacity: AVAudioFrameCount(frameCount)),
              let floatPtr = buf.floatChannelData?[0] else { return nil }
        buf.frameLength = AVAudioFrameCount(frameCount)

        data.withUnsafeBytes { raw in
            guard let int16Ptr = raw.bindMemory(to: Int16.self).baseAddress else { return }
            // vDSP_vflt16: Int16 → Float32 in one pass
            vDSP_vflt16(int16Ptr, 1, floatPtr, 1, vDSP_Length(frameCount))
            // Normalize to [-1, 1]
            var scale = 1.0 / Float(Int16.max)
            vDSP_vsmul(floatPtr, 1, &scale, floatPtr, 1, vDSP_Length(frameCount))
        }
        return buf
    }
}
