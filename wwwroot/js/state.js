// Central, mutable application state shared between the feature modules.
// Kept intentionally simple (no framework) since the whole client is a
// small hand-rolled SPA loaded as native ES modules.
export const state = {
  me: null,
  rooms: [],
  activeRoomId: null,
  onlineByRoom: {},
  call: {
    active: false,
    roomId: null,
    callId: null,
    micOn: false,
    sharingScreen: false,
  },
};
