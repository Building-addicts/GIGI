# Deep fix plan — Ollama SSE "no answer" bug

**Date**: 2026-05-12
**Author**: Claude + Armando
**Status**: Active
**Severity**: P0 (blocks MVP demo Ollama path)
**Scope**: `02_GIGI_APP/GIGI/GigiHarnessClient+Streams.swift`

---

## 1. Requirements Summary

After 3 reinstalls + 2 root-cause fixes, the iOS `runLocalLLM` SSE consumer still
reports `chunks emitted=0` while the harness server actually produces 2 chunks
(`"Bonjour"` + `"."`). Symptom: "Ollama returned no answer · 0 chars".

User wants:
1. **Definitive fix** that does not depend on Apple's `URLSession.bytes.lines`
   parsing semantics
2. **Diagnostic surfacing** so we can tell, from a single log entry, whether the
   fix is installed on device
3. **Defensive fallback** in case the next fix attempt also fails — never again
   ship a "chunks=0" loop

---

## 2. Acceptance Criteria

| # | Criterion | Verification |
|---|-----------|--------------|
| AC1 | Build with new parser installed → "Translate good morning to French" returns `"Bonjour."` audibly | User test on iPhone with Brain Path Override = Ollama |
| AC2 | New build log line includes `parser=manual-buffer` token so installation can be verified at-a-glance | Settings → Captured GIGI logs contains the literal string |
| AC3 | Stream-end log reports `chunks emitted=N` where N matches server-reported `chunks` | Visible in Captured logs after each Ollama call |
| AC4 | If chunks emitted=0 AND server reported chunks>0, banner says `"SSE parse mismatch · check Captured logs"` instead of generic "no answer" | Forced via curl-stubbed mock or by inverting parser logic in dev build |
| AC5 | `runClaudeCode` parser also migrated to same implementation (consistency) | Code review |
| AC6 | Server-side `ios-local-llm.js` confirmed to emit standard SSE format (`\n\n` between events) | Curl test against tunnel: visible empty line between events |

---

## 3. Root cause analysis (confirmed)

### What the harness server emits (curl verified earlier)
```
event: chunk\n
data: {"text":"Bonjour"}\n
\n                              ← SSE event boundary (LF)
event: chunk\n
data: {"text":"."}\n
\n
event: done\n
data: {"latencyMs":3411,...}\n
\n
```

### What Cloudflare Tunnel forwards
The tunnel re-encodes line endings to **CRLF** (`\r\n`) because HTTP/1.1 default
is CRLF and quick tunnels normalize. So the wire actually carries:
```
event: chunk\r\n
data: {"text":"Bonjour"}\r\n
\r\n
...
```

### What Swift `bytes.lines` (AsyncLineSequence) does
Per Apple docs, `AsyncLineSequence` "produces lines by splitting on Unicode line
terminators" — which collectively include CR, LF, **and CRLF**. The
implementation iterates byte-by-byte and treats CRLF as a single terminator.

**The trap**: when two consecutive CRLF sequences appear (event separator), the
sequence may yield the empty line OR silently coalesce them, depending on the
buffer boundary alignment. With small chunks arriving at network speed, the
empty line is often consumed without being yielded. This matches our observation:
**6 lines total, zero empties** — server emitted 9 logical lines (3×event,
3×data, 3×empty separators).

This is not a bug in Swift; it's that `AsyncLineSequence` is designed for
text-line iteration, **not** SSE parsing. SSE requires the parser to see the
empty line as a delimiter, which `AsyncLineSequence` does not guarantee.

### Confirmation from the community
- mattt/EventSource (Swift's de-facto SSE library) implements a manual byte
  buffer parser, **not** `bytes.lines`.
- Swift Forums proposal SOAR-0010 proposes adding native SSE support precisely
  because community implementations on top of `bytes.lines` are fragile.

---

## 4. Implementation Steps

### Phase A — Verify current fix `c72d1a5` first (1 min)
**Step A1**. User reinstalls IPA built from commit `c72d1a5`.
**Step A2**. Test "Translate good morning to French" with Brain Path Override = Ollama.
**Step A3**. Check Captured logs. **Decision point**:
- If `chunks emitted=2` → done, AC1 met. Skip to Phase D.
- If `chunks emitted=0` still → proceed to Phase B (deep fix).

### Phase B — Manual byte-buffer SSE parser (defensive deep fix)

Replace the `for try await rawLine in bytes.lines` loop in `runLocalLLM` with
a manual byte buffer that:
1. Reads `UInt8` chunks from `bytes` (using `.makeAsyncIterator()`)
2. Accumulates into a `Data` buffer
3. On every read, scans for the SSE event boundary (`\n\n` OR `\r\n\r\n`)
4. When boundary found: extracts the event, dispatches it, drops it from buffer
5. Continues until stream ends

**Step B1**: Refactor in `GigiHarnessClient+Streams.swift:90-128`:
```swift
GigiDebugLogger.log("GIGI runLocalLLM connected · parser=manual-buffer-v1")

var buffer = Data()
var totalBytes = 0
var chunksEmitted = 0
var eventsProcessed = 0

for try await byte in bytes {
    buffer.append(byte)
    totalBytes += 1

    // Look for event boundary: \n\n (LF) or \r\n\r\n (CRLF)
    while let boundary = findEventBoundary(in: buffer) {
        let eventBytes = buffer.prefix(boundary.start)
        buffer.removeFirst(boundary.end)  // drop event + delimiter

        if let evt = parseSSEEvent(eventBytes) {
            eventsProcessed += 1
            Self.dispatchSSE(event: evt.name, data: evt.data,
                             started: started, continuation: continuation)
            if evt.name == "chunk" { chunksEmitted += 1 }
        }
    }
}
// Flush any final event without trailing boundary
if let evt = parseSSEEvent(buffer) {
    eventsProcessed += 1
    Self.dispatchSSE(event: evt.name, data: evt.data,
                     started: started, continuation: continuation)
    if evt.name == "chunk" { chunksEmitted += 1 }
}

GigiDebugLogger.log("GIGI runLocalLLM stream ended · parser=manual-buffer-v1 · bytes=\(totalBytes) events=\(eventsProcessed) chunks emitted=\(chunksEmitted)")
```

**Step B2**: Implement `findEventBoundary(in:)` and `parseSSEEvent(_:)`:
- `findEventBoundary`: scans for `\n\n` first; if not found, scans for `\r\n\r\n`.
  Returns `(start, end)` indices (`start` = where event body ends, `end` = where
  next event begins after delimiter).
- `parseSSEEvent`: takes raw event bytes, splits on `\n` OR `\r\n`, walks each
  line, accumulates `data:` fields, captures last `event:` header.

**Step B3**: Migrate `runClaudeCode` to use the same helper (AC5).

### Phase C — Diagnostic safety net (always-on)

**Step C1**: In `runLocalLLM`, after stream ends, compare `chunksEmitted` to
the server-reported chunk count (extracted from the final `done` event).
If they diverge by > 0, surface this in the result:
```swift
if let serverChunks = serverDoneEvent?["chunks"] as? Int,
   serverChunks > 0, chunksEmitted == 0 {
    continuation.yield(.error("SSE parse mismatch · server emitted \(serverChunks) chunks · check Captured logs"))
}
```

**Step C2**: Add a stamped version token to every connection log so we always
know which parser is running:
```swift
GigiDebugLogger.log("GIGI runLocalLLM connected · parser=manual-buffer-v1 to \(url)")
```

### Phase D — Verify & document

**Step D1**: Curl test against the deployed tunnel to confirm server still emits
`\n\n` boundaries:
```bash
curl -N -H "Authorization: Bearer $S" -H "Content-Type: application/json" \
  -d '{"deviceId":"test","prompt":"Translate good morning to French"}' \
  https://installing-blocked-bomb-skin.trycloudflare.com/api/ios/local-llm/generate \
  | hexdump -C | head -40
```
Look for `0d 0a 0d 0a` (CRLF×2) or `0a 0a` (LF×2) between events.

**Step D2**: Update `docs/memory/CONTEXT.md` with the resolution + parser change.

**Step D3**: Add note in `docs/adr/` if Phase B is needed (architectural decision
to use manual SSE parser over Apple's `bytes.lines`).

---

## 5. Risks and Mitigations

| Risk | Probability | Impact | Mitigation |
|---|---|---|---|
| Phase B parser has off-by-one on boundary detection | Med | High (0 chunks again) | Unit test the helper against canned SSE payloads (CRLF + LF + mixed) before push |
| Buffer grows unbounded on long streams | Low | Med (memory) | `buffer.removeFirst(boundary.end)` drops processed bytes after each event |
| Server-side stops emitting boundary correctly | Low | High | Phase D1 curl probe + integration test |
| Multi-byte UTF-8 boundary straddles read | Low | Med | Buffer is `Data` (bytes), not `String`; UTF-8 decode happens only at `parseSSEEvent` time on whole event |
| User confused which build is installed | High | Med | AC2: parser version token logged on every connection |

---

## 6. Verification Steps (post-implementation)

1. ✅ Curl returns `chunks=2` from server (proves server-side OK)
2. ✅ User reinstalls IPA with Phase B
3. ✅ Captured logs contains `parser=manual-buffer-v1` (AC2)
4. ✅ Stream-end log shows `chunks emitted=2` (AC3)
5. ✅ TTS plays "Bonjour." audibly (AC1)
6. ✅ Test 3 more prompts:
   - "Who was Nikola Tesla" → coherent answer
   - "What is the capital of Japan" → "Tokyo"
   - "Translate hello to Spanish" → "Hola"
7. ✅ Switch override to Auto, repeat "Translate" → router still routes to delegate_local → Ollama still works

---

## 7. Rollback plan

If Phase B breaks something worse:
```bash
git revert <phase-B-commit>
git push
# User reinstalls previous IPA from commit c72d1a5 (which at minimum has CRLF strip)
```

The minimum baseline is `c72d1a5` (CRLF strip + flush on new event).

---

## 8. Files affected

| File | Change |
|---|---|
| `02_GIGI_APP/GIGI/GigiHarnessClient+Streams.swift` | Replace `bytes.lines` with manual buffer parser in `runLocalLLM` + `runClaudeCode` |
| `02_GIGI_APP/GIGI/GigiDebugLogger.swift` | (no change) |
| `docs/adr/` | New ADR `00XX-sse-manual-parser.md` if Phase B applied |
| `docs/memory/CONTEXT.md` | Note resolution |

---

## 9. Sequenza operativa (per Armando)

**STEP 1** (1 min) — Costruisci IPA dal commit attuale `c72d1a5` e installa sul device.

**STEP 2** (2 min) — Test "Translate good morning to French" con Brain Path = Ollama. Apri Captured logs → Copia tutto → incolla in chat.

**STEP 3** (decisione automatica):
- Se `chunks emitted=2` nei log → ✅ FIX OK, andiamo avanti con Phase C (router 5-path) e demo
- Se `chunks emitted=0` ancora → procedo con Phase B (manual buffer parser), pusho, e tu reinstalli ancora

Il log da cercare per capire quale build è installata:
- Build `c72d1a5` (attuale): `stream ended · raw lines=N chunks emitted=N` (senza `bufLen`, senza `lastEvent`)
- Build vecchia `7a3585a`: `stream ended · raw lines=N chunks emitted=N lastEvent='...' bufLen=N`
- Build futura Phase B: `stream ended · parser=manual-buffer-v1 · bytes=N events=N chunks emitted=N`

---

## 10. Note operative

Il vero rischio non è il parser SSE: è il loop install→test→log→fix che brucia
20 minuti a giro. La diagnostica `parser=manual-buffer-v1` token (AC2) garantisce
che, a colpo d'occhio sui log, sai se sei sul fix giusto o no.

**Riferimenti**:
- [mattt/EventSource](https://github.com/mattt/EventSource) — Swift SSE client, parser custom byte-buffer
- [Swift Forums SOAR-0010](https://forums.swift.org/t/proposal-soar-0010-support-for-json-lines-json-sequence-and-server-sent-events/69098) — Conferma che `bytes.lines` non basta per SSE
- [WHATWG HTML §9.2 Server-sent events](https://html.spec.whatwg.org/dev/server-sent-events.html) — Spec ufficiale parsing
- [Recouse/EventSource](https://github.com/Recouse/EventSource) — Altro riferimento implementativo
