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
  tile.figure.remove();
  tiles.delete(id);
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

    // No STUN/TURN yet: on one network, host candidates are enough.
    pcs = {
      publish: new RTCPeerConnection({ iceServers: [] }),
      subscribe: new RTCPeerConnection({ iceServers: [] }),
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

    // Messages are handled one at a time, in order: a candidate must not be
    // applied before the offer it belongs to.
    let queue = Promise.resolve();
    ws.onmessage = (event) => {
      const msg = JSON.parse(event.data);
      queue = queue.then(() => handle(msg)).catch((err) => log(`Error: ${err.message}`, 'bad'));
    };
    ws.onclose = () => {
      log('Signalling WebSocket closed');
      if (pcs) leave();
    };
    $('stop').disabled = false;
  } catch (err) {
    log(`Error: ${err.message}`, 'bad');
    leave();
  }
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

      ensureTile(me).video.srcObject = localStream;
      for (const track of localStream.getTracks()) {
        pcs.publish.addTrack(track, localStream);
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

  const pubById = new Map();
  pub.forEach((s) => pubById.set(s.id, s));
  pub.forEach((s) => {
    if (s.type === 'outbound-rtp') sentBytes += s.bytesSent;
    if (s.type === 'outbound-rtp' && s.kind === 'video') {
      rows['Sending'] = describeVideo(s);
      setDetail(me, describeVideo(s));
    }
    if (s.type === 'candidate-pair' && s.nominated && s.state === 'succeeded') {
      const local = pubById.get(s.localCandidateId);
      const remote = pubById.get(s.remoteCandidateId);
      rows['Path'] = `${local?.candidateType} ${local?.address || '(address hidden by browser)'} → ${remote?.candidateType} ${remote?.address ?? ''}:${remote?.port ?? ''} (${local?.protocol})`;
      if (s.currentRoundTripTime !== undefined) rows['Round trip'] = `${Math.round(s.currentRoundTripTime * 1000)} ms`;
    }
  });

  // Inbound video stats name the track; the track's stream is the sender.
  const streamOfTrack = new Map();
  for (const r of pcs.subscribe.getReceivers()) {
    for (const [id, tile] of tiles) {
      if (tile.video.srcObject?.getTracks().includes(r.track)) streamOfTrack.set(r.track.id, id);
    }
  }
  let receiving = 0;
  sub.forEach((s) => {
    if (s.type === 'inbound-rtp') receivedBytes += s.bytesReceived;
    if (s.type === 'inbound-rtp' && s.kind === 'video' && s.bytesReceived > 0) {
      receiving++;
      const id = streamOfTrack.get(s.trackIdentifier);
      if (id) setDetail(id, describeVideo(s));
    }
  });

  rows['In the room'] = `${names.size} ${names.size === 1 ? 'person' : 'people'}`;
  rows['Receiving'] = `${receiving} video ${receiving === 1 ? 'stream' : 'streams'}`;
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
