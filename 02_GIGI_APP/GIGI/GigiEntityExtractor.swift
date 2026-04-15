import Foundation
import NaturalLanguage

// MARK: - Entità estratte dalla frase
struct GigiEntities {
    var contacts:     [String]  = []  // "mom", "dentist", "John"
    var dates:        [String]  = []  // "tomorrow", "Friday", "next week"
    var times:        [String]  = []  // "8am", "15:00", "tonight"
    var apps:         [String]  = []  // "Spotify", "WhatsApp"
    var places:       [String]  = []  // "New York", "home", "office"
    var topics:       [String]  = []  // "dentist", "flight", "birthday"
    var actions:      [String]  = []  // "send", "call", "open", "remind"
    var numbers:      [String]  = []  // "8", "30", "3"
    var rawText:      String    = ""
    var sentiment:    String    = "neutral" // "urgent", "casual", "question"

    var isEmpty: Bool {
        contacts.isEmpty && dates.isEmpty && times.isEmpty &&
        apps.isEmpty && places.isEmpty && topics.isEmpty
    }
}

// MARK: - GigiEntityExtractor
class GigiEntityExtractor {
    static let shared = GigiEntityExtractor()

    private let tagger = NLTagger(tagSchemes: [
        .nameType,
        .lexicalClass,
        .language
    ])

    // MARK: - Estrazione principale
    func extract(from text: String) -> GigiEntities {
        var entities = GigiEntities()
        entities.rawText = text
        let lower = text.lowercased()

        // 1. NLTagger per entità nominate
        extractNamedEntities(from: text, into: &entities)

        // 2. Date e orari
        entities.dates  = extractDates(from: lower)
        entities.times  = extractTimes(from: lower)
        entities.numbers = extractNumbers(from: lower)

        // 3. App conosciute
        entities.apps = extractApps(from: lower)

        // 4. Luoghi
        entities.places = extractPlaces(from: lower)

        // 5. Topic/contesto
        entities.topics = extractTopics(from: lower)

        // 6. Azioni esplicite
        entities.actions = extractActions(from: lower)

        // 7. Sentiment/urgenza
        entities.sentiment = extractSentiment(from: lower)

        print("GIGI Entities: \(entities)")
        return entities
    }

    // MARK: - NLTagger named entities
    private func extractNamedEntities(from text: String, into entities: inout GigiEntities) {
        tagger.string = text
        let range = text.startIndex..<text.endIndex

        tagger.enumerateTags(
            in: range,
            unit: .word,
            scheme: .nameType,
            options: [.omitWhitespace, .omitPunctuation, .joinNames]
        ) { tag, tokenRange in
            let token = String(text[tokenRange])
            switch tag {
            case .personalName:
                entities.contacts.append(token)
            case .placeName:
                entities.places.append(token)
            case .organizationName:
                entities.topics.append(token)
            default:
                break
            }
            return true
        }
    }

    // MARK: - Date
    private func extractDates(from text: String) -> [String] {
        var dates: [String] = []

        let patterns: [(String, String)] = [
            ("tomorrow", "tomorrow"),
            ("today", "today"),
            ("tonight", "tonight"),
            ("next week", "next_week"),
            ("this weekend", "this_weekend"),
            ("next month", "next_month"),
            ("monday", "monday"), ("tuesday", "tuesday"),
            ("wednesday", "wednesday"), ("thursday", "thursday"),
            ("friday", "friday"), ("saturday", "saturday"),
            ("sunday", "sunday"),
            ("january|february|march|april|may|june|july|august|september|october|november|december", "month")
        ]

        for (pattern, label) in patterns {
            if text.range(of: pattern, options: .regularExpression) != nil {
                if !dates.contains(label) { dates.append(label) }
            }
        }

        // Date numeriche: "April 14", "14/04", "04-14"
        let datePatterns = [
            "\\d{1,2}/\\d{1,2}(?:/\\d{2,4})?",
            "\\d{1,2}-\\d{1,2}(?:-\\d{2,4})?",
            "(jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec)[a-z]* \\d{1,2}"
        ]
        for pattern in datePatterns {
            if let match = text.range(of: pattern, options: .regularExpression) {
                dates.append(String(text[match]))
            }
        }

        return dates
    }

    // MARK: - Orari
    private func extractTimes(from text: String) -> [String] {
        var times: [String] = []

        let patterns = [
            "\\d{1,2}:\\d{2}\\s*(?:am|pm)?",
            "\\d{1,2}\\s*(?:am|pm)",
            "\\d{1,2}\\s*o'?clock",
            "noon", "midnight", "morning", "afternoon",
            "evening", "tonight", "night"
        ]

        for pattern in patterns {
            if let match = text.range(of: pattern, options: .regularExpression) {
                let t = String(text[match]).trimmingCharacters(in: .whitespaces)
                if !times.contains(t) { times.append(t) }
            }
        }

        return times
    }

    // MARK: - Numeri
    private func extractNumbers(from text: String) -> [String] {
        var numbers: [String] = []
        let pattern = "\\b\\d+\\b"
        var searchRange = text.startIndex..<text.endIndex

        while let match = text.range(of: pattern, options: .regularExpression, range: searchRange) {
            numbers.append(String(text[match]))
            searchRange = match.upperBound..<text.endIndex
        }

        // Numeri scritti
        let written: [String: String] = [
            "one":"1","two":"2","three":"3","four":"4","five":"5",
            "six":"6","seven":"7","eight":"8","nine":"9","ten":"10",
            "fifteen":"15","twenty":"20","thirty":"30","sixty":"60"
        ]
        for (word, num) in written {
            if text.contains(word) && !numbers.contains(num) {
                numbers.append(num)
            }
        }

        return numbers
    }

    // MARK: - App
    private func extractApps(from text: String) -> [String] {
        let knownApps = [
            "spotify","instagram","whatsapp","telegram","youtube",
            "netflix","tiktok","twitter","uber","doordash","gmail",
            "slack","zoom","maps","waze","facetime","discord",
            "snapchat","linkedin","reddit","notion","chatgpt",
            "claude","gemini","signal","messenger","apple music",
            "music","podcasts","news","health","fitness"
        ]
        return knownApps.filter { text.contains($0) }.map { $0.capitalized }
    }

    // MARK: - Luoghi
    private func extractPlaces(from text: String) -> [String] {
        var places: [String] = []

        let knownPlaces = [
            "home","office","work","school","gym","hospital",
            "airport","station","downtown","uptown","mall",
            "restaurant","cafe","bar","park","beach","hotel"
        ]

        for place in knownPlaces {
            if text.contains(place) { places.append(place) }
        }

        return places
    }

    // MARK: - Topic/Contesto
    private func extractTopics(from text: String) -> [String] {
        var topics: [String] = []

        let topicMap: [String: [String]] = [
            "medical":    ["dentist","doctor","appointment","checkup","hospital","medicine","pill","medication"],
            "travel":     ["flight","plane","trip","vacation","travel","hotel","booking","airport"],
            "fitness":    ["gym","workout","exercise","run","training","yoga","swim"],
            "food":       ["lunch","dinner","breakfast","restaurant","eat","food","coffee","drink"],
            "work":       ["meeting","presentation","deadline","boss","colleague","project","call","conference"],
            "family":     ["birthday","anniversary","party","wedding","graduation","holiday"],
            "finance":    ["payment","bill","rent","salary","bank","money","transfer"],
            "music":      ["song","playlist","album","artist","concert","listen","music"],
            "shopping":   ["buy","order","delivery","package","store","shop"]
        ]

        for (topic, keywords) in topicMap {
            if keywords.contains(where: { text.contains($0) }) {
                topics.append(topic)
            }
        }

        return topics
    }

    // MARK: - Azioni esplicite
    private func extractActions(from text: String) -> [String] {
        let actionWords = [
            "send","call","open","play","remind","schedule","add",
            "create","set","turn","enable","disable","find","search",
            "navigate","order","book","cancel","delete","check",
            "read","write","message","text","email","buy","pay"
        ]
        return actionWords.filter { text.contains($0) }
    }

    // MARK: - Sentiment
    private func extractSentiment(from text: String) -> String {
        let urgentWords = ["urgent","asap","now","immediately","quick","fast","emergency","right now","hurry"]
        let questionWords = ["what","who","where","when","why","how","which","can you","do you","is it"]
        let casualWords = ["hey","yo","sup","chill","whatever","maybe","kinda"]

        if urgentWords.contains(where: { text.contains($0) }) { return "urgent" }
        if questionWords.contains(where: { text.contains($0) }) { return "question" }
        if casualWords.contains(where: { text.contains($0) }) { return "casual" }
        return "neutral"
    }
}
