import 'package:flutter_test/flutter_test.dart';
import 'package:grchat_client/src/call/call_state.dart';

/// Regression: the callee used to rebuild its ringing state from scratch
/// *after* `setRemoteDescription`, which silently discarded the
/// `remoteVideo: true` that `onTrack` had already set during that await. The
/// call connected and audio worked, but the remote camera stayed behind the
/// "Подключение видео…" avatar - and only for the party that answers, which is
/// why calling Windows->macOS was broken while macOS->Windows was fine.
void main() {
  group('incomingRingingCall', () {
    test('keeps a remote video track that arrived before the state existed', () {
      final s = incomingRingingCall(
          callId: 'c1',
          peerNick: 'Rafael',
          video: true,
          remoteVideoArrived: true);
      expect(s.remoteVideo, isTrue,
          reason: 'onTrack fired during setRemoteDescription; the rebuilt '
              'state must not forget it');
      expect(s.video, isTrue);
      expect(s.outgoing, isFalse);
      expect(s.phase, CallPhase.ringing);
    });

    test('audio-only call never claims a remote video track', () {
      final s = incomingRingingCall(
          callId: 'c1',
          peerNick: 'Rafael',
          video: false,
          remoteVideoArrived: false);
      expect(s.remoteVideo, isFalse);
      expect(s.video, isFalse);
      expect(s.outgoing, isFalse);
    });

    test('video call without a track yet shows the avatar', () {
      final s = incomingRingingCall(
          callId: 'c1', peerNick: 'Rafael', video: true, remoteVideoArrived: false);
      expect(s.remoteVideo, isFalse,
          reason: 'no onTrack yet - the placeholder is correct here');
    });

    test('accepting does not need to re-derive remoteVideo', () {
      // acceptIncoming patches the live state rather than writing back a
      // snapshot taken before its awaits, so this transition preserves the
      // flag no matter when onTrack landed.
      final ringing = incomingRingingCall(
          callId: 'c1',
          peerNick: 'Rafael',
          video: true,
          remoteVideoArrived: true);
      final active = ringing.copyWith(phase: CallPhase.active);
      expect(active.remoteVideo, isTrue);
      expect(active.phase, CallPhase.active);
    });

    test('copyWith is non-destructive for every field it does not name', () {
      final s = incomingRingingCall(
              callId: 'c1',
              peerNick: 'Rafael',
              video: true,
              remoteVideoArrived: true)
          .copyWith(remoteVideo: false);
      expect(s.remoteVideo, isFalse);
      // Everything else survives, so a late toggle cannot wipe unrelated state.
      expect(s.video, isTrue);
      expect(s.callId, 'c1');
      expect(s.peerNick, 'Rafael');
      expect(s.phase, CallPhase.ringing);
    });
  });
}
