# Documentation Status
_Last updated: 2026-04-24 after Phase 4 (Tailscale + QR pairing) commit `ca8a599`_

This file tracks the freshness of every `.md` that humans or agents are expected
to trust. Generated docs (`docs/memory/agents/*.md`, `ACTIVITY_LOG.md`,
`TASK_PLAN.md`) are excluded because the owning agent keeps them current.

## Status Legend
- UP_TO_DATE — matches current code
- PARTIAL — mostly current, known gaps noted in Stale Sections
- STALE — not yet updated for recent code changes
- MISSING — should exist but doesn't
- IMMUTABLE — source-of-truth plan, do not edit in maintenance passes

## Documentation Health

| Document | Status | Last Verified | Notes |
|---|---|---|---|
| `CLAUDE.md` (root) | UP_TO_DATE | 2026-04-24 | Dev/Test section now includes Tailscale requirement for pairing (user-side, not dev workflow) |
| `00_DOCS/ARCHITETTURA_V3.md` | PARTIAL | 2026-04-24 | New §9.TER "Pairing Flow (QR + Tailscale)" added for fase 4. Older sections (§5, §9.x) + Claude Bridge P1.x sections not re-audited in this pass |
| `00_DOCS/PIANO_INTEGRAZIONE_HARNESS.md` | UP_TO_DATE | 2026-04-23 | Phases 10-18 complete per `03_HARNESS/CLAUDE.md`; not touched in this pass |
| `00_DOCS/TASK_PLAN_V3.md` | UP_TO_DATE | 2026-04-23 | V3 roadmap; Phase 4 tracked separately in `docs/TASK_PLAN.md` |
| `03_HARNESS/CLAUDE.md` | UP_TO_DATE | 2026-04-24 | No Swift-side claims; harness internals match code. No pairing-specific updates needed (the file is an index, not a spec) |
| `03_HARNESS/README.md` | UNAUDITED | — | Not reviewed this pass |
| `03_HARNESS/docs/api/ios-integration.md` | PARTIAL | 2026-04-24 | New §10 "Pairing iOS (Tailscale + QR)" added for `GET /api/pair`, loopback-only, bypass Bearer. §5 WebSocket envelope drift from P1.4 still open (see Stale Sections) |
| `docs/plans/claude-bridge-integration.md` | IMMUTABLE | 2026-04-24 | Source-of-truth plan; do not edit |
| `docs/plans/tailscale-qr-pairing.md` | IMMUTABLE | 2026-04-24 | Source-of-truth plan for fase 4. Implementation in `ca8a599` matches the design. Minor drift: plan references `recentMemories(limit:)` which in code is `recallAll(category:)` — not relevant to pairing, noted for memory-subsystem follow-up |
| `docs/TASK_PLAN.md` | UP_TO_DATE | 2026-04-24 | Maintained by project-manager |
| `02_GIGI_APP/README_SETUP.md` | UNAUDITED | — | Not reviewed this pass |
| `INVENTARIO_COMPLETO.md` | UNAUDITED | — | Not reviewed this pass |
| Inline Swift doc comments (GigiPairScanner, GigiPairingSheet, MainTabView banner) | UP_TO_DATE | 2026-04-24 | Task-author wrote thorough comments on the new fase 4 files; verified clear and non-ambiguous |
| Inline Swift doc comments (GigiConversationMemory, ChatView, GigiClaudeBridge) | UP_TO_DATE | 2026-04-24 | Verified during P1.1-P1.3 pass |
| Inline JS comments (`03_HARNESS/server/api/pair.js`) | UP_TO_DATE | 2026-04-24 | Top-of-file docblock explains security model (loopback-only, why it bypasses Bearer) |

## Stale Sections (known gaps)

- **`03_HARNESS/docs/api/ios-integration.md` §5 "WebSocket streaming"** — the spec
  currently says `claude_event` wraps `event: { /* evento JSONL Claude CLI */ }`
  as an opaque passthrough. The iOS P1.4 work assumes a normalized envelope
  (`type=thought | tool_start | tool_result | speech | done` with `content` /
  `tool` fields). Confirmed by grep on `03_HARNESS/server/api/ios-agent.js`
  (line 35) and `ios-stream.js`: the server forwards raw Claude CLI JSONL and
  does NOT currently emit the normalized shape. **Action required**: either
  (a) add normalization in `ios-agent.js` before broadcast, OR (b) parse raw
  Claude CLI JSONL client-side in `GigiClaudeBridge`. Either way, the spec
  must document the final shape the app can rely on.
  _Carried over from 2026-04-24 Claude Bridge P1.x pass — unchanged by Phase 4._

- **`docs/plans/tailscale-qr-pairing.md` — `recentMemories(limit:)` reference**
  — the plan mentions a method `recentMemories(limit:)` that in the current
  code is handled by `recallAll(category:)`. Not a fase 4 issue (fase 4 is
  pairing, not memory). Flagged here so that whoever next touches the memory
  subsystem reconciles naming or adds a shim.

## Task candidates (follow-up documenter passes)

> High-effort doc work not completed in this pass. A future documenter or
> project-manager can pull these into `docs/TASK_PLAN.md`.

- **[DOC-T1] Full sweep of `00_DOCS/ARCHITETTURA_V3.md`** — 1866+ lines,
  pre-dates Claude Bridge, energy/wake-word refactor, APNS token sync,
  computer-use pipeline, AND now fase 4 pairing. §5, §9.x, §12 (Gemini Live)
  have drifted from code. Sweep would take 2-3h and needs architect input
  for §5 model definitions. Priority: LOW (plans + fase-specific sections
  are the live source of truth).

- **[DOC-T2] WebSocket envelope contract resolution** — pick option (a) or
  (b) from Stale Sections §5 above, implement, then update the spec. This
  is a code+doc change, not pure doc. Priority: MEDIUM (blocks Claude Bridge
  P2 when it starts relying on normalized events).

- **[DOC-T3] `02_GIGI_APP/README_SETUP.md` audit** — not touched since
  pre-fase-4 UX. Needs to be reviewed and likely point to the new QR pairing
  flow as primary setup path. Priority: LOW.

- **[DOC-T4] Standalone root `README.md`** — still missing. Describes "what
  is GIGI, how to build+run". Mac SSH workflow + Tailscale install requirement
  currently live only in `CLAUDE.md` (gitignored). Priority: LOW while
  single-developer; MEDIUM before any open-source release.

## Documentation Debt (structural)

- `00_DOCS/ARCHITETTURA_V3.md` accretes `§N.BIS`, `§N.TER` subsections
  (9.BIS for Harness, 9.TER for Pairing) instead of proper renumbering. This
  is intentional for now (preserves stable anchor links in commits/plans) but
  gets messier every phase. Consider a v4 reorg once 5+ N.BIS-style additions
  accumulate.
- No `docs/ARCHITECTURE.md` / `docs/API.md` at root per the standard
  documenter-agent template. Decision unchanged: the Italian-language
  `00_DOCS/ARCHITETTURA_V3.md` and the harness `docs/api/ios-integration.md`
  play those roles. Do NOT create English duplicates.
