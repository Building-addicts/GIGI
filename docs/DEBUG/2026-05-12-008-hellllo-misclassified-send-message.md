# Bug 008 — `Hellllo` (typo/repeated greeting) misclassified as `send_message` action

- **Status**: open
- **Severity**: P2 (recurring issue when STT/user introduces typos — affects naturalness)
- **Discovered**: 2026-05-12 — Armando's re-test wave after bug 003 fix
- **Area**: iOS · Apple FM router classification · edge case for casual greetings with typos

## Symptom

User typed: **"Hellllo"** (typo with repeated `l`)

GIGI response:
> Can you please specify who you want to send the message to?

The router classified the utterance as `send_message` with the contact slot
missing, then fell through to `ask_clarification` for the missing contact.
The intended interpretation was a casual greeting (small talk).

## Evidence

Tester screenshot 2026-05-12 (third bubble in the screenshot showing
"Create a note... → Hey... → Hellllo → 'Can you please specify who you
want to send the message to?'").

## Why this slipped through bug 003 fix

The bug 003 fix added an explicit shape for casual greetings:
```
Input shape: casual greeting / small talk / unclear short utterance
  ("Hey", "How are you", "What's up") → path=delegate_local, complexity=10,
  reason="small talk".
```

But the example anchor list is short (3 examples: "Hey", "How are you",
"What's up"). Apple FM doesn't generalize to typo variants:
- `Hellllo` (four l's)
- `Hellooooo` (extended o)
- `Heyyyy` (repeated y)
- `Ciaoooo` (Italian variants)

Without seeing a typo/extension pattern in the few-shot, the model
defaults to its most semantically nearest match — which for "Hello"
sometimes means "user wants to send a message starting with Hello".

## Repro

1. Reset chat (icon ↻)
2. Type or pronounce: "Hellllo" (more than 2 of any letter)
3. GIGI responds with the send_message clarification

## Root cause hypothesis

Apple FM @Generable constrained decoding pattern-matches the utterance
against the prompt's STRUCTURE EXAMPLES. With only 3 literal casual-greeting
examples and many send_message examples in capabilities/slot rules, the
model interprets "Hellllo" as text destined for a message body.

The fix added in bug 003 reduces this for canonical greetings but doesn't
cover edge cases of repeated/elongated characters that humans use to
express tone.

## Proposed fix (2 layers)

### Layer A — strengthen FM router prompt with typo-aware greeting shape

In `GigiFoundationAgent.swift` greeting shape rule:

```
Input shape: casual greeting / small talk / unclear short utterance →
  Examples: "Hey", "How are you", "What's up", "Yo", "Hello",
  "Ciao", "Hi there", AND any spelling variant or character-repetition
  pattern of the above (e.g. "Hellllo", "Heyyy", "Ciaoooo", "Yooo"
  are all the same as "Hello" / "Hey" / "Ciao" / "Yo" with emotional
  emphasis — they are NEVER send_message bodies).
  → path=delegate_local, complexity=10, capabilities=[], reason="small talk".
```

### Layer B — defensive iOS pre-filter

Before sending to Apple FM, run a quick regex normalizer:
```swift
// Collapse repeated characters (≥3 in a row) to 2 for greeting detection.
// "Hellllo" → "Hello", "Heyyy" → "Heyy" → close to "Hey".
let normalized = text.replacingOccurrences(
    of: "(.)\\1{2,}",
    with: "$1$1",
    options: .regularExpression
)
// If normalized text matches a known greeting list, force delegate_local
// without going through Apple FM router at all.
let greetingExact = ["hey", "hello", "hi", "yo", "ciao", "buongiorno",
                     "buonasera", "what's up", "good morning"]
if greetingExact.contains(normalized.lowercased().trimmingCharacters(in: .punctuationCharacters)) {
    return .greeting(originalText: text)  // skip router, go straight to local response
}
```

This is essentially a "deterministic NLU fast-path" addition for greetings
— exactly what `GigiAgentEngine.deterministicFastPath` does for high-confidence
intents like "what time is it". Adds zero latency, bypasses Apple FM
entirely for safe cases.

## Files involved

| File | What |
|---|---|
| `02_GIGI_APP/GIGI/GigiFoundationAgent.swift:277-279` | Greeting shape rule in router prompt |
| `02_GIGI_APP/GIGI/GigiAgentEngine.swift:131-160` | deterministicFastPath — add greeting normalizer |
| `02_GIGI_APP/GIGI/GigiNLUEngine.swift` | If used by fast-path, may need greeting entry |

## Resolution

_(empty)_
