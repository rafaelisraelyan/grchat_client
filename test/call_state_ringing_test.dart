import 'package:flutter_riverpod/flutter_riverpod.dart';
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

  /// Call waiting on the real engine, headless: dry ring creates no
  /// transport, so prepare/decline never touch WebRTC here. Every scenario
  /// ends hung up: no 58s ring timer may leak out of the test.
  group('displaced live call under a dry ring', () {
    ActiveCall activeA() => ActiveCall(
        callId: 'a',
        peerNick: 'Alex',
        video: false,
        outgoing: true,
        phase: CallPhase.active);

    ProviderContainer container() {
      final c = ProviderContainer();
      addTearDown(c.dispose);
      return c;
    }

    test('dry ring sets state with no transport behind it', () async {
      final c = container();
      final st = c.read(callStateProvider.notifier);
      // Old code opened a PC + mic here and died headless (cleanup → null).
      await st.debugIncomingForTest(
          callId: 'b', peerNick: 'Masha', video: true);
      final s = c.read(callStateProvider);
      expect(s?.callId, 'b');
      expect(s?.phase, CallPhase.ringing);
      await st.decline();
      expect(c.read(callStateProvider), isNull);
    });

    test('ring over active stashes it, decline restores it', () async {
      final c = container();
      final st = c.read(callStateProvider.notifier);
      st.state = activeA();
      await st.debugIncomingForTest(
          callId: 'b', peerNick: 'Masha', video: false);
      expect(c.read(callStateProvider)?.callId, 'b');
      expect(st.debugDisplacedForTest?.callId, 'a');
      await st.decline();
      expect(c.read(callStateProvider)?.callId, 'a');
      expect(st.debugDisplacedForTest, isNull);
      await st.endAll();
      expect(c.read(callStateProvider), isNull);
    });

    test('remote end of the hidden call drops it silently', () async {
      final c = container();
      final st = c.read(callStateProvider.notifier);
      st.state = activeA();
      await st.debugIncomingForTest(
          callId: 'b', peerNick: 'Masha', video: false);
      st.debugRemoteEndedForTest('a');
      expect(st.debugDisplacedForTest, isNull);
      expect(c.read(callStateProvider)?.callId, 'b');
      await st.decline();
      expect(c.read(callStateProvider), isNull);
    });

    test('remote end of the ring resurfaces the live call', () async {
      final c = container();
      final st = c.read(callStateProvider.notifier);
      st.state = activeA();
      await st.debugIncomingForTest(
          callId: 'b', peerNick: 'Masha', video: false);
      st.debugRemoteEndedForTest('b');
      expect(c.read(callStateProvider)?.callId, 'a');
      expect(st.debugDisplacedForTest, isNull);
      await st.endAll();
      expect(c.read(callStateProvider), isNull);
    });

    test('endAll ends both, except keeps the accepted ring', () async {
      final c = container();
      final st = c.read(callStateProvider.notifier);
      st.state = activeA();
      await st.debugIncomingForTest(
          callId: 'b', peerNick: 'Masha', video: false);
      await st.endAll(exceptPendingId: 'b');
      expect(c.read(callStateProvider)?.callId, 'b');
      expect(st.debugDisplacedForTest, isNull);
      await st.endAll();
      expect(c.read(callStateProvider), isNull);
    });
  });
}
