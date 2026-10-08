// Stage 1 echo client: plain browser WebRTC, no libraries, so every step of a
// connection is visible. Open the browser's chrome://webrtc-internals (or
// about:webrtc in Firefox) alongside for even more detail.
'use strict';

const $ = (id) => document.getElementById(id);
let pc = null;
let ws = null;
let statsTimer = null;
let lastBytes = null;

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

function send(message) {
  ws.send(JSON.stringify(message));
}

async function start() {
  $('start').disabled = true;
  $('log').replaceChildren();
  try {
    const withAudio = $('audio').checked;
    log('Asking for the camera' + (withAudio ? ' and microphone' : ''));
    const stream = await navigator.mediaDevices.getUserMedia({
      video: { width: 1280, height: 720, frameRate: 24 },
      audio: withAudio,
    });
    $('local').srcObject = stream;

    const scheme = location.protocol === 'https:' ? 'wss' : 'ws';
    ws = new WebSocket(`${scheme}://${location.host}/ws/echo`);
    await new Promise((resolve, reject) => {
      ws.onopen = resolve;
      ws.onerror = () => reject(new Error('WebSocket failed to open'));
    });
    log('Signalling WebSocket open');

    // No STUN/TURN yet: on one network, host candidates are enough. Stage 3
    // adds a TURN server for phones on mobile data.
    pc = new RTCPeerConnection({ iceServers: [] });

    for (const track of stream.getTracks()) {
      pc.addTrack(track, stream);
      log(`Added local ${track.kind} track: ${track.label}`);
    }

    pc.ontrack = (e) => {
      log(`Receiving ${e.track.kind} back from the server`, 'good');
      $('remote').srcObject = e.streams[0];
    };

    pc.onicecandidate = (e) => {
      if (!e.candidate) {
        log('Finished gathering local candidates');
        return;
      }
      log(`Local candidate: ${describeCandidate(e.candidate)}`, 'muted');
      send({ type: 'candidate', candidate: e.candidate.toJSON() });
    };

    pc.oniceconnectionstatechange = () => log(`ICE state: ${pc.iceConnectionState}`);
    pc.onconnectionstatechange = () => {
      const state = pc.connectionState;
      log(`Connection state: ${state}`, state === 'connected' ? 'good' : state === 'failed' ? 'bad' : '');
      if (state === 'connected') startStats();
      if (state === 'failed') stop();
    };

    ws.onmessage = async (event) => {
      const msg = JSON.parse(event.data);
      switch (msg.type) {
        case 'answer':
          log('Received answer from the server');
          await pc.setRemoteDescription({ type: 'answer', sdp: msg.sdp });
          break;
        case 'candidate':
          log(`Server candidate: ${describeCandidate(msg.candidate)}`, 'muted');
          await pc.addIceCandidate(msg.candidate);
          break;
        case 'error':
          log(`Server error: ${msg.error}`, 'bad');
          break;
      }
    };
    ws.onclose = () => {
      log('Signalling WebSocket closed');
      if (pc) stop();
    };

    const offer = await pc.createOffer();
    await pc.setLocalDescription(offer);
    log(`Created offer (${offer.sdp.split('\n').length} lines of SDP), sending it`);
    send({ type: 'offer', sdp: offer.sdp });
    $('stop').disabled = false;
  } catch (err) {
    log(`Error: ${err.message}`, 'bad');
    stop();
  }
}

function stop() {
  clearInterval(statsTimer);
  statsTimer = null;
  lastBytes = null;
  if (pc) {
    pc.getSenders().forEach((s) => s.track && s.track.stop());
    pc.close();
    pc = null;
    log('Closed the peer connection');
  }
  if (ws) {
    ws.onclose = null;
    ws.close();
    ws = null;
  }
  $('local').srcObject = null;
  $('remote').srcObject = null;
  $('start').disabled = false;
  $('stop').disabled = true;
}

function startStats() {
  if (statsTimer) return;
  statsTimer = setInterval(showStats, 1000);
}

async function showStats() {
  if (!pc) return;
  const report = await pc.getStats();
  const byId = new Map();
  report.forEach((s) => byId.set(s.id, s));

  const rows = {};
  let sentBytes = 0;
  let receivedBytes = 0;
  report.forEach((s) => {
    if (s.type === 'outbound-rtp' && s.kind === 'video') {
      sentBytes = s.bytesSent;
      rows['Sending'] = `${s.frameWidth ?? '?'}×${s.frameHeight ?? '?'} at ${Math.round(s.framesPerSecond ?? 0)} fps`;
      const codec = byId.get(s.codecId);
      if (codec) rows['Codec'] = codec.mimeType;
    }
    if (s.type === 'inbound-rtp' && s.kind === 'video') {
      receivedBytes = s.bytesReceived;
      rows['Receiving'] = `${s.frameWidth ?? '?'}×${s.frameHeight ?? '?'} at ${Math.round(s.framesPerSecond ?? 0)} fps`;
      rows['Packets lost'] = `${s.packetsLost} of ${s.packetsReceived + s.packetsLost}`;
      rows['Jitter'] = `${Math.round((s.jitter ?? 0) * 1000)} ms`;
    }
    if (s.type === 'candidate-pair' && s.nominated && s.state === 'succeeded') {
      const local = byId.get(s.localCandidateId);
      const remote = byId.get(s.remoteCandidateId);
      rows['Path'] = `${local?.candidateType} ${local?.address || '(address hidden by browser)'} → ${remote?.candidateType} ${remote?.address ?? ''}:${remote?.port ?? ''} (${local?.protocol})`;
      if (s.currentRoundTripTime !== undefined) {
        rows['Round trip'] = `${Math.round(s.currentRoundTripTime * 1000)} ms`;
      }
    }
  });

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

$('start').onclick = start;
$('stop').onclick = stop;
