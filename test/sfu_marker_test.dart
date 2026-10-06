import 'package:flutter_test/flutter_test.dart';
import 'package:grchat_client/src/call/sfu_marker.dart';

void main() {
  group('SFU marker', () {
    test('builds audio and video markers', () {
      expect(buildSfuMarker('grchat_123', false), 'livekit:grchat_123');
      expect(buildSfuMarker('grchat_123', true),
          'livekit:grchat_123:m=video');
    });

    test('parses markers back', () {
      expect(parseSfuMarker('livekit:grchat_123'),
          (room: 'grchat_123', video: false));
      expect(parseSfuMarker('livekit:grchat_123:m=video'),
          (room: 'grchat_123', video: true));
    });

    test('rejects P2P sdp and garbage', () {
      expect(parseSfuMarker('v=0\r\nm=audio 9 UDP/TLS/RTP/SAVPF 111'),
          isNull);
      expect(parseSfuMarker('livekit:'), isNull);
      expect(parseSfuMarker(''), isNull);
      expect(parseSfuMarker('livekit'), isNull);
    });

    test('room derivation mirrors the server', () {
      expect(sfuRoomForDm('abc'), 'grchat_abc');
    });
  });
}
