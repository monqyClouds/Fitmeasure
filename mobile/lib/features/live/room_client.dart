import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'live_protocol.dart';

/// The live sessions server. Override for a local server with
/// `--dart-define=LIVE_SERVER=http://192.168.0.134:8282`.
final liveServer = Uri.parse(
  const String.fromEnvironment(
    'LIVE_SERVER',
    defaultValue: 'https://live.somto.si',
  ),
);

/// Whether the server answers its health check.
Future<bool> liveServerOnline() async {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 6);
  try {
    final req = await client.getUrl(liveServer.replace(path: '/healthz'));
    final res = await req.close().timeout(const Duration(seconds: 6));
    await res.drain<void>();
    return res.statusCode == 200;
  } catch (_) {
    return false;
  } finally {
    client.close(force: true);
  }
}

enum RoomState { connecting, live, ended }

/// Simulcast: the camera goes up as three layers at once, and the server
/// sends each viewer the one that suits their tile. When the upload can't
/// carry all three, the encoder stops the top layers by itself and resumes
/// them when it can. "f" is the full 960×540 camera.
final simulcastLayers = [
  RTCRtpEncoding(rid: 'q', scaleResolutionDownBy: 4, maxBitrate: 150000),
  RTCRtpEncoding(rid: 'h', scaleResolutionDownBy: 2, maxBitrate: 500000),
  RTCRtpEncoding(rid: 'f', maxBitrate: 1200000),
];

/// The upload all three layers need, in kbit/s.
const fullQualityKbps = 1850;

/// Someone else in the room. Their camera and mic arrive on the subscribe
/// connection, in a stream whose ID is their participant ID.
class RemoteParticipant {
  RemoteParticipant(this.id, this.name);

  final String id;
  String name;
  final renderer = RTCVideoRenderer();
  MediaStream? stream;
  bool hasVideo = false;

  // Audio and video arrive as two track events moments apart. Both must
  // wait on the same initialisation: initialising twice creates a second
  // texture, and the tile may keep showing the first, which gets no frames.
  Future<void>? _rendererInit;

  Future<void> _attach(MediaStream s) async {
    await (_rendererInit ??= renderer.initialize());
    stream = s;
    renderer.srcObject = s;
  }

  Future<void> _dispose() async {
    if (_rendererInit case final init?) {
      await init;
      renderer.srcObject = null;
      await renderer.dispose();
    }
  }
}

/// How our media is getting to the server, for the connection sheet.
class LinkInfo {
  const LinkInfo({
    this.path,
    this.relayed = false,
    this.roundTripMs,
    this.uploadKbps,
    this.sending,
    this.downloadKbps,
  });

  /// e.g. "Direct (udp)" or "Relayed through TURN (tcp)".
  final String? path;
  final bool relayed;
  final int? roundTripMs;

  /// The bandwidth estimate for what we send.
  final int? uploadKbps;

  /// What each simulcast layer is sending, e.g. "q 240×135 · h 480×270 ·
  /// f off".
  final String? sending;

  /// The server's estimate of how fast it can send to us, from our
  /// congestion feedback. It picks each camera's layer to fit.
  final int? downloadKbps;
}

/// One person's connection to a room: the signalling WebSocket and two peer
/// connections, as described in live_protocol.dart.
class RoomClient extends ChangeNotifier {
  RoomClient({
    required this.room,
    required this.name,
    required this.localStream,
  });

  final String room;
  final String name;

  /// Our camera and mic, opened by the pre-join screen. The client owns it
  /// from here and stops it on leave.
  final MediaStream localStream;

  RoomState state = RoomState.connecting;

  /// Why the room ended, if not by leaving.
  String? endReason;
  String? myId;

  /// Everyone else, in the order they appeared.
  final participants = <String, RemoteParticipant>{};

  bool get micOn => localStream.getAudioTracks().any((t) => t.enabled);
  bool get cameraOn => localStream.getVideoTracks().any((t) => t.enabled);
  bool frontCamera = true;
  LinkInfo link = const LinkInfo();
  int? _downloadKbps;

  WebSocketChannel? _ws;
  StreamSubscription<dynamic>? _wsSub;
  RTCPeerConnection? _pub;
  RTCPeerConnection? _sub;
  bool _pubRemoteSet = false;
  bool _subRemoteSet = false;
  final _pendingCandidates = <String, List<CandidateInit>>{};
  Future<void> _queue = Future.value();
  Timer? _statsTimer;
  // Tile sizes reported by the screen, sent to the server when they change.
  final _tiles = <String, TileSize>{};
  String _sentLayout = '';
  Timer? _layoutTimer;
  bool _closed = false;
  bool _disposed = false;

  Future<void> join() async {
    final uri = liveServer.replace(
      scheme: liveServer.scheme == 'https' ? 'wss' : 'ws',
      path: '/ws/rooms/$room',
      queryParameters: {'name': name},
    );
    try {
      final ws = WebSocketChannel.connect(uri);
      _ws = ws;
      await ws.ready;
      _wsSub = ws.stream.listen(
        (data) {
          final msg = SignalMessage.decode(data as String);
          // One message at a time, in order: a candidate must not be
          // applied before the offer it belongs to.
          _queue = _queue
              .then((_) => _handle(msg))
              .catchError((Object e) => _end('Something went wrong: $e'));
        },
        // After any queued messages, so a refusal like "room is full"
        // explains the close rather than being lost to it.
        onDone: () =>
            _queue = _queue.then((_) => _end('Disconnected from the server')),
        onError: (_) => _queue = _queue.then(
          (_) => _end('Lost the connection to the server'),
        ),
      );
    } catch (_) {
      await _end("Couldn't reach the server");
    }
  }

  void _send(SignalMessage m) => _ws?.sink.add(m.encode());

  Future<void> _handle(SignalMessage msg) async {
    if (_closed) return;
    switch (msg.type) {
      case SignalType.welcome:
        myId = msg.id;
        for (final p in msg.participants) {
          participants[p.id] = RemoteParticipant(p.id, p.name);
        }
        notifyListeners();
        await _connect(msg.iceServers);

      case SignalType.answer:
        await _pub!.setRemoteDescription(
          RTCSessionDescription(msg.sdp, 'answer'),
        );
        _pubRemoteSet = true;
        await _flushCandidates(PeerName.publish);

      case SignalType.offer when msg.pc == PeerName.subscribe:
        await _sub!.setRemoteDescription(
          RTCSessionDescription(msg.sdp, 'offer'),
        );
        _subRemoteSet = true;
        final answer = await _sub!.createAnswer();
        await _sub!.setLocalDescription(answer);
        _send(
          SignalMessage(
            type: SignalType.answer,
            pc: PeerName.subscribe,
            sdp: answer.sdp,
          ),
        );
        await _flushCandidates(PeerName.subscribe);

      case SignalType.candidate:
        final c = msg.candidate;
        if (c == null) return;
        final ready = msg.pc == PeerName.publish
            ? _pubRemoteSet
            : _subRemoteSet;
        if (!ready) {
          (_pendingCandidates[msg.pc!] ??= []).add(c);
          return;
        }
        await _addCandidate(msg.pc!, c);

      case SignalType.participantJoined:
        final p = msg.participant!;
        (participants[p.id] ??= RemoteParticipant(p.id, p.name)).name = p.name;
        notifyListeners();

      case SignalType.participantLeft:
        final p = participants.remove(msg.participant!.id);
        _tiles.remove(msg.participant!.id);
        notifyListeners();
        await p?._dispose();

      case SignalType.estimate:
        if (msg.bitrate case final b?) _downloadKbps = (b / 1000).round();

      case SignalType.error:
        // Before the welcome an error means we weren't let in (e.g. the
        // room is full); after it, it's informational.
        if (myId == null) await _end(_describeError(msg.error));
        debugPrint('live: server error: ${msg.error}');
    }
  }

  String _describeError(String? error) => switch (error) {
    'room is full' => 'This room is full (4 people)',
    final e? => 'The server said: $e',
    null => 'The server refused to let you in',
  };

  /// Creates both peer connections with the STUN and TURN servers from the
  /// welcome, and offers our camera and mic.
  Future<void> _connect(List<Map<String, dynamic>> iceServers) async {
    final config = {'iceServers': iceServers, 'sdpSemantics': 'unified-plan'};
    final pub = _pub = await createPeerConnection(config);
    final sub = _sub = await createPeerConnection(config);

    for (final (pcName, pc) in [
      (PeerName.publish, pub),
      (PeerName.subscribe, sub),
    ]) {
      pc.onIceCandidate = (c) {
        if (c.candidate == null) return;
        _send(
          SignalMessage(
            type: SignalType.candidate,
            pc: pcName,
            candidate: CandidateInit(
              candidate: c.candidate!,
              sdpMid: c.sdpMid,
              sdpMLineIndex: c.sdpMLineIndex,
            ),
          ),
        );
      };
      pc.onConnectionState = (s) {
        if (s == RTCPeerConnectionState.RTCPeerConnectionStateFailed) {
          _end('The connection failed');
        }
        if (pcName == PeerName.publish &&
            s == RTCPeerConnectionState.RTCPeerConnectionStateConnected &&
            state == RoomState.connecting) {
          state = RoomState.live;
          _statsTimer ??= Timer.periodic(
            const Duration(seconds: 1),
            (_) => _updateLink(),
          );
          notifyListeners();
        }
      };
    }

    sub.onTrack = (e) {
      if (e.streams.isEmpty) return;
      final stream = e.streams.first;
      final p = participants[stream.id] ??= RemoteParticipant(stream.id, '');
      if (e.track.kind == 'video') p.hasVideo = true;
      p._attach(stream).then((_) => notifyListeners());
    };

    for (final track in localStream.getAudioTracks()) {
      await pub.addTrack(track, localStream);
    }
    for (final track in localStream.getVideoTracks()) {
      await pub.addTransceiver(
        track: track,
        kind: RTCRtpMediaType.RTCRtpMediaTypeVideo,
        init: RTCRtpTransceiverInit(
          direction: TransceiverDirection.SendOnly,
          streams: [localStream],
          sendEncodings: simulcastLayers,
        ),
      );
    }
    final offer = await pub.createOffer();
    await pub.setLocalDescription(offer);
    _send(
      SignalMessage(
        type: SignalType.offer,
        pc: PeerName.publish,
        sdp: offer.sdp,
      ),
    );

    // Calls are loud and hands-free: use the speaker, or earbuds if
    // they're connected.
    unawaited(Helper.setSpeakerphoneOnButPreferBluetooth());
  }

  Future<void> _addCandidate(String pcName, CandidateInit c) async {
    final pc = pcName == PeerName.publish ? _pub : _sub;
    try {
      await pc?.addCandidate(
        RTCIceCandidate(c.candidate, c.sdpMid, c.sdpMLineIndex),
      );
    } catch (e) {
      debugPrint('live: bad $pcName candidate: $e');
    }
  }

  Future<void> _flushCandidates(String pcName) async {
    for (final c in _pendingCandidates.remove(pcName) ?? const []) {
      await _addCandidate(pcName, c);
    }
  }

  /// Reads the publish connection's stats once a second: the path ICE
  /// chose, the upload estimate, what we're sending; and adapts the picture
  /// size to the estimate.
  Future<void> _updateLink() async {
    final pub = _pub;
    if (pub == null || _closed) return;
    final reports = await pub.getStats();
    final byId = {for (final r in reports) r.id: r};

    StatsReport? pair;
    for (final r in reports) {
      final selected = r.values['selectedCandidatePairId'];
      if (r.type == 'transport' && selected != null) pair = byId[selected];
    }
    pair ??= reports
        .where(
          (r) =>
              r.type == 'candidate-pair' &&
              r.values['nominated'] == true &&
              r.values['state'] == 'succeeded',
        )
        .firstOrNull;

    String? path;
    var relayed = false;
    int? rtt;
    int? upload;
    if (pair != null) {
      final local = byId[pair.values['localCandidateId']];
      final type = local?.values['candidateType'];
      relayed = type == 'relay';
      path = relayed
          ? 'Relayed through TURN (${local?.values['relayProtocol'] ?? 'udp'})'
          : 'Direct (${local?.values['protocol'] ?? 'udp'})';
      if (pair.values['currentRoundTripTime'] case final num t) {
        rtt = (t * 1000).round();
      }
      if (pair.values['availableOutgoingBitrate'] case final num b) {
        upload = (b / 1000).round();
      }
    }

    // One outbound stream per simulcast layer, smallest first.
    final layers = <String, String>{};
    for (final r in reports) {
      if (r.type == 'outbound-rtp' && r.values['kind'] == 'video') {
        final w = r.values['frameWidth'];
        final h = r.values['frameHeight'];
        final fps = (r.values['framesPerSecond'] as num? ?? 0).round();
        layers[r.values['rid'] as String? ?? ''] =
            w != null && h != null && fps > 0 ? '$w×$h' : 'off';
      }
    }
    final sending = layers.isEmpty
        ? null
        : [
            for (final rid in ['q', 'h', 'f', ''])
              if (layers[rid] case final v?) '$rid $v'.trim(),
          ].join(' · ');

    link = LinkInfo(
      path: path,
      relayed: relayed,
      roundTripMs: rtt,
      uploadKbps: upload,
      sending: sending,
      downloadKbps: _downloadKbps,
    );
    notifyListeners();
  }

  /// Records how big someone's tile is on screen, in device pixels. The
  /// layout goes to the server shortly after tiles settle, and only when it
  /// changed, so it can pick each camera's layer.
  void reportTile(String id, int width, int height) {
    final old = _tiles[id];
    if (old != null && old.width == width && old.height == height) return;
    _tiles[id] = TileSize(id: id, width: width, height: height);
    _scheduleLayout();
  }

  void _scheduleLayout() {
    _layoutTimer?.cancel();
    _layoutTimer = Timer(const Duration(milliseconds: 250), _sendLayout);
  }

  void _sendLayout() {
    if (_closed || myId == null) return;
    final tiles = [
      for (final t in _tiles.values)
        if (participants.containsKey(t.id)) t,
    ];
    final key = [for (final t in tiles) '${t.id}:${t.width}x${t.height}']
        .join(',');
    if (key == _sentLayout) return;
    _sentLayout = key;
    _send(SignalMessage(type: SignalType.layout, tiles: tiles));
  }

  void setMic(bool on) {
    for (final t in localStream.getAudioTracks()) {
      t.enabled = on;
    }
    notifyListeners();
  }

  void setCamera(bool on) {
    for (final t in localStream.getVideoTracks()) {
      t.enabled = on;
    }
    notifyListeners();
  }

  Future<void> flipCamera() async {
    final track = localStream.getVideoTracks().firstOrNull;
    if (track == null) return;
    await Helper.switchCamera(track);
    frontCamera = !frontCamera;
    notifyListeners();
  }

  /// Leaves the room and releases the camera, mic and connections.
  Future<void> leave() => _end(null);

  Future<void> _end(String? reason) async {
    if (_closed) return;
    _closed = true;
    endReason = reason;
    state = RoomState.ended;
    _statsTimer?.cancel();
    _layoutTimer?.cancel();
    notifyListeners();

    await _wsSub?.cancel();
    await _ws?.sink.close();
    await _pub?.close();
    await _sub?.close();
    for (final t in localStream.getTracks()) {
      await t.stop();
    }
    await localStream.dispose();
    for (final p in participants.values) {
      await p._dispose();
    }
  }

  @override
  void notifyListeners() {
    if (!_disposed) super.notifyListeners();
  }

  @override
  void dispose() {
    leave();
    _disposed = true;
    super.dispose();
  }
}
