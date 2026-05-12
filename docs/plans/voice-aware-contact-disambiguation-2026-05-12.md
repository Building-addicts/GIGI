# Voice-aware contact disambiguation — design plan

**Status**: draft (awaiting Armando approval before code)
**Date**: 2026-05-12
**Author**: Claude + Armando
**Related bug**: docs/DEBUG/2026-05-12-017-* (will be created)
**Scope**: `02_GIGI_APP/GIGI/{GigiSmartOrchestrator, GigiAgentEngine, ContactDisambiguationBubble}.swift`

---

## 1. Requirements

User feedback after bug-017 v4 ship:

> *"Altra problematica secondo me è che la decisione non è basata sul nulla,
> GIGI dovrebbe proporre una scelta che l'utente può decidere chattando,
> non solo cliccando, invece noto che quando chatto è come se fosse
> parallela la chat capito? […] Perché la chat poi sarà vocale quindi
> dobbiamo immaginare un funzionamento vocale già di GIGI."*

Translation: the bubble accepts taps but ignores voice / text input. Since
the primary GIGI UX is voice, the disambiguation must work conversationally
— the user must be able to **say** which contact, not just tap.

Concrete examples:
- *"Call Fede"* → bubble appears → *"Fede Rossi"* (voice) → call dispatched.
- *"Call Fede"* → bubble appears → *"il primo"* / *"la seconda"* → call.
- *"Call Fede"* → bubble appears → *"quella col tre otto zero"* → call.
- *"Call Fede"* → bubble appears → *"annulla"* / *"cancel"* → cancelled.

Both touch AND voice must work. They are the same affordance; voice wins
because no extra tap.

---

## 2. Acceptance Criteria (all testable)

| # | Behavior | Verifiable |
|---|---|---|
| AC1 | When disambiguation is active, the next user utterance (voice or text) is intercepted by the disambig resolver **before** the main router. | Log line `[disambig] intercepted, resolved → Fede Rossi`; main router gets nothing. |
| AC2 | Speaking the full name (e.g. *"Fede Rossi"*) resolves to that candidate even with 1-word match (*"Rossi"*). | Pronounce → screenshot bubble disappears + Calling pill shows correct name. |
| AC3 | Speaking an ordinal (*"il primo"*, *"la seconda"*, *"first one"*, *"second"*) resolves to position 1 or 2. | Pronounce → correct candidate dispatched. |
| AC4 | Speaking digits from the phone number (*"three eight zero"* / *"trecentottanta"* / *"380"*) resolves the matching candidate. | Pronounce 3+ digits from one of the phones → that candidate dispatched. |
| AC5 | Speaking *"annulla"* / *"cancel"* / *"stop"* / *"no"* resolves to nil, bubble disappears, conversation continues. | Pronounce → bubble disappears + chat returns to ready. |
| AC6 | If user voice input does NOT match any candidate, GIGI re-asks once via TTS (*"I didn't catch that. Fede Rossi or Fede Bianchi?"*) and bubble stays. After 2 consecutive misses, cancel automatically. | Speak unrelated word → TTS re-prompt + bubble persists. Speak unrelated 2nd time → cancel. |
| AC7 | When bubble appears, GIGI speaks the question via TTS (*"Which Fede do you mean?"*) — not just visual. | Audio captured during test. |
| AC8 | A timeout of 30 seconds with no input auto-cancels the disambiguation. | Wait 30s without speaking → bubble disappears + chat ready. |
| AC9 | Touch interaction (tap a row) keeps working unchanged after this change. | Tap → call (existing path). |
| AC10 | The intercepted utterance does NOT pollute conversation memory as a user turn (avoids router seeing *"Fede Rossi"* as a new query later). | Inspect GigiConversationMemory after disambig — only the original *"Call Fede"* is recorded. |

---

## 3. Architecture

### 3.1 State machine

```
Idle                                Disambig pending
 │                                    │
 │ user: "Call Fede"                  │ user: "Fede Rossi" (voice or text)
 │                                    │   OR tap row in bubble
 │  (2+ matches)                      │   OR voice: "primo" / digits / cancel
 ▼                                    ▼
 Show bubble        ←─────────  Resolve match
 Speak question                  │
 Mark pending          ┌─────────┴────────┐
                       │                  │
                  Matched              No match
                       │                  │
                  state.completion      Speak re-prompt
                  (candidate)           (max 1 retry, then auto-cancel)
                       │
                  Clear pending
                  Dispatch action
```

### 3.2 Code structure

**`GigiSmartOrchestrator.process(text:)`** intercept block (mirrors the
existing `showDraftPreview` pattern at lines 285-310):

```swift
// --- Contact disambiguation voice intercept ---
if let disambig = contactDisambiguation {
    let result = ContactDisambiguationResolver.resolve(
        utterance: trimmed,
        state: disambig
    )
    switch result {
    case .matched(let candidate):
        disambig.completion(candidate)
        contactDisambiguation = nil
        memory.resolveThinking(id: thinkingID, with: "")  // no echo
        isThinking = false
        return
    case .cancelled:
        disambig.completion(nil)
        contactDisambiguation = nil
        speech.speak("Cancelled.")
        memory.resolveThinking(id: thinkingID, with: "Cancelled.")
        isThinking = false
        return
    case .unresolved:
        retryCount += 1
        if retryCount >= 2 {
            disambig.completion(nil)
            contactDisambiguation = nil
            speech.speak("OK, never mind.")
            isThinking = false
            return
        }
        let names = disambig.candidates.map { $0.name }.joined(separator: " or ")
        speech.speak("I didn't catch that. \(names)?")
        memory.removeLastThinking(id: thinkingID)  // don't accumulate
        isThinking = false
        return  // bubble persists
    }
}
```

**`ContactDisambiguationResolver`** (new file or static helper):

```swift
enum DisambigResult {
    case matched(ContactCandidate)
    case cancelled
    case unresolved
}

static func resolve(utterance: String, state: ContactDisambiguationState) -> DisambigResult {
    let t = utterance.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)

    // 1. Cancel intents
    let cancelTokens = ["cancel", "annulla", "stop", "no", "lascia stare",
                        "lascia perdere", "ferma", "nothing", "nevermind"]
    if cancelTokens.contains(where: { t == $0 || t.hasPrefix($0 + " ") }) {
        return .cancelled
    }

    // 2. Ordinals — position 1 / 2 / 3 ...
    let firstTokens = ["first", "the first", "first one", "primo", "il primo", "la prima", "1"]
    let secondTokens = ["second", "the second", "second one", "secondo", "il secondo", "la seconda", "2"]
    let thirdTokens = ["third", "il terzo", "la terza", "3"]
    if firstTokens.contains(where: { t == $0 || t.contains($0) }),
       state.candidates.indices.contains(0) {
        return .matched(state.candidates[0])
    }
    if secondTokens.contains(where: { t == $0 || t.contains($0) }),
       state.candidates.indices.contains(1) {
        return .matched(state.candidates[1])
    }
    if thirdTokens.contains(where: { t == $0 || t.contains($0) }),
       state.candidates.indices.contains(2) {
        return .matched(state.candidates[2])
    }

    // 3. Name match — score each candidate by how many words from
    //    candidate.name appear in the utterance.
    let scored: [(ContactCandidate, Int)] = state.candidates.map { c in
        let nameWords = c.name.lowercased().split(separator: " ").map(String.init)
        let hits = nameWords.filter { word in
            word.count >= 2 && t.contains(word)
        }.count
        return (c, hits)
    }
    if let best = scored.max(by: { $0.1 < $1.1 }), best.1 > 0 {
        // Check ambiguity: if 2+ candidates tie with same hit count, unresolved.
        let topScore = best.1
        let ties = scored.filter { $0.1 == topScore }
        if ties.count == 1 {
            return .matched(best.0)
        }
    }

    // 4. Phone digit match — extract digits from utterance, match against
    //    candidate.phone digit suffixes / contiguous substrings.
    let utterDigits = t.filter(\.isNumber)
    if utterDigits.count >= 3 {
        for c in state.candidates {
            let phoneDigits = c.phone.filter(\.isNumber)
            if phoneDigits.contains(utterDigits) {
                return .matched(c)
            }
        }
    }

    // 5. Word-to-digit conversion ("three eight zero" → "380")
    //    Reuses WORD_TO_NUMBER dict from parseTimerDuration if shared.
    let convertedDigits = wordsToDigits(t)
    if convertedDigits.count >= 3 {
        for c in state.candidates {
            let phoneDigits = c.phone.filter(\.isNumber)
            if phoneDigits.contains(convertedDigits) {
                return .matched(c)
            }
        }
    }

    return .unresolved
}
```

### 3.3 TTS speak question on bubble appear

In `GigiActionBridge.disambiguateContact` right before the
`presentContactDisambiguation` call, add:

```swift
// Speak the question (voice channel) so user knows GIGI is waiting.
let preview = candidates.prefix(2).map { $0.name }.joined(separator: " or ")
let question = candidates.count == 2
    ? "Which \(query)? \(preview)?"
    : "Which \(query)? I have \(candidates.count) matches."
await MainActor.run {
    GigiSpeechService.shared.speak(question)
}
```

### 3.4 Timeout (30s auto-cancel)

In `presentContactDisambiguation` (orchestrator), schedule a Task:

```swift
let timeoutTask = Task { [weak self] in
    try? await Task.sleep(nanoseconds: 30_000_000_000)
    guard !Task.isCancelled else { return }
    await MainActor.run {
        if let s = self?.contactDisambiguation, s.id == newState.id {
            s.completion(nil)
            self?.contactDisambiguation = nil
            self?.speech.speak("Cancelled — took too long.")
        }
    }
}
state.timeoutTask = timeoutTask  // stored to cancel on early resolve
```

Cancel the task in `choose()` / `cancel()` paths.

### 3.5 Memory hygiene

The intercepted disambig response (*"Fede Rossi"*) should NOT be added
to `GigiConversationMemory` as a user message. Reason: if the user later
says *"Call Fede"* again, the router would see *"Fede Rossi"* in history
and might mis-anchor.

Implementation: in the orchestrator intercept block, do NOT call
`memory.addUser(trimmed)` before the disambig check. Currently
`process(text:)` calls `memory.addUser(trimmed)` at line 277 — we need to
delay that call until AFTER the disambig intercept.

```swift
func process(text: String) async {
    isThinking = true
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { ... return }

    // *** Check disambig BEFORE recording in memory ***
    if let disambig = contactDisambiguation {
        await handleDisambigUtterance(trimmed, state: disambig)
        return
    }

    // Normal path: NOW record memory
    memory.addUser(trimmed)
    ...
}
```

---

## 4. Implementation Steps

| # | Step | File | Effort |
|---|---|---|---|
| 1 | Add `ContactDisambiguationResolver` enum + static `resolve()` with cancel / ordinal / name / phone-digit matchers | new file `GigiContactDisambiguationResolver.swift` | 30 min |
| 2 | Add `wordsToDigits(_:)` helper (or reuse `WORD_TO_NUMBER` from `parseTimerDuration`) | extend `GigiActionBridge.swift` or share via new util | 15 min |
| 3 | Add `retryCount` + `timeoutTask` state to `ContactDisambiguationState` (private, transient) | `GigiSmartOrchestrator.swift` | 10 min |
| 4 | Add voice intercept block to `process(text:)` before `memory.addUser(trimmed)` | `GigiSmartOrchestrator.swift:254-278` | 20 min |
| 5 | Speak question via TTS when bubble appears | `GigiActionBridge.disambiguateContact` | 5 min |
| 6 | Cancel `timeoutTask` in `choose()` and `cancel()` in `ContactDisambiguationBubble` | `ContactDisambiguationBubble.swift` | 5 min |
| 7 | Auto-cancel after 30s timeout | `GigiSmartOrchestrator.presentContactDisambiguation` | 15 min |
| 8 | Test on device: voice flows (5 scenarios) + tap flows (2 regression) | manual | 15 min |

**Total**: ~2 hours implementation + verification.

---

## 5. Risks & Mitigations

| Risk | Probability | Impact | Mitigation |
|---|---|---|---|
| Voice-intercept catches a legit unrelated query (user says "Call Marco" after Fede bubble) | Med | Med — wrong action | First check if utterance is a fresh top-level command (e.g. starts with "call", "send", "set"); if so, dismiss disambig and route to main path. Add to AC6: "explicit new command intent → cancel disambig + process normally". |
| Name match ambiguity with shared surname ("Fede Rossi" vs "Marco Rossi" → user says "Rossi" while Fede disambig pending) | Low | Low — `state.candidates` are pre-filtered to Fede matches only, so "Rossi" hits one. | None needed, scoped by query. |
| TTS speaks question, user replies before TTS finishes → STT misses partial input | Med | Low | Common voice UX — Siri has same issue. Mitigate later with TTS-end barge-in. |
| Phone digit utterance contains unrelated digits ("call him about the 380 thing") | Low | Med | Only intercept if the utterance is SHORT (<5 words) — otherwise route as new query. |
| Timeout 30s too short / too long | Low | Low | Make it a UserDefault `gigi.disambig.timeoutSeconds` default 30. Adjust based on user feedback. |
| Retry counter resets across multiple bubbles (user gets stuck in loop) | Low | Low | Reset retry count when bubble dismissed for any reason. |
| Memory `addUser` placement change breaks other interceptors (draft preview voice intercept already uses similar pattern) | Med | Med | Draft preview path already places `memory.addUser` AFTER its check — same pattern. Verify no regression with draft+disambig combined test. |

---

## 6. Verification Steps

After implementation, run these on-device tests in order. **Each must PASS** before sign-off.

### Voice scenarios (primary)

1. **Setup**: in Contacts add 2+ entries with same first name (e.g. "Fede Bianchi", "Fede Rossi").
2. Say *"Call Fede"* → bubble appears + TTS speaks *"Which Fede? Fede Bianchi or Fede Rossi?"*
3. Say *"Fede Rossi"* → bubble disappears, banner pill *"Calling Fede Rossi…"*, iOS popup dial.
4. Repeat step 2 → say *"il primo"* → first candidate dispatched.
5. Repeat step 2 → say *"380"* (digits from one phone) → that candidate dispatched.
6. Repeat step 2 → say *"annulla"* → bubble disappears + TTS *"Cancelled."*.
7. Repeat step 2 → say *"banana"* → TTS re-asks *"I didn't catch that. Fede Bianchi or Fede Rossi?"* → say *"banana"* again → auto-cancel + TTS *"OK, never mind."*

### Touch regression

8. Repeat step 2 → tap "Fede Bianchi" row → call dispatched (existing path).
9. Repeat step 2 → tap "Cancel" → bubble disappears.

### Edge: new command interrupts

10. Repeat step 2 → say *"Set a timer for 5 minutes"* (clearly a new top-level command) → disambig cancels, timer set.

### Timeout

11. Repeat step 2 → wait 30 seconds without speaking → bubble disappears + TTS *"Cancelled — took too long."*.

### Memory hygiene

12. After any pass, check `GigiConversationMemory.contents` — only the original *"Call Fede"* should be recorded as a user turn. The disambig response (*"Fede Rossi"*, *"primo"*, etc.) must not appear.

---

## 7. Open design questions

1. **Should the bubble FIRST be silent until TTS finishes?** Trade-off: barge-in friendly vs. user might speak too early. Default for v1: speak short question (~1.5s), no barge-in.
2. **Should we show transcribed input in real-time in the bubble?** (Live-listen feedback). For v1: no — keep bubble static, rely on chat scroll for transcript display.
3. **Should disambig timeout speak feedback or be silent?** Default v1: speak *"Cancelled — took too long."* once.
4. **Should "anyone" / "qualunque" / "non importa" resolve to the "Last call" candidate as default?** Convenient but ambiguous. Default v1: no, route to unresolved (asks again).

---

## 8. Out of scope (deferred)

- **Multilingual support**: only EN + IT for v1. Spanish/French/German keywords deferred.
- **Barge-in TTS**: stop TTS playback when user starts speaking. Standard Siri behavior. Deferred to v1.1.
- **Visual transcribed text inside bubble**: live "listening… (your voice)" feedback. Deferred.
- **Multi-step disambig**: 3+ candidates with same first AND last name (rare). Resolver handles up to N candidates already (no special case).
- **Number-to-word conversion fallback**: e.g. STT may transcribe *"three hundred eighty"* as *"three hundred eighty"* — current `wordsToDigits` covers basic 0-99; compound numbers (300+) deferred.

---

## 9. Risk-adjusted recommendation

**Implement steps 1-7 in one cumulative commit**. ~2 hours. The voice
intercept + TTS speak are the core value; ordinal + digit matching are
quick wins; timeout is essential safety.

**Defer**: barge-in, live transcription, multilingual.

---

## 10. Sign-off

Awaiting Armando's approval. Proposed answer: **proceed with full plan
as-is**, then test on device with the 12-scenario suite in §6.
