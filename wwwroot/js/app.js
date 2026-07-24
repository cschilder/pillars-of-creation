// Bootstraps the SPA: signs the user in (a self-declared, unverified
// NETWERK.TLD\gebruikersnaam - see Auth.psm1 for why), wires the tab
// navigation and hands off to the feature modules.
import { Api } from './api.js';
import { connectWs, onWs, sendWs, closeWs } from './ws.js';
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
  const err = document.getElementById('login-error');
  err.classList.remove('u-hide');
  err.querySelector('.p-notification__content').textContent = message;
}

function wireLoginForm(onLoggedIn) {
  const form = document.getElementById('login-form');
  const status = document.getElementById('login-status');
  form.addEventListener('submit', async (e) => {
    e.preventDefault();
    const username = document.getElementById('login-username').value.trim();
    if (!username) return;

    document.getElementById('login-error').classList.add('u-hide');
    form.hidden = true;
    status.classList.remove('u-hide');
    status.textContent = 'Bezig met aanmelden...';

    try {
      await Api.login(username);
      await onLoggedIn();
    } catch (err) {
      form.hidden = false;
      status.classList.add('u-hide');
      showLoginError(err.message);
    }
  });
}

function showLoginGate() {
  document.getElementById('app-root').classList.add('u-hide');
  document.getElementById('login-gate').classList.remove('u-hide');
  document.getElementById('login-form').hidden = false;
  document.getElementById('login-status').classList.add('u-hide');
}

function wireLogout() {
  document.getElementById('btn-logout').addEventListener('click', async () => {
    closeWs();
    try { await Api.logout(); } catch (e) { /* best effort */ }
    location.reload();
  });
}

async function startApp(me) {
  state.me = me;

  document.getElementById('login-gate').classList.add('u-hide');
  document.getElementById('app-root').classList.remove('u-hide');
  document.getElementById('current-user-label').textContent = `${me.displayName} (${me.username})`;
  document.getElementById('logout-item').hidden = false;
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

async function bootstrap() {
  wireLogout();

  async function tryEnter() {
    let me;
    try {
      me = await Api.me();
    } catch (e) {
      if (e.status === 401) {
        showLoginGate();
        return;
      }
      showLoginError('Kon niet bij de server komen: ' + e.message);
      showLoginGate();
      return;
    }
    await startApp(me);
  }

  wireLoginForm(tryEnter);
  await tryEnter();
}

bootstrap();
