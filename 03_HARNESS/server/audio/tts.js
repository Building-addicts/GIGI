// tts.js
// Text-to-speech for channel responses.
// Supports OpenAI TTS API. Output format adapts per channel.

import { spawnSync } from 'node:child_process';

/**
 * Synthesize text to audio.
 * @param {string} text
 * @param {{ format?: 'mp3'|'ogg_opus', voice?: string, apiKey: string }} opts
 * @returns {Promise<Buffer>} audio buffer in requested format
 */
export async function synthesize(text, opts = {}) {
  const key = opts.apiKey;
  if (!key) throw new Error('TTS requires openai.api_key in config');

  const voice = opts.voice || 'nova';
  const format = opts.format || 'mp3';

  const resp = await fetch('https://api.openai.com/v1/audio/speech', {
    method: 'POST',
    headers: {
      Authorization: `Bearer ${key}`,
      'Content-Type': 'application/json',
    },
    body: JSON.stringify({
      model: 'tts-1',
      input: text,
      voice,
      response_format: 'mp3',  // always request mp3, convert below if needed
    }),
  });

  if (!resp.ok) {
    const body = await resp.text().catch(() => '');
    throw new Error(`TTS API ${resp.status}: ${body.slice(0, 300)}`);
  }

  const mp3Buffer = Buffer.from(await resp.arrayBuffer());

  if (format === 'ogg_opus') {
    return convertToOggOpus(mp3Buffer);
  }
  return mp3Buffer;
}

/**
 * Convert MP3 buffer to OGG Opus (required by Telegram sendVoice).
 */
function convertToOggOpus(mp3Buffer) {
  const result = spawnSync('ffmpeg', [
    '-y',
    '-f', 'mp3', '-i', 'pipe:0',
    '-c:a', 'libopus',
    '-b:a', '32k',
    '-f', 'ogg',
    'pipe:1',
  ], {
    input: mp3Buffer,
    maxBuffer: 16 * 1024 * 1024,
    timeout: 20_000,
  });

  if (result.error) throw new Error(`ffmpeg ogg convert error: ${result.error.message}`);
  if (result.status !== 0) {
    const stderr = result.stderr?.toString() ?? '';
    throw new Error(`ffmpeg ogg exit ${result.status}: ${stderr.slice(-300)}`);
  }
  return result.stdout;
}
