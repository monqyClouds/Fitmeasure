// Stage 2 room client: plain browser WebRTC, no libraries.
//
// Two peer connections:
//   publish   - we offer our camera and mic, the server answers (as in the echo)
//   subscribe - the server offers everyone else's tracks, we answer; it offers
//               again whenever someone joins or leaves (renegotiation)
// Every signalling message says which connection it belongs to in `pc`.
'use strict';

const $ = (id) => document.getElementById(id);
let ws = null;
let pcs = null; // { publish, subscribe }
let me = null; // our participant ID, from the welcome
let localStream = null;
let statsTimer = null;
let lastBytes = null;
let subscribeOffers = 0;
const names = new Map(); // participant ID → name
const states = new Map(); // participant ID → { mic, camera }, as they report
let speakers = new Set(); // participant IDs speaking now, from the server
const tiles = new Map(); // participant ID → { figure, video, caption }

// Simulcast: the camera goes up as three layers at once, and the server
// sends each viewer the one that suits their tile. When the upload can't
// carry all three, the browser stops the top layers by itself and resumes
// them when it can. "f" is the full 960×540 camera.
const simulcastLayers = [
  { rid: 'q', scaleResolutionDownBy: 4, maxBitrate: 150_000 },
  { rid: 'h', scaleResolutionDownBy: 2, maxBitrate: 500_000 },
  { rid: 'f', maxBitrate: 1_200_000 },
];

// The server's estimate of how fast it can send to us, from our congestion
// feedback (stage 5). It picks each camera's layer to fit this.
let downloadEstimate = null;

// Tile sizes last sent to the server, to send only changes.
let lastLayout = '';
let layoutTimer = null;
const resizeObserver = new ResizeObserver(() => scheduleLayout());

function log(text, kind = '') {
  const li = document.createElement('li');
  const time = new Date().toLocaleTimeString([], { hour12: false });
  li.textContent = `${time}  ${text}`;
  if (kind) li.className = kind;
  $('log').prepend(li);
}

// "candidate:… 192.168.1.5 54321 typ host …" → "host 192.168.1.5:54321 udp"
function describeCandidate(c) {
  if (!c || !c.candidate) return 'end of candidates';
  const parts = c.candidate.split(' ');
  const type = parts[parts.indexOf('typ') + 1];
  return `${type} ${parts[4]}:${parts[5]} ${parts[2].toLowerCase()}`;
}

// What an SDP describes, e.g. "2 video, 2 audio (1 inactive)".
function describeSDP(sdp) {
  const sections = sdp.split(/\r?\nm=/).slice(1);
  const counts = {};
  let inactive = 0;
  for (const s of sections) {
    const [kind, port] = s.split(' ');
    // Port 0 means rejected; recvonly from the server means nothing to send us.
    if (port === '0' || /a=inactive|a=recvonly/.test(s)) {
      inactive++;
      continue;
    }
    counts[kind] = (counts[kind] ?? 0) + 1;
  }
  const active = Object.entries(counts).map(([k, n]) => `${n} ${k}`).join(', ') || 'no tracks';
  return inactive ? `${active} (${inactive} inactive)` : active;
}

function send(message) {
  // While reconnecting there's no socket; the server catches up after.
  if (ws?.readyState === WebSocket.OPEN) ws.send(JSON.stringify(message));
}

function nameOf(id) {
  return names.get(id) ?? 'Joining…';
}

function ensureTile(id) {
  let tile = tiles.get(id);
  if (tile) return tile;
  const figure = document.createElement('figure');
  figure.className = 'tile' + (id === me ? ' self' : '');
  const video = document.createElement('video');
  video.autoplay = true;
  video.playsInline = true;
  video.muted = id === me; // never play our own mic back
  const caption = document.createElement('figcaption');
  // Initials, shown instead of the black picture when the camera is off.
  const avatar = document.createElement('div');
  avatar.className = 'avatar';
  figure.append(video, avatar, caption);
  $('tiles').append(figure);
  if (id !== me) {
    // Click a tile to make it large (pin it), again to shrink it. The
    // server switches its layer to match.
    figure.title = 'Click to enlarge';
    figure.onclick = () => {
      const pinned = figure.classList.toggle('pinned');
      figure.title = pinned ? 'Click to shrink' : 'Click to enlarge';
      log(`${pinned ? 'Enlarged' : 'Shrank'} ${nameOf(id)}'s tile`);
    };
    resizeObserver.observe(figure);
  }
  tile = { figure, video, avatar, caption, detail: '' };
  tiles.set(id, tile);
  renderCaption(id);
  return tile;
}

// A microphone with a line through it.
const micOffIcon = '<svg viewBox="0 0 24 24" width="14" height="14" aria-label="muted"><path fill="currentColor" d="M19 11h-1.7c0 .74-.16 1.43-.43 2.05l1.23 1.23c.56-.98.9-2.09.9-3.28zm-4.02.17c0-.06.02-.11.02-.17V5c0-1.66-1.34-3-3-3S9 3.34 9 5v.18l5.98 5.99zM4.27 3 3 4.27l6.01 6.01V11c0 1.66 1.33 3 2.99 3 .22 0 .44-.03.65-.08l1.66 1.66c-.71.33-1.5.52-2.31.52-2.76 0-5.3-2.1-5.3-5.1H5c0 3.41 2.72 6.23 6 6.72V21h2v-3.28c.91-.13 1.77-.45 2.54-.9L19.73 21 21 19.73 4.27 3z"/></svg>';

function renderCaption(id) {
  const tile = tiles.get(id);
  if (!tile) return;
  const state = states.get(id) ?? { mic: true, camera: true };
  tile.caption.textContent = id === me ? `${nameOf(id)} (you)` : nameOf(id);
  if (!state.mic) tile.caption.insertAdjacentHTML('afterbegin', micOffIcon + ' ');
  tile.figure.classList.toggle('camera-off', !state.camera);
  tile.figure.classList.toggle('speaking', speakers.has(id));
  tile.avatar.textContent = (nameOf(id).trim()[0] ?? '?').toUpperCase();
  if (tile.detail) {
    const small = document.createElement('small');
    small.textContent = tile.detail;
    tile.caption.append(small);
  }
}

function removeTile(id) {
  const tile = tiles.get(id);
  if (!tile) return;
  tile.video.srcObject = null;
  resizeObserver.unobserve(tile.figure);
  tile.figure.remove();
  tiles.delete(id);
  scheduleLayout();
}

// Tells the server how big each person's tile is, in device pixels, so it
// can pick each one's layer. Sent shortly after tiles settle, and only when
// something changed.
function scheduleLayout() {
  clearTimeout(layoutTimer);
  layoutTimer = setTimeout(sendLayout, 250);
}

function sendLayout() {
  if (!ws || ws.readyState !== WebSocket.OPEN || !me) return;
  const dpr = window.devicePixelRatio || 1;
  const list = [];
  for (const [id, tile] of tiles) {
    if (id === me) continue;
    const r = tile.figure.getBoundingClientRect();
    list.push({ id, width: Math.round(r.width * dpr), height: Math.round(r.height * dpr) });
  }
  const json = JSON.stringify(list);
  if (json === lastLayout) return;
  lastLayout = json;
  send({ type: 'layout', tiles: list });
  log(`Layout: ${list.map((t) => `${nameOf(t.id)} ${t.width}×${t.height}`).join(', ') || 'nobody on screen'}`, 'muted');
}

async function join(event) {
  event.preventDefault();
  const name = $('name').value.trim();
  const room = $('room').value.trim();
  try { localStorage.setItem('fitmeasure-name', name); } catch {}
  history.replaceState(null, '', `?room=${encodeURIComponent(room)}`);

  $('start').disabled = true;
  $('log').replaceChildren();
  subscribeOffers = 0;
  try {
    const withAudio = $('audio').checked;
    log('Asking for the camera' + (withAudio ? ' and microphone' : ''));
    localStream = await navigator.mediaDevices.getUserMedia({
      video: { width: 960, height: 540, frameRate: 24 },
      audio: withAudio ? { echoCancellation: true, noiseSuppression: true, autoGainControl: true } : false,
    });

    roomUrl = `${location.protocol === 'https:' ? 'wss' : 'ws'}://${location.host}/ws/rooms/${encodeURIComponent(room)}`;
    await openSocket(`${roomUrl}?name=${encodeURIComponent(name)}`);
    log(`Signalling WebSocket open, joining room "${room}"`);
    $('stop').disabled = false;
  } catch (err) {
    log(`Error: ${err.message}`, 'bad');
    leave();
  }
}

// Messages are handled one at a time, in order: a candidate must not be
// applied before the offer it belongs to.
let queue = Promise.resolve();
let roomUrl = null;
let resumeToken = null; // from the welcome: lets us back in after a drop

// openSocket connects the signalling WebSocket. If it drops (rather than us
// leaving), we reconnect with the resume token; the server keeps our place
// for 20 seconds, so a phone changing networks doesn't leave the room.
async function openSocket(url) {
  const socket = new WebSocket(url);
  await new Promise((resolve, reject) => {
    socket.onopen = resolve;
    socket.onerror = () => reject(new Error('WebSocket failed to open'));
  });
  ws = socket;
  socket.onmessage = (event) => {
    const msg = JSON.parse(event.data);
    queue = queue.then(() => handle(msg)).catch((err) => log(`Error: ${err.message}`, 'bad'));
  };
  socket.onclose = () => {
    if (ws !== socket) return;
    if (!resumeToken || !pcs) {
      log('Signalling WebSocket closed');
      leave();
      return;
    }
    reconnect();
  };
}

async function reconnect() {
  log('Connection lost, reconnecting…', 'bad');
  ws = null;
  const until = Date.now() + 20_000;
  while (pcs && Date.now() < until) {
    try {
      await openSocket(`${roomUrl}?resume=${resumeToken}`);
      log('Reconnected; waiting for the server');
      return;
    } catch {
      await new Promise((r) => setTimeout(r, 1000));
    }
  }
  if (pcs) {
    log("Couldn't reconnect in time", 'bad');
    leave();
  }
}

// restartPublishICE gathers new candidates for our sending connection, as
// after changing networks; the server answers the new offer.
async function restartPublishICE() {
  const offer = await pcs.publish.createOffer({ iceRestart: true });
  await pcs.publish.setLocalDescription(offer);
  send({ type: 'offer', pc: 'publish', sdp: offer.sdp });
}

// Both peer connections are made once the welcome brings the STUN and TURN
// servers, with credentials just for us.
function createPeerConnections(iceServers) {
  const relayOnly = $('relay').checked;
  const config = { iceServers, iceTransportPolicy: relayOnly ? 'relay' : 'all' };
  const turnUrls = iceServers.flatMap((s) => s.urls).filter((u) => u.startsWith('turn'));
  if (turnUrls.length) log(`TURN servers: ${turnUrls.join(', ')}`, 'muted');
  else log('No TURN server configured: direct connections only', 'muted');
  if (relayOnly) log('Relay only: every packet goes through TURN', relayOnly && !turnUrls.length ? 'bad' : '');

  pcs = {
    publish: new RTCPeerConnection(config),
    subscribe: new RTCPeerConnection(config),
  };
  for (const [pcName, pc] of Object.entries(pcs)) {
    pc.onicecandidate = (e) => {
      if (!e.candidate) return;
      log(`Local ${pcName} candidate: ${describeCandidate(e.candidate)}`, 'muted');
      send({ type: 'candidate', pc: pcName, candidate: e.candidate.toJSON() });
    };
    pc.onconnectionstatechange = () => {
      const state = pc.connectionState;
      log(`${pcName} connection: ${state}`, state === 'connected' ? 'good' : state === 'failed' ? 'bad' : '');
      if (state === 'connected') startStats();
      // Media lost but signalling fine (say the network changed): restart
      // ICE on both connections rather than giving up. The server restarts
      // the subscribe side when asked.
      if (state === 'failed' && ws && pcName === 'publish') {
        log('Media connection failed; restarting ICE', 'bad');
        send({ type: 'restart_ice' });
        restartPublishICE().catch((err) => log(`ICE restart: ${err.message}`, 'bad'));
      }
    };
  }

  // Everyone's tracks arrive on the subscribe connection, in a stream whose
  // ID is the sender's participant ID.
  pcs.subscribe.ontrack = (e) => {
    const stream = e.streams[0];
    if (!stream) return;
    log(`Receiving ${e.track.kind} from ${nameOf(stream.id)}`, 'good');
    const tile = ensureTile(stream.id);
    if (tile.video.srcObject !== stream) tile.video.srcObject = stream;
  };
}

async function handle(msg) {
  switch (msg.type) {
    case 'welcome': {
      me = msg.id;
      resumeToken = msg.resume;
      names.set(me, $('name').value.trim());
      for (const p of msg.participants ?? []) {
        names.set(p.id, p.name);
        states.set(p.id, { mic: p.mic, camera: p.camera });
      }
      states.set(me, { mic: micOn(), camera: true });
      sendState();
      $('mic').hidden = $('cam').hidden = false;
      renderToggles();
      const others = msg.participants?.length ?? 0;
      log(`Joined as ${me}. ${others ? `Already here: ${msg.participants.map((p) => p.name).join(', ')}` : 'Nobody else here yet'}`, 'good');
      tiles.forEach((_, id) => renderCaption(id));

      createPeerConnections(msg.iceServers ?? []);
      ensureTile(me).video.srcObject = localStream;
      for (const track of localStream.getAudioTracks()) {
        pcs.publish.addTrack(track, localStream);
      }
      for (const track of localStream.getVideoTracks()) {
        pcs.publish.addTransceiver(track, {
          direction: 'sendonly',
          streams: [localStream],
          sendEncodings: simulcastLayers,
        });
      }
      const offer = await pcs.publish.createOffer();
      await pcs.publish.setLocalDescription(offer);
      log(`Publishing: sending offer for ${describeSDP(offer.sdp)}`);
      send({ type: 'offer', pc: 'publish', sdp: offer.sdp });
      break;
    }
    case 'answer':
      log('Server answered the publish offer');
      await pcs.publish.setRemoteDescription({ type: 'answer', sdp: msg.sdp });
      break;
    case 'offer': {
      subscribeOffers++;
      const what = subscribeOffers === 1 ? 'Server offers' : `Renegotiation #${subscribeOffers - 1}: server now offers`;
      log(`${what} ${describeSDP(msg.sdp)}`);
      await pcs.subscribe.setRemoteDescription({ type: 'offer', sdp: msg.sdp });
      const answer = await pcs.subscribe.createAnswer();
      await pcs.subscribe.setLocalDescription(answer);
      send({ type: 'answer', pc: 'subscribe', sdp: answer.sdp });
      break;
    }
    case 'candidate':
      log(`Server ${msg.pc} candidate: ${describeCandidate(msg.candidate)}`, 'muted');
      await pcs[msg.pc].addIceCandidate(msg.candidate);
      break;
    case 'participant_joined':
      names.set(msg.participant.id, msg.participant.name);
      states.set(msg.participant.id, { mic: msg.participant.mic, camera: msg.participant.camera });
      renderCaption(msg.participant.id);
      log(`${msg.participant.name} joined`, 'good');
      break;
    case 'participant_left':
      log(`${msg.participant.name} left`);
      removeTile(msg.participant.id);
      names.delete(msg.participant.id);
      break;
    case 'resumed': {
      // Back in the room. Catch up on who's here now: anyone who left while
      // we were away goes, and their state is current.
      const here = new Set((msg.participants ?? []).map((p) => p.id));
      for (const p of msg.participants ?? []) {
        names.set(p.id, p.name);
        states.set(p.id, { mic: p.mic, camera: p.camera });
        renderCaption(p.id);
      }
      for (const id of [...tiles.keys()]) {
        if (id !== me && !here.has(id)) {
          removeTile(id);
          names.delete(id);
        }
      }
      log('Back in the room; restarting ICE', 'good');
      sendState();
      lastLayout = '';
      sendLayout();
      await restartPublishICE();
      break;
    }
    case 'participant_changed': {
      const p = msg.participant;
      const before = states.get(p.id);
      states.set(p.id, { mic: p.mic, camera: p.camera });
      renderCaption(p.id);
      if (before && before.mic !== p.mic) log(`${p.name} ${p.mic ? 'unmuted' : 'muted'}`);
      if (before && before.camera !== p.camera) log(`${p.name} turned their camera ${p.camera ? 'on' : 'off'}`);
      break;
    }
    case 'speakers': {
      // Everyone speaking now, including us; the tiles' outlines follow.
      const was = speakers;
      speakers = new Set(msg.speakers ?? []);
      for (const id of new Set([...was, ...speakers])) renderCaption(id);
      break;
    }
    case 'estimate':
      downloadEstimate = msg.bitrate;
      break;
    case 'error':
      log(`Server error: ${msg.error}`, 'bad');
      break;
  }
}

function micOn() {
  return localStream?.getAudioTracks().some((t) => t.enabled) ?? false;
}

function cameraOn() {
  return localStream?.getVideoTracks().some((t) => t.enabled) ?? false;
}

// Tells everyone (through the server) whether our mic and camera are on.
// A disabled track still sends silence or black frames; the server stops
// forwarding video from a camera that's off.
function sendState() {
  if (!ws || ws.readyState !== WebSocket.OPEN) return;
  send({ type: 'state', mic: micOn(), camera: cameraOn() });
  states.set(me, { mic: micOn(), camera: cameraOn() });
  renderCaption(me);
}

function renderToggles() {
  $('mic').textContent = micOn() ? 'Mute' : 'Unmute';
  $('cam').textContent = cameraOn() ? 'Camera off' : 'Camera on';
  $('mic').classList.toggle('off', !micOn());
  $('cam').classList.toggle('off', !cameraOn());
}

function toggle(kind) {
  const tracks = kind === 'mic' ? localStream?.getAudioTracks() : localStream?.getVideoTracks();
  if (!tracks?.length) return;
  const on = !tracks.some((t) => t.enabled);
  tracks.forEach((t) => (t.enabled = on));
  renderToggles();
  sendState();
}

function leave() {
  clearInterval(statsTimer);
  statsTimer = null;
  lastBytes = null;
  lastLayout = '';
  downloadEstimate = null;
  clearTimeout(layoutTimer);
  if (localStream) {
    localStream.getTracks().forEach((t) => t.stop());
    localStream = null;
  }
  if (pcs) {
    pcs.publish.close();
    pcs.subscribe.close();
    pcs = null;
    log('Left the room');
  }
  resumeToken = null;
  if (ws) {
    ws.onclose = null;
    ws.close(1000); // a deliberate leave, not a dropped connection
    ws = null;
  }
  for (const id of [...tiles.keys()]) removeTile(id);
  names.clear();
  states.clear();
  speakers = new Set();
  $('mic').hidden = $('cam').hidden = true;
  me = null;
  $('stats').replaceChildren();
  $('start').disabled = false;
  $('stop').disabled = true;
}

function startStats() {
  if (statsTimer) return;
  statsTimer = setInterval(showStats, 1000);
}

function describeVideo(s) {
  return `${s.frameWidth ?? '?'}×${s.frameHeight ?? '?'} · ${Math.round(s.framesPerSecond ?? 0)} fps`;
}

async function showStats() {
  if (!pcs) return;
  const [pub, sub] = await Promise.all([pcs.publish.getStats(), pcs.subscribe.getStats()]);
  if (!pcs) return;
  const rows = {};
  let sentBytes = 0;
  let receivedBytes = 0;
  const sending = []; // one per simulcast layer
  const repairs = { nacks: 0, resent: 0, plis: 0 };

  pub.forEach((s) => {
    if (s.type === 'outbound-rtp') sentBytes += s.bytesSent;
    if (s.type === 'outbound-rtp' && s.kind === 'video') {
      sending.push(s);
      // NACK: the server asked us to resend lost packets. PLI: a receiver
      // couldn't decode and asked for a keyframe (relayed by the server).
      repairs.nacks += s.nackCount ?? 0;
      repairs.resent += s.retransmittedPacketsSent ?? 0;
      repairs.plis += s.pliCount ?? 0;
    }
  });
  // Each layer, smallest first; a layer the browser has stopped for lack of
  // bandwidth shows as off.
  const order = { q: 0, h: 1, f: 2 };
  sending.sort((a, b) => (order[a.rid] ?? 0) - (order[b.rid] ?? 0));
  rows['Sending'] = sending
    .map((s) => `${s.rid ?? ''} ${s.active === false || !s.framesPerSecond ? 'off' : describeVideo(s)}`)
    .join('  ·  ');
  const top = sending.filter((s) => s.framesPerSecond).at(-1);
  if (top) setDetail(me, `${top.rid} ${describeVideo(top)}`);
  rows['Sending repairs'] = `${repairs.nacks} NACKs, ${repairs.resent} packets resent, ${repairs.plis} keyframe requests`;

  for (const [label, report] of [['Publish path', pub], ['Subscribe path', sub]]) {
    const path = describePath(report);
    if (!path) continue;
    rows[label] = path.text;
    if (label === 'Publish path' && path.rtt !== undefined) rows['Round trip'] = `${Math.round(path.rtt * 1000)} ms`;
    if (label === 'Publish path' && path.availableKbps) rows['Upload estimate'] = `${path.availableKbps} kbit/s`;
  }

  // Inbound video stats name the track; the track's stream is the sender.
  const streamOfTrack = new Map();
  for (const r of pcs.subscribe.getReceivers()) {
    for (const [id, tile] of tiles) {
      if (tile.video.srcObject?.getTracks().includes(r.track)) streamOfTrack.set(r.track.id, id);
    }
  }
  let receiving = 0;
  const losses = { lost: 0, nacks: 0, plis: 0 };
  sub.forEach((s) => {
    if (s.type === 'inbound-rtp') receivedBytes += s.bytesReceived;
    if (s.type === 'inbound-rtp' && s.kind === 'video') {
      losses.lost += s.packetsLost ?? 0;
      losses.nacks += s.nackCount ?? 0;
      losses.plis += s.pliCount ?? 0;
    }
    if (s.type === 'inbound-rtp' && s.kind === 'video' && s.bytesReceived > 0) {
      receiving++;
      const id = streamOfTrack.get(s.trackIdentifier);
      if (id) setDetail(id, describeVideo(s));
    }
  });

  rows['In the room'] = `${names.size} ${names.size === 1 ? 'person' : 'people'}`;
  rows['Receiving'] = `${receiving} video ${receiving === 1 ? 'stream' : 'streams'}`;
  rows['Receiving repairs'] = `${losses.lost} packets lost, ${losses.nacks} NACKs, ${losses.plis} keyframe requests`;
  if (downloadEstimate) rows['Download estimate'] = `${Math.round(downloadEstimate / 1000)} kbit/s (the server's, from our feedback)`;
  if (lastBytes) {
    rows['Upload'] = `${Math.round(((sentBytes - lastBytes.sent) * 8) / 1000)} kbit/s`;
    rows['Download'] = `${Math.round(((receivedBytes - lastBytes.received) * 8) / 1000)} kbit/s`;
  }
  lastBytes = { sent: sentBytes, received: receivedBytes };

  const dl = $('stats');
  dl.replaceChildren();
  for (const [k, v] of Object.entries(rows)) {
    const dt = document.createElement('dt');
    dt.textContent = k;
    const dd = document.createElement('dd');
    dd.textContent = v;
    dl.append(dt, dd);
  }
}

// The candidate pair ICE chose, e.g. "relay via TURN over tls: … → host …".
// Candidate types: host (a local address), srflx (our public address as a
// STUN server saw it), prflx (learned during checks), relay (a TURN server).
function describePath(report) {
  let pair;
  report.forEach((s) => {
    if (s.type === 'transport' && s.selectedCandidatePairId) pair = report.get(s.selectedCandidatePairId);
  });
  if (!pair) {
    report.forEach((s) => {
      if (s.type === 'candidate-pair' && s.nominated && s.state === 'succeeded') pair = s;
    });
  }
  if (!pair) return null;
  const local = report.get(pair.localCandidateId);
  const remote = report.get(pair.remoteCandidateId);
  const how = local?.candidateType === 'relay' ? `relay via TURN over ${local.relayProtocol ?? '?'}` : local?.candidateType;
  return {
    text: `${how} ${local?.address || '(address hidden)'} → ${remote?.candidateType} ${remote?.address ?? ''}:${remote?.port ?? ''} (${local?.protocol})`,
    rtt: pair.currentRoundTripTime,
    // The sender's bandwidth estimate, from the server's congestion
    // feedback (TWCC). Chrome reports it; Firefox doesn't.
    availableKbps: pair.availableOutgoingBitrate ? Math.round(pair.availableOutgoingBitrate / 1000) : null,
  };
}

function setDetail(id, detail) {
  const tile = tiles.get(id);
  if (!tile || tile.detail === detail) return;
  tile.detail = detail;
  renderCaption(id);
}

const params = new URLSearchParams(location.search);
$('room').value = params.get('room') || 'gym';
try { $('name').value = localStorage.getItem('fitmeasure-name') || ''; } catch {}
$('join').onsubmit = join;
$('stop').onclick = leave;
$('mic').onclick = () => toggle('mic');
$('cam').onclick = () => toggle('cam');
