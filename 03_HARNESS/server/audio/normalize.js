// normalize.js
// Converts audio buffers to 16kHz mono WAV PCM16 using ffmpeg.
// Required before sending to Whisper STT.

import { spawnSync } from 'node:child_process';

/**
 * Normalize audio to 16kHz mono WAV PCM16.
 * @param {Buffer} inputBuffer
 * @param {string} [inputFormat] - hint like 'ogg', 'mp3', 'aac' (optional, ffmpeg auto-detects)
 * @returns {Buffer} WAV PCM16 buffer
 */
export function normalize(inputBuffer, inputFormat = 'pipe') {
  const args = [
    '-y',
    '-f', inputFormat === 'pipe' ? 'pipe:0' : inputFormat,
    '-i', 'pipe:0',
    '-ar', '16000',
    '-ac', '1',
    '-f', 'wav',
    '-acodec', 'pcm_s16le',
    'pipe:1',
  ];

  const result = spawnSync('ffmpeg', args, {
    input: inputBuffer,
    maxBuffer: 32 * 1024 * 1024,
    timeout: 30_000,
  });

  if (result.error) throw new Error(`ffmpeg spawn error: ${result.error.message}`);
  if (result.status !== 0) {
    const stderr = result.stderr?.toString() ?? '';
    throw new Error(`ffmpeg exit ${result.status}: ${stderr.slice(-400)}`);
  }

  return result.stdout;
}
