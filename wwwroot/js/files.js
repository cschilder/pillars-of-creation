// File upload glue for the chat composer. The server turns a successful
// upload into a chat message and broadcasts it over the WebSocket, so we
// don't need to touch the message list ourselves after the request completes.
import { Api } from './api.js';

export function initFiles() {
  // Nothing to wire globally - uploadAndSend() is called directly by chat.js.
}

export async function uploadAndSend(roomId, file) {
  const progressEl = document.getElementById('upload-progress');
  progressEl.hidden = false;
  progressEl.textContent = `Uploaden: ${file.name} (0%)`;
  try {
    await Api.uploadFile(roomId, file, (fraction) => {
      progressEl.textContent = `Uploaden: ${file.name} (${Math.round(fraction * 100)}%)`;
    });
  } catch (e) {
    alert('Uploaden mislukt: ' + e.message);
  } finally {
    progressEl.hidden = true;
  }
}
