// iOS local-LLM endpoint (stub — Phase 2)
//
// REST + WebSocket bridge between iOS app and harness Ollama (Path 3).
// Mounted under /api/ios/local-llm/* by ios-router.js when Phase 2 lands.
//
// Reference: docs/plans/frolicking-stargazing-pancake.md §3.2
// ADR-0010 (TBD) — Ollama as first-class Path 3

// TODO Phase 2: implement
//
//   POST /api/ios/local-llm/generate
//     body: { prompt, model?, think?, sessionId? }
//     -> streams chunks via SSE (text/event-stream)
//
//   GET  /api/ios/local-llm/status
//     -> { reachable: bool, models: [...], current_tier: "default" }
//
//   POST /api/ios/local-llm/cancel
//     body: { sessionId }
//     -> { cancelled: bool }
//
// Auth: same Bearer middleware as ios-router (ios-auth.js).
// Streaming: server-sent events (SSE) — iOS uses URLSession streaming, not WS.
// Cancel: AbortController per sessionId, propagated to ollama-client.

import express from 'express';

export const router = express.Router();

router.all('*', (_req, res) => {
  res.status(501).json({
    error: 'Not implemented',
    phase: 'Phase 2 stub',
    plan: 'docs/plans/frolicking-stargazing-pancake.md §3.2',
  });
});

export default router;
