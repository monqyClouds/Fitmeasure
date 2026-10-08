import 'package:fitmeasure/features/live/live_protocol.dart';
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
        const SignalMessage(
          type: SignalType.answer,
          pc: PeerName.subscribe,
          sdp: 'v=0',
        ).encode(),
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

  test('decodes an estimate', () {
    final m = SignalMessage.decode('{"type": "estimate", "bitrate": 850000}');
    expect(m.type, SignalType.estimate);
    expect(m.bitrate, 850000);
  });

  test('decodes state changes and speakers', () {
    final changed = SignalMessage.decode(
      '{"type": "participant_changed", "participant": {"id": "p1", "name": "Ada", "mic": false, "camera": true}}',
    );
    expect(changed.participant!.mic, isFalse);
    expect(changed.participant!.camera, isTrue);
    expect(
      SignalMessage.decode('{"type": "speakers", "speakers": ["p1", "p2"]}')
          .speakers,
      ['p1', 'p2'],
    );
    expect(SignalMessage.decode('{"type": "speakers"}').speakers, isEmpty);
  });

  test('encodes our state', () {
    expect(
      const SignalMessage(
        type: SignalType.state,
        mic: false,
        camera: true,
      ).encode(),
      '{"type":"state","mic":false,"camera":true}',
    );
  });

  test('decodes a resume token and a resumed room', () {
    final welcome = SignalMessage.decode(
      '{"type": "welcome", "id": "me", "resume": "secret"}',
    );
    expect(welcome.resume, 'secret');
    final resumed = SignalMessage.decode(
      '{"type": "resumed", "id": "me", "resume": "secret", '
      '"participants": [{"id": "p1", "name": "Ada", "mic": false, "camera": true}]}',
    );
    expect(resumed.type, SignalType.resumed);
    expect(resumed.participants.single.mic, isFalse);
  });

  test('moderation messages', () {
    expect(
      const SignalMessage(
        type: SignalType.mute,
        id: 'p1',
        track: 'mic',
      ).encode(),
      '{"type":"mute","id":"p1","track":"mic"}',
    );
    expect(
      const SignalMessage(type: SignalType.setSettings, locked: true).encode(),
      '{"type":"set_settings","locked":true}',
    );
    final p = SignalMessage.decode(
      '{"type": "participant_changed", "participant": {"id": "p1", "name": "Ada", '
      '"mic": true, "camera": true, "role": "moderator", "visibility": "trainer_only"}}',
    ).participant!;
    expect(p.role, Role.moderator);
    expect(p.visibility, VideoVisibility.trainerOnly);
    final muted = SignalMessage.decode(
      '{"type": "muted_by", "id": "p2", "track": "camera"}',
    );
    expect(muted.track, 'camera');
    final settings = SignalMessage.decode(
      '{"type": "settings", "locked": true, "everyoneCanModerate": false}',
    );
    expect(settings.locked, isTrue);
    expect(settings.everyoneCanModerate, isFalse);
  });

  test('encodes a layout', () {
    expect(
      const SignalMessage(
        type: SignalType.layout,
        tiles: [TileSize(id: 'p1', width: 1080, height: 608)],
      ).encode(),
      '{"type":"layout","tiles":[{"id":"p1","width":1080,"height":608}]}',
    );
    expect(
      const SignalMessage(type: SignalType.layout, tiles: []).encode(),
      '{"type":"layout","tiles":[]}',
    );
  });
}
