import 'package:fitmeasure/features/live/live_protocol.dart';
import 'package:fitmeasure/features/live/video_levels.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('SignalMessage', () {
    test('decodes a welcome with others and ICE servers', () {
      final m = SignalMessage.decode('''{
        "type": "welcome", "id": "abc",
        "participants": [{"id": "p1", "name": "Ada"}],
        "iceServers": [
          {"urls": ["stun:1.2.3.4:3478"]},
          {"urls": ["turn:1.2.3.4:3478?transport=udp"], "username": "1:abc", "credential": "pw"}
        ]
      }''');
      expect(m.type, SignalType.welcome);
      expect(m.id, 'abc');
      expect(m.participants.single.name, 'Ada');
      expect(m.iceServers, hasLength(2));
      expect(m.iceServers[1]['credential'], 'pw');
    });

    test('decodes a welcome to an empty room', () {
      final m = SignalMessage.decode('{"type": "welcome", "id": "abc"}');
      expect(m.participants, isEmpty);
      expect(m.iceServers, isEmpty);
    });

    test('decodes a subscribe offer and a candidate', () {
      final offer = SignalMessage.decode(
        '{"type": "offer", "pc": "subscribe", "sdp": "v=0"}',
      );
      expect(offer.pc, PeerName.subscribe);
      expect(offer.sdp, 'v=0');

      final c = SignalMessage.decode(
        '{"type": "candidate", "pc": "publish", "candidate": '
        '{"candidate": "candidate:1 1 udp 1 1.2.3.4 7882 typ host", "sdpMid": "0", "sdpMLineIndex": 0}}',
      );
      expect(c.candidate!.sdpMLineIndex, 0);
      expect(c.candidate!.candidate, contains('typ host'));
    });

    test('decodes participant events', () {
      final m = SignalMessage.decode(
        '{"type": "participant_left", "participant": {"id": "p1", "name": "Ada"}}',
      );
      expect(m.participant!.id, 'p1');
    });

    test('encodes only what is set', () {
      expect(
        const SignalMessage(type: SignalType.answer, pc: PeerName.subscribe, sdp: 'v=0').encode(),
        '{"type":"answer","pc":"subscribe","sdp":"v=0"}',
      );
      expect(
        const SignalMessage(
          type: SignalType.candidate,
          pc: PeerName.publish,
          candidate: CandidateInit(candidate: 'c', sdpMid: '0'),
        ).encode(),
        '{"type":"candidate","pc":"publish","candidate":{"candidate":"c","sdpMid":"0"}}',
      );
    });
  });

  group('VideoLevelPolicy', () {
    test('starts at 640×360', () {
      expect(videoLevels[VideoLevelPolicy().level].label, '640×360');
    });

    test('drops straight to the level that fits', () {
      final p = VideoLevelPolicy(level: 0);
      expect(p.sample(300), 2);
      expect(p.sample(300), isNull);
    });

    test('climbs one level after three samples with headroom', () {
      final p = VideoLevelPolicy(level: 2);
      // 600 clears 450 × 1.3 = 585.
      expect(p.sample(600), isNull);
      expect(p.sample(600), isNull);
      expect(p.sample(600), 1);
      // Plenty of room for 960×540 still takes three more samples.
      expect(p.sample(5000), isNull);
      expect(p.sample(5000), isNull);
      expect(p.sample(5000), 0);
    });

    test('a dip resets the climb', () {
      final p = VideoLevelPolicy(level: 2);
      p.sample(600);
      p.sample(600);
      p.sample(500); // fits 640×360 but without 30% headroom
      expect(p.sample(600), isNull);
      expect(p.sample(600), isNull);
      expect(p.sample(600), 1);
    });

    test('ignores missing estimates', () {
      final p = VideoLevelPolicy();
      expect(p.sample(null), isNull);
      expect(p.sample(0), isNull);
      expect(p.level, VideoLevelPolicy.startLevel);
    });
  });
}
