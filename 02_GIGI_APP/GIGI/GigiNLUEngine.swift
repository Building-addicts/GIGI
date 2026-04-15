import Foundation
import CoreML
import NaturalLanguage

// MARK: - GigiIntent
struct GigiIntent {
    let label: String
    let confidence: Double
    let params: [String: String]
}

// MARK: - GigiNLUEngine
// Usa MobileBERT (GigiNLU_Transformer) se disponibile,
// altrimenti fallback su GigiNLU (Maximum Entropy)
class GigiNLUEngine {
    static let shared = GigiNLUEngine()

    private var transformerModel: MLModel?
    private var fallbackClassifier: NLModel?
    private var labels: [String] = []
    private let maxLen = 64

    // Tokenizer MobileBERT (vocab WordPiece)
    private var vocab: [String: Int] = [:]

    private init() {
        loadTransformer()
        loadFallback()
        loadLabels()
    }

    // MARK: - Caricamento modelli

    private func loadTransformer() {
        // Prova a caricare GigiNLU_Transformer.mlpackage
        guard let url = Bundle.main.url(forResource: "GigiNLU_Transformer",
                                         withExtension: "mlpackage") ??
                        Bundle.main.url(forResource: "GigiNLU_Transformer",
                                         withExtension: "mlmodelc")
        else {
            print("GIGI NLU: Transformer non trovato — uso fallback.")
            return
        }
        do {
            let config = MLModelConfiguration()
            config.computeUnits = .all  // Neural Engine + GPU + CPU
            transformerModel = try MLModel(contentsOf: url, configuration: config)
            print("GIGI NLU: MobileBERT caricato ✓")
        } catch {
            print("GIGI NLU: Errore caricamento transformer — \(error)")
        }
    }

    private func loadFallback() {
        do {
            let config = MLModelConfiguration()
            let mlModel = try GigiNLU(configuration: config)
            fallbackClassifier = try NLModel(mlModel: mlModel.model)
            print("GIGI NLU: Fallback GigiNLU caricato ✓")
        } catch {
            print("GIGI NLU: Errore fallback — \(error)")
        }
    }

    private func loadLabels() {
        // Carica labels dal bundle (gigi_labels.json generato dallo script Python)
        if let url = Bundle.main.url(forResource: "gigi_labels", withExtension: "json"),
           let data = try? Data(contentsOf: url),
           let decoded = try? JSONDecoder().decode([String].self, from: data) {
            labels = decoded
            print("GIGI NLU: \(labels.count) labels caricate ✓")
            return
        }
        // Fallback labels hardcoded
        labels = [
            "ask_cloud", "create_event", "create_note", "find_nearby",
            "food_delivery", "make_call", "music_control", "navigation",
            "open_app", "open_settings", "open_settings_vpn",
            "phone_system", "play_music", "read_calendar", "read_email",
            "read_messages", "ride_share", "search_web", "send_email",
            "send_message", "set_alarm", "set_brightness_down",
            "set_brightness_up", "set_reminder", "set_timer",
            "social_media", "take_photo", "toggle_bluetooth",
            "toggle_do_not_disturb", "toggle_wifi", "torch_off",
            "torch_on", "weather"
        ]
    }

    // MARK: - Classificazione principale
    func classify(_ text: String) -> GigiIntent {
        let cleaned = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)

        // 1. Prova transformer MobileBERT
        if let result = classifyWithTransformer(cleaned) {
            print("GIGI NLU [BERT]: '\(cleaned)' → \(result.label) (\(Int(result.confidence * 100))%)")
            let params = extractParams(from: cleaned, intent: result.label)
            return GigiIntent(label: result.label, confidence: result.confidence, params: params)
        }

        // 2. Fallback GigiNLU Maximum Entropy
        if let result = classifyWithFallback(cleaned) {
            print("GIGI NLU [ME]: '\(cleaned)' → \(result.label) (\(Int(result.confidence * 100))%)")
            let params = extractParams(from: cleaned, intent: result.label)
            return GigiIntent(label: result.label, confidence: result.confidence, params: params)
        }

        // 3. Ultra-fallback: ask_cloud
        print("GIGI NLU: fallback ask_cloud")
        return GigiIntent(label: "ask_cloud", confidence: 0.5,
                          params: ["raw": cleaned])
    }

    // MARK: - MobileBERT inference
    private func classifyWithTransformer(_ text: String) -> (label: String, confidence: Double)? {
        guard let model = transformerModel else { return nil }

        let tokens = tokenize(text)
        guard tokens.count > 0 else { return nil }

        do {
            // Costruisci input tensors
            let inputIds   = try MLMultiArray(shape: [1, NSNumber(value: maxLen)], dataType: .int32)
            let attnMask   = try MLMultiArray(shape: [1, NSNumber(value: maxLen)], dataType: .int32)

            // CLS token = 101, SEP token = 102, PAD = 0
            inputIds[0] = 101
            for (i, tok) in tokens.prefix(maxLen - 2).enumerated() {
                inputIds[i + 1] = NSNumber(value: tok)
                attnMask[i + 1] = 1
            }
            let sepIdx = min(tokens.count + 1, maxLen - 1)
            inputIds[sepIdx] = 102
            attnMask[sepIdx] = 1
            // Attention mask per CLS
            attnMask[0] = 1

            let provider = try MLDictionaryFeatureProvider(dictionary: [
                "input_ids":      MLFeatureValue(multiArray: inputIds),
                "attention_mask": MLFeatureValue(multiArray: attnMask)
            ])

            let output   = try model.prediction(from: provider)
            guard let logits = output.featureValue(for: "logits")?.multiArrayValue else {
                return nil
            }

            // Softmax
            var scores = (0..<labels.count).map { Double(truncating: logits[$0]) }
            let maxScore = scores.max() ?? 0
            scores = scores.map { exp($0 - maxScore) }
            let sum = scores.reduce(0, +)
            scores = scores.map { $0 / sum }

            let bestIdx = scores.indices.max(by: { scores[$0] < scores[$1] }) ?? 0
            return (labels[bestIdx], scores[bestIdx])

        } catch {
            print("GIGI NLU transformer error: \(error)")
            return nil
        }
    }

    // MARK: - Maximum Entropy fallback
    private func classifyWithFallback(_ text: String) -> (label: String, confidence: Double)? {
        guard let clf = fallbackClassifier else { return nil }
        let label = clf.predictedLabel(for: text) ?? "ask_cloud"
        let confidence = clf.predictedLabelHypotheses(for: text, maximumCount: 3)[label] ?? 0.5
        return (label, confidence)
    }

    // MARK: - Tokenizer WordPiece semplificato
    // Per deployment completo usa il vocab file di MobileBERT
    private func tokenize(_ text: String) -> [Int] {
        // Tokenizzazione base: split su spazi, lookup nel vocab
        // Se il vocab non è caricato, usa hash stabile come approssimazione
        let words = text.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
        return words.compactMap { word -> Int? in
            if let id = vocab[word] { return id }
            // Fallback: hash deterministico nel range vocab MobileBERT (30522 tokens)
            var hash = 5381
            for char in word.unicodeScalars { hash = ((hash << 5) &+ hash) &+ Int(char.value) }
            return abs(hash) % 30522
        }
    }

    // MARK: - Estrazione parametri (invariata)
    private func extractParams(from text: String, intent: String) -> [String: String] {
        var params: [String: String] = ["raw": text]

        switch intent {
        case "send_message", "make_call", "send_email":
            if let name = extractName(from: text) { params["contact"] = name }
            if let body = extractBody(from: text)  { params["body"] = body }
            if let platform = extractPlatform(from: text) { params["platform"] = platform }

        case "read_email":
            if let index = extractEmailIndex(from: text) { params["index"] = String(index) }

        case "create_event", "set_alarm":
            if let time = extractTime(from: text) { params["time"] = time }
            if let date = extractDate(from: text)  { params["date"] = date }
            if let title = extractEventTitle(from: text) { params["title"] = title }

        case "set_timer":
            if let seconds = extractDuration(from: text) { params["seconds"] = String(seconds) }

        case "open_app", "social_media", "food_delivery", "ride_share":
            if let app = extractAppName(from: text) { params["app"] = app }

        case "navigation", "find_nearby":
            if let dest = extractDestination(from: text) { params["destination"] = dest }

        case "play_music", "play_specific_music":
            if let query = extractMusicQuery(from: text) { params["query"] = query }

        case "set_brightness_up", "set_brightness_down":
            if let level = extractPercentage(from: text) { params["level"] = String(level) }

        case "set_reminder":
            params["text"] = text

        default: break
        }
        return params
    }

    // MARK: - Estrattori

    private func extractName(from text: String) -> String? {
        let triggers = ["to ", "call ", "message ", "text ", "email ", "from ", "with "]
        for trigger in triggers {
            if let range = text.range(of: trigger) {
                var remainder = String(text[range.upperBound...])
                    .trimmingCharacters(in: .whitespaces)
                // Rimuovi "on whatsapp" ecc.
                for platform in ["on whatsapp","on telegram","on imessage","saying","that"] {
                    if let r = remainder.range(of: " " + platform) {
                        remainder = String(remainder[..<r.lowerBound])
                    }
                }
                let name = remainder.components(separatedBy: " ").prefix(2).joined(separator: " ")
                if !name.isEmpty && name.count > 1 { return name }
            }
        }
        return nil
    }

    private func extractBody(from text: String) -> String? {
        let triggers = ["saying ", "that says ", "tell him ", "tell her ", "with the message "]
        for t in triggers {
            if let range = text.range(of: t) {
                return String(text[range.upperBound...]).trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }

    private func extractPlatform(from text: String) -> String? {
        let platforms = ["whatsapp","telegram","imessage","signal","messenger","snapchat"]
        return platforms.first(where: { text.lowercased().contains($0) })
    }

    private func extractEmailIndex(from text: String) -> Int? {
        if text.contains("second to last") || text.contains("penultimate") { return -2 }
        if text.contains("third to last") { return -3 }
        if text.contains("last") || text.contains("latest") { return -1 }
        if text.contains("first") { return 1 }
        return nil
    }

    private func extractTime(from text: String) -> String? {
        let patterns = [
            "at\\s+(\\d{1,2}:\\d{2})\\s*(am|pm)?",
            "at\\s+(\\d{1,2})\\s*(am|pm)",
            "(\\d{1,2}:\\d{2})\\s*(am|pm)?",
            "(\\d{1,2})\\s*(am|pm)"
        ]
        for pattern in patterns {
            if let match = text.range(of: pattern, options: .regularExpression) {
                return String(text[match]).replacingOccurrences(of: "at ", with: "").trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }

    private func extractDate(from text: String) -> String? {
        if text.contains("tomorrow") { return "tomorrow" }
        if text.contains("today")    { return "today" }
        if text.contains("next week") { return "next_week" }
        for day in ["monday","tuesday","wednesday","thursday","friday","saturday","sunday"] {
            if text.contains(day) { return day }
        }
        return "today"
    }

    private func extractEventTitle(from text: String) -> String? {
        let kw = ["doctor","dentist","gym","lunch","dinner","meeting","interview",
                  "appointment","workout","flight","call","date","party"]
        return kw.first(where: { text.contains($0) })?.capitalized
    }

    private func extractDuration(from text: String) -> Int? {
        let patterns: [(String, Int)] = [("(\\d+)\\s*hour", 3600), ("(\\d+)\\s*minute", 60), ("(\\d+)\\s*second", 1)]
        for (pattern, multiplier) in patterns {
            if let match = text.range(of: pattern, options: .regularExpression) {
                let digits = String(text[match]).filter { $0.isNumber }
                if let n = Int(digits) { return n * multiplier }
            }
        }
        return nil
    }

    private func extractAppName(from text: String) -> String? {
        let apps = ["spotify","instagram","tiktok","twitter","youtube","netflix","whatsapp",
                    "telegram","uber","doordash","uber eats","gmail","slack","zoom","notion",
                    "discord","snapchat","facebook","reddit","pinterest","linkedin","facetime",
                    "chatgpt","claude","gemini","apple music","maps","google maps","waze"]
        let lower = text.lowercased()
        return apps.first(where: { lower.contains($0) })?.capitalized
    }

    private func extractDestination(from text: String) -> String? {
        let triggers = ["take me to ","navigate to ","directions to ","go to ","get me to ","drive to ","walk to "]
        for t in triggers {
            if let range = text.range(of: t) {
                return String(text[range.upperBound...]).trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }

    private func extractMusicQuery(from text: String) -> String? {
        let triggers = ["play ","put on ","listen to ","hear some "]
        for t in triggers {
            if let range = text.range(of: t) {
                let q = String(text[range.upperBound...]).trimmingCharacters(in: .whitespaces)
                if !q.isEmpty { return q }
            }
        }
        return nil
    }

    private func extractPercentage(from text: String) -> Double? {
        if let match = text.range(of: "(\\d+)%", options: .regularExpression) {
            let digits = String(text[match]).filter { $0.isNumber }
            if let v = Double(digits) { return v / 100.0 }
        }
        return nil
    }
}
