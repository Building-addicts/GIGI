# ADR-0013: Manual byte-buffer SSE parser instead of URLSession.bytes.lines

- **Status:** Accepted
- **Date:** 2026-05-12
- **Deciders:** @ArmandoBattaglino, Claude
- **Tags:** ios, networking, sse, path-3-ollama, path-4-claude-code

## Context

Path 3 (Ollama via harness) and Path 4 (Claude Code via harness) both stream
responses to the iOS app as Server-Sent Events over Cloudflare Tunnel. The
initial implementation in `GigiHarnessClient+Streams.swift` used Apple's
idiomatic `for try await line in bytes.lines` (where `bytes` is
`URLSession.AsyncBytes` and `.lines` is `AsyncLineSequence`).

In production this produced a hard 100% failure: `chunks emitted=0` on every
call. Server-side curl confirmed the harness emitted spec-compliant SSE
(`event: chunk\ndata: {...}\n\n`). Three reinstall cycles with progressively
more diagnostic logging showed:

1. Cloudflare Tunnel re-encodes line endings to CRLF (`\r\n`).
2. Apple's `AsyncLineSequence` silently coalesces consecutive line terminators
   on CRLF streams — the empty SSE separator line was never yielded.
3. Without the empty-line delimiter, the parser never knew when one event
   ended, so `dispatchSSE` was never called → `chunks=0` → user heard
   "Ollama returned no answer."

Mitigation attempts that did not resolve the issue:
- Stripping trailing `\r` from each `rawLine` (commit `7a3585a`)
- Flushing the pending event on every new `event:` header instead of waiting
  for an empty line (commit `c72d1a5`)

Both fixes were sound in isolation but masked the deeper problem: `bytes.lines`
is not designed for SSE. The community confirms this — `mattt/EventSource`,
the de-facto Swift SSE library, uses a manual byte-buffer parser. Swift
Forums proposal [SOAR-0010](https://forums.swift.org/t/proposal-soar-0010-support-for-json-lines-json-sequence-and-server-sent-events/69098)
exists specifically because community SSE implementations on top of
`bytes.lines` are fragile.

## Decision

We replace `URLSession.bytes.lines` with a manual byte-buffer parser in both
`runLocalLLM` and `runClaudeCode`. The parser:

1. Iterates raw `UInt8` bytes from `URLSession.AsyncBytes`.
2. Accumulates into a `[UInt8]` buffer.
3. After each byte, checks the buffer tail for an SSE event boundary —
   `LF×2` (`0x0A 0x0A`) or `CRLF×2` (`0x0D 0x0A 0x0D 0x0A`).
4. On boundary: extracts the event bytes, dispatches via a shared
   `parseSSEEvent(_:)` helper (spec-compliant: handles LF/CRLF mix, multi-line
   `data:` accumulation, ignores comment lines), clears the buffer, continues.
5. On stream end: flushes any trailing event without a terminating boundary.

The implementation stamps `parser=manual-buffer-v1` in the connection log and
the stream-end log so the running binary can be identified at-a-glance from
Captured GIGI logs in Settings → 🔧 Debug.

## Alternatives considered

- **A — Adopt `mattt/EventSource` as a dependency**: would solve the bug but
  adds an SPM/Carthage dependency to a critical path and is overkill for two
  call sites. Rejected for scope creep + transitive dependency risk on an
  app targeting OSS release.
- **B — Keep `bytes.lines` and read-ahead one line to detect empty separator**:
  fragile — depends on undocumented buffering behavior of
  `AsyncLineSequence`. Rejected for being a workaround on top of a workaround.
- **C — Switch transport from SSE to WebSocket**: would bypass the bug but
  rewrites the server's `ios-local-llm.js` endpoint, breaks any non-iOS
  client, and is a deep change with 24h until demo. Rejected for cost.

## Consequences

### Positive
- Deterministic SSE parsing that matches the WHATWG spec (handles LF, CRLF,
  and mixed delimiters).
- No external dependency added.
- Identical parser shared between Path 3 (Ollama) and Path 4 (Claude Code)
  via `parseSSEEvent(_:)`.
- Diagnostic version token (`parser=manual-buffer-v1`) means future regressions
  can be diagnosed in seconds from one log line.

### Negative / Trade-off
- Byte-by-byte iteration is theoretically slower than line-by-line for very
  large payloads. In practice both paths stream ≤ a few KB per call, so the
  overhead is invisible. If a future Path streams MB-scale responses, we'd
  buffer in larger chunks (read N bytes per await iteration) before scanning.
- More code to maintain (~80 lines vs. ~30 with `bytes.lines`).

### Neutral / Note
- `parseSSEEvent(_:)` is `fileprivate` and only used internally — not a public
  API.
- If Apple eventually ships native SSE support (per SOAR-0010), we can replace
  this with the standard library version. Until then, this parser is the
  load-bearing component for Paths 3+4.

## References

- Plan: [`docs/plans/sse-ollama-deep-fix-2026-05-12.md`](../plans/sse-ollama-deep-fix-2026-05-12.md)
- Commits: `7a3585a` (CRLF strip), `c72d1a5` (flush on event:), `6a74842` (Phase B parser)
- ADR-0007 — Hybrid 5-path router (defines Paths 3 + 4 that depend on this parser)
- ADR-0010 — Ollama as first-class path
- External: [mattt/EventSource](https://github.com/mattt/EventSource)
- External: [Swift Forums SOAR-0010 SSE proposal](https://forums.swift.org/t/proposal-soar-0010-support-for-json-lines-json-sequence-and-server-sent-events/69098)
- External: [WHATWG HTML §9.2 Server-sent events](https://html.spec.whatwg.org/dev/server-sent-events.html)
