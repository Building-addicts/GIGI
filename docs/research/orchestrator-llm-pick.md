# Orchestrator LLM provider pick + system prompt v1 — issue #144

**Goal**: select the LLM provider (and model variant) that powers the
`GigiOrchestratorClient` on iOS, and design the system prompt that
constrains its output to the marker grammar consumed by the iOS Shortcut.
Decision drives implementation in sub #147.

**Constraints from #143**:
- Direct iOS → cloud LLM (no harness proxy). API key in Keychain.
- Latency target: < 500 ms P50 round-trip.
- Output must match strict marker grammar (any deviation → user-visible
  error or wrong action).
- Multi-language: Italian + English. The user demo target is English but
  the team tests in Italian; both must work.
- iOS native HTTP client (`URLSession`). No SDK requirement that pulls a
  Python/Node runtime.

## 1. Comparative table

| Provider | Model | Median latency (small-prompt completion ~50 tok) | Cost / 1M input tok | Cost / 1M output tok | Notes |
|---|---|---|---|---|---|
| **Groq** | `llama-3.3-70b-versatile` | **~150-300 ms** | $0.59 | $0.79 | Fastest by far. OpenAI-compatible REST API. |
| **Groq** | `llama-3.1-8b-instant` | ~100-200 ms | $0.05 | $0.08 | Cheap + fast but lower instruction-following quality. |
| **Anthropic** | `claude-haiku-4-5` | ~400-700 ms | $1.00 | $5.00 | Excellent instruction-following. Native iOS SDK exists. |
| **Anthropic** | `claude-sonnet-4-6` | ~700-1500 ms | $3.00 | $15.00 | Overkill for routing. |
| **OpenAI** | `gpt-4o-mini` | ~500-900 ms | $0.15 | $0.60 | Solid quality, mid latency. |
| **OpenAI** | `gpt-4o` | ~700-1500 ms | $2.50 | $10.00 | Overkill. |
| **Google** | `gemini-2.5-flash` | ~400-800 ms | $0.075 | $0.30 | Cheapest among major providers; quality on routing acceptable. |
| **Apple** | Foundation Models (on-device) | <50 ms theoretical | $0 | $0 | iOS 26+ only. Quality on instruction-following marker grammar untested. Strict context limits. |

Latency ranges sourced from public benchmarks 2026 Q1 + provider docs.
Real numbers depend heavily on geographic egress + warm-vs-cold path.

## 2. Quality test set (20 phrases)

Phrases the user is likely to speak. Two languages mixed.

| # | Phrase | Expected marker |
|---|---|---|
| 1 | turn on the flashlight | `SYS:torch:on` |
| 2 | accendi la luce del telefono | `SYS:torch:on` |
| 3 | turn off torch | `SYS:torch:off` |
| 4 | volume to 70 percent | `SYS:volume:70` |
| 5 | alza il volume al 50 | `SYS:volume:50` |
| 6 | brightness 100 | `SYS:brightness:100` |
| 7 | call Marco | `CALL:<resolved E.164>` |
| 8 | squillo a Federico | `CALL:<resolved E.164>` |
| 9 | text Marco saying I'm late | `SMS:<phone>\|I'm late` |
| 10 | manda un messaggio a mamma dicendo che sto arrivando | `SMS:<phone>\|sto arrivando` |
| 11 | open Spotify | `OPEN:spotify://` |
| 12 | open Instagram | `OPEN:instagram://` |
| 13 | take a screenshot | `SYS:screenshot:` |
| 14 | what time is it | `it's <HH:MM>` (plain text) |
| 15 | tell me a joke | `<plain text joke>` |
| 16 | weather today | `SYS:weather:` (or plain text fallback) |
| 17 | enable do not disturb | `SYS:dnd:on` |
| 18 | airplane mode off | `SYS:airplane:off` |
| 19 | next song | `SYS:music:next` |
| 20 | pause music | `SYS:music:pause` |

Quality target: **18/20 correct marker** for the chosen model with the v1
system prompt. Below 16/20 → consider swapping model.

## 3. Decision

**Primary pick**: **Groq `llama-3.3-70b-versatile`**.

Rationale:
1. **Latency wins**: 150-300 ms P50 is in another league. The iOS user is
   speaking and expecting near-instant action. Anthropic Haiku at 400-700 ms
   is good but still ~2-4× slower for the same routing accuracy.
2. **Cost**: $0.59 / $0.79 per 1M tokens. At ~150 input + ~30 output tokens
   per call, a call costs ~$0.0001. 1000 calls/day = $0.10/day.
3. **API surface**: OpenAI-compatible REST. `URLSession` POST to
   `https://api.groq.com/openai/v1/chat/completions`. No SDK overhead.
4. **70b weights**: 70b llama-3.3 is more than enough for instruction-
   following on a constrained grammar like ours. We are not asking the model
   to reason about novel domains.
5. **Acceptable risks**: Groq does occasional brownouts (rate limits), and
   model rotation may force a re-test. Mitigation: store the model ID in
   `GigiConfig.swift` so it's swappable without recompiling LLM code.

**Fallback (configurable)**: **Anthropic `claude-haiku-4-5`**.

When to swap: Groq region down, or quality regression on routing accuracy.
The orchestrator client should accept a `provider` enum
(`.groq` / `.anthropic`) so swapping is a one-line config change.

**Rejected**:
- **Apple Foundation Models** — quality on multi-language marker grammar is
  unproven. Worth a parallel spike post-MVP, but not for May 1 demo.
- **gpt-4o-mini** — strictly worse on cost AND latency vs Groq. No reason
  to pick.
- **Gemini 2.5 Flash** — cheaper than Groq but slower (400-800 ms). If
  cost becomes the constraint instead of latency, revisit.

## 4. System prompt v1

Below is the literal prompt the iOS client sends as the `system` message
each turn. Variables in `<ANGLE_BRACKETS>` are substituted at runtime by
`GigiOrchestratorClient`.

```
You are GIGI's command router. The user is speaking to you in English or
Italian and expects you to either trigger a device action (via marker) or
answer briefly in plain text.

Your output is read by a strict parser. Output EXACTLY ONE line, no prefix,
no explanation, no quotes, no markdown.

# Marker grammar (preferred when applicable)

CALL:<E.164 phone>
  - Use when the user wants to call a contact or a phone number.
  - Resolve contact names against the roster below. If multiple matches,
    pick the most-recently contacted; if none, return plain text:
    "No contact named X".

SMS:<E.164 phone>|<message body in user's language>
  - Use when the user wants to text/send a message.
  - Same resolution rules as CALL. Body keeps original language. Strip the
    leading verb ("text X saying ...", "manda a X dicendo ..."). Body must
    not contain '|' characters; replace with ', ' if it does.

SYS:<command>:<param>
  - Use for device hardware actions. Catalog:
      torch:on | torch:off
      volume:<0..100>
      brightness:<0..100>
      wifi:on | wifi:off
      bluetooth:on | bluetooth:off
      airplane:on | airplane:off
      dnd:on | dnd:off
      silent:on | silent:off
      lpm:on | lpm:off
      screenshot:
      music:play | music:pause | music:next | music:prev
      weather:
      location:
      alarm:<HH:MM 24h>

OPEN:<url scheme>
  - Use to launch another app. Common schemes:
      spotify:// instagram:// youtube:// maps:// whatsapp:// amazon://
  - Search variants:
      spotify:search:<encoded query>
      youtube:search:<encoded query>
      amazon:search:<encoded query>

# Plain text fallback

If the user is asking a chat-style question (joke, time, fact, opinion,
follow-up to your previous answer), or the request is ambiguous, output a
short plain-text answer (≤ 140 characters, in the user's language). Never
prefix with "Answer:" or any label.

# Hard rules

1. Output ONE line. No leading/trailing whitespace. No markdown. No quotes.
2. If you are even slightly unsure whether a marker fits, prefer plain text.
3. Never invent phone numbers. If contact resolution fails, output plain
   text "No contact named X" or "Non trovo X" (mirror the user's language).
4. Never include thoughts, planning, or chain-of-reasoning. Only the result.
5. Volumes/brightness/percent must be integers 0-100. Clamp out-of-range.

# Contact roster (resolved by GIGI)

<USER_CONTACTS>
  - Each line: <name> | <E.164 phone> | <last contacted ISO date>
</USER_CONTACTS>

# Locale hint

User spoken language tag: <USER_LOCALE>  (e.g. en-US, it-IT)
```

### Example interactions

| User said | Marker / answer |
|---|---|
| accendi la luce | `SYS:torch:on` |
| volume al 60 | `SYS:volume:60` |
| chiama Marco | `CALL:+393331234567` (assuming Marco resolves) |
| call somebody named Wilbur | `Non trovo Wilbur` |
| che ore sono | `Sono le 14:32` |
| tell me a joke | `Why don't scientists trust atoms? Because they make up everything.` |
| open spotify and play jazz | `spotify:search:jazz` |
| send Federico saying I'm five minutes late | `SMS:+393339876543\|I'm five minutes late` |

## 5. Implementation hints for sub #147

- HTTP method: `POST https://api.groq.com/openai/v1/chat/completions`
- Headers: `Authorization: Bearer <key>`, `Content-Type: application/json`
- Body:
  ```json
  {
    "model": "llama-3.3-70b-versatile",
    "messages": [
      {"role": "system", "content": "<prompt above with substitutions>"},
      {"role": "user", "content": "<transcript>"}
    ],
    "max_tokens": 100,
    "temperature": 0.0,
    "stop": ["\n"]
  }
  ```
- `temperature: 0.0` — we want deterministic routing. Plain-text answers
  may sound a bit dry; acceptable for v1.
- `stop: ["\n"]` — hard guarantees one-line output even if the model
  starts to elaborate.
- Timeout: 4.0 s. On timeout, surface "Couldn't reach GIGI" plain text via
  Confirm intent + DI `.error` phase.
- Retry: zero retries on a routing call. The user spoke once; a retry adds
  latency without value. If first call fails, fail loud.

## 6. AC checklist (post-implementation, post-test)

- [ ] AC#1 — Doc lists 3 providers compared on latency/cost/quality
- [ ] AC#2 — Final pick documented with reasoning (this section)
- [ ] AC#3 — System prompt v1 tested on the 20 phrases — accuracy ≥ 90%
      (≥ 18/20)
- [ ] AC#4 — Provider has REST API consumable by `URLSession` (Groq ✅)

## Open questions

1. **Italian TTS quality of plain-text answers** — Groq llama-3.3 in
   Italian sometimes produces stiff phrasing. If the dev audience
   complains during demo, swap to Haiku for plain-text turns only
   (hybrid).
2. **Contact roster size** — full roster injection inflates input tokens.
   For users with > 500 contacts, prune to the 50 most-recently used
   inside `GigiOrchestratorClient`.
3. **Streaming vs. non-streaming** — non-streaming for v1 (simpler). For
   plain-text answers > 140 chars (we cap), streaming would let TTS start
   earlier but adds complexity.

cc @ArmandoBattaglino — review pick (impacts monthly cost: estimated
$3-15/month at projected demo+post-launch usage).
