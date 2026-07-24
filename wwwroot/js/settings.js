// User configuration screen: display name override, theme, notification sound.
import { Api } from './api.js';
import { state } from './state.js';

export function initSettings() {
  const form = document.getElementById('user-settings-form');
  const settings = state.me.settings || {};

  document.getElementById('setting-username').value = state.me.username;
  document.getElementById('setting-displayname').value = settings.displayNameOverride || '';
  document.getElementById('setting-theme').value = settings.theme || 'light';
  document.getElementById('setting-notifications').checked = settings.notificationsSound !== false;

  form.addEventListener('submit', async (e) => {
    e.preventDefault();
    const displayNameOverride = document.getElementById('setting-displayname').value.trim() || null;
    const theme = document.getElementById('setting-theme').value;
    const notificationsSound = document.getElementById('setting-notifications').checked;

    const updated = await Api.updateMySettings({ displayNameOverride, theme, notificationsSound });
    state.me.settings = updated.settings;
    // Vanilla Framework's own theme class - see the comment in app.js.
    document.body.classList.toggle('is-dark', theme === 'dark');

    const saved = document.getElementById('user-settings-saved');
    saved.classList.remove('u-hide');
    setTimeout(() => saved.classList.add('u-hide'), 2000);
  });
}
