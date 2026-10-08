// Signalling messages exchanged with the live sessions server over its room
// WebSocket. They mirror server/internal/signal/signal.go.
//
// Each participant has two peer connections, named in every offer, answer
// and candidate:
//   publish   - we offer our camera and mic, the server answers
//   subscribe - the server offers everyone else's tracks, we answer; it
//               offers again whenever someone joins or leaves

import 'dart:convert';

abstract final class SignalType {
  static const offer = 'offer';
  static const answer = 'answer';
  static const candidate = 'candidate';
  static const error = 'error';
  static const welcome = 'welcome';
  static const participantJoined = 'participant_joined';
  static const participantLeft = 'participant_left';

  /// Client to server: how big each person's tile is on screen, so the
  /// server can send each camera's simulcast layer that fits.
  static const layout = 'layout';

  /// Server to client: how fast the server estimates it can send to us.
  static const estimate = 'estimate';

  /// Client to server: whether our mic and camera are on.
  static const state = 'state';

  /// Server to client: someone's mic or camera changed.
  static const participantChanged = 'participant_changed';

  /// Server to client: who is speaking now.
  static const speakers = 'speakers';

  /// Server to client: back in the room after reconnecting with our resume
  /// token; the room as it is now.
  static const resumed = 'resumed';

  /// Client to server: our media paths failed; restart ICE on the
  /// subscribe connection.
  static const restartIce = 'restart_ice';

  // Moderation (docs/live-sessions.md section 3). The server checks each
  // against the sender's role.
  static const setRole = 'set_role';
  static const transferHost = 'transfer_host';
  static const mute = 'mute';
  static const requestUnmute = 'request_unmute';
  static const remove = 'remove';
  static const setSettings = 'set_settings';
  static const mutedBy = 'muted_by';
  static const unmuteRequested = 'unmute_requested';
  static const removed = 'removed';
  static const settings = 'settings';
}

abstract final class Role {
  static const host = 'host';
  static const moderator = 'moderator';
  static const participant = 'participant';
}

abstract final class VideoVisibility {
  static const everyone = 'everyone';

  /// Video to the host alone; everyone still hears you.
  static const trainerOnly = 'trainer_only';
}

abstract final class PeerName {
  static const publish = 'publish';
  static const subscribe = 'subscribe';
}

class LiveParticipant {
  const LiveParticipant({
    required this.id,
    required this.name,
    this.mic = true,
    this.camera = true,
    this.role = Role.participant,
    this.visibility = VideoVisibility.everyone,
  });

  factory LiveParticipant.fromJson(Map<String, dynamic> json) =>
      LiveParticipant(
        id: json['id'] as String,
        name: json['name'] as String,
        mic: json['mic'] as bool? ?? true,
        camera: json['camera'] as bool? ?? true,
        role: json['role'] as String? ?? Role.participant,
        visibility: json['visibility'] as String? ?? VideoVisibility.everyone,
      );

  final String id;
  final String name;
  final bool mic;
  final bool camera;
  final String role;
  final String visibility;
}

/// An ICE candidate as JSON carries it (RTCIceCandidateInit).
class CandidateInit {
  const CandidateInit({
    required this.candidate,
    this.sdpMid,
    this.sdpMLineIndex,
  });

  factory CandidateInit.fromJson(Map<String, dynamic> json) => CandidateInit(
    candidate: json['candidate'] as String,
    sdpMid: json['sdpMid'] as String?,
    sdpMLineIndex: json['sdpMLineIndex'] as int?,
  );

  final String candidate;
  final String? sdpMid;
  final int? sdpMLineIndex;

  Map<String, dynamic> toJson() => {
    'candidate': candidate,
    'sdpMid': ?sdpMid,
    'sdpMLineIndex': ?sdpMLineIndex,
  };
}

/// One person's tile on screen, in device pixels.
class TileSize {
  const TileSize({required this.id, required this.width, required this.height});

  final String id;
  final int width;
  final int height;

  Map<String, dynamic> toJson() => {'id': id, 'width': width, 'height': height};
}

class SignalMessage {
  const SignalMessage({
    required this.type,
    this.pc,
    this.sdp,
    this.candidate,
    this.error,
    this.id,
    this.participant,
    this.participants = const [],
    this.iceServers = const [],
    this.tiles,
    this.bitrate,
    this.mic,
    this.camera,
    this.speakers = const [],
    this.resume,
    this.roomName,
    this.track,
    this.role,
    this.visibility,
    this.locked,
    this.everyoneCanModerate,
  });

  factory SignalMessage.decode(String text) {
    final json = jsonDecode(text) as Map<String, dynamic>;
    return SignalMessage(
      type: json['type'] as String,
      pc: json['pc'] as String?,
      sdp: json['sdp'] as String?,
      candidate: switch (json['candidate']) {
        final Map<String, dynamic> c => CandidateInit.fromJson(c),
        _ => null,
      },
      error: json['error'] as String?,
      resume: json['resume'] as String?,
      roomName: json['roomName'] as String?,
      track: json['track'] as String?,
      role: json['role'] as String?,
      locked: json['locked'] as bool?,
      everyoneCanModerate: json['everyoneCanModerate'] as bool?,
      bitrate: json['bitrate'] as int?,
      speakers: [
        for (final s in (json['speakers'] as List?) ?? const []) s as String,
      ],
      id: json['id'] as String?,
      participant: switch (json['participant']) {
        final Map<String, dynamic> p => LiveParticipant.fromJson(p),
        _ => null,
      },
      participants: [
        for (final p in (json['participants'] as List?) ?? const [])
          LiveParticipant.fromJson(p as Map<String, dynamic>),
      ],
      // Passed to RTCPeerConnection as is: {urls, username?, credential?}.
      iceServers: [
        for (final s in (json['iceServers'] as List?) ?? const [])
          Map<String, dynamic>.from(s as Map),
      ],
    );
  }

  final String type;
  final String? pc;
  final String? sdp;
  final CandidateInit? candidate;
  final String? error;
  final String? id;
  final LiveParticipant? participant;
  final List<LiveParticipant> participants;
  final List<Map<String, dynamic>> iceServers;

  /// In a layout: everyone on screen. Anyone missing gets no video.
  final List<TileSize>? tiles;

  /// In an estimate, in bit/s.
  final int? bitrate;

  /// In a state: whether our mic and camera are on.
  final bool? mic;
  final bool? camera;

  /// In a speakers message: who is speaking (participant IDs).
  final List<String> speakers;

  /// In a welcome or resumed: the secret token for reconnecting.
  final String? resume;

  /// In a welcome: the room's name (we join by its ID).
  final String? roomName;

  /// In moderation messages: "mic" or "camera".
  final String? track;

  /// In a set_role.
  final String? role;

  /// In a state: VideoVisibility.everyone or VideoVisibility.trainerOnly.
  final String? visibility;

  /// Room settings, in settings, welcome, resumed and set_settings.
  final bool? locked;
  final bool? everyoneCanModerate;

  String encode() => jsonEncode({
    'type': type,
    'pc': ?pc,
    'sdp': ?sdp,
    if (candidate != null) 'candidate': candidate!.toJson(),
    if (tiles != null) 'tiles': [for (final t in tiles!) t.toJson()],
    'mic': ?mic,
    'camera': ?camera,
    'id': ?id,
    'track': ?track,
    'role': ?role,
    'visibility': ?visibility,
    'locked': ?locked,
    'everyoneCanModerate': ?everyoneCanModerate,
  });
}
