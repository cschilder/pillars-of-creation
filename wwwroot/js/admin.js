// Admin tab: app-wide configuration, creating public department-wide
// rooms, approving/rejecting private room requests, and promoting/
// demoting other users to admin.
import { Api } from './api.js';
import { escapeHtml, formatTime } from './ui.js';
import { refreshRooms } from './chat.js';

export async function initAdmin() {
  wireAppConfigForm();
  wireNewPublicRoomForm();
  await Promise.all([loadAppConfig(), refreshRoomRequests(), refreshAdminUsers()]);

  // The snapshot above is taken during page bootstrap, BEFORE the
  // WebSocket connects - so it can never show the viewer themselves as
  // online, and it goes stale the moment anyone joins or leaves. Keep the
  // list current while the Beheer tab is actually in view.
  setInterval(() => {
    const panel = document.querySelector('[data-tab-panel="admin"]');
    if (panel && !panel.classList.contains('u-hide')) {
      refreshAdminUsers().catch(() => {});
      refreshRoomRequests().catch(() => {});
    }
  }, 10000);
}

export async function refreshAdminData() {
  await Promise.all([refreshRoomRequests(), refreshAdminUsers()]);
}

async function loadAppConfig() {
  const cfg = await Api.adminConfig();
  document.getElementById('cfg-department').value = cfg.departmentName || '';
  document.getElementById('cfg-upload-limit').value = cfg.maxUploadSizeMb || 100;
  document.getElementById('cfg-history-limit').value = cfg.messageHistoryLimit || 500;
}

function wireAppConfigForm() {
  document.getElementById('app-config-form').addEventListener('submit', async (e) => {
    e.preventDefault();
    const body = {
      departmentName: document.getElementById('cfg-department').value.trim(),
      maxUploadSizeMb: Number(document.getElementById('cfg-upload-limit').value),
      messageHistoryLimit: Number(document.getElementById('cfg-history-limit').value),
    };
    await Api.updateAdminConfig(body);
    document.getElementById('department-name').textContent = body.departmentName;

    const saved = document.getElementById('app-config-saved');
    saved.classList.remove('u-hide');
    setTimeout(() => saved.classList.add('u-hide'), 2000);
  });
}

function wireNewPublicRoomForm() {
  document.getElementById('new-public-room-form').addEventListener('submit', async (e) => {
    e.preventDefault();
    const name = document.getElementById('new-room-name').value.trim();
    const topic = document.getElementById('new-room-topic').value.trim();
    if (!name) return;
    await Api.createRoom({ name, topic, type: 'public' });
    e.target.reset();
    await refreshRooms();
  });
}

async function refreshRoomRequests() {
  const requests = await Api.roomRequests();
  const list = document.getElementById('room-request-list');
  list.innerHTML = '';

  if (requests.length === 0) {
    list.innerHTML = '<li class="p-list__item u-text--muted">Geen openstaande aanvragen.</li>';
    return;
  }

  requests.forEach((req) => {
    const li = document.createElement('li');
    li.className = 'p-list__item';
    li.innerHTML = `
      <strong>${escapeHtml(req.name)}</strong> - aangevraagd door ${escapeHtml(req.requestedBy)}<br/>
      <span class="u-text--muted">${escapeHtml(req.purpose || '')}</span><br/>
      <span class="u-text--muted">Voorgestelde leden: ${escapeHtml((req.proposedMembers || []).join(', ') || '(geen)')}</span>
    `;

    const approveBtn = document.createElement('button');
    approveBtn.className = 'p-button--positive is-small';
    approveBtn.type = 'button';
    approveBtn.textContent = 'Goedkeuren';
    approveBtn.addEventListener('click', async () => {
      await Api.approveRoomRequest(req.id, { managers: [req.requestedBy], members: req.proposedMembers || [] });
      await refreshRoomRequests();
      await refreshRooms();
    });

    const rejectBtn = document.createElement('button');
    rejectBtn.className = 'p-button--negative is-small';
    rejectBtn.type = 'button';
    rejectBtn.textContent = 'Afwijzen';
    rejectBtn.addEventListener('click', async () => {
      await Api.rejectRoomRequest(req.id);
      await refreshRoomRequests();
    });

    li.appendChild(approveBtn);
    li.appendChild(rejectBtn);
    list.appendChild(li);
  });
}

async function refreshAdminUsers() {
  const users = await Api.adminUsers();
  const tbody = document.getElementById('admin-users-body');
  tbody.innerHTML = '';

  users.forEach((u) => {
    const tr = document.createElement('tr');
    tr.innerHTML = `
      <td>${escapeHtml(u.displayName)} (${escapeHtml(u.username)})</td>
      <td>${formatTime(u.lastSeen)}</td>
      <td>${u.online ? '🟢' : '⚪'}</td>
    `;
    const td = document.createElement('td');
    const checkbox = document.createElement('input');
    checkbox.type = 'checkbox';
    checkbox.checked = !!u.isAdmin;
    checkbox.addEventListener('change', async () => {
      await Api.setUserAdmin(u.username, checkbox.checked);
    });
    td.appendChild(checkbox);
    tr.appendChild(td);
    tbody.appendChild(tr);
  });
}
