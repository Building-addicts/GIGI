import Foundation

// MARK: - GigiContactDisambiguationResolver
//
// Parses a user utterance (typed or transcribed) against the candidates of
// an active ContactDisambiguationState. Returns one of three outcomes:
//
//   .matched(candidate)  — confidently picked one
//   .cancelled           — user said cancel/annulla/stop/no
//   .unresolved          — couldn't decide; orchestrator re-prompts or aborts
//
// Matching strategies, in order:
//   1. Cancel intents (EN + IT)
//   2. Ordinal references ("the first", "il primo", "second one", "secondo", "1")
//   3. Name match (any word from candidate.name appears in utterance —
//      most discriminating, applied before phone digits because users tend
//      to say last names)
//   4. Phone digit match (3+ contiguous digits from one candidate's number)
//   5. Word-to-digit conversion ("three eight zero" → "380" → match)
//
// Designed identically for text input now and voice/STT input later — same
// resolve() signature works for both.

enum ContactDisambiguationResult {
    case matched(GigiSmartOrchestrator.ContactCandidate)
    case cancelled
    case unresolved
}

enum GigiContactDisambiguationResolver {

    // MARK: - Public API

    static func resolve(
        utterance: String,
        state: GigiSmartOrchestrator.ContactDisambiguationState
    ) -> ContactDisambiguationResult {
        let t = utterance
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !t.isEmpty else { return .unresolved }

        // 1. Cancel intents (multilingual)
        if isCancelIntent(t) { return .cancelled }

        // 2. Ordinal references — covers "primo/secondo/terzo", "first/second/third",
        //    bare digit "1"/"2"/"3", and "the X one" forms.
        if let idx = ordinalIndex(in: t), state.candidates.indices.contains(idx) {
            return .matched(state.candidates[idx])
        }

        // 3. Name-word match — score each candidate by how many ≥2-char tokens
        //    from its full name appear in the utterance. Ties → unresolved.
        let nameMatched = matchByName(utterance: t, candidates: state.candidates)
        if case .matched = nameMatched { return nameMatched }

        // 4. Phone digit match (literal digits in utterance)
        if let candidate = matchByPhoneDigits(utterance: t, candidates: state.candidates) {
            return .matched(candidate)
        }

        // 5. Word-to-digit (e.g. "three eight zero" → "380")
        let convertedDigits = wordsToDigits(t)
        if convertedDigits.count >= 3,
           let candidate = matchByDigitSubstring(digits: convertedDigits, candidates: state.candidates) {
            return .matched(candidate)
        }

        return .unresolved
    }

    // MARK: - 1. Cancel intent

    private static let cancelTokens: Set<String> = [
        // English
        "cancel", "cancelled", "stop", "no", "nevermind", "never mind",
        "nothing", "skip", "abort", "forget it", "go back",
        // Italian
        "annulla", "annullala", "ferma", "lascia stare", "lascia perdere",
        "niente", "nessuno", "indietro", "no grazie"
    ]

    private static func isCancelIntent(_ t: String) -> Bool {
        // Match exact, prefix-with-space, or wholly contained for multi-word forms.
        for token in cancelTokens {
            if t == token { return true }
            if t.hasPrefix(token + " ") { return true }
            if t.hasSuffix(" " + token) { return true }
            // For multi-word tokens (e.g. "never mind"), use contains
            if token.contains(" ") && t.contains(token) { return true }
        }
        return false
    }

    // MARK: - 2. Ordinal index (returns 0-based)

    private static let ordinalFirst: Set<String> = [
        // English
        "first", "the first", "first one", "1st", "1",
        // Italian
        "primo", "il primo", "la prima", "prima"
    ]
    private static let ordinalSecond: Set<String> = [
        "second", "the second", "second one", "2nd", "2",
        "secondo", "il secondo", "la seconda", "seconda"
    ]
    private static let ordinalThird: Set<String> = [
        "third", "the third", "third one", "3rd", "3",
        "terzo", "il terzo", "la terza", "terza"
    ]
    private static let ordinalFourth: Set<String> = [
        "fourth", "the fourth", "4th", "4",
        "quarto", "il quarto", "la quarta", "quarta"
    ]
    private static let ordinalFifth: Set<String> = [
        "fifth", "the fifth", "5th", "5",
        "quinto", "il quinto", "la quinta", "quinta"
    ]

    private static func ordinalIndex(in t: String) -> Int? {
        if ordinalFifth.contains(t) || ordinalFifth.contains(where: { t.hasPrefix($0 + " ") }) { return 4 }
        if ordinalFourth.contains(t) || ordinalFourth.contains(where: { t.hasPrefix($0 + " ") }) { return 3 }
        if ordinalThird.contains(t) || ordinalThird.contains(where: { t.hasPrefix($0 + " ") }) { return 2 }
        if ordinalSecond.contains(t) || ordinalSecond.contains(where: { t.hasPrefix($0 + " ") }) { return 1 }
        if ordinalFirst.contains(t) || ordinalFirst.contains(where: { t.hasPrefix($0 + " ") }) { return 0 }
        return nil
    }

    // MARK: - 3. Name match (most discriminating)

    private static func matchByName(
        utterance t: String,
        candidates: [GigiSmartOrchestrator.ContactCandidate]
    ) -> ContactDisambiguationResult {
        let scored: [(GigiSmartOrchestrator.ContactCandidate, Int)] = candidates.map { c in
            let nameWords = c.name
                .lowercased()
                .split(whereSeparator: { !$0.isLetter })
                .map(String.init)
                .filter { $0.count >= 2 }
            let hits = nameWords.reduce(0) { acc, word in
                acc + (t.contains(word) ? 1 : 0)
            }
            return (c, hits)
        }
        let top = scored.max { $0.1 < $1.1 }
        guard let (winner, score) = top, score > 0 else { return .unresolved }
        // Ambiguity check — if multiple candidates share the top score, can't decide.
        let ties = scored.filter { $0.1 == score }
        if ties.count == 1 {
            return .matched(winner)
        }
        return .unresolved
    }

    // MARK: - 4. Phone digit match

    private static func matchByPhoneDigits(
        utterance t: String,
        candidates: [GigiSmartOrchestrator.ContactCandidate]
    ) -> GigiSmartOrchestrator.ContactCandidate? {
        let digits = t.filter(\.isNumber)
        guard digits.count >= 3 else { return nil }
        return matchByDigitSubstring(digits: digits, candidates: candidates)
    }

    private static func matchByDigitSubstring(
        digits: String,
        candidates: [GigiSmartOrchestrator.ContactCandidate]
    ) -> GigiSmartOrchestrator.ContactCandidate? {
        // Find candidates whose phone digit string contains the utterance digits.
        let matches = candidates.filter { c in
            c.phone.filter(\.isNumber).contains(digits)
        }
        return matches.count == 1 ? matches[0] : nil
    }

    // MARK: - 5. Word-to-digit (subset of parseTimerDuration's dict)

    private static let WORD_TO_DIGIT: [String: String] = [
        "zero": "0",
        "one": "1", "two": "2", "three": "3", "four": "4", "five": "5",
        "six": "6", "seven": "7", "eight": "8", "nine": "9",
        // Italian
        "uno": "1", "due": "2", "tre": "3", "quattro": "4", "cinque": "5",
        "sei": "6", "sette": "7", "otto": "8", "nove": "9"
    ]

    /// Walk through utterance words and concatenate digit equivalents.
    /// "three eight zero" → "380". Non-digit words don't break the sequence
    /// (e.g. "three and eight zero" → "380" too) — phone numbers usually
    /// have filler.
    private static func wordsToDigits(_ t: String) -> String {
        let tokens = t.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
        var out = ""
        for token in tokens {
            if let d = WORD_TO_DIGIT[token] {
                out.append(d)
            } else if let n = Int(token), (0...9).contains(n) {
                out.append("\(n)")
            }
        }
        return out
    }
}
