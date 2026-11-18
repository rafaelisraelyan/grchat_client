// STAGE 2C.4b - Задача A: call identity for P2PMediaRecovery.
//
// The production defect: an outgoing call registers the controller through
// _newPc('') BEFORE the server assigns a callId. Once the real id arrived,
// every ICE event was rejected as stale even though the epoch matched.
//
// These tests pin both halves of the fix: the real id must be adopted, and the
// recovery session (phase, deadline, budget, restart count) must NOT be reset
// while doing so.

import 'package:flutter_test/flutter_test.dart';
import 'package:grchat_client/src/call/call_diagnostics.dart';
import 'package:grchat_client/src/call/p2p_media_recovery.dart';

const String realId = '81238e35462144c5a641b3e762895030';

void main() {
  late DateTime now;

  setUp(() {
    now = DateTime.utc(2026, 10, 20, 12, 0, 0);
  });

  group('§2C.4b call identity', () {
    test('outgoing: ICE failure is STALE while the id is still empty', () {
      final r = P2PMediaRecovery();
      // Exactly what _newPc('') does at dial time.
      r.onCallChanged(callId: '', epoch: 5);

      final d = r.onIceState(
        state: MediaLinkState.failed,
        callId: realId,
        epoch: 5,
        now: now,
      );

      expect(d.action, RecoveryAction.stale);
      expect(d.phase, RecoveryPhase.idle);
      expect(r.phase, RecoveryPhase.idle,
          reason: 'recovery must not start for an event it does not own');
    });

    test('outgoing: after the server answers, the SAME event is handled', () {
      final r = P2PMediaRecovery();
      r.onCallChanged(callId: '', epoch: 5);
      // call_state.startCall: the id comes back from api.offer().
      r.bindCallId(realId);

      final d = r.onIceState(
        state: MediaLinkState.failed,
        callId: realId,
        epoch: 5,
        now: now,
      );

      expect(d.action, RecoveryAction.showReconnecting);
      expect(d.phase, RecoveryPhase.recovering);
      expect(r.phase, RecoveryPhase.recovering);
      expect(r.deadline, now.add(r.grace));
    });

    test('bindCallId never overwrites an already known id', () {
      final r = P2PMediaRecovery();
      r.onCallChanged(callId: realId, epoch: 1);
      r.bindCallId('some-other-call');

      final d = r.onIceState(
        state: MediaLinkState.failed,
        callId: realId,
        epoch: 1,
        now: now,
      );
      expect(d.action, RecoveryAction.showReconnecting,
          reason: 'the original identity must still own the controller');
    });

    test('incoming: the id is known at accept time', () {
      final r = P2PMediaRecovery();
      // acceptIncoming -> _newPc(cur.callId) with the real id already present.
      r.onCallChanged(callId: realId, epoch: 1);

      final d = r.onIceState(
        state: MediaLinkState.failed,
        callId: realId,
        epoch: 1,
        now: now,
      );
      expect(d.action, RecoveryAction.showReconnecting);
    });

    test('bindCallId does NOT reset the budget of a live recovery', () {
      final r = P2PMediaRecovery();
      r.onCallChanged(callId: '', epoch: 2);
      r.onIceState(
        state: MediaLinkState.disconnected,
        callId: '',
        epoch: 2,
        now: now,
      );
      final budgetBefore = r.recoveryDeadline;
      final deadlineBefore = r.deadline;
      expect(budgetBefore, isNotNull);
      expect(deadlineBefore, isNotNull);

      r.bindCallId(realId);

      expect(r.recoveryDeadline, budgetBefore,
          reason: 'a late id must not restart the wall-clock budget');
      expect(r.deadline, deadlineBefore,
          reason: 'a late id must not restore the grace period');
      expect(r.phase, RecoveryPhase.recovering);
    });

    test('bindCallId does NOT refund ICE restart attempts', () {
      final r = P2PMediaRecovery(grace: const Duration(seconds: 1));
      r.onCallChanged(callId: '', epoch: 2);
      r.onIceState(
          state: MediaLinkState.failed, callId: '', epoch: 2, now: now);
      // grace expires -> restart #1 is requested
      final tick = r.onTick(
          callId: '', epoch: 2, now: now.add(const Duration(seconds: 2)));
      expect(tick.action, RecoveryAction.requestIceRestart);
      expect(r.iceRestartsUsed, 1);

      r.bindCallId(realId);

      expect(r.iceRestartsUsed, 1, reason: 'restart budget belongs to the outage');
      expect(r.iceRestartsLeft, r.maxIceRestarts - 1);
    });

    test('an event from a PREVIOUS call id stays stale', () {
      final r = P2PMediaRecovery();
      r.onCallChanged(callId: realId, epoch: 1);

      final d = r.onIceState(
        state: MediaLinkState.failed,
        callId: 'previous-call',
        epoch: 1,
        now: now,
      );
      expect(d.action, RecoveryAction.stale);
    });

    test('an event from a PREVIOUS epoch stays stale', () {
      final r = P2PMediaRecovery();
      r.onCallChanged(callId: realId, epoch: 7);

      final d = r.onIceState(
        state: MediaLinkState.failed,
        callId: realId,
        epoch: 6,
        now: now,
      );
      expect(d.action, RecoveryAction.stale);
      expect(r.phase, RecoveryPhase.idle);
    });

    test('late callbacks after teardown cannot resurrect the call', () {
      final r = P2PMediaRecovery();
      r.onCallChanged(callId: realId, epoch: 3);
      r.onIceState(
          state: MediaLinkState.failed, callId: realId, epoch: 3, now: now);
      expect(r.recovering, isTrue);

      final ended = r.onCallEnded(reason: 'user hangup');
      expect(ended.action, RecoveryAction.endCall);
      expect(r.phase, RecoveryPhase.ended);

      // The PeerConnection often fires one last Connected right after close.
      final late = r.onIceState(
        state: MediaLinkState.connected,
        callId: realId,
        epoch: 3,
        now: now.add(const Duration(seconds: 1)),
      );
      expect(late.action, RecoveryAction.stale);
      expect(r.phase, RecoveryPhase.ended,
          reason: 'a closed call must never be restored');

      final lateTick = r.onTick(
          callId: realId, epoch: 3, now: now.add(const Duration(seconds: 2)));
      expect(lateTick.action, RecoveryAction.stale);
      expect(r.phase, RecoveryPhase.ended);
    });

    test('bindCallId ignores an empty id', () {
      final r = P2PMediaRecovery();
      r.onCallChanged(callId: '', epoch: 1);
      r.bindCallId('');
      final d = r.onIceState(
          state: MediaLinkState.failed,
          callId: realId,
          epoch: 1,
          now: now);
      expect(d.action, RecoveryAction.stale,
          reason: 'an empty id must not adopt a foreign call');
    });
  });

  group('§2C.4b remote ICE queue ownership', () {
    test('drain returns candidates and empties the queue exactly once', () {
      final q = IceBuffer<Map<String, String?>>();
      q.add({'candidate': 'a'});
      q.add({'candidate': 'b'});

      expect(q.length, 2);
      final drained = q.drain();
      expect(drained.length, 2);
      expect(q.isEmpty, isTrue);

      // A second flush must not re-apply the same candidates.
      expect(q.drain(), isEmpty);
    });

    test('clear is the ownership boundary for a superseding ring', () {
      final q = IceBuffer<Map<String, String?>>();
      q.add({'candidate': 'from-previous-ring'});
      q.clear();
      q.add({'candidate': 'from-current-ring'});

      final out = q.drain();
      expect(out.length, 1);
      expect(out.single['candidate'], 'from-current-ring');
    });
  });
}