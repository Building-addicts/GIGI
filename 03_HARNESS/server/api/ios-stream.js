// WebSocket /ws/ios/stream?deviceId=...&token=...
// Broadcast degli eventi interim (thoughts, tool calls, progress) per un device
// iOS mentre il runClaude sottostante è in volo. Più client possono connettersi
// allo stesso deviceId (es. app + dashboard admin).
import { WebSocketServer } from 'ws';
import { getSharedSecret } from './ios-auth.js';
import { log } from '../logger.js';

// Mappa deviceId → Set<WebSocket>
const rooms = new Map();

function joinRoom(deviceId, ws) {
  let set = rooms.get(deviceId);
  if (!set) { set = new Set(); rooms.set(deviceId, set); }
  set.add(ws);
}

function leaveRoom(deviceId, ws) {
  const set = rooms.get(deviceId);
  if (!set) return;
  set.delete(ws);
  if (!set.size) rooms.delete(deviceId);
}

export function broadcast(deviceId, event) {
  const set = rooms.get(deviceId);
  if (!set || !set.size) return 0;
  const msg = JSON.stringify(event);
  let sent = 0;
  for (const ws of set) {
    if (ws.readyState === ws.OPEN) {
      try { ws.send(msg); sent++; } catch {}
    }
  }
  return sent;
}

export function attachWebSocketServer(httpServer, cfg) {
  const wss = new WebSocketServer({ noServer: true });

  httpServer.on('upgrade', (req, socket, head) => {
    const url = new URL(req.url, `http://${req.headers.host}`);
    if (url.pathname !== '/ws/ios/stream') {
      socket.destroy();
      return;
    }
    const token = url.searchParams.get('token') || (req.headers['authorization'] || '').replace(/^Bearer\s+/i, '');
    const deviceId = url.searchParams.get('deviceId') || '';
    const expected = getSharedSecret(cfg);
    if (!expected || token !== expected) {
      socket.write('HTTP/1.1 401 Unauthorized\r\n\r\n');
      socket.destroy();
      return;
    }
    if (!deviceId) {
      socket.write('HTTP/1.1 400 Bad Request\r\n\r\n');
      socket.destroy();
      return;
    }
    wss.handleUpgrade(req, socket, head, (ws) => {
      ws.deviceId = deviceId;
      joinRoom(deviceId, ws);
      ws.on('close', () => leaveRoom(deviceId, ws));
      ws.on('error', () => leaveRoom(deviceId, ws));
      try { ws.send(JSON.stringify({ type: 'connected', deviceId, ts: Date.now() })); } catch {}
    });
  });

  log('ws: iOS stream pronto su /ws/ios/stream');
  return wss;
}
