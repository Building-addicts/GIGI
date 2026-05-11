// Ollama HTTP client — Phase 2 Path 3 (GATE 4).
//
// Wraps the local Ollama HTTP API (default http://127.0.0.1:11434).
//
// Tier-based model selection (read from config.json, override via Settings):
//   - lite     (RAM 4-8GB):   qwen3:4b
//   - standard (RAM 8-16GB):  qwen3:8b
//   - default  (RAM 16-32GB): qwen3:14b
//   - pro      (RAM 32GB+):   qwen3.6:27b
//
// AVOID qwen3.5:* family (Ollama tool calling broken, Issue ollama#14493).
//
// References:
//   docs/plans/frolicking-stargazing-pancake.md §3.2 + §7.Q1
//   docs/knowledge/llm-open-source-research.md §7
//   ADR-0010 (TBD) — Ollama as first-class Path 3

import { log } from '../logger.js';
// Shim for the older `logger.info/warn` calls we kept from the stub days.
const logger = {
  info: (msg, meta) => log(`[ollama] ${msg}`, meta || ''),
  warn: (msg, meta) => log(`[ollama][warn] ${msg}`, meta || ''),
  error: (msg, meta) => log(`[ollama][err] ${msg}`, meta || ''),
};

const DEFAULT_BASE_URL = process.env.OLLAMA_URL || 'http://127.0.0.1:11434';
const DEFAULT_TIMEOUT_MS = 5 * 60 * 1000; // 5min hard cap per request
const FIRST_BYTE_TIMEOUT_MS = 30 * 1000;  // 30s cold-load tolerance

export const OLLAMA_PHASE2_STUB = false;

// MARK: - OllamaClient class

export class OllamaClient {
  /**
   * @param {object} opts
   * @param {string} [opts.baseURL]
   * @param {number} [opts.timeoutMs]
   */
  constructor({ baseURL = DEFAULT_BASE_URL, timeoutMs = DEFAULT_TIMEOUT_MS } = {}) {
    this.baseURL = baseURL.replace(/\/+$/, '');
    this.timeoutMs = timeoutMs;
  }

  // ---------- discovery ----------

  /**
   * List installed models. Returns [] on error.
   * @returns {Promise<string[]>}
   */
  async listModels() {
    try {
      const res = await fetch(`${this.baseURL}/api/tags`);
      if (!res.ok) return [];
      const json = await res.json();
      return (json.models || []).map((m) => m.name);
    } catch (err) {
      logger?.warn?.('ollama_list_failed', { err: String(err) });
      return [];
    }
  }

  /**
   * Reachability + version probe.
   * @returns {Promise<{ok: boolean, version?: string, models?: string[]}>}
   */
  async isReachable() {
    try {
      const vRes = await fetch(`${this.baseURL}/api/version`);
      if (!vRes.ok) return { ok: false };
      const v = await vRes.json();
      const models = await this.listModels();
      return { ok: true, version: v.version, models };
    } catch {
      return { ok: false };
    }
  }

  // ---------- generation ----------

  /**
   * Streaming generation. Yields text chunks. Stops on error or signal abort.
   *
   * @param {object} opts
   * @param {string} opts.model
   * @param {string} opts.prompt
   * @param {AbortSignal} [opts.signal]
   * @param {boolean} [opts.think]
   * @returns {AsyncIterable<string>}
   */
  async *generate({ model, prompt, signal, think = false, system }) {
    const payload = { model, prompt, stream: true, think };
    if (system) payload.system = system;
    const body = JSON.stringify(payload);
    const url = `${this.baseURL}/api/generate`;

    const ctrl = new AbortController();
    const onAbort = () => ctrl.abort();
    signal?.addEventListener?.('abort', onAbort);
    const totalTimer = setTimeout(() => ctrl.abort(), this.timeoutMs);

    let firstByteTimer = setTimeout(() => ctrl.abort(), FIRST_BYTE_TIMEOUT_MS);

    let res;
    try {
      res = await fetch(url, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body,
        signal: ctrl.signal,
      });
    } catch (err) {
      clearTimeout(totalTimer);
      clearTimeout(firstByteTimer);
      throw new Error(`ollama_request_failed: ${err.message}`);
    }

    if (!res.ok) {
      clearTimeout(totalTimer);
      clearTimeout(firstByteTimer);
      throw new Error(`ollama_http_${res.status}: ${await res.text().catch(() => '')}`);
    }
    clearTimeout(firstByteTimer);

    const reader = res.body.getReader();
    const decoder = new TextDecoder();
    let buffer = '';

    try {
      while (true) {
        const { value, done } = await reader.read();
        if (done) break;
        buffer += decoder.decode(value, { stream: true });
        // Ollama emits JSON-lines, one per chunk.
        const lines = buffer.split('\n');
        buffer = lines.pop() || '';
        for (const line of lines) {
          if (!line.trim()) continue;
          try {
            const obj = JSON.parse(line);
            if (typeof obj.response === 'string' && obj.response.length > 0) {
              yield obj.response;
            }
            if (obj.error) {
              throw new Error(`ollama_runtime: ${obj.error}`);
            }
            if (obj.done) {
              // Stream finished cleanly
              return;
            }
          } catch (e) {
            if (e.message?.startsWith?.('ollama_')) throw e;
            // Otherwise: skip malformed line.
          }
        }
      }
    } finally {
      clearTimeout(totalTimer);
      signal?.removeEventListener?.('abort', onAbort);
    }
  }

  /**
   * Chat-format generation with optional tool_calling. Yields ChatEvent.
   * Note: tools rely on Ollama tool_calling support; qwen3:* works,
   * qwen3.5:* is BROKEN (Issue ollama#14493).
   *
   * @returns {AsyncIterable<{type: 'text_delta'|'tool_use'|'done', text?: string, name?: string, args?: object}>}
   */
  async *chat({ model, messages, tools = [], signal, think = false }) {
    const body = JSON.stringify({ model, messages, tools, stream: true, think });
    const url = `${this.baseURL}/api/chat`;

    const ctrl = new AbortController();
    const onAbort = () => ctrl.abort();
    signal?.addEventListener?.('abort', onAbort);
    const totalTimer = setTimeout(() => ctrl.abort(), this.timeoutMs);

    let res;
    try {
      res = await fetch(url, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body,
        signal: ctrl.signal,
      });
    } catch (err) {
      clearTimeout(totalTimer);
      throw new Error(`ollama_chat_failed: ${err.message}`);
    }
    if (!res.ok) {
      clearTimeout(totalTimer);
      throw new Error(`ollama_chat_http_${res.status}: ${await res.text().catch(() => '')}`);
    }

    const reader = res.body.getReader();
    const decoder = new TextDecoder();
    let buffer = '';

    try {
      while (true) {
        const { value, done } = await reader.read();
        if (done) break;
        buffer += decoder.decode(value, { stream: true });
        const lines = buffer.split('\n');
        buffer = lines.pop() || '';
        for (const line of lines) {
          if (!line.trim()) continue;
          try {
            const obj = JSON.parse(line);
            const msg = obj.message;
            if (msg?.tool_calls?.length) {
              for (const tc of msg.tool_calls) {
                yield {
                  type: 'tool_use',
                  name: tc.function?.name || tc.name,
                  args: tc.function?.arguments || tc.arguments,
                };
              }
            } else if (typeof msg?.content === 'string' && msg.content.length > 0) {
              yield { type: 'text_delta', text: msg.content };
            }
            if (obj.done) {
              yield { type: 'done' };
              return;
            }
          } catch (e) {
            // skip
          }
        }
      }
    } finally {
      clearTimeout(totalTimer);
      signal?.removeEventListener?.('abort', onAbort);
    }
  }

  // ---------- admin ----------

  /**
   * Pull a model. Yields progress updates.
   */
  async *pullModel(modelName) {
    const res = await fetch(`${this.baseURL}/api/pull`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ name: modelName, stream: true }),
    });
    if (!res.ok) throw new Error(`ollama_pull_http_${res.status}`);
    const reader = res.body.getReader();
    const decoder = new TextDecoder();
    let buffer = '';
    while (true) {
      const { value, done } = await reader.read();
      if (done) break;
      buffer += decoder.decode(value, { stream: true });
      const lines = buffer.split('\n');
      buffer = lines.pop() || '';
      for (const line of lines) {
        if (!line.trim()) continue;
        try {
          yield JSON.parse(line);
        } catch {
          // skip
        }
      }
    }
  }
}

// MARK: - Default singleton

let _defaultClient = null;
export function getDefaultOllamaClient() {
  if (!_defaultClient) _defaultClient = new OllamaClient();
  return _defaultClient;
}

export default OllamaClient;
