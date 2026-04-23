// Queue per deviceId: serialize richieste iOS + cancel + track processi figli.
// - chatQueues: Promise chain per deviceId — garantisce ordine
// - chatDepth: contatore richieste in corso (per metrics / UI)
// - runningChildren: ChildProcess in volo (per SIGTERM su cancel/rate limit)
// - cancelledUpdates: Set<runId> per deviceId, consumato quando il task finisce

const chatQueues = new Map();
const chatDepth = new Map();
const runningChildren = new Map();
const runningUpdates = new Map();
const cancelledUpdates = new Map();

export function incDepth(deviceId) {
  const d = (chatDepth.get(deviceId) || 0) + 1;
  chatDepth.set(deviceId, d);
  return d;
}

export function decDepth(deviceId) {
  const d = Math.max(0, (chatDepth.get(deviceId) || 0) - 1);
  if (d === 0) chatDepth.delete(deviceId); else chatDepth.set(deviceId, d);
  return d;
}

export function getDepth(deviceId) {
  return chatDepth.get(deviceId) || 0;
}

export function enqueue(deviceId, fn) {
  const prev = chatQueues.get(deviceId) || Promise.resolve();
  const next = prev.then(fn, fn);
  chatQueues.set(deviceId, next);
  next.finally(() => {
    if (chatQueues.get(deviceId) === next) chatQueues.delete(deviceId);
  });
  return next;
}

export function markCancelled(deviceId, runId) {
  let set = cancelledUpdates.get(deviceId);
  if (!set) { set = new Set(); cancelledUpdates.set(deviceId, set); }
  set.add(runId);
}

export function consumeCancelled(deviceId, runId) {
  const set = cancelledUpdates.get(deviceId);
  if (!set) return false;
  const had = set.delete(runId);
  if (!set.size) cancelledUpdates.delete(deviceId);
  return had;
}

export function trackChild(deviceId, child, runId) {
  runningChildren.set(deviceId, child);
  if (runId != null) runningUpdates.set(deviceId, runId);
}

export function untrackChild(deviceId) {
  runningChildren.delete(deviceId);
  runningUpdates.delete(deviceId);
}

export function getRunningChildren() {
  return runningChildren;
}

export function getRunningUpdates() {
  return runningUpdates;
}

export function killAllActive() {
  let count = 0;
  for (const [deviceId, child] of runningChildren.entries()) {
    const runId = runningUpdates.get(deviceId);
    if (runId != null) markCancelled(deviceId, runId);
    try { child.kill('SIGTERM'); } catch {}
    setTimeout(() => { try { child.kill('SIGKILL'); } catch {} }, 2000);
    count++;
  }
  return count;
}
