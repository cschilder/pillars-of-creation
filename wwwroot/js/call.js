// Voice call relay. Each chatroom has one standing call channel
// (callId = "call-<roomId>"), so anyone who clicks "Bel" on the same room
// joins the same session - no separate invite/accept handshake needed.
// Microphone audio is captured in ~250ms MediaRecorder chunks and relayed
// through the server to everyone else in the call (server relay, not
// peer-to-peer WebRTC) - see WebSocketHub.psm1 call_signal handling.
import { sendWs } from './ws.js';
import { state } from './state.js';
import { switchTab, escapeHtml } from './ui.js';
import { startScreenShareCapture, stopScreenShareCapture, renderScreenFrame, clearScreenShareViewer } from './screenshare.js';

let mediaStream = null;
let recorder = null;
let audioQueue = [];
let audioPlaying = false;
const participants = new Set();

export function initCall() {
  document.getElementById('btn-start-call').addEventListener('click', () => {
    if (!state.activeRoomId) return;
    startCall(state.activeRoomId);
  });
  document.getElementById('btn-leave-call').addEventListener('click', leaveCall);
  document.getElementById('btn-toggle-mic').addEventListener('click', toggleMic);
  document.getElementById('btn-toggle-screenshare').addEventListener('click', toggleScreenShare);
}

function startCall(roomId) {
  const room = state.rooms.find((r) => r.id === roomId);
  state.call.active = true;
  state.call.roomId = roomId;
  state.call.callId = `call-${roomId}`;
  participants.clear();
  participants.add(state.me.username);

  document.getElementById('call-room-name').textContent = room ? room.name : roomId;
  document.getElementById('call-active-row').hidden = false;
  document.getElementById('no-active-call-message').hidden = true;
  renderParticipants();
  switchTab('calls');

  sendWs({ type: 'call_signal', roomId, callId: state.call.callId, kind: 'join', data: null });
}

function leaveCall() {
  if (!state.call.active) return;
  const { roomId, callId } = state.call;

  if (state.call.micOn) toggleMic();
  if (state.call.sharingScreen) {
    stopScreenShareCapture();
    state.call.sharingScreen = false;
    document.getElementById('btn-toggle-screenshare').textContent = '🖥️ Scherm delen starten';
  }

  sendWs({ type: 'call_signal', roomId, callId, kind: 'leave', data: null });

  state.call.active = false;
  state.call.roomId = null;
  state.call.callId = null;
  participants.clear();

  document.getElementById('call-active-row').hidden = true;
  document.getElementById('no-active-call-message').hidden = false;
  clearScreenShareViewer();
}

function renderParticipants() {
  const el = document.getElementById('call-participants');
  el.innerHTML = '';
  participants.forEach((name) => {
    const span = document.createElement('span');
    span.className = 'p-chip call-participant-chip';
    span.innerHTML = `<span class="p-chip__value">${escapeHtml(name)}</span>`;
    el.appendChild(span);
  });
}

async function toggleMic() {
  const btn = document.getElementById('btn-toggle-mic');
  if (!state.call.micOn) {
    try {
      mediaStream = await navigator.mediaDevices.getUserMedia({ audio: true });
    } catch (e) {
      alert('Kon microfoon niet openen: ' + e.message);
      return;
    }
    const mimeType = (window.MediaRecorder && MediaRecorder.isTypeSupported('audio/webm;codecs=opus'))
      ? 'audio/webm;codecs=opus'
      : 'audio/webm';
    recorder = new MediaRecorder(mediaStream, { mimeType });
    recorder.ondataavailable = async (e) => {
      if (e.data.size === 0 || !state.call.active) return;
      const base64 = await blobToBase64(e.data);
      sendWs({ type: 'call_signal', roomId: state.call.roomId, callId: state.call.callId, kind: 'audio-chunk', data: base64 });
    };
    recorder.start(250);
    state.call.micOn = true;
    btn.textContent = '🎙️ Microfoon uit';
  } else {
    if (recorder && recorder.state !== 'inactive') recorder.stop();
    if (mediaStream) mediaStream.getTracks().forEach((t) => t.stop());
    mediaStream = null;
    recorder = null;
    state.call.micOn = false;
    btn.textContent = '🎙️ Microfoon aan';
  }
}

async function toggleScreenShare() {
  const btn = document.getElementById('btn-toggle-screenshare');
  if (!state.call.sharingScreen) {
    const ok = await startScreenShareCapture(state.call.roomId, state.call.callId, () => {
      state.call.sharingScreen = false;
      btn.textContent = '🖥️ Scherm delen starten';
    });
    if (ok) {
      state.call.sharingScreen = true;
      btn.textContent = '🖥️ Scherm delen stoppen';
    }
  } else {
    stopScreenShareCapture();
    state.call.sharingScreen = false;
    btn.textContent = '🖥️ Scherm delen starten';
  }
}

function blobToBase64(blob) {
  return new Promise((resolve, reject) => {
    const reader = new FileReader();
    reader.onloadend = () => resolve(reader.result.split(',')[1]);
    reader.onerror = reject;
    reader.readAsDataURL(blob);
  });
}

function playAudioChunk(base64) {
  const byteChars = atob(base64);
  const bytes = new Uint8Array(byteChars.length);
  for (let i = 0; i < byteChars.length; i++) bytes[i] = byteChars.charCodeAt(i);
  const blob = new Blob([bytes], { type: 'audio/webm' });
  const url = URL.createObjectURL(blob);
  audioQueue.push(url);
  if (!audioPlaying) playNextInQueue();
}

function playNextInQueue() {
  const url = audioQueue.shift();
  if (!url) {
    audioPlaying = false;
    return;
  }
  audioPlaying = true;
  const audio = new Audio(url);
  const advance = () => {
    URL.revokeObjectURL(url);
    playNextInQueue();
  };
  audio.addEventListener('ended', advance);
  audio.addEventListener('error', advance);
  audio.play().catch(advance);
}

export function handleCallSignal(msg) {
  if (!state.call.active || msg.callId !== state.call.callId) return;

  if (msg.kind === 'join') {
    participants.add(msg.from);
    renderParticipants();
  } else if (msg.kind === 'leave') {
    participants.delete(msg.from);
    renderParticipants();
  } else if (msg.kind === 'audio-chunk') {
    playAudioChunk(msg.data);
  } else if (msg.kind === 'screen-frame') {
    renderScreenFrame(msg.data, msg.fromDisplayName || msg.from);
  }
}
