import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/status.dart' as ws_status;
import 'package:web_socket_channel/web_socket_channel.dart';

import 'live_protocol.dart';
import 'rooms_api.dart';

/// "the host", "a moderator", "a participant".
String roleName(String role) => switch (role) {
  Role.host => 'the host',
  Role.moderator => 'a moderator',
  _ => 'a participant',
};

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

/// Something to tell the person in the room, for the screen to show.
sealed class RoomNotice {
  const RoomNotice();
}

/// A moderator turned off our mic or camera.
class MutedNotice extends RoomNotice {
  const MutedNotice(this.by, this.track);
  final String by;
  final String track;
}

/// A moderator asks us to unmute; only we can.
class UnmuteRequest extends RoomNotice {
  const UnmuteRequest(this.by, this.track);
  final String by;
  final String track;
}

/// A short message, e.g. "You're now the host".
class InfoNotice extends RoomNotice {
  const InfoNotice(this.text);
  final String text;
}

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
  bool mic = true;
  bool camera = true;
  String role = Role.participant;
  String visibility = VideoVisibility.everyone;

  void _update(LiveParticipant p) {
    name = p.name;
    mic = p.mic;
    camera = p.camera;
    role = p.role;
    visibility = p.visibility;
  }

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
    required this.roomId,
    required this.roomName,
    required this.name,
    required this.localStream,
    this.hostKey,
  });

  /// The room's ID, which we join by, and its name, which the server
  /// confirms in the welcome.
  final String roomId;
  String roomName;

  /// The room's host key, if we created it: joining with it makes us host.
  final String? hostKey;

  /// The room, for sharing.
  LiveRoom get room => LiveRoom(id: roomId, name: roomName, hostKey: hostKey);
  final String name;

  /// Our camera and mic, opened by the pre-join screen. The client owns it
  /// from here and stops it on leave.
  final MediaStream localStream;

  RoomState state = RoomState.connecting;

  /// True while reconnecting after the connection to the server dropped,
  /// as when the phone changes networks. The server keeps our place for 20
  /// seconds.
  bool reconnecting = false;
  String? _resumeToken;

  /// Why the room ended, if not by leaving.
  String? endReason;
  String? myId;

  /// Everyone else, in the order they appeared.
  final participants = <String, RemoteParticipant>{};

  /// Who is speaking now (participant IDs, ours included), from the server.
  Set<String> speaking = {};

  /// Our role, and the room's settings.
  String myRole = Role.participant;
  String myVisibility = VideoVisibility.everyone;
  bool locked = false;
  bool everyoneCanModerate = false;

  bool get canModerate =>
      myRole == Role.host || myRole == Role.moderator || everyoneCanModerate;

  bool get _trainerOnlyViewer =>
      myVisibility == VideoVisibility.trainerOnly && myRole != Role.host;

  /// Whether p's video reaches us, by the same rules the server applies:
  /// "trainer only" video goes to the host alone, and someone trainer-only
  /// sees the host alone. When it doesn't, their tile shows their avatar
  /// rather than the last frame received.
  bool canSeeVideoOf(RemoteParticipant p) {
    if (!p.camera) return false;
    if (p.visibility == VideoVisibility.trainerOnly && myRole != Role.host) {
      return false;
    }
    if (_trainerOnlyViewer && p.role != Role.host) return false;
    return true;
  }

  /// Whether p gets a tile: everyone, except that someone trainer-only sees
  /// the trainer alone (they still hear everyone).
  bool inGrid(RemoteParticipant p) =>
      !_trainerOnlyViewer || p.role == Role.host;

  final _notices = StreamController<RoomNotice>.broadcast();

  /// Things to show: being muted, unmute requests, role changes.
  Stream<RoomNotice> get notices => _notices.stream;

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

  /// The people whose tiles are on screen (the current page). Everyone else
  /// gets no video: they're left out of the layout.
  Set<String>? _onScreen;
  String _sentLayout = '';
  Timer? _layoutTimer;
  bool _closed = false;
  bool _disposed = false;

  Uri _roomUri(Map<String, String> query) => liveServer.replace(
    scheme: liveServer.scheme == 'https' ? 'wss' : 'ws',
    path: '/ws/rooms/$roomId',
    queryParameters: query,
  );

  Future<void> join() async {
    try {
      await _open(_roomUri({'name': name, 'key': ?hostKey}));
    } catch (_) {
      await _end("Couldn't reach the server");
    }
  }

  /// Opens the signalling WebSocket. Pings every 10 seconds notice a dead
  /// connection (a phone that changed networks) quickly, so the reconnect
  /// starts within the 20 seconds the server keeps our place.
  Future<void> _open(Uri uri) async {
    final WebSocketChannel ws = IOWebSocketChannel.connect(
      uri,
      pingInterval: const Duration(seconds: 10),
    );
    await ws.ready;
    await _wsSub?.cancel();
    _ws = ws;
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
      onDone: () => _queue = _queue.then((_) => _socketClosed(ws)),
      onError: (_) => _queue = _queue.then((_) => _socketClosed(ws)),
    );
  }

  /// The WebSocket closed without us leaving: reconnect if we're in the
  /// room, otherwise it's the end.
  Future<void> _socketClosed(WebSocketChannel ws) async {
    if (_closed || ws != _ws) return;
    if (_resumeToken == null) {
      await _end('Disconnected from the server');
      return;
    }
    // A reconnected socket that closed again before the server resumed us:
    // keep trying.
    reconnecting = false;
    await _reconnect();
  }

  /// Reconnects with the resume token, trying every second for as long as
  /// the server keeps our place.
  Future<void> _reconnect() async {
    if (reconnecting || _closed) return;
    reconnecting = true;
    _ws = null;
    notifyListeners();
    final until = DateTime.now().add(const Duration(seconds: 20));
    while (!_closed && DateTime.now().isBefore(until)) {
      try {
        await _open(_roomUri({'resume': _resumeToken!}));
        return; // the server's "resumed" finishes it
      } catch (_) {
        await Future<void>.delayed(const Duration(seconds: 1));
      }
    }
    if (!_closed) await _end('Lost the connection to the server');
  }

  /// Gathers new candidates for our sending connection, as after changing
  /// networks; the server answers the new offer.
  Future<void> _restartPublishIce() async {
    final pub = _pub;
    if (pub == null) return;
    // Marks the next offer as an ICE restart (new credentials, so new
    // candidates are gathered and checked). On Android an iceRestart
    // option to createOffer is ignored.
    await pub.restartIce();
    final offer = await pub.createOffer();
    await pub.setLocalDescription(offer);
    _send(
      SignalMessage(
        type: SignalType.offer,
        pc: PeerName.publish,
        sdp: offer.sdp,
      ),
    );
  }

  void _send(SignalMessage m) {
    // While reconnecting there's no socket; the server catches up after.
    if (reconnecting) return;
    try {
      _ws?.sink.add(m.encode());
    } catch (_) {}
  }

  Future<void> _handle(SignalMessage msg) async {
    if (_closed) return;
    switch (msg.type) {
      case SignalType.welcome:
        myId = msg.id;
        roomName = msg.roomName ?? roomName;
        _resumeToken = msg.resume;
        myRole = msg.participant?.role ?? Role.participant;
        _applySettings(msg);
        for (final p in msg.participants) {
          participants[p.id] = RemoteParticipant(p.id, p.name).._update(p);
        }
        if (myRole == Role.host) {
          _notices.add(
            const InfoNotice(
              "You're the host: tap the people button to mute, remove or "
              'promote people',
            ),
          );
        }
        _sendState();
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
        (participants[p.id] ??= RemoteParticipant(p.id, p.name))._update(p);
        notifyListeners();

      case SignalType.participantChanged:
        final p = msg.participant!;
        if (p.id == myId) {
          // Our role changed: a promotion, or the host role passing to us.
          if (p.role != myRole) {
            _notices.add(InfoNotice("You're now ${roleName(p.role)}"));
          }
          myRole = p.role;
        } else {
          final q = participants[p.id];
          if (q != null && q.role != p.role) {
            _notices.add(InfoNotice('${p.name} is now ${roleName(p.role)}'));
          }
          q?._update(p);
        }
        notifyListeners();

      case SignalType.settings:
        _applySettings(msg);
        notifyListeners();

      case SignalType.mutedBy:
        // The server has already stopped forwarding; turn it off here too
        // so our controls match. Only we can turn it back on.
        if (msg.track == 'mic') setMic(false);
        if (msg.track == 'camera') setCamera(false);
        _notices.add(MutedNotice(_nameOf(msg.id), msg.track ?? 'mic'));

      case SignalType.unmuteRequested:
        _notices.add(UnmuteRequest(_nameOf(msg.id), msg.track ?? 'mic'));

      case SignalType.removed:
        await _end('You were removed from the room');

      case SignalType.resumed:
        // Back in the room. Catch up on who's here now: anyone who left
        // while we were away goes, and everyone's state is current.
        reconnecting = false;
        myRole = msg.participant?.role ?? myRole;
        _applySettings(msg);
        final here = {for (final p in msg.participants) p.id: p};
        for (final id in participants.keys.toList()) {
          if (!here.containsKey(id)) await participants.remove(id)?._dispose();
        }
        for (final p in here.values) {
          (participants[p.id] ??= RemoteParticipant(p.id, p.name))._update(p);
        }
        notifyListeners();
        _sendState();
        _sentLayout = '';
        _sendLayout();
        await _restartPublishIce();

      case SignalType.speakers:
        speaking = msg.speakers.toSet();
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
        // room is full); after it, it's informational, unless a resume was
        // refused: our place is gone.
        if (myId == null) await _end(_describeError(msg.error));
        if (msg.error == 'session expired') {
          await _end('You lost your place in the room. Join again to go back.');
        }
        debugPrint('live: server error: ${msg.error}');
    }
  }

  String _describeError(String? error) => switch (error) {
    'room is full' => 'This room is full (16 people)',
    'room is locked' => 'The host has locked this room',
    'no room with that ID' =>
      'This room no longer exists. Rooms are removed after 30 days unused.',
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
        // Media lost but signalling fine (the network changed): restart
        // ICE on both connections rather than giving up. The server
        // restarts the subscribe side when asked.
        if (s == RTCPeerConnectionState.RTCPeerConnectionStateFailed &&
            pcName == PeerName.publish &&
            !reconnecting) {
          _send(const SignalMessage(type: SignalType.restartIce));
          _restartPublishIce();
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

  /// Records which people are on screen now; the rest get no video.
  void setOnScreen(Set<String> ids) {
    if (setEquals(ids, _onScreen)) return;
    _onScreen = ids;
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
        if (participants.containsKey(t.id) &&
            (_onScreen == null || _onScreen!.contains(t.id)))
          t,
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
    _sendState();
    notifyListeners();
  }

  void setCamera(bool on) {
    for (final t in localStream.getVideoTracks()) {
      t.enabled = on;
    }
    _sendState();
    notifyListeners();
  }

  void _applySettings(SignalMessage m) {
    locked = m.locked ?? locked;
    everyoneCanModerate = m.everyoneCanModerate ?? everyoneCanModerate;
  }

  String _nameOf(String? id) => participants[id]?.name ?? 'Someone';

  // Moderation. The server checks each against our role and replies with
  // an error if it isn't allowed.
  void mute(String id, String track) =>
      _send(SignalMessage(type: SignalType.mute, id: id, track: track));
  void requestUnmute(String id, String track) => _send(
    SignalMessage(type: SignalType.requestUnmute, id: id, track: track),
  );
  void setRole(String id, String role) =>
      _send(SignalMessage(type: SignalType.setRole, id: id, role: role));
  void transferHost(String id) =>
      _send(SignalMessage(type: SignalType.transferHost, id: id));
  void remove(String id) =>
      _send(SignalMessage(type: SignalType.remove, id: id));
  void setLocked(bool on) =>
      _send(SignalMessage(type: SignalType.setSettings, locked: on));
  void setEveryoneCanModerate(bool on) => _send(
    SignalMessage(type: SignalType.setSettings, everyoneCanModerate: on),
  );

  /// Shows our video to the host alone, or to everyone.
  void setVisibility(String visibility) {
    myVisibility = visibility;
    _send(SignalMessage(type: SignalType.state, visibility: visibility));
    notifyListeners();
  }

  /// Tells everyone (through the server) whether our mic and camera are
  /// on. A disabled track still sends silence or black frames; the server
  /// stops forwarding video from a camera that's off.
  void _sendState() {
    if (myId == null || _closed) return;
    _send(SignalMessage(type: SignalType.state, mic: micOn, camera: cameraOn));
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
    unawaited(_notices.close());
    _layoutTimer?.cancel();
    notifyListeners();

    await _wsSub?.cancel();
    // A normal close tells the server we left on purpose.
    await _ws?.sink.close(ws_status.normalClosure);
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
