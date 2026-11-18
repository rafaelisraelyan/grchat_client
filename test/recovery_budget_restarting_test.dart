// STAGE 2C.4j - C: does the wall-clock budget fire while phase == restarting
// and _deadline == null? Scenario from the review request:
//   t=0  ICE disconnected
//   t=11 grace expired -> restart #1
//   t=12 restart signaling completed, ICE still not Connected
//   t=46 onTick with no new ICE events
//
// The reported expectation is endCall at t=46. This test PRINTS the actual
// action and asserts it, so the answer is a measurement, not a reading.

import 'package:flutter_test/flutter_test.dart';
import 'package:grchat_client/src/call/p2p_media_recovery.dart';

void main() {
  test('budget fires in restarting with deadline == null (t=46)', () {
    final t0 = DateTime.utc(2026, 10, 20, 12, 0, 0);
    final r = P2PMediaRecovery();
    r.onCallChanged(callId: 'c1', epoch: 1);

    final d0 = r.onIceState(
        state: MediaLinkState.disconnected,
        callId: 'c1',
        epoch: 1,
        now: t0);
    // ignore: avoid_print
    print('t=0  action=${d0.action.name} phase=${d0.phase.name} '
        'budgetEnd=${r.recoveryDeadline}');

    final d11 = r.onTick(
        callId: 'c1', epoch: 1, now: t0.add(const Duration(seconds: 11)));
    // ignore: avoid_print
    print('t=11 action=${d11.action.name} phase=${r.phase.name} '
        'deadline=${r.deadline} used=${r.iceRestartsUsed}');

    final d12 = r.onIceRestartCompleted(
        restartNumber: 1, callId: 'c1', epoch: 1, succeeded: true);
    // ignore: avoid_print
    print('t=12 action=${d12.action.name} phase=${r.phase.name} '
        'deadline=${r.deadline} budgetEnd=${r.recoveryDeadline}');
    final d20 = r.onTick(
        callId: 'c1', epoch: 1, now: t0.add(const Duration(seconds: 20)));
    // ignore: avoid_print
    print('t=20 action=${d20.action.name} phase=${d20.phase.name}');

    final d46 = r.onTick(
        callId: 'c1', epoch: 1, now: t0.add(const Duration(seconds: 46)));
    // ignore: avoid_print
    print('t=46 action=${d46.action.name} phase=${d46.phase.name} '
        'reason=${d46.reason}');

    expect(d11.action, RecoveryAction.requestIceRestart);
    expect(d12.phase, RecoveryPhase.restarting);
    expect(d46.action, RecoveryAction.endCall,
        reason: 'the wall-clock budget must terminate the call at t=46');
    expect(d46.reason, contains('budget'));
  });

  test('budget also fires when the restart never reports completion', () {
    final t0 = DateTime.utc(2026, 10, 20, 12, 0, 0);
    final r = P2PMediaRecovery();
    r.onCallChanged(callId: 'c2', epoch: 1);
    r.onIceState(
        state: MediaLinkState.failed,
        callId: 'c2',
        epoch: 1,
        now: t0);
    final started = r.onTick(
        callId: 'c2', epoch: 1, now: t0.add(const Duration(seconds: 11)));
    expect(started.action, RecoveryAction.requestIceRestart);

    // Signaling hangs: no onIceRestartCompleted at all, no ICE events.
    final d46 = r.onTick(
        callId: 'c2', epoch: 1, now: t0.add(const Duration(seconds: 46)));
    // ignore: avoid_print
    print('hanging-restart t=46 action=${d46.action.name} '
        'phase=${d46.phase.name} reason=${d46.reason}');
    expect(d46.action, RecoveryAction.endCall,
        reason: 'a hung restart must not outlive the budget');
  });
}