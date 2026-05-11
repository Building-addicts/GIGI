# Bug 004 — `Set a timer for two minutes` fails — regex only matches digits

- **Status**: open
- **Severity**: P1 (very common phrasing for voice input — STT often spells out small numbers)
- **Discovered**: 2026-05-12 — beta tester wave
- **Area**: iOS · GigiActionBridge · parseTimerDuration

## Symptom

| Prompt | Behavior |
|---|---|
| "Set a timer for **2** minutes" | ✅ Works — Apple FM extracts duration="2 minutes" → regex parses 2 → 120s notification |
| "Set a timer for **two** minutes" | ❌ Fails — Apple FM passes duration="two minutes" → regex returns 0 → GIGI: "How long should the timer run? Say something like '10 minutes'." |

## Repro

1. Tab GIGI → microphone → say "Set a timer for two minutes" (spelled out)
2. GIGI asks for clarification instead of setting the timer

## Root cause

In `02_GIGI_APP/GIGI/GigiActionBridge.swift:467-478`:

```swift
private func parseTimerDuration(_ text: String) -> Int {
    let lower = text.lowercased()
    var total = 0
    let patterns: [(String, Int)] = [
        ("(\\d+)\\s*(?:hours?|ora|ore|hr|h)\\b", 3600),
        ("(\\d+)\\s*(?:minutes?|minuto|minuti|min|m)\\b", 60),
        ("(\\d+)\\s*(?:seconds?|secondo|secondi|sec|s)\\b", 1)
    ]
    for (pattern, mult) in patterns {
        if let match = lower.range(of: pattern, options: .regularExpression) {
            let digits = String(lower[match]).filter { $0.isNumber }
            if let n = Int(digits) { total += n * mult }
        }
    }
    return total
}
```

Regex `\d+` only matches numeric digits. "two", "three", "ten" are not
captured → match fails → 0 returned.

## Why STT often spells out

Apple's SFSpeech recognizer converts spoken short numbers to words
("two" not "2"), especially when:
- Number ≤ ten ("one", "two", "three"…)
- Spoken slowly or in isolation
- The phrase is short ("two minutes" vs "twenty five minutes")

So "Set a timer for two minutes" is a VERY common natural utterance
that currently fails.

## Proposed fix

Add a `wordToNumber` pre-pass that converts English number words
(0–99 at least) to digits before regex matching:

```swift
private static let WORD_TO_NUMBER: [String: Int] = [
    "zero": 0, "one": 1, "two": 2, "three": 3, "four": 4,
    "five": 5, "six": 6, "seven": 7, "eight": 8, "nine": 9,
    "ten": 10, "eleven": 11, "twelve": 12, "thirteen": 13,
    "fourteen": 14, "fifteen": 15, "sixteen": 16, "seventeen": 17,
    "eighteen": 18, "nineteen": 19, "twenty": 20, "thirty": 30,
    "forty": 40, "fifty": 50, "sixty": 60, "seventy": 70,
    "eighty": 80, "ninety": 90, "hundred": 100,
    // Italian (covers IT testers too)
    "uno": 1, "due": 2, "tre": 3, "quattro": 4, "cinque": 5,
    "sei": 6, "sette": 7, "otto": 8, "nove": 9, "dieci": 10,
    "venti": 20, "trenta": 30, "quaranta": 40, "cinquanta": 50,
    "un": 1, "una": 1
]

private func normalizeNumbers(_ text: String) -> String {
    var out = text
    // First handle compound numbers like "twenty five" → "25"
    // (skip for v1; just do single words)
    for (word, n) in Self.WORD_TO_NUMBER {
        out = out.replacingOccurrences(
            of: "\\b\(word)\\b",
            with: "\(n)",
            options: [.regularExpression, .caseInsensitive]
        )
    }
    return out
}

private func parseTimerDuration(_ text: String) -> Int {
    let normalized = normalizeNumbers(text.lowercased())
    // ... existing regex logic on `normalized`
}
```

Compound numbers ("twenty five minutes") need a second pass to
combine adjacent words → integer sum, e.g. `twenty five` → `20 5` → 25.
Defer to v1.1 if v1 only needs 1–10 coverage.

## Edge cases to test after fix

| Input | Expected seconds |
|---|---|
| "two minutes" | 120 |
| "five seconds" | 5 |
| "one hour" | 3600 |
| "ten and a half minutes" | 600 (fractional in v1.1) |
| "twenty minutes" | 1200 |
| "twenty five minutes" | 1500 (compound, v1.1) |
| "due minuti" (IT) | 120 |
| "mezz'ora" | 1800 (v1.1) |

## Files involved

| File | What |
|---|---|
| `02_GIGI_APP/GIGI/GigiActionBridge.swift:464-479` | parseTimerDuration |
| Similar fix needed for: `set_alarm` time parsing, `set_reminder` time parsing |

## Resolution

_(empty)_
