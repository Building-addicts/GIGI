const $ = s => document.querySelector(s);
const $$ = s => document.querySelectorAll(s);
async function api(p, opts = {}) {
  const r = await fetch(p, { headers: { 'Content-Type': 'application/json' }, ...opts });
  return r.headers.get('content-type')?.includes('json') ? r.json() : r.text();
}

let cfg = null;

async function refreshStatus() {
  const s = await api('/api/status');
  const pill = $('#status-pill');
  if (s.running) {
    pill.textContent = `● attivo (pid ${s.pid})`;
    pill.className = 'status on';
  } else {
    pill.textContent = '○ fermo';
    pill.className = 'status off';
  }
  $('#card-running').textContent = s.running ? 'Attivo' : 'Fermo';
  $('#card-uptime').textContent = s.running
    ? `uptime ${formatDur(s.uptime_s)}`
    : 'avvia dal pulsante in alto';
  $('#card-reqs').textContent = s.requests;
  $('#card-last').textContent = s.last_request
    ? `ultima: ${timeAgo(s.last_request.time)} — "${s.last_request.text.slice(0, 60)}"`
    : 'nessuna';
  $('#card-errs').textContent = s.errors;
  $('#card-last-err').textContent = s.last_error
    ? `${timeAgo(s.last_error.time)} — ${s.last_error.text.slice(0, 80)}`
    : '—';
}

function formatDur(s) {
  if (s < 60) return `${s}s`;
  if (s < 3600) return `${Math.floor(s/60)}m ${s%60}s`;
  return `${Math.floor(s/3600)}h ${Math.floor((s%3600)/60)}m`;
}
function timeAgo(ts) {
  const d = Math.floor((Date.now() - ts)/1000);
  if (d < 60) return `${d}s fa`;
  if (d < 3600) return `${Math.floor(d/60)}m fa`;
  return `${Math.floor(d/3600)}h fa`;
}

async function loadConfig() {
  cfg = await api('/api/config');
  // Nuovo schema iOS-centric: cfg.ios.shared_secret, cfg.ios.allowed_device_ids, cfg.server.port
  cfg.ios = cfg.ios || {};
  cfg.server = cfg.server || {};
  $('#cfg-token').value = cfg.ios.shared_secret || '';
  $('#cfg-chats').value = (cfg.ios.allowed_device_ids || []).join('\n');
  $('#cfg-bin').value = cfg.claude.bin || '';
  $('#cfg-timeout').value = cfg.claude.timeout_ms || 600000;
  $('#cfg-sessmin').value = cfg.claude.session_timeout_minutes ?? 60;
  $('#cfg-live').checked = !!cfg.claude.show_live_window;
  $('#cfg-perm').value = cfg.claude.permission_mode || 'bypassPermissions';
  $('#cfg-sysprompt').value = cfg.claude.system_prompt || '';
  $('#cfg-port').value = cfg.server?.port || cfg.ui?.port || 7777;
}

async function saveConfig(silent = false) {
  cfg.ios = cfg.ios || {};
  cfg.server = cfg.server || {};
  cfg.ios.shared_secret = $('#cfg-token').value.trim();
  cfg.ios.allowed_device_ids = $('#cfg-chats').value.split('\n').map(s=>s.trim()).filter(Boolean);
  cfg.claude.bin = $('#cfg-bin').value.trim();
  cfg.claude.timeout_ms = parseInt($('#cfg-timeout').value, 10);
  cfg.claude.session_timeout_minutes = parseInt($('#cfg-sessmin').value, 10);
  cfg.claude.show_live_window = $('#cfg-live').checked;
  cfg.claude.permission_mode = $('#cfg-perm').value;
  cfg.claude.system_prompt = $('#cfg-sysprompt').value;
  cfg.server.port = parseInt($('#cfg-port').value, 10);
  delete cfg.telegram;
  delete cfg.ui;
  delete cfg.shortcuts;
  const r = await api('/api/config', { method: 'POST', body: JSON.stringify(cfg) });
  if (!silent) {
    $('#save-msg').textContent = r.ok ? '✓ salvato, riavvio bridge...' : 'errore: ' + r.error;
    await api('/api/bridge/restart', { method: 'POST' });
    setTimeout(() => { $('#save-msg').textContent = ''; refreshStatus(); }, 2000);
  }
}

async function refreshLogs() {
  const t = await api('/api/logs?lines=400');
  const box = $('#log-box');
  box.textContent = t || '(vuoto)';
  box.scrollTop = box.scrollHeight;
}

$$('.tab').forEach(b => {
  b.onclick = () => {
    $$('.tab').forEach(x => x.classList.remove('active'));
    b.classList.add('active');
    $$('.panel').forEach(p => p.classList.remove('active'));
    $(`#tab-${b.dataset.tab}`).classList.add('active');
    if (b.dataset.tab === 'logs') refreshLogs();
  };
});

$('#btn-start').onclick = async () => { await api('/api/bridge/start', { method:'POST' }); refreshStatus(); };
$('#btn-stop').onclick = async () => { await api('/api/bridge/stop', { method:'POST' }); refreshStatus(); };
$('#btn-restart').onclick = async () => { await api('/api/bridge/restart', { method:'POST' }); refreshStatus(); };
$('#btn-save').onclick = () => saveConfig(false);
$('#btn-log-refresh').onclick = refreshLogs;
$('#btn-log-clear').onclick = async () => { await api('/api/logs/clear', { method:'POST' }); refreshLogs(); };

async function refreshAutostart() {
  const r = await api('/api/autostart');
  const t = $('#autostart-toggle');
  t.checked = !!r.enabled;
  $('#autostart-label').textContent = r.enabled ? '✓ Attivo al login' : '○ Non attivo';
}
$('#autostart-toggle').onchange = async (e) => {
  const t = e.target;
  t.disabled = true;
  const r = await api('/api/autostart', { method:'POST', body: JSON.stringify({ enabled: t.checked }) });
  t.disabled = false;
  if (!r.ok) {
    alert('Errore: ' + (r.error || ''));
    t.checked = !t.checked;
  }
  refreshAutostart();
};

async function refreshBrowser() {
  const s = await api('/api/browser/status');
  const lbl = $('#browser-label');
  if (s.alive) {
    lbl.textContent = `✓ Attivo (CDP :${s.cdp_port}, uptime ${formatDur(s.uptime_s)})`;
  } else if (s.running) {
    lbl.textContent = '⚠ Processo avviato ma CDP non risponde';
  } else {
    lbl.textContent = '○ Non attivo';
  }
}
$('#btn-browser-start').onclick = async () => { await api('/api/browser/start', {method:'POST'}); setTimeout(refreshBrowser, 1500); };
$('#btn-browser-stop').onclick = async () => { await api('/api/browser/stop', {method:'POST'}); setTimeout(refreshBrowser, 500); };
$('#btn-term-open').onclick = async () => { await api('/api/terminal/open', {method:'POST'}); };
$('#btn-term-close').onclick = async () => { await api('/api/terminal/close', {method:'POST'}); };

async function refreshBrowsersGrid() {
  const list = await api('/api/browser/instances');
  const grid = $('#browsers-grid');
  if (!Array.isArray(list)) { grid.innerHTML = '<div class="sub">errore caricamento</div>'; return; }
  const bust = Date.now();
  grid.innerHTML = list.map(b => {
    const status = b.alive ? `<span class="status on">● alive</span>` : (b.running ? `<span class="status off">⚠ processo ma CDP giù</span>` : `<span class="status off">○ spento</span>`);
    const upt = b.uptime_s ? formatDur(b.uptime_s) : '—';
    return `
      <div class="card" style="padding:14px;border:1px solid rgba(255,255,255,.08)">
        <div class="row" style="justify-content:space-between;align-items:center;margin-bottom:8px">
          <div>
            <div style="font-weight:600;font-size:15px">${b.name}</div>
            <div class="sub">CDP :${b.cdp_port} · pid ${b.pid || '—'} · up ${upt}</div>
          </div>
          <div style="display:flex;gap:6px;align-items:center">
            ${status}
            <button class="btn" data-bstart="${b.name}">▶</button>
            <button class="btn" data-brestart="${b.name}">⟲</button>
            <button class="btn" data-bstop="${b.name}">■</button>
          </div>
        </div>
        <div style="background:#000;border-radius:6px;overflow:hidden;aspect-ratio:16/10;position:relative">
          ${b.alive ? `<img id="thumb-${b.name}" src="/api/browser/screenshot?instance=${encodeURIComponent(b.name)}&_=${bust}" style="width:100%;height:100%;object-fit:contain;display:block" onerror="this.style.display='none';this.nextElementSibling.style.display='flex'">
          <div style="display:none;position:absolute;inset:0;align-items:center;justify-content:center;color:#888;font-size:13px">screenshot non disponibile</div>` : `<div style="height:100%;display:flex;align-items:center;justify-content:center;color:#888;font-size:13px">Chrome non attivo</div>`}
        </div>
        <div class="sub" style="margin-top:6px;word-break:break-all">${b.profile_dir}</div>
      </div>
    `;
  }).join('');
  grid.querySelectorAll('[data-bstart]').forEach(b => {
    b.onclick = async () => { await api(`/api/browser/start?instance=${encodeURIComponent(b.dataset.bstart)}`, {method:'POST'}); setTimeout(refreshBrowsersGrid, 1500); };
  });
  grid.querySelectorAll('[data-bstop]').forEach(b => {
    b.onclick = async () => { await api(`/api/browser/stop?instance=${encodeURIComponent(b.dataset.bstop)}`, {method:'POST'}); setTimeout(refreshBrowsersGrid, 800); };
  });
  grid.querySelectorAll('[data-brestart]').forEach(b => {
    b.onclick = async () => { await api(`/api/browser/restart?instance=${encodeURIComponent(b.dataset.brestart)}`, {method:'POST'}); setTimeout(refreshBrowsersGrid, 2000); };
  });
}

async function refreshThumbs() {
  if (!$('#browsers-auto')?.checked) return;
  // Solo se tab browsers è attivo, per non sprecare
  if (!$('#tab-browsers')?.classList.contains('active')) return;
  const bust = Date.now();
  document.querySelectorAll('[id^="thumb-"]').forEach(img => {
    const name = img.id.replace('thumb-', '');
    img.src = `/api/browser/screenshot?instance=${encodeURIComponent(name)}&_=${bust}`;
  });
}

async function refreshLeases() {
  try {
    const data = await api('/api/browser/leases');
    const box = $('#leases-box');
    if (!data.leases?.length) {
      box.innerHTML = '<div class="sub" style="padding:8px">Nessun lease attivo. Pool libero.</div>';
      return;
    }
    box.innerHTML = `<table style="width:100%;border-collapse:collapse;font-size:13px">
      <thead><tr style="background:rgba(255,255,255,.04)">
        <th style="text-align:left;padding:8px">task_id</th>
        <th style="text-align:left;padding:8px">instance</th>
        <th style="text-align:left;padding:8px">app</th>
        <th style="text-align:left;padding:8px">pid</th>
        <th style="text-align:left;padding:8px">età</th>
        <th style="text-align:left;padding:8px">stato</th>
      </tr></thead><tbody>
      ${data.leases.map(l => `<tr style="border-top:1px solid rgba(255,255,255,.06)">
        <td style="padding:8px"><code>${l.task_id}</code></td>
        <td style="padding:8px"><strong>${l.instance}</strong></td>
        <td style="padding:8px">${l.app || '—'}</td>
        <td style="padding:8px">${l.pid || '—'}</td>
        <td style="padding:8px">${Math.floor(l.age_ms / 1000)}s</td>
        <td style="padding:8px">${l.pid_alive ? '● vivo' : '<span style="color:#f88">○ pid morto (verrà pulito)</span>'}${l.queued ? ' · <span style="color:#fa0">queued</span>' : ''}</td>
      </tr>`).join('')}
      </tbody></table>`;
  } catch (e) { $('#leases-box').textContent = 'errore: ' + e.message; }
}

async function refreshSessions() {
  try {
    const data = await api('/api/sessions');
    const box = $('#sessions-box');
    if (!data.sessions?.length) {
      box.innerHTML = '<div class="sub" style="padding:8px">Nessuna sessione device iOS attiva.</div>';
      return;
    }
    box.innerHTML = `<table style="width:100%;border-collapse:collapse;font-size:13px">
      <thead><tr style="background:rgba(255,255,255,.04)">
        <th style="text-align:left;padding:8px">device_id</th>
        <th style="text-align:left;padding:8px">session_id</th>
        <th style="text-align:left;padding:8px">ultimo messaggio</th>
      </tr></thead><tbody>
      ${data.sessions.map(s => `<tr style="border-top:1px solid rgba(255,255,255,.06)">
        <td style="padding:8px"><code>${s.device_id}</code></td>
        <td style="padding:8px"><code style="font-size:11px">${(s.session_id || '').slice(0, 12)}…</code></td>
        <td style="padding:8px">${s.last_active_ago_s !== null ? formatDur(s.last_active_ago_s) + ' fa' : '—'}</td>
      </tr>`).join('')}
      </tbody></table>`;
  } catch (e) { $('#sessions-box').textContent = 'errore: ' + e.message; }
}

$('#btn-browsers-refresh')?.addEventListener('click', refreshBrowsersGrid);
$('#btn-leases-refresh')?.addEventListener('click', refreshLeases);

async function refreshWorkers() {
  const data = await api('/api/watchers');
  const box = $('#workers-list');
  // getStatus() ora ritorna { watchers: [...], rate_limit_active, rate_limit_paused_until }
  const list = Array.isArray(data) ? data : (data?.watchers || []);
  const rlActive = data?.rate_limit_active || false;
  const rlUntil = data?.rate_limit_paused_until || null;
  if (!list.length) {
    box.innerHTML = '<div class="sub">Nessun watcher configurato. Aggiungili in <code>server/watchers.json</code>.</div>';
    return;
  }
  const rlBanner = rlActive && rlUntil
    ? `<div class="card" style="padding:10px;border:1px solid #f59e0b;background:rgba(245,158,11,.1);margin-bottom:10px">⚠️ Rate limit Claude attivo — worker in pausa fino alle <strong>${new Date(rlUntil).toLocaleTimeString('it-IT', { timeZone: 'Europe/Rome' })}</strong> (Europe/Rome)</div>`
    : '';
  box.innerHTML = rlBanner + list.map(w => {
    const lastFire = w.last_fire_at ? timeAgo(w.last_fire_at) : 'mai';
    const dur = w.last_duration_ms ? Math.floor(w.last_duration_ms/1000) + 's' : '—';
    const code = w.last_exit_code === null || w.last_exit_code === undefined ? '—' : `exit ${w.last_exit_code}`;
    const pill = w.running_now ? '<span class="status on">● in esecuzione</span>' : (w.enabled ? '<span class="status on">● attivo</span>' : '<span class="status off">○ disattivato</span>');
    const summary = (w.last_summary || '').replace(/</g, '&lt;');
    const curBudget = (typeof w.max_responses === 'number' && w.max_responses > 0) ? w.max_responses : '';
    const counter = w.responses_count || 0;
    const budgetBadge = curBudget
      ? `<span class="status ${counter >= curBudget ? 'off' : 'on'}" title="Risposte inviate / budget">🎯 ${counter}/${curBudget}</span>`
      : '';
    return `
      <div class="card" style="padding:14px;border:1px solid rgba(255,255,255,.08)">
        <div class="row" style="justify-content:space-between;align-items:start">
          <div>
            <div style="font-weight:600;font-size:15px">${w.name || w.id}</div>
            <div class="sub"><code>${w.id}</code> · ogni ${w.interval_sec}s · ultimo fire ${lastFire} (${dur}, ${code})</div>
          </div>
          <div style="display:flex;gap:6px;align-items:center;flex-wrap:wrap;justify-content:flex-end">
            ${pill}
            ${budgetBadge}
            <button class="btn" data-fire="${w.id}">▶ Run ora</button>
            <button class="btn" data-toggle="${w.id}" data-enabled="${w.enabled}">${w.enabled ? 'Disattiva' : 'Attiva'}</button>
          </div>
        </div>
        <div class="row" style="margin-top:8px;gap:6px;align-items:center">
          <label class="sub" style="margin:0">🎯 Budget max responses:</label>
          <input type="number" min="0" step="1" placeholder="off" value="${curBudget}" data-budget-input="${w.id}" style="width:90px;padding:4px 6px;background:rgba(255,255,255,.05);border:1px solid rgba(255,255,255,.1);color:inherit;border-radius:4px">
          <button class="btn" data-budget-save="${w.id}">💾</button>
          <button class="btn" data-budget-reset="${w.id}" title="Azzera contatore">🔁 Reset counter</button>
        </div>
        ${summary ? `<div class="sub" style="margin-top:8px"><strong>Ultimo output:</strong> ${summary.slice(0, 300)}${summary.length > 300 ? '…' : ''}</div>` : ''}
      </div>
    `;
  }).join('');
  box.querySelectorAll('[data-fire]').forEach(b => {
    b.onclick = async () => {
      b.disabled = true; b.textContent = '⟳…';
      await api(`/api/watchers/${encodeURIComponent(b.dataset.fire)}/fire`, { method:'POST' });
      setTimeout(refreshWorkers, 1500);
    };
  });
  box.querySelectorAll('[data-toggle]').forEach(b => {
    b.onclick = async () => {
      const id = b.dataset.toggle;
      const nowEnabled = b.dataset.enabled === 'true';
      b.disabled = true;
      await api(`/api/watchers/${encodeURIComponent(id)}/toggle`, { method:'POST', body: JSON.stringify({ enabled: !nowEnabled }) });
      setTimeout(refreshWorkers, 500);
    };
  });
  box.querySelectorAll('[data-budget-save]').forEach(b => {
    b.onclick = async () => {
      const id = b.dataset.budgetSave;
      const input = box.querySelector(`[data-budget-input="${id}"]`);
      const raw = (input?.value || '').trim();
      const val = raw === '' || raw === '0' ? null : parseInt(raw, 10);
      if (val !== null && (!Number.isFinite(val) || val <= 0)) { alert('Inserisci un intero > 0 oppure lascia vuoto per disattivare'); return; }
      b.disabled = true; b.textContent = '⟳';
      try {
        await api(`/api/watchers/${encodeURIComponent(id)}/budget`, { method:'POST', body: JSON.stringify({ max_responses: val }) });
      } finally {
        setTimeout(refreshWorkers, 300);
      }
    };
  });
  box.querySelectorAll('[data-budget-reset]').forEach(b => {
    b.onclick = async () => {
      const id = b.dataset.budgetReset;
      if (!confirm(`Azzerare il contatore responses di "${id}"?`)) return;
      b.disabled = true; b.textContent = '⟳';
      try {
        await api(`/api/watchers/${encodeURIComponent(id)}/reset_budget`, { method:'POST' });
      } finally {
        setTimeout(refreshWorkers, 300);
      }
    };
  });
}

async function refreshWorkerLogs() {
  try {
    const t = await api('/api/watchers/log?lines=200');
    $('#wlog-box').textContent = (typeof t === 'string' ? t : JSON.stringify(t)) || '(vuoto)';
  } catch (e) { $('#wlog-box').textContent = 'errore: ' + e.message; }
}

$('#btn-workers-refresh')?.addEventListener('click', refreshWorkers);
$('#btn-wlog-refresh')?.addEventListener('click', refreshWorkerLogs);

loadConfig();
refreshStatus();
refreshAutostart();
refreshBrowser();
refreshWorkers();
refreshWorkerLogs();
refreshBrowsersGrid();
refreshLeases();
refreshSessions();
setInterval(refreshStatus, 3000);
setInterval(refreshBrowser, 5000);
setInterval(refreshWorkers, 5000);
setInterval(refreshBrowsersGrid, 8000);
setInterval(refreshLeases, 3000);
setInterval(refreshSessions, 10000);
setInterval(refreshThumbs, 5000);
