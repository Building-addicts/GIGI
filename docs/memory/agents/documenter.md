# documenter — session memory

## 2026-04-24 · Claude Bridge P1.1/P1.2/P1.3 doc sweep

**Trigger**: P1.1 (commit `0a8316d`), P1.2 + P1.3 (commit `a400500`) completed.
Files modified by upstream agents:
- `02_GIGI_APP/GIGI/GigiConversationMemory.swift` — Role enum now 4 cases; new `addThought`, `addToolEvent`, `updateToolEvent`; filtered out of `contextString` and `trimIfNeeded`.
- `02_GIGI_APP/GIGI/ChatView.swift` — `MessageBubble` switches on role; two new views `thoughtLine` (italic grey `💭`) and `toolEventLine` (gear icon).
- `02_GIGI_APP/GIGI/GigiClaudeBridge.swift` — NEW file, `@MainActor` singleton, stub `run(task:context:)`, working `buildContextSnapshot()` (≤8 KB profile + calendar via `ReadWeekCalendarTool` + top memories).

**Audit findings**
- Root `CLAUDE.md` — UP_TO_DATE (no code-shape claims)
- `03_HARNESS/CLAUDE.md` — UP_TO_DATE (no Swift-side claims)
- `00_DOCS/ARCHITETTURA_V3.md` — STALE: file tree (§18) didn't list Bridge/, `ChatView.swift` marked "invariato"; `GigiConversationMemory` section (§11) didn't mention the new Role cases. Fixed.
- `03_HARNESS/docs/api/ios-integration.md` §5 — **IMPORTANT GAP**: spec says `claude_event.event` is raw Claude CLI JSONL (confirmed via grep on `ios-agent.js:35` — just forwards `ev` untouched). The P1.4 task expects a normalized envelope with `type ∈ {thought, tool_start, tool_result, speech, done}`. This normalization is NOT currently implemented server-side. Flagged inline in the spec AND in `DOC_STATUS.md` Stale Sections. Recommended: normalize in `ios-agent.js` before broadcast (single source of truth).
- Inline Swift doc comments on the 3 modified files — already thorough and unambiguous, no tweaks.

**Artifacts produced**
- Edited: `00_DOCS/ARCHITETTURA_V3.md` (2 surgical inserts)
- Edited: `03_HARNESS/docs/api/ios-integration.md` (§5 gap callout)
- Created: `docs/memory/DOC_STATUS.md`
- Updated: `docs/memory/ACTIVITY_LOG.md`

**Open doc-debt for future passes**
- Full `ARCHITETTURA_V3.md` audit (1866 lines, predates Claude Bridge + energy refactor + APNS)
- No build/run `README.md` at `02_GIGI_APP/GIGI/` level
- Decide final shape of `claude_event.event` (normalized vs raw) and update spec accordingly — probably tracked against P1.4 close-out.

**Decision log**
- Did NOT create English-language `docs/ARCHITECTURE.md` / `docs/API.md` duplicates. Italian originals (`00_DOCS/ARCHITETTURA_V3.md`, `03_HARNESS/docs/api/ios-integration.md`) are the authoritative docs per user convention; creating English stubs would split truth.
- Did NOT touch `docs/plans/claude-bridge-integration.md` per user instruction (IMMUTABLE).
- Did NOT touch `docs/TASK_PLAN.md` — owned by project-manager (running in parallel).

---

## 2026-04-24 · Phase 4 (Tailscale + QR pairing) doc sweep

**Trigger**: Phase 4 P4.1-P4.8 completed in commit `ca8a599`. User asked for
targeted audit + low-effort updates, deferring high-effort work as task candidates.

**Scope** (per user instruction):
- Files to update: `00_DOCS/ARCHITETTURA_V3.md`, `03_HARNESS/docs/api/ios-integration.md`, root `CLAUDE.md`, `docs/memory/DOC_STATUS.md`.
- Do NOT rewrite `docs/plans/tailscale-qr-pairing.md` (source of truth).
- Do NOT write code comments (new files already thoroughly documented).

**Code changes reviewed** (12 files from commit):
- Backend: `03_HARNESS/server/api/pair.js` (NEW), `public/pair.html` (NEW), `panel-routes.js` (+11), `server.js` (+5), `package.json` (qrcode dep).
- iOS: `GigiPairScanner.swift` (NEW, VisionKit wrapper), `GigiPairingSheet.swift` (NEW, state machine), `SettingsView.swift` (harnessSection rewrite), `MainTabView.swift` (onboarding banner), `GigiClaudeBridge.swift` (error hints for 100.* URLs), `Info.plist` (NSCameraUsageDescription).

**Updates made**
- `00_DOCS/ARCHITETTURA_V3.md` — Added §9.TER "Pairing Flow (QR + Tailscale)" after §9.BIS. ASCII diagram of PC↔iPhone, 7-step flow narrative, security model table (loopback-only, Bearer bypass justification, CORS, rollback), component list, requirement-cross-reference to root `CLAUDE.md`. ~110 lines.
- `03_HARNESS/docs/api/ios-integration.md` — Added §10 "Pairing iOS (Tailscale + QR) — fase 4". Documents `GET /api/pair` with explicit callout that this is **the only route** bypassing Bearer, loopback-only security model explained with chicken-and-egg rationale, response shapes for JSON + SVG, error table (`LOOPBACK_ONLY`, `METHOD_NOT_ALLOWED`, `QR_FAIL`), client flow reference, file-level pointers to server handler + panel page + iOS scanner/sheet + design doc.
- Root `CLAUDE.md` — Added "Tailscale requirement (lato utente)" subsection under Dev/Test Infrastructure. User-side prerequisites only (install Tailscale on Windows + iOS, login same account, verify via `tailscale status`). Explicitly notes this is NOT dev workflow. LAN-only fallback mentioned.
- `docs/memory/DOC_STATUS.md` — Rewrote. New entries for `docs/plans/tailscale-qr-pairing.md` (IMMUTABLE), `server/api/pair.js` inline comments (UP_TO_DATE). Phase-4 updates logged in notes column. Task candidates section added (DOC-T1..T4) for follow-up passes.

**Findings**
- `03_HARNESS/CLAUDE.md` — no update needed; it's an index, not a spec, and doesn't claim anything about pairing that would drift.
- Inline code comments on `pair.js` top-of-file docblock already explain security model thoroughly. No tweaks.
- Swift new files (`GigiPairScanner`, `GigiPairingSheet`) verified to have meaningful comments on non-obvious logic (permission flow branches, rollback logic); no tweaks per user instruction.
- Design doc drift: `tailscale-qr-pairing.md` mentions `recentMemories(limit:)`; current code uses `recallAll(category:)`. Logged as Stale Section — not a fase-4 concern (memory subsystem, not pairing).

**Deferred (as task candidates in DOC_STATUS.md)**
- DOC-T1: full sweep of ARCHITETTURA_V3.md (2-3h, needs architect input).
- DOC-T2: resolve WebSocket envelope contract (carryover from P1.x).
- DOC-T3: audit `02_GIGI_APP/README_SETUP.md` for fase-4 UX.
- DOC-T4: create standalone root `README.md`.

**Decision log**
- Added §9.TER instead of renumbering — preserves stable anchor links.
  Noted in DOC_STATUS.md "Documentation Debt" that >5 N.BIS-style additions should trigger a v4 reorg.
- Chose to document `/api/pair` in its own §10 (not appended to §6 Health or §7 Keychain) because the Bearer-bypass exception is unique and deserves surface visibility.
- Updated root `CLAUDE.md` even though it's gitignored — it's the living dev context for the user and for future Claude Code sessions, per project convention.
