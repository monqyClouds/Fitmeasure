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
}

abstract final class PeerName {
  static const publish = 'publish';
  static const subscribe = 'subscribe';
}

class LiveParticipant {
  const LiveParticipant({required this.id, required this.name});

  factory LiveParticipant.fromJson(Map<String, dynamic> json) =>
      LiveParticipant(id: json['id'] as String, name: json['name'] as String);

  final String id;
  final String name;
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

  String encode() => jsonEncode({
    'type': type,
    'pc': ?pc,
    'sdp': ?sdp,
    if (candidate != null) 'candidate': candidate!.toJson(),
  });
}
