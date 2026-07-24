// Screen sharing over the canvas element: the presenter grabs the screen
// with getDisplayMedia(), draws throttled frames onto an offscreen canvas,
// JPEG-encodes them and relays them through the server's WebSocket hub as
// base64 (see WebSocketHub.psm1 / call_signal kind "screen-frame"). Viewers
// just draw the incoming frames onto <canvas id="screenshare-canvas">.
// This is a server-relayed frame stream, not peer-to-peer WebRTC.
import { sendWs } from './ws.js';

const FRAME_INTERVAL_MS = 200; // ~5 fps, keeps relayed frames small
const JPEG_QUALITY = 0.6;

let captureStream = null;
let captureInterval = null;
let offscreenCanvas = null;
let offscreenCtx = null;
let videoEl = null;

export async function startScreenShareCapture(roomId, callId, onStoppedByBrowser) {
  try {
    captureStream = await navigator.mediaDevices.getDisplayMedia({ video: { frameRate: 6 }, audio: false });
  } catch (e) {
    alert('Scherm delen geannuleerd of niet toegestaan: ' + e.message);
    return false;
  }

  videoEl = document.createElement('video');
  videoEl.srcObject = captureStream;
  videoEl.muted = true;
  try {
    await videoEl.play();
  } catch (e) {
    /* autoplay restrictions shouldn't apply to a muted, user-initiated capture */
  }

  offscreenCanvas = document.createElement('canvas');
  offscreenCanvas.width = 1280;
  offscreenCanvas.height = 720;
  offscreenCtx = offscreenCanvas.getContext('2d');

  const track = captureStream.getVideoTracks()[0];
  track.addEventListener('ended', () => {
    stopScreenShareCapture();
    if (onStoppedByBrowser) onStoppedByBrowser();
  });

  captureInterval = setInterval(() => {
    if (!videoEl || !videoEl.videoWidth) return;
    const scale = Math.min(offscreenCanvas.width / videoEl.videoWidth, offscreenCanvas.height / videoEl.videoHeight);
    const w = videoEl.videoWidth * scale;
    const h = videoEl.videoHeight * scale;

    offscreenCtx.fillStyle = '#111';
    offscreenCtx.fillRect(0, 0, offscreenCanvas.width, offscreenCanvas.height);
    offscreenCtx.drawImage(videoEl, (offscreenCanvas.width - w) / 2, (offscreenCanvas.height - h) / 2, w, h);

    offscreenCanvas.toBlob((blob) => {
      if (!blob) return;
      const reader = new FileReader();
      reader.onloadend = () => {
        const base64 = reader.result.split(',')[1];
        sendWs({ type: 'call_signal', roomId, callId, kind: 'screen-frame', data: base64 });
      };
      reader.readAsDataURL(blob);
    }, 'image/jpeg', JPEG_QUALITY);
  }, FRAME_INTERVAL_MS);

  return true;
}

export function stopScreenShareCapture() {
  if (captureInterval) {
    clearInterval(captureInterval);
    captureInterval = null;
  }
  if (captureStream) {
    captureStream.getTracks().forEach((t) => t.stop());
    captureStream = null;
  }
  videoEl = null;
}

export function renderScreenFrame(base64, fromLabel) {
  const canvas = document.getElementById('screenshare-canvas');
  const ctx = canvas.getContext('2d');
  const img = new Image();
  img.onload = () => {
    ctx.clearRect(0, 0, canvas.width, canvas.height);
    ctx.drawImage(img, 0, 0, canvas.width, canvas.height);
  };
  img.src = 'data:image/jpeg;base64,' + base64;
  document.getElementById('screenshare-status').textContent = `${fromLabel} deelt het scherm.`;
}

export function clearScreenShareViewer() {
  const canvas = document.getElementById('screenshare-canvas');
  const ctx = canvas.getContext('2d');
  ctx.clearRect(0, 0, canvas.width, canvas.height);
  document.getElementById('screenshare-status').textContent = 'Niemand deelt op dit moment het scherm.';
}

export function initScreenShareViewer() {
  clearScreenShareViewer();
}
