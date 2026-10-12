import 'package:flutter_test/flutter_test.dart';
import 'package:grchat_client/src/call/call_state.dart';

/// The ActiveCall side of the late camera enable: `video` became mutable
/// so a voice-only call can turn into a video call in place (renegotiation
/// on `call_renegotiate`), without losing the other live flags.
void main() {
  ActiveCall base() => ActiveCall(
        callId: 'c1',
        peerNick: 'Masha',
        video: false,
        outgoing: true,
        phase: CallPhase.active,
        muted: true,
        cameraOff: false,
        linkDown: false,
      );

  test('copyWith(video) flips the flag into a video call', () {
    final a = base();
    expect(a.video, isFalse);
    final b = a.copyWith(video: true);
    expect(b.video, isTrue);
    // Everything else rides along unchanged.
    expect(b.callId, 'c1');
    expect(b.peerNick, 'Masha');
    expect(b.phase, CallPhase.active);
    expect(b.muted, isTrue);
    expect(b.outgoing, isTrue);
  });

  test('copyWith without video keeps the current flag', () {
    final a = base().copyWith(video: true, cameraOff: true);
    final b = a.copyWith(muted: false);
    expect(b.video, isTrue, reason: 'an explicit copyWith(muted:) must not '
        'silently flip video back to false');
    expect(b.cameraOff, isTrue);
    expect(b.muted, isFalse);
  });

  test('ringing state still starts without video in an audio dial', () {
    // The dial-time path keeps its old semantics: audio-only incoming.
    final st = ActiveCall(
        callId: 'c2',
        peerNick: 'Rafael',
        video: false,
        outgoing: false,
        phase: CallPhase.ringing);
    expect(st.video, isFalse);
    expect(st.cameraOff, isFalse);
  });
}
