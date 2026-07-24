// Bootstraps the SPA: verifies the Windows-session login, wires the tab
// navigation and hands off to the feature modules.
import { Api } from './api.js';
import { connectWs, onWs, sendWs } from './ws.js';
import { state } from './state.js';
import { switchTab } from './ui.js';
import { initRooms, handleChatWsMessage } from './chat.js';
import { initSettings } from './settings.js';
import { initAdmin } from './admin.js';
import { initFiles } from './files.js';
import { initCall, handleCallSignal } from './call.js';
import { initScreenShareViewer } from './screenshare.js';

function wireTabs() {
  document.querySelectorAll('.p-tabs__link').forEach((a) => {
    a.addEventListener('click', (e) => {
      e.preventDefault();
      switchTab(a.dataset.tab);
    });
  });
}

function showLoginError(message) {
  document.getElementById('login-status').textContent = 'Aanmelden mislukt.';
  const err = document.getElementById('login-error');
  err.classList.remove('u-hide');
  err.querySelector('.p-notification__content').textContent = message;
}

async function bootstrap() {
  let me;
  try {
    me = await Api.me();
  } catch (e) {
    showLoginError(
      'Kon je Windows-sessie niet verifiëren: ' + e.message + '. ' +
      'Vraag je beheerder Integrated Windows Authentication te controleren, ' +
      'of open deze pagina in Chrome/Edge binnen het bedrijfsnetwerk.'
    );
    return;
  }
  state.me = me;

  document.getElementById('login-gate').classList.add('u-hide');
  document.getElementById('app-root').classList.remove('u-hide');
  document.getElementById('current-user-label').textContent = `${me.displayName} (${me.username})`;
  if (me.departmentName) {
    document.getElementById('department-name').textContent = me.departmentName;
    document.title = me.departmentName;
  }
  if (me.isAdmin) document.getElementById('admin-tab-item').hidden = false;
  document.body.classList.toggle('theme-dark', me.settings && me.settings.theme === 'dark');

  wireTabs();
  initSettings();
  initFiles();
  initCall();
  initScreenShareViewer();
  await initRooms();
  if (me.isAdmin) await initAdmin();

  onWs('hello', () => {
    if (state.activeRoomId) sendWs({ type: 'join_room', roomId: state.activeRoomId });
  });
  onWs('room_history', handleChatWsMessage);
  onWs('chat_message', handleChatWsMessage);
  onWs('presence', handleChatWsMessage);
  onWs('typing', handleChatWsMessage);
  onWs('call_signal', handleCallSignal);
  onWs('error', (msg) => console.warn('WS-fout:', msg && msg.message));

  connectWs();
}

bootstrap();
