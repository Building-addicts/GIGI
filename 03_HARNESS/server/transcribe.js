// Trascrizione vocali via whisper.cpp locale (scoop-installed) + ffmpeg-static.
// Whisper-cli accetta wav/mp3/ogg, ma per sicurezza convertiamo l'OGG/Opus di Telegram in WAV 16kHz mono.
import { spawn } from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import ffmpegPath from 'ffmpeg-static';

const __dirname = path.dirname(fileURLToPath(import.meta.url));

const WHISPER_CLI = process.env.WHISPER_CLI || 'whisper-cli';
const DEFAULT_MODEL = process.env.WHISPER_MODEL || path.join(__dirname, 'whisper-models', 'ggml-small.bin');
const TMP_DIR = path.join(__dirname, 'logs', 'tmp-audio');
try { fs.mkdirSync(TMP_DIR, { recursive: true }); } catch {}

function runSpawn(cmd, args, opts = {}) {
  return new Promise((resolve) => {
    const child = spawn(cmd, args, { shell: false, windowsHide: true, ...opts });
    let stdout = '', stderr = '';
    child.stdout?.on('data', d => stdout += d.toString());
    child.stderr?.on('data', d => stderr += d.toString());
    child.on('error', err => resolve({ code: -1, stdout, stderr, error: err.message }));
    child.on('close', code => resolve({ code, stdout, stderr }));
  });
}

export async function downloadTelegramFile(token, fileId, destPath) {
  const r = await fetch(`https://api.telegram.org/bot${token}/getFile?file_id=${encodeURIComponent(fileId)}`);
  const data = await r.json();
  if (!data.ok) throw new Error(`getFile failed: ${JSON.stringify(data)}`);
  const filePath = data.result.file_path;
  const fileUrl = `https://api.telegram.org/file/bot${token}/${filePath}`;
  const res = await fetch(fileUrl);
  if (!res.ok) throw new Error(`download failed: ${res.status}`);
  const buf = Buffer.from(await res.arrayBuffer());
  fs.writeFileSync(destPath, buf);
  return { size: buf.length, original_ext: path.extname(filePath) };
}

export async function convertToWav16k(srcPath, wavPath) {
  const args = ['-y', '-i', srcPath, '-ar', '16000', '-ac', '1', '-c:a', 'pcm_s16le', wavPath];
  const r = await runSpawn(ffmpegPath, args);
  if (r.code !== 0) throw new Error(`ffmpeg failed: ${r.stderr.slice(-400)}`);
}

export async function transcribeWav(wavPath, opts = {}) {
  const model = opts.model || DEFAULT_MODEL;
  if (!fs.existsSync(model)) throw new Error(`modello whisper non trovato: ${model}`);
  // whisper-cli scrive il testo su stdout quando non si usa -otxt/-ojson/etc.
  // Per avere output pulito usiamo -otxt e leggiamo il .txt.
  const lang = opts.language || 'it';
  const threads = opts.threads || 4;
  const args = [
    '-m', model,
    '-l', lang,
    '-t', String(threads),
    '-nt', // no timestamps
    '-np', // no prints extra
    '-otxt', // output testo
    '-f', wavPath
  ];
  const r = await runSpawn(WHISPER_CLI, args);
  if (r.code !== 0) throw new Error(`whisper-cli failed: ${r.stderr.slice(-400)}`);
  // whisper-cli scrive il testo anche su stdout con -nt -np. Ci sono righe di status su stderr.
  // Inoltre crea <wav>.txt
  const txtPath = wavPath + '.txt';
  let text = '';
  if (fs.existsSync(txtPath)) {
    text = fs.readFileSync(txtPath, 'utf8').trim();
    try { fs.unlinkSync(txtPath); } catch {}
  } else {
    text = r.stdout.trim();
  }
  return text;
}

// Pipeline completa: file_id Telegram -> testo trascritto
export async function transcribeTelegramVoice(token, fileId, opts = {}) {
  const tag = `${Date.now()}-${Math.floor(Math.random()*1e6)}`;
  const rawPath = path.join(TMP_DIR, `${tag}.ogg`);
  const wavPath = path.join(TMP_DIR, `${tag}.wav`);
  try {
    await downloadTelegramFile(token, fileId, rawPath);
    await convertToWav16k(rawPath, wavPath);
    const text = await transcribeWav(wavPath, opts);
    return { text, tag };
  } finally {
    try { if (fs.existsSync(rawPath)) fs.unlinkSync(rawPath); } catch {}
    try { if (fs.existsSync(wavPath)) fs.unlinkSync(wavPath); } catch {}
  }
}

export function modelPath() { return DEFAULT_MODEL; }
export function modelExists() { return fs.existsSync(DEFAULT_MODEL); }
