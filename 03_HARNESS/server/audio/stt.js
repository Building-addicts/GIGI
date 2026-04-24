// stt.js
// Batch STT via Groq Whisper API (same key used for the brain model).
// Falls back to OpenAI Whisper if groq key not available.

import { normalize } from './normalize.js';

/**
 * Transcribe audio buffer to text.
 * @param {Buffer} audioBuffer
 * @param {string} [mimeType] - original MIME type hint (unused, normalized to WAV)
 * @param {{ language?: string, apiKey?: string, groqApiKey?: string }} [opts]
 * @returns {Promise<{ transcript: string, durationMs: number }>}
 */
export async function transcribe(audioBuffer, mimeType = 'audio/ogg', opts = {}) {
  const t0 = Date.now();

  let wavBuffer;
  try {
    wavBuffer = normalize(audioBuffer);
  } catch (e) {
    throw new Error(`Audio normalization failed: ${e.message}`);
  }

  // Prefer Groq (same key already in config), fall back to OpenAI
  const groqKey = opts.groqApiKey;
  const openaiKey = opts.apiKey;
  const key = groqKey || openaiKey;
  if (!key) throw new Error('No STT API key configured (groq.api_key or openai.api_key)');

  const baseUrl = groqKey
    ? 'https://api.groq.com/openai/v1/audio/transcriptions'
    : 'https://api.openai.com/v1/audio/transcriptions';

  const formData = new FormData();
  formData.append('file', new Blob([wavBuffer], { type: 'audio/wav' }), 'audio.wav');
  formData.append('model', groqKey ? 'whisper-large-v3' : 'whisper-1');
  if (opts.language) formData.append('language', opts.language);

  const resp = await fetch(baseUrl, {
    method: 'POST',
    headers: { Authorization: `Bearer ${key}` },
    body: formData,
  });

  if (!resp.ok) {
    const body = await resp.text().catch(() => '');
    throw new Error(`STT API ${resp.status}: ${body.slice(0, 300)}`);
  }

  const json = await resp.json();
  const transcript = (json.text || '').trim();
  return { transcript, durationMs: Date.now() - t0 };
}
