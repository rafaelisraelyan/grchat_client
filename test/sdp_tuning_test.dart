import 'package:flutter_test/flutter_test.dart';
import 'package:grchat_client/src/call/sdp_tuning.dart';

const _offer = 'v=0\r\n'
    'o=- 1 1 IN IP4 127.0.0.1\r\n'
    'm=audio 9 UDP/TLS/RTP/SAVPF 111 0\r\n'
    'a=rtpmap:111 opus/48000/2\r\n'
    'a=rtpmap:0 PCMU/8000\r\n'
    'a=fmtp:111 minptime=10\r\n'
    'm=video 9 UDP/TLS/RTP/SAVPF 96\r\n'
    'a=rtpmap:96 VP8/90000\r\n'
    'a=sendrecv\r\n';

void main() {
  group('tuneLocalSdp', () {
    test('pins opus bitrate+fec, keeps existing params', () {
      final t = tuneLocalSdp(_offer);
      expect(t, contains('a=fmtp:111 minptime=10;'
          'maxaveragebitrate=32000;useinbandfec=1'));
      expect(t, isNot(contains('usedtx')));
    });

    test('adds fmtp when opus has none', () {
      final noFmtp = _offer.replaceAll(
          'a=fmtp:111 minptime=10\r\n', '');
      final t = tuneLocalSdp(noFmtp);
      expect(t, contains('a=fmtp:111 '
          'maxaveragebitrate=32000;useinbandfec=1'));
    });

    test('caps video bandwidth, replaces existing b=AS', () {
      var t = tuneLocalSdp(_offer);
      expect(t, contains('b=AS:1500'));
      final withCap = _offer.replaceFirst(
          'a=rtpmap:96 VP8/90000\r\n',
          'a=rtpmap:96 VP8/90000\r\nb=AS:4000\r\n');
      t = tuneLocalSdp(withCap);
      expect(t, contains('b=AS:1500'));
      expect(t, isNot(contains('b=AS:4000')));
      // Exactly one cap per video section.
      expect('b=AS:'.allMatches(t).length, 1);
    });

    test('audio-only sdp gets no video cap', () {
      final audioOnly = 'v=0\r\n'
          'm=audio 9 UDP/TLS/RTP/SAVPF 111\r\n'
          'a=rtpmap:111 opus/48000/2\r\n';
      final t = tuneLocalSdp(audioOnly);
      expect(t, isNot(contains('b=AS')));
      expect(t, contains('maxaveragebitrate=32000'));
    });

    test('no opus means byte-identical passthrough', () {
      const sdp = 'v=0\r\nm=audio 9 RTP/AVP 0\r\na=rtpmap:0 PCMU/8000\r\n';
      expect(tuneLocalSdp(sdp), sdp);
    });

    test('CRLF endings preserved', () {
      final t = tuneLocalSdp(_offer);
      expect(t, contains('b=AS:1500\r\n'));
      expect(t, isNot(contains('\n\n')));
    });
  });
}
