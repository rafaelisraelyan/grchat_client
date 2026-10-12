import 'package:flutter_test/flutter_test.dart';
import 'package:grchat_client/src/call/sdp_tuning.dart';

const _offer = 'v=0\r\n'
    'o=- 1 1 IN IP4 127.0.0.1\r\n'
    'm=audio 9 UDP/TLS/RTP/SAVPF 111 0\r\n'
    'a=rtpmap:111 opus/48000/2\r\n'
    'a=fmtp:111 minptime=10\r\n'
    'a=rtpmap:0 PCMU/8000\r\n'
    'm=video 9 UDP/TLS/RTP/SAVPF 96\r\n'
    'a=rtpmap:96 VP8/90000\r\n'
    'a=sendrecv\r\n';

void main() {
  group('tuneOpusSdp', () {
    test('extends an existing opus fmtp, keeps its own keys', () {
      final out = tuneOpusSdp(_offer);
      expect(out, contains('a=fmtp:111 minptime=10;useinbandfec=1;'));
      expect(out, contains('usedtx=0'));
      expect(out, contains('maxaveragebitrate=64000'));
      expect(out, contains('maxplaybackrate=48000'));
      // Not duplicated.
      expect('useinbandfec'.allMatches(out).length, 1);
    });

    test('does not override a value that is already set', () {
      final sdp = _offer.replaceFirst(
          'a=fmtp:111 minptime=10\r\n',
          'a=fmtp:111 maxaveragebitrate=24000\r\n');
      final out = tuneOpusSdp(sdp);
      expect(out, contains('maxaveragebitrate=24000'));
      expect(out.contains('maxaveragebitrate=64000'), isFalse);
    });

    test('adds an fmtp line when opus has none', () {
      final noFmtp = _offer.replaceAll('a=fmtp:111 minptime=10\r\n', '');
      final out = tuneOpusSdp(noFmtp);
      expect(out, contains('a=fmtp:111 useinbandfec=1;usedtx=0;'));
    });

    test('leaves non-opus lines and CRLF endings untouched', () {
      final out = tuneOpusSdp(_offer);
      expect(out, contains('a=rtpmap:96 VP8/90000'));
      expect(out.endsWith('\r\n'), isTrue);
      expect(out.contains('\n\n'), isFalse);
    });

    test('no opus, or empty input: returned unchanged', () {
      const noOpus = 'v=0\r\nm=video 9 UDP/TLS/RTP/SAVPF 96\r\n'
          'a=rtpmap:96 VP8/90000\r\n';
      expect(tuneOpusSdp(noOpus), noOpus);
      expect(tuneOpusSdp(''), '');
    });
  });

  group('tuneLocalSdp', () {
    test('pins opus bitrate+fec, keeps existing params', () {
      final t = tuneLocalSdp(_offer);
      // Keys are appended after existing ones, so check membership, not order.
      expect(t, contains('a=fmtp:111 '));
      expect(t, contains('minptime=10'));
      expect(t, contains('maxaveragebitrate=64000'));
      expect(t, contains('useinbandfec=1'));
      expect(t, contains('usedtx=0'));
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
      expect(t, contains('maxaveragebitrate=64000'));
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
