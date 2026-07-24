// Thin fetch() wrapper for the /api/* REST surface. Real-time traffic
// (chat, presence, calls) goes over ws.js instead.

async function request(method, path, body) {
  const opts = { method, headers: {} };
  if (body !== undefined) {
    opts.headers['Content-Type'] = 'application/json';
    opts.body = JSON.stringify(body);
  }
  const res = await fetch(path, opts);
  if (!res.ok) {
    let message = `${res.status} ${res.statusText}`;
    try {
      const data = await res.json();
      if (data && data.error) message = data.error;
    } catch (e) {
      /* body wasn't JSON - keep the generic message */
    }
    const err = new Error(message);
    err.status = res.status;
    throw err;
  }
  if (res.status === 204) return null;
  const text = await res.text();
  return text ? JSON.parse(text) : null;
}

function uploadFile(roomId, file, onProgress) {
  return new Promise((resolve, reject) => {
    const xhr = new XMLHttpRequest();
    xhr.open('POST', `/api/rooms/${encodeURIComponent(roomId)}/files`);
    xhr.upload.onprogress = (e) => {
      if (onProgress && e.lengthComputable) onProgress(e.loaded / e.total);
    };
    xhr.onload = () => {
      if (xhr.status >= 200 && xhr.status < 300) {
        resolve(JSON.parse(xhr.responseText));
      } else {
        let message = `Upload mislukt (${xhr.status})`;
        try {
          const data = JSON.parse(xhr.responseText);
          if (data && data.error) message = data.error;
        } catch (e) { /* ignore */ }
        reject(new Error(message));
      }
    };
    xhr.onerror = () => reject(new Error('Uploadfout (netwerk).'));
    const form = new FormData();
    form.append('file', file, file.name);
    xhr.send(form);
  });
}

export const Api = {
  me: () => request('GET', '/api/me'),
  login: (username) => request('POST', '/api/login', { username }),
  logout: () => request('POST', '/api/logout'),
  updateMySettings: (body) => request('PUT', '/api/me/settings', body),

  rooms: () => request('GET', '/api/rooms'),
  createRoom: (body) => request('POST', '/api/rooms', body),
  updateRoom: (id, body) => request('PATCH', `/api/rooms/${encodeURIComponent(id)}`, body),
  deleteRoom: (id) => request('DELETE', `/api/rooms/${encodeURIComponent(id)}`),
  addMember: (id, body) => request('POST', `/api/rooms/${encodeURIComponent(id)}/members`, body),
  removeMember: (id, username) => request('DELETE', `/api/rooms/${encodeURIComponent(id)}/members/${encodeURIComponent(username)}`),
  messages: (id, limit = 100) => request('GET', `/api/rooms/${encodeURIComponent(id)}/messages?limit=${limit}`),

  requestRoom: (body) => request('POST', '/api/room-requests', body),
  roomRequests: () => request('GET', '/api/room-requests'),
  approveRoomRequest: (id, body) => request('POST', `/api/room-requests/${encodeURIComponent(id)}/approve`, body),
  rejectRoomRequest: (id) => request('POST', `/api/room-requests/${encodeURIComponent(id)}/reject`, {}),

  uploadFile,

  adminConfig: () => request('GET', '/api/admin/config'),
  updateAdminConfig: (body) => request('PUT', '/api/admin/config', body),
  adminUsers: () => request('GET', '/api/admin/users'),
  setUserAdmin: (username, isAdmin) => request('PUT', `/api/admin/users/${encodeURIComponent(username)}/admin`, { isAdmin }),
};
