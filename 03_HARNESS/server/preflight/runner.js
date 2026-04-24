// Runs every check in checks.js in parallel with a hard global timeout
// and aggregates the results into a stable `DiagnosticsReport` shape:
//
//   {
//     generatedAt: ISO-8601 string,
//     elapsedMs:   number,
//     summary: {
//       allCriticalOk: boolean,
//       counts: { critical: {ok, total}, warning: {ok, total}, info: {ok, total} }
//     },
//     checks: CheckResult[]
//   }
//
// Order of checks in the array is stable so the iOS UI can render without
// re-sorting. Each check is wrapped with a per-check timeout fallback so
// one broken probe never breaks the whole report.
import * as checks from './checks.js';

const REGISTRY = [
  checks.claude_cli_installed,
  checks.claude_cli_authenticated,
  checks.config_secret_strength,
  checks.tunnel_mode_active,
  checks.tunnel_running,
  checks.cloudflared_binary,
  checks.outbound_https,
  checks.port_7779_bound,
  checks.disk_space,
  checks.last_request_ago
];

const PER_CHECK_TIMEOUT_MS = 18_000;
const GLOBAL_BUDGET_MS     = 25_000;

function fallbackResult(fn, error) {
  return {
    id: fn.name || 'unknown_check',
    label: 'Check failed to run',
    severity: 'warning',
    ok: false,
    hint: 'This diagnostic check itself errored — likely a harness bug.',
    detail: { error: String(error).slice(0, 200) }
  };
}

function timeoutResult(fn) {
  return {
    id: fn.name || 'unknown_check',
    label: 'Check timed out',
    severity: 'warning',
    ok: false,
    hint: `The ${fn.name} probe took longer than ${PER_CHECK_TIMEOUT_MS / 1000}s.`,
    detail: { timedOut: true }
  };
}

function runOne(fn, ctx) {
  return Promise.race([
    Promise.resolve().then(() => fn(ctx)).catch(e => fallbackResult(fn, e)),
    new Promise(resolve => setTimeout(() => resolve(timeoutResult(fn)), PER_CHECK_TIMEOUT_MS))
  ]);
}

/**
 * Runs every check in parallel and returns a DiagnosticsReport.
 *
 * @param {object} ctx — { cfg, cloudflared, gigiServer }
 * @returns {Promise<DiagnosticsReport>}
 */
export async function runDiagnostics(ctx) {
  const startedAt = Date.now();
  const settled = await Promise.race([
    Promise.all(REGISTRY.map(fn => runOne(fn, ctx))),
    new Promise(resolve => setTimeout(() => resolve(null), GLOBAL_BUDGET_MS))
  ]);

  const results = settled || REGISTRY.map(fn => timeoutResult(fn));

  // Counts per severity
  const counts = {
    critical: { ok: 0, total: 0 },
    warning:  { ok: 0, total: 0 },
    info:     { ok: 0, total: 0 }
  };
  for (const r of results) {
    const s = r.severity in counts ? r.severity : 'info';
    counts[s].total += 1;
    if (r.ok) counts[s].ok += 1;
  }
  const allCriticalOk = counts.critical.total === 0
    || counts.critical.ok === counts.critical.total;

  return {
    generatedAt: new Date().toISOString(),
    elapsedMs:   Date.now() - startedAt,
    summary: {
      allCriticalOk,
      counts
    },
    checks: results
  };
}
