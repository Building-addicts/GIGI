// Computer-use: loop Anthropic Claude con tool computer_20241022.
// iOS POST /api/ios/computer-use { deviceId, task } → enqueue job, risposta 202.
// Loop background:
//   1. lease istanza browser (browser-pool/driver.js)
//   2. screenshot 1280×800 JPEG q70
//   3. claude.messages.create con tool computer_20241022 + screenshot
//   4. esegui ogni tool_use (click/type/key/screenshot/navigate)
//   5. loop fino a "end_turn" senza tool oppure max 20 step / 2min
//   6. CONFIRM_REQUIRED regex (checkout, totale €/$, pay, conferma)
//      → pausa, broadcast "awaiting_confirm", attesa POST /confirm
//      → se approved=true, riprende con "utente ha confermato"
//      → se approved=false, cancella job
//   7. rilascia lease, salva cost (prompt_tokens, output_tokens, $ stima)
//
// Stato job serializzato in logs/computer_use_jobs.json.
import { randomUUID } from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';
import Anthropic from '@anthropic-ai/sdk';
import { LOGS_DIR } from '../paths.js';
import { log } from '../logger.js';
import { lease, release, openSession } from '../../browser-pool/driver.js';
import { broadcast } from './ios-stream.js';

const JOBS_FILE = path.join(LOGS_DIR, 'computer_use_jobs.json');
const COST_FILE = path.join(LOGS_DIR, 'cost_tracking.json');
const MAX_STEPS = 20;
const TIMEOUT_MS = 2 * 60 * 1000;

const CONFIRM_PATTERNS = [
  /(?:totale|total|importo|amount|subtotal|grand\s*total)[^\d]{0,10}[€$£]\s*\d+(?:[.,]\d{2})?/i,
  /[€$£]\s*\d+(?:[.,]\d{2})?[^\d]{0,20}(?:paga|pay\b|checkout|confirm|conferm[ao])/i,
  /\b(?:conferma\s+(?:ordine|pagamento|acquisto)|place\s+order|pay\s+now|complete\s+purchase)\b/i
];

// Input token/output token placeholder prezzi Claude Opus 4.7
const PRICE_IN_PER_MTOK = 15.0;
const PRICE_OUT_PER_MTOK = 75.0;

function loadJobs() {
  try { return JSON.parse(fs.readFileSync(JOBS_FILE, 'utf8')); } catch { return {}; }
}
function saveJobs(j) {
  try { fs.writeFileSync(JOBS_FILE, JSON.stringify(j, null, 2)); } catch {}
}
function putJob(job) {
  const all = loadJobs();
  all[job.id] = job;
  saveJobs(all);
}
function getJob(id) {
  const all = loadJobs();
  return all[id] || null;
}

function appendCost(entry) {
  let arr;
  try { arr = JSON.parse(fs.readFileSync(COST_FILE, 'utf8')); } catch { arr = []; }
  arr.push(entry);
  if (arr.length > 1000) arr = arr.slice(-1000);
  try { fs.writeFileSync(COST_FILE, JSON.stringify(arr, null, 2)); } catch {}
}

function updateJob(id, patch) {
  const j = getJob(id);
  if (!j) return null;
  Object.assign(j, patch, { updated_at: Date.now() });
  putJob(j);
  broadcast(j.deviceId, { type: 'computer_use_update', jobId: id, ...patch });
  return j;
}

function matchesConfirm(text) {
  if (!text) return null;
  for (const pat of CONFIRM_PATTERNS) {
    const m = pat.exec(text);
    if (m) return m[0];
  }
  return null;
}

async function executeToolCall(session, input) {
  const action = input?.action;
  switch (action) {
    case 'screenshot': {
      const s = await session.screenshot();
      return { type: 'image', image: s.buffer.toString('base64'), media_type: s.mimeType };
    }
    case 'left_click':
    case 'mouse_move': {
      const [x, y] = input.coordinate || [0, 0];
      if (action === 'left_click') await session.click(x, y); else await session.moveMouse(x, y);
      return { type: 'text', text: `${action} at ${x},${y}` };
    }
    case 'double_click': {
      const [x, y] = input.coordinate || [0, 0];
      await session.doubleClick(x, y);
      return { type: 'text', text: `double_click at ${x},${y}` };
    }
    case 'right_click': {
      const [x, y] = input.coordinate || [0, 0];
      await session.rightClick(x, y);
      return { type: 'text', text: `right_click at ${x},${y}` };
    }
    case 'type':
      await session.type(String(input.text || ''));
      return { type: 'text', text: `typed ${String(input.text || '').length} chars` };
    case 'key':
      await session.key(String(input.text || 'Enter'));
      return { type: 'text', text: `key ${input.text}` };
    case 'scroll': {
      await session.scroll(input.scroll_direction || 'down', input.scroll_amount || 500);
      return { type: 'text', text: `scroll ${input.scroll_direction}` };
    }
    default:
      return { type: 'text', text: `action non supportata: ${action}` };
  }
}

async function runLoop(job, cfg) {
  const apiKey = process.env.ANTHROPIC_API_KEY || cfg?.anthropic?.api_key;
  if (!apiKey || apiKey.startsWith('sk-ant-... ')) {
    return updateJob(job.id, { status: 'failed', error: 'ANTHROPIC_API_KEY non configurata' });
  }
  const anthropic = new Anthropic({ apiKey });
  let currentLease = null;
  let session = null;

  try {
    updateJob(job.id, { status: 'running' });
    currentLease = await lease({ app: 'ios-computer-use', taskId: job.id });
    session = await openSession(currentLease.cdp_url);
    updateJob(job.id, { browser_instance: currentLease.instance });

    const systemPrompt = `Sei GIGI, assistente personale di Leonardo. Esegui il task sul browser con prudenza. Task: ${job.task}. Scatta screenshot prima di ogni azione complessa. Se arrivi a una pagina di conferma pagamento o checkout con importo visibile, FERMATI e rispondi in testo "CONFIRM_REQUIRED: <descrizione breve>" senza cliccare; sarà Leonardo ad approvare manualmente.`;

    const messages = [
      { role: 'user', content: [{ type: 'text', text: job.task }] }
    ];

    const startedAt = Date.now();
    let totalIn = 0, totalOut = 0;

    for (let step = 0; step < MAX_STEPS; step++) {
      if (Date.now() - startedAt > TIMEOUT_MS) {
        return updateJob(job.id, { status: 'failed', error: `timeout dopo ${step} step` });
      }
      const current = getJob(job.id);
      if (current?.status === 'cancelled') return;

      const resp = await anthropic.messages.create({
        model: cfg?.claude?.model || 'claude-opus-4-7',
        max_tokens: 4096,
        system: systemPrompt,
        tools: [{ type: 'computer_20241022', name: 'computer', display_width_px: 1280, display_height_px: 800, display_number: 1 }],
        messages,
        betas: ['computer-use-2024-10-22']
      }).catch(e => ({ _error: e.message }));

      if (resp._error) return updateJob(job.id, { status: 'failed', error: `anthropic: ${resp._error}` });

      totalIn += resp.usage?.input_tokens || 0;
      totalOut += resp.usage?.output_tokens || 0;

      const content = resp.content || [];
      const stepEntry = { step, at: Date.now(), text: '', actions: [] };

      // Check CONFIRM_REQUIRED in any text output
      for (const block of content) {
        if (block.type === 'text' && block.text) {
          stepEntry.text += block.text + '\n';
          const hit = /CONFIRM_REQUIRED:\s*(.+)/i.exec(block.text) || (matchesConfirm(await session.text()) ? ['CONFIRM_REQUIRED', 'pattern prezzo/checkout'] : null);
          if (hit) {
            updateJob(job.id, {
              status: 'awaiting_confirm',
              confirm_required: { reason: hit[1] || String(hit[0]), at: Date.now() },
              steps: [...(job.steps || []), stepEntry]
            });
            // Wait polling per confirm response
            const waitStart = Date.now();
            while (Date.now() - waitStart < 10 * 60 * 1000) {
              const c = getJob(job.id);
              if (c?.status === 'cancelled') return;
              if (c?.confirm_response) {
                if (!c.confirm_response.approved) {
                  return updateJob(job.id, { status: 'cancelled', error: 'confirm denied by user' });
                }
                messages.push({ role: 'assistant', content });
                messages.push({ role: 'user', content: [{ type: 'text', text: 'Utente ha confermato. Prosegui con il checkout.' }] });
                break;
              }
              await new Promise(r => setTimeout(r, 1500));
            }
            break;
          }
        }
      }

      // Collect tool uses
      const toolUses = content.filter(c => c.type === 'tool_use');
      if (!toolUses.length) {
        // End of turn, return result
        const finalText = content.filter(c => c.type === 'text').map(c => c.text).join('\n').trim() || '(nessun testo)';
        updateJob(job.id, {
          status: 'done',
          result: finalText,
          steps: [...(job.steps || []), stepEntry],
          tokens: { in: totalIn, out: totalOut }
        });
        appendCost({ jobId: job.id, deviceId: job.deviceId, task: job.task.slice(0, 120), tokens: { in: totalIn, out: totalOut }, usd: (totalIn * PRICE_IN_PER_MTOK + totalOut * PRICE_OUT_PER_MTOK) / 1e6, at: Date.now() });
        return;
      }

      messages.push({ role: 'assistant', content });

      const toolResults = [];
      for (const tu of toolUses) {
        const r = await executeToolCall(session, tu.input || {});
        stepEntry.actions.push({ action: tu.input?.action, ok: true });
        toolResults.push({
          type: 'tool_result',
          tool_use_id: tu.id,
          content: r.type === 'image'
            ? [{ type: 'image', source: { type: 'base64', media_type: r.media_type, data: r.image } }]
            : [{ type: 'text', text: r.text || 'ok' }]
        });
      }
      messages.push({ role: 'user', content: toolResults });
      const j2 = getJob(job.id) || job;
      updateJob(job.id, { steps: [...(j2.steps || []), stepEntry] });
    }

    updateJob(job.id, { status: 'failed', error: `max step raggiunti (${MAX_STEPS})`, tokens: { in: totalIn, out: totalOut } });
  } catch (e) {
    log('computer-use loop error:', e.message);
    updateJob(job.id, { status: 'failed', error: e.message });
  } finally {
    try { if (session) await session.close(); } catch {}
    try { if (currentLease) await release(currentLease.task_id); } catch {}
  }
}

export async function handleStart(req, res, deps) {
  const { readBody, sendJson, cfg } = deps;
  let body;
  try { body = JSON.parse(await readBody(req) || '{}'); }
  catch { return sendJson(res, 400, { ok: false, error: { code: 'BAD_JSON', message: 'body non JSON' } }); }
  const deviceId = String(body.deviceId || '').trim();
  const task = String(body.task || '').trim();
  if (!deviceId) return sendJson(res, 400, { ok: false, error: { code: 'MISSING_DEVICE', message: 'deviceId mancante' } });
  if (!task) return sendJson(res, 400, { ok: false, error: { code: 'MISSING_TASK', message: 'task mancante' } });

  const id = randomUUID();
  const job = {
    id, deviceId, task,
    status: 'pending',
    created_at: Date.now(),
    updated_at: Date.now(),
    steps: [],
    confirm_required: null,
    confirm_response: null,
    result: null
  };
  putJob(job);
  log('computer-use job', id, 'start for', deviceId);
  // Kick off loop in background
  runLoop(job, cfg).catch(e => {
    log('computer-use runLoop error:', e.message);
    updateJob(id, { status: 'failed', error: e.message });
  });
  return sendJson(res, 202, { ok: true, data: { jobId: id, status: job.status } });
}

export async function handleStatus(req, res, deps) {
  const { sendJson } = deps;
  const url = new URL(req.url, `http://${req.headers.host}`);
  const id = url.pathname.split('/').pop();
  const job = getJob(id);
  if (!job) return sendJson(res, 404, { ok: false, error: { code: 'NOT_FOUND', message: 'job non trovato' } });
  return sendJson(res, 200, { ok: true, data: job });
}

export async function handleConfirm(req, res, deps) {
  const { readBody, sendJson } = deps;
  const m = req.url.match(/\/api\/ios\/computer-use\/([^/]+)\/confirm/);
  const id = m ? decodeURIComponent(m[1]) : null;
  if (!id) return sendJson(res, 400, { ok: false, error: { code: 'MISSING_ID', message: 'jobId mancante' } });
  let body;
  try { body = JSON.parse(await readBody(req) || '{}'); }
  catch { return sendJson(res, 400, { ok: false, error: { code: 'BAD_JSON', message: 'body non JSON' } }); }
  const job = getJob(id);
  if (!job) return sendJson(res, 404, { ok: false, error: { code: 'NOT_FOUND', message: 'job non trovato' } });
  if (job.status !== 'awaiting_confirm') {
    return sendJson(res, 409, { ok: false, error: { code: 'WRONG_STATE', message: `job in stato ${job.status}` } });
  }
  job.confirm_response = { approved: !!body.approved, at: Date.now() };
  // Il loop polling rileva il change e riprende
  putJob(job);
  return sendJson(res, 200, { ok: true, data: { jobId: id, status: job.status, approved: !!body.approved } });
}
