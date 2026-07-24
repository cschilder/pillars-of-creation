// WebSocket client with auto-reconnect (exponential backoff) and a small
// type -> handlers dispatch table. The server relays chat, presence and
// call signalling (audio chunks / screen-share frames) over this single
// connection - see server/modules/WebSocketHub.psm1.

const handlers = new Map();
let socket = null;
let reconnectDelayMs = 1000;
let manuallyClosed = false;

export function onWs(type, handler) {
  if (!handlers.has(type)) handlers.set(type, new Set());
  handlers.get(type).add(handler);
  return () => handlers.get(type).delete(handler);
}

function dispatch(type, payload) {
  const set = handlers.get(type);
  if (set) set.forEach((fn) => fn(payload));
}

export function connectWs() {
  manuallyClosed = false;
  const protocol = location.protocol === 'https:' ? 'wss:' : 'ws:';
  socket = new WebSocket(`${protocol}//${location.host}/ws`);

  socket.addEventListener('open', () => {
    reconnectDelayMs = 1000;
    dispatch('_open', null);
  });

  socket.addEventListener('message', (event) => {
    let data;
    try {
      data = JSON.parse(event.data);
    } catch (e) {
      return;
    }
    dispatch(data.type, data);
  });

  socket.addEventListener('close', () => {
    dispatch('_close', null);
    if (!manuallyClosed) {
      setTimeout(connectWs, reconnectDelayMs);
      reconnectDelayMs = Math.min(reconnectDelayMs * 2, 15000);
    }
  });

  socket.addEventListener('error', () => {
    try { socket.close(); } catch (e) { /* ignore */ }
  });
}

export function sendWs(data) {
  if (socket && socket.readyState === WebSocket.OPEN) {
    socket.send(JSON.stringify(data));
    return true;
  }
  return false;
}

export function closeWs() {
  manuallyClosed = true;
  if (socket) socket.close();
}
