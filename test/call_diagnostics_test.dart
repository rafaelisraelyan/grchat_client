import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:grchat_client/src/call/call_diagnostics.dart';

StatsReport _rep(String id, String type, Map<String, dynamic> values) =>
    StatsReport(id, type, 0, values);

void main() {
  group('SdpSummary', () {
    test('parses audio+video sendrecv offer', () {
      const sdp = 'v=0\r\n'
          'm=audio 9 UDP/TLS/RTP/SAVPF 111\r\n'
          'a=sendrecv\r\n'
          'm=video 9 UDP/TLS/RTP/SAVPF 96\r\n'
          'a=sendrecv\r\n';
      final s = SdpSummary.parse(sdp);
      expect(s.hasAudio, isTrue);
      expect(s.hasVideo, isTrue);
      expect(s.audioDirs, ['sendrecv']);
      expect(s.videoDirs, ['sendrecv']);
    });

    test('detects recvonly answer without video', () {
      const sdp = 'v=0\r\n'
          'm=audio 9 UDP/TLS/RTP/SAVPF 111\r\n'
          'a=recvonly\r\n';
      final s = SdpSummary.parse(sdp);
      expect(s.hasAudio, isTrue);
      expect(s.hasVideo, isFalse);
      expect(s.audioDirs, ['recvonly']);
      expect(s.videoDirs, isEmpty);
    });

    test('ignores non-audio/video sections', () {
      const sdp = 'v=0\r\n'
          'm=application 9 DTLS/SCTP 5000\r\n'
          'm=video 9 UDP/TLS/RTP/SAVPF 96\r\n'
          'a=inactive\r\n';
      final s = SdpSummary.parse(sdp);
      expect(s.hasAudio, isFalse);
      expect(s.hasVideo, isTrue);
      expect(s.videoDirs, ['inactive']);
    });
  });

  group('IceBuffer', () {
    test('queues until drained, then empty', () {
      final b = IceBuffer<String>();
      expect(b.isEmpty, isTrue);
      b.add('a');
      b.add('b');
      expect(b.length, 2);
      expect(b.drain(), ['a', 'b']);
      expect(b.isEmpty, isTrue);
      expect(b.drain(), isEmpty);
    });

    test('clear drops everything', () {
      final b = IceBuffer<String>();
      b.add('a');
      b.clear();
      expect(b.isEmpty, isTrue);
    });
  });

  group('StatsSummary', () {
    test('sums RTP and resolves relay pair', () {
      final reports = [
        _rep('o1', 'outbound-rtp',
            {'kind': 'audio', 'bytesSent': 100, 'packetsSent': 2}),
        _rep('o2', 'outbound-rtp',
            {'kind': 'video', 'bytesSent': 5000, 'packetsSent': 40}),
        _rep('i1', 'inbound-rtp',
            {'kind': 'audio', 'bytesReceived': 50, 'packetsReceived': 1}),
        _rep('i2', 'inbound-rtp',
            {'kind': 'video', 'bytesReceived': 0, 'packetsReceived': 0}),
        _rep('lc1', 'local-candidate', {'candidateType': 'relay'}),
        _rep('cp1', 'candidate-pair', {
          'selected': true,
          'localCandidateId': 'lc1',
        }),
      ];
      final s = StatsSummary.summarize(reports);
      expect(s.outboundAudioBytes, 100);
      expect(s.outboundVideoBytes, 5000);
      expect(s.inboundAudioBytes, 50);
      expect(s.inboundVideoBytes, 0);
      expect(s.selectedCandidateType, 'relay');
    });

    test('unknown pair without selection', () {
      final s = StatsSummary.summarize(
          [_rep('o1', 'outbound-rtp', {'kind': 'audio'})]);
      expect(s.selectedCandidateType, 'unknown');
      expect(s.outboundAudioBytes, 0);
    });
  });

  group('buildDebugSummary', () {
    test('contains the key lines, no credentials', () {
      final stats = StatsSummary.summarize(const []);
      final text = buildDebugSummary(
          platform: 'macOS',
          callId: 'abcdef123456',
          role: 'callee',
          localAudioTracks: 1,
          localVideoTracks: 1,
          signalingState: 'stable',
          iceGatheringState: 'complete',
          iceConnectionState: 'connected',
          connectionState: 'connected',
          remoteAudio: true,
          remoteVideo: false,
          stats: stats);
      expect(text, contains('Platform: macOS'));
      expect(text, contains('Role: callee'));
      expect(text, contains('audio tracks=1'));
      expect(text, contains('connection=connected'));
      expect(text, contains('video=no'));
      expect(text, contains('Selected ICE: unknown'));
    });
  });
}
