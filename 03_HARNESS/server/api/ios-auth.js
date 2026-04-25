// Middleware Bearer token per API iOS.
// Secret prelevato da env HARNESS_SHARED_SECRET o cfg.ios.shared_secret.
// Se cfg.ios.allowed_device_ids è non vuoto, valida anche il device id passato
// nel body (POST) o nella query string (GET/DELETE).
export function getSharedSecret(cfg) {
  return process.env.HARNESS_SHARED_SECRET || cfg?.ios?.shared_secret || '';
}

export function checkBearer(cfg, req) {
  const expected = getSharedSecret(cfg);
  if (!expected) return { ok: false, code: 500, error: 'iOS shared secret non configurato' };
  const header = req.headers['authorization'] || '';
  const m = /^Bearer\s+(.+)$/i.exec(header);
  if (!m) return { ok: false, code: 401, error: 'Authorization header mancante o malformato' };
  if (m[1].trim() !== expected) return { ok: false, code: 401, error: 'Bearer token non valido' };
  return { ok: true };
}

export function checkDevice(cfg, deviceId) {
  // Phase 6B — blocked devices (revoke action). Checked first so a revoke
  // takes effect immediately even if the device was previously allowed.
  const blocked = cfg?.ios?.blocked_device_ids;
  if (Array.isArray(blocked) && deviceId && blocked.includes(deviceId)) {
    return { ok: false, code: 403, error: 'DEVICE_REVOKED' };
  }
  const allowed = cfg?.ios?.allowed_device_ids;
  if (!Array.isArray(allowed) || allowed.length === 0) return { ok: true };
  if (!deviceId) return { ok: false, code: 400, error: 'deviceId mancante' };
  if (!allowed.includes(deviceId)) return { ok: false, code: 403, error: 'deviceId non autorizzato' };
  return { ok: true };
}
