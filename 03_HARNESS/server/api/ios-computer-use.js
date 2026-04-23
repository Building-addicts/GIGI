// Computer-use via Anthropic Claude con tool computer_20241022.
// In fase 12 implementiamo solo il contratto (job enqueue, status, confirm).
// Il loop completo arriva in fase 14 (vedi PIANO §14).
import { randomUUID } from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';
import { LOGS_DIR } from '../paths.js';
import { log } from '../logger.js';

const JOBS_FILE = path.join(LOGS_DIR, 'computer_use_jobs.json');

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

export async function handleStart(req, res, deps) {
  const { readBody, sendJson } = deps;
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
    status: 'pending', // pending | running | awaiting_confirm | done | failed | cancelled
    created_at: Date.now(),
    updated_at: Date.now(),
    steps: [],
    confirm_required: null,
    result: null
  };
  putJob(job);
  log('computer-use job created', id, 'for', deviceId, '— implementazione loop in fase 14');
  return sendJson(res, 202, { ok: true, data: { jobId: id, status: job.status, note: 'loop completo in fase 14 — job registrato ma non eseguito' } });
}

export async function handleStatus(req, res, deps) {
  const { sendJson } = deps;
  const url = new URL(req.url, `http://${req.headers.host}`);
  const id = url.pathname.split('/').pop();
  const all = loadJobs();
  const job = all[id];
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
  const all = loadJobs();
  const job = all[id];
  if (!job) return sendJson(res, 404, { ok: false, error: { code: 'NOT_FOUND', message: 'job non trovato' } });
  if (job.status !== 'awaiting_confirm') {
    return sendJson(res, 409, { ok: false, error: { code: 'WRONG_STATE', message: `job in stato ${job.status}` } });
  }
  job.confirm_response = { approved: !!body.approved, at: Date.now() };
  job.status = body.approved ? 'pending' : 'cancelled';
  job.updated_at = Date.now();
  putJob(job);
  return sendJson(res, 200, { ok: true, data: { jobId: id, status: job.status, note: 'resume loop — implementato in fase 14' } });
}
