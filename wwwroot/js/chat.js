// Room list + active room message pane, and the two modals for requesting
// a private room and managing an existing room's members/managers.
import { Api } from './api.js';
import { sendWs } from './ws.js';
import { state } from './state.js';
import { escapeHtml, formatTime, formatBytes, playNotifySound, wireModal } from './ui.js';
import { uploadAndSend } from './files.js';

let requestModal = null;
let manageModal = null;

export async function initRooms() {
  requestModal = wireModal(document.getElementById('modal-request-room'));
  manageModal = wireModal(document.getElementById('modal-manage-room'));
  wireComposer();
  wireRequestRoomModal();
  wireManageRoomModal();
  await refreshRooms();
}

export async function refreshRooms() {
  state.rooms = await Api.rooms();
  renderRoomList();
  if (state.activeRoomId && !state.rooms.some((r) => r.id === state.activeRoomId)) {
    state.activeRoomId = null;
  }
}

export function renderRoomList() {
  const ul = document.getElementById('room-list');
  ul.innerHTML = '';

  const renderGroup = (title, rooms) => {
    if (rooms.length === 0) return;
    const heading = document.createElement('li');
    heading.className = 'p-list__item room-group-heading';
    heading.innerHTML = `<strong>${escapeHtml(title)}</strong>`;
    ul.appendChild(heading);
    rooms.forEach((r) => {
      const li = document.createElement('li');
      li.className = 'p-list__item';
      const btn = document.createElement('button');
      btn.type = 'button';
      btn.className = 'room-list-item' + (r.id === state.activeRoomId ? ' is-active' : '');
      btn.innerHTML = `${escapeHtml(r.name)} <span class="room-type-badge">${r.type === 'public' ? '(openbaar)' : '(privé)'}</span>`;
      btn.addEventListener('click', () => selectRoom(r.id));
      li.appendChild(btn);
      ul.appendChild(li);
    });
  };

  renderGroup('Openbaar', state.rooms.filter((r) => r.type === 'public'));
  renderGroup('Privé', state.rooms.filter((r) => r.type === 'private'));

  if (state.rooms.length === 0) {
    ul.innerHTML = '<li class="p-list__item u-text--muted">Geen chatrooms zichtbaar.</li>';
  }
}

export function selectRoom(roomId) {
  if (state.activeRoomId === roomId) return;
  if (state.activeRoomId) sendWs({ type: 'leave_room', roomId: state.activeRoomId });

  state.activeRoomId = roomId;
  renderRoomList();

  const room = state.rooms.find((r) => r.id === roomId);
  document.getElementById('chat-room-name').textContent = room ? room.name : '';
  document.getElementById('chat-room-topic').textContent = room ? room.topic || '' : '';
  document.getElementById('chat-room-controls').hidden = !room;
  document.getElementById('chat-composer').hidden = !room;
  document.getElementById('btn-manage-room').hidden = !(room && room.isManager);
  document.getElementById('chat-messages').innerHTML = '';
  document.getElementById('chat-typing-indicator').textContent = '';

  sendWs({ type: 'join_room', roomId });
}

function appendMessage(msg, { scroll = true } = {}) {
  const container = document.getElementById('chat-messages');
  const div = document.createElement('div');
  const isOwn = state.me && msg.author === state.me.username;
  div.className = 'chat-message' + (isOwn ? ' is-own' : '');
  const displayAuthor = isOwn ? 'Jij' : msg.author;

  let bodyHtml;
  if (msg.type === 'file' && msg.file) {
    bodyHtml = `<div class="chat-message-file">📎 <a href="/api/files/${encodeURIComponent(msg.file.id)}">${escapeHtml(msg.file.originalName)}</a> <span class="u-text--muted">(${formatBytes(msg.file.size)})</span></div>`;
  } else {
    bodyHtml = `<div class="chat-message-text">${escapeHtml(msg.text)}</div>`;
  }

  div.innerHTML = `<div class="chat-message-meta">${escapeHtml(displayAuthor)} · ${formatTime(msg.createdAt)}</div>${bodyHtml}`;
  container.appendChild(div);
  if (scroll) container.scrollTop = container.scrollHeight;
}

export function handleChatWsMessage(msg) {
  if (msg.type === 'room_history' && msg.roomId === state.activeRoomId) {
    const container = document.getElementById('chat-messages');
    container.innerHTML = '';
    (msg.messages || []).forEach((m) => appendMessage(m, { scroll: false }));
    container.scrollTop = container.scrollHeight;
  } else if (msg.type === 'chat_message') {
    if (msg.roomId === state.activeRoomId) {
      appendMessage(msg.message);
      const isOwn = state.me && msg.message.author === state.me.username;
      const soundOn = state.me && state.me.settings && state.me.settings.notificationsSound !== false;
      if (!isOwn && soundOn) playNotifySound();
    }
  } else if (msg.type === 'presence') {
    state.onlineByRoom[msg.roomId] = msg.online || [];
    if (msg.roomId === state.activeRoomId) {
      const chip = document.querySelector('#chat-online-chip .p-chip__value');
      if (chip) chip.textContent = `${(msg.online || []).length} online`;
    }
  } else if (msg.type === 'typing') {
    if (msg.roomId === state.activeRoomId && state.me && msg.username !== state.me.username) {
      document.getElementById('chat-typing-indicator').textContent = msg.isTyping ? `${msg.username} is aan het typen...` : '';
    }
  }
}

function wireComposer() {
  const form = document.getElementById('message-form');
  const input = document.getElementById('message-input');
  let typingTimeout = null;

  form.addEventListener('submit', (e) => {
    e.preventDefault();
    const text = input.value.trim();
    if (!text || !state.activeRoomId) return;
    sendWs({ type: 'chat_message', roomId: state.activeRoomId, text });
    input.value = '';
    sendWs({ type: 'typing', roomId: state.activeRoomId, isTyping: false });
  });

  input.addEventListener('input', () => {
    if (!state.activeRoomId) return;
    sendWs({ type: 'typing', roomId: state.activeRoomId, isTyping: true });
    clearTimeout(typingTimeout);
    typingTimeout = setTimeout(() => {
      sendWs({ type: 'typing', roomId: state.activeRoomId, isTyping: false });
    }, 2000);
  });

  const fileInput = document.getElementById('file-input');
  fileInput.addEventListener('change', async () => {
    if (fileInput.files.length === 0 || !state.activeRoomId) return;
    await uploadAndSend(state.activeRoomId, fileInput.files[0]);
    fileInput.value = '';
  });
}

function wireRequestRoomModal() {
  document.getElementById('btn-request-room').addEventListener('click', () => requestModal.open());

  document.getElementById('request-room-form').addEventListener('submit', async (e) => {
    e.preventDefault();
    const name = document.getElementById('req-room-name').value.trim();
    const purpose = document.getElementById('req-room-purpose').value.trim();
    const membersRaw = document.getElementById('req-room-members').value.trim();
    const proposedMembers = membersRaw ? membersRaw.split(',').map((s) => s.trim()).filter(Boolean) : [];
    if (!name) return;

    await Api.requestRoom({ name, purpose, proposedMembers });
    requestModal.close();
    e.target.reset();
    alert('Aanvraag verstuurd. Een beheerder moet deze nog goedkeuren op het tabblad Beheer.');
  });
}

function wireManageRoomModal() {
  document.getElementById('btn-manage-room').addEventListener('click', () => {
    const room = state.rooms.find((r) => r.id === state.activeRoomId);
    if (!room) return;
    renderManageRoomModal(room);
    manageModal.open();
  });

  document.getElementById('add-member-form').addEventListener('submit', async (e) => {
    e.preventDefault();
    const username = document.getElementById('add-member-username').value.trim();
    const asManager = document.getElementById('add-member-as-manager').checked;
    if (!username || !state.activeRoomId) return;
    const updated = await Api.addMember(state.activeRoomId, { username, asManager });
    updateRoomInState(updated);
    renderManageRoomModal(updated);
    e.target.reset();
  });

  document.getElementById('edit-room-form').addEventListener('submit', async (e) => {
    e.preventDefault();
    if (!state.activeRoomId) return;
    const name = document.getElementById('edit-room-name').value.trim();
    const topic = document.getElementById('edit-room-topic').value.trim();
    const updated = await Api.updateRoom(state.activeRoomId, { name, topic });
    updateRoomInState(updated);
    document.getElementById('chat-room-name').textContent = updated.name;
    document.getElementById('chat-room-topic').textContent = updated.topic || '';
  });
}

function renderManageRoomModal(room) {
  document.getElementById('edit-room-name').value = room.name;
  document.getElementById('edit-room-topic').value = room.topic || '';

  const list = document.getElementById('manage-room-member-list');
  list.innerHTML = '';
  if (room.type === 'public') {
    list.innerHTML = '<li class="p-list__item u-text--muted">Openbare room: iedereen op de afdeling is lid en manager.</li>';
    return;
  }
  room.members.forEach((username) => {
    const isManager = room.managers.includes(username);
    const li = document.createElement('li');
    li.className = 'p-list__item';
    li.innerHTML = `${escapeHtml(username)} ${isManager ? '<span class="room-type-badge">(manager)</span>' : ''} `;
    const removeBtn = document.createElement('button');
    removeBtn.className = 'p-button--negative is-small';
    removeBtn.type = 'button';
    removeBtn.textContent = 'Verwijderen';
    removeBtn.addEventListener('click', async () => {
      const updated = await Api.removeMember(room.id, username);
      updateRoomInState(updated);
      renderManageRoomModal(updated);
    });
    li.appendChild(removeBtn);
    list.appendChild(li);
  });
}

function updateRoomInState(updatedRoom) {
  const idx = state.rooms.findIndex((r) => r.id === updatedRoom.id);
  if (idx >= 0) state.rooms[idx] = updatedRoom; else state.rooms.push(updatedRoom);
  renderRoomList();
}
