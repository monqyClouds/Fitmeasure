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
  ws.send(JSON.stringify(message));
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
  figure.append(video, caption);
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
  tile = { figure, video, caption, detail: '' };
  tiles.set(id, tile);
  renderCaption(id);
  return tile;
}

function renderCaption(id) {
  const tile = tiles.get(id);
  if (!tile) return;
  tile.caption.textContent = id === me ? `${nameOf(id)} (you)` : nameOf(id);
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

    const scheme = location.protocol === 'https:' ? 'wss' : 'ws';
    ws = new WebSocket(`${scheme}://${location.host}/ws/rooms/${encodeURIComponent(room)}?name=${encodeURIComponent(name)}`);
    await new Promise((resolve, reject) => {
      ws.onopen = resolve;
      ws.onerror = () => reject(new Error('WebSocket failed to open'));
    });
    log(`Signalling WebSocket open, joining room "${room}"`);

    // Messages are handled one at a time, in order: a candidate must not be
    // applied before the offer it belongs to.
    let queue = Promise.resolve();
    ws.onmessage = (event) => {
      const msg = JSON.parse(event.data);
      queue = queue.then(() => handle(msg)).catch((err) => log(`Error: ${err.message}`, 'bad'));
    };
    ws.onclose = () => {
      log('Signalling WebSocket closed');
      leave();
    };
    $('stop').disabled = false;
  } catch (err) {
    log(`Error: ${err.message}`, 'bad');
    leave();
  }
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
      if (state === 'failed') leave();
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
      names.set(me, $('name').value.trim());
      for (const p of msg.participants ?? []) names.set(p.id, p.name);
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
      renderCaption(msg.participant.id);
      log(`${msg.participant.name} joined`, 'good');
      break;
    case 'participant_left':
      log(`${msg.participant.name} left`);
      removeTile(msg.participant.id);
      names.delete(msg.participant.id);
      break;
    case 'error':
      log(`Server error: ${msg.error}`, 'bad');
      break;
  }
}

function leave() {
  clearInterval(statsTimer);
  statsTimer = null;
  lastBytes = null;
  lastLayout = '';
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
  if (ws) {
    ws.onclose = null;
    ws.close();
    ws = null;
  }
  for (const id of [...tiles.keys()]) removeTile(id);
  names.clear();
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
