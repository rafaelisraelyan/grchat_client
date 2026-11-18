// Stage 2C.2 - unit tests for P2PMediaRecovery.
//
// Pure controller tests: no PeerConnection, no transport, no timers. Each test
// pins one rule from the Stage 2C.2 invariant list. The controller is clock
// injected, so recovery deadlines are exercised with exact virtual time rather
// than sleeps.
import 'package:flutter_test/flutter_test.dart';

import 'package:grchat_client/src/call/p2p_media_recovery.dart';

final DateTime t0 = DateTime(2026, 1, 1, 12, 0, 0);
DateTime plus(Duration d) => t0.add(d);

void main() {
  late P2PMediaRecovery r;

  setUp(() {
    r = P2PMediaRecovery();
    r.onCallChanged(callId: 'c1', epoch: 1);
  });

  group('healthy call', () {
    test('checking is never a failure', () {
      final d = r.onIceState(
          state: MediaLinkState.checking,
          callId: 'c1',
          epoch: 1,
          now: t0);
      expect(d.action, RecoveryAction.keep);
      expect(r.recovering, isFalse);
    });

    test('connected on a healthy call changes nothing', () {
      final d = r.onIceState(
          state: MediaLinkState.connected,
          callId: 'c1',
          epoch: 1,
          now: t0);
      expect(d.action, RecoveryAction.keep);
      expect(r.deadline, isNull);
    });
  });

  group('transient loss', () {
    test('disconnected starts the grace period and shows reconnecting', () {
      final d = r.onIceState(
          state: MediaLinkState.disconnected,
          callId: 'c1',
          epoch: 1,
          now: t0);
      expect(d.action, RecoveryAction.showReconnecting);
      expect(r.phase, RecoveryPhase.recovering);
      expect(r.deadline, plus(const Duration(seconds: 10)));
    });

    test('reconnecting before the deadline keeps the call', () {
      r.onIceState(
          state: MediaLinkState.disconnected, callId: 'c1', epoch: 1, now: t0);
      final d = r.onTick(callId: 'c1', epoch: 1, now: plus(const Duration(seconds: 9)));
      expect(d.action, RecoveryAction.keep);
      expect(r.phase, RecoveryPhase.recovering);
    });

    test('reconnected inside the grace period cancels recovery', () {
      r.onIceState(
          state: MediaLinkState.disconnected, callId: 'c1', epoch: 1, now: t0);
      final d = r.onIceState(
          state: MediaLinkState.connected, callId: 'c1', epoch: 1, now: plus(const Duration(seconds: 2)));
      expect(d.action, RecoveryAction.recovered);
      expect(r.phase, RecoveryPhase.idle);
      expect(r.deadline, isNull);
      expect(r.recovering, isFalse);
    });

    test('a repeated disconnect does not extend the deadline', () {
      r.onIceState(
          state: MediaLinkState.disconnected, callId: 'c1', epoch: 1, now: t0);
      final deadline = r.deadline;
      final d = r.onIceState(
          state: MediaLinkState.disconnected,
          callId: 'c1',
          epoch: 1,
          now: plus(const Duration(seconds: 5)));
      expect(d.action, RecoveryAction.keep);
      expect(r.deadline, deadline,
          reason: 'flapping must not hold the call open forever');
    });
  });

  group('failed is repairable, closed is final', () {
    test('failed does NOT end the call immediately', () {
      final d = r.onIceState(
          state: MediaLinkState.failed, callId: 'c1', epoch: 1, now: t0);
      expect(d.action, RecoveryAction.showReconnecting,
          reason: 'a failed ICE generation is repairable in place');
      expect(r.phase, RecoveryPhase.recovering);
    });

    test('grace expiry after failed requests an ICE restart', () {
      r.onIceState(
          state: MediaLinkState.failed, callId: 'c1', epoch: 1, now: t0);
      final d = r.onTick(callId: 'c1', epoch: 1, now: plus(const Duration(seconds: 11)));
      expect(d.action, RecoveryAction.requestIceRestart);
      expect(d.restartNumber, 1);
      expect(r.phase, RecoveryPhase.restarting);
      expect(r.iceRestartsLeft, 1);
    });

    test('closed ends the call at once', () {
      final d = r.onIceState(
          state: MediaLinkState.closed, callId: 'c1', epoch: 1, now: t0);
      expect(d.action, RecoveryAction.endCall);
      expect(r.phase, RecoveryPhase.ended);
    });
  });

  group('restart budget', () {
    test('the budget is finite: no infinite restarts', () {
      r.onIceState(
          state: MediaLinkState.failed, callId: 'c1', epoch: 1, now: t0);
      // First restart
      r.onTick(callId: 'c1', epoch: 1, now: plus(const Duration(seconds: 11)));
      // Media still down after the restart -> new grace, then second restart
      r.onIceState(
          state: MediaLinkState.failed, callId: 'c1', epoch: 1, now: plus(const Duration(seconds: 12)));
      final second = r.onTick(
          callId: 'c1', epoch: 1, now: plus(const Duration(seconds: 24)));
      expect(second.action, RecoveryAction.requestIceRestart);
      expect(second.restartNumber, 2);
      expect(r.iceRestartsLeft, 0);

      // Third outage has no budget left -> the call must end.
      r.onIceState(
          state: MediaLinkState.failed, callId: 'c1', epoch: 1, now: plus(const Duration(seconds: 25)));
      final end = r.onTick(
          callId: 'c1', epoch: 1, now: plus(const Duration(seconds: 40)));
      expect(end.action, RecoveryAction.endCall);
      expect(end.reason, contains('budget exhausted'));
    });

    test('a restart that fails ends the call without burning the budget', () {
      r.onIceState(
          state: MediaLinkState.failed, callId: 'c1', epoch: 1, now: t0);
      r.onTick(callId: 'c1', epoch: 1, now: plus(const Duration(seconds: 11)));
      final d = r.onIceRestartCompleted(
          restartNumber: 1, callId: 'c1', epoch: 1, succeeded: false);
      expect(d.action, RecoveryAction.endCall);
      expect(r.iceRestartsUsed, 1);
    });

    test('media restored after a restart cancels the recovery', () {
      r.onIceState(
          state: MediaLinkState.failed, callId: 'c1', epoch: 1, now: t0);
      r.onTick(callId: 'c1', epoch: 1, now: plus(const Duration(seconds: 11)));
      r.onIceRestartCompleted(
          restartNumber: 1, callId: 'c1', epoch: 1, succeeded: true);
      final d = r.onIceState(
          state: MediaLinkState.completed,
          callId: 'c1',
          epoch: 1,
          now: plus(const Duration(seconds: 13)));
      expect(d.action, RecoveryAction.recovered);
      expect(r.phase, RecoveryPhase.idle);
    });
  });

  group('stale callbacks and timers', () {
    test('an old epoch can never end the current call', () {
      r.onIceState(
          state: MediaLinkState.disconnected, callId: 'c1', epoch: 1, now: t0);
      final d = r.onTick(callId: 'c1', epoch: 0, now: plus(const Duration(seconds: 30)));
      expect(d.action, RecoveryAction.stale);
      expect(r.phase, RecoveryPhase.recovering,
          reason: 'the live call keeps its protection');
    });

    test('a different callId cannot end this call', () {
      r.onIceState(
          state: MediaLinkState.disconnected, callId: 'c1', epoch: 1, now: t0);
      final d = r.onIceState(
          state: MediaLinkState.closed, callId: 'other', epoch: 1, now: t0);
      expect(d.action, RecoveryAction.stale);
      expect(r.callId, 'c1');
    });

    test('a stale restart completion is ignored', () {
      r.onIceState(
          state: MediaLinkState.failed, callId: 'c1', epoch: 1, now: t0);
      r.onTick(callId: 'c1', epoch: 1, now: plus(const Duration(seconds: 11)));
      final d = r.onIceRestartCompleted(
          restartNumber: 7, callId: 'c1', epoch: 1, succeeded: true);
      expect(d.action, RecoveryAction.stale);
      expect(r.phase, RecoveryPhase.restarting);
    });

    test('a restart completion for a finished call is ignored', () {
      final d = r.onIceRestartCompleted(
          restartNumber: 1, callId: 'c1', epoch: 1, succeeded: true);
      expect(d.action, RecoveryAction.stale,
          reason: 'no restart was requested at all');
    });

    test('a new call does not inherit the previous grace deadline', () {
      r.onIceState(
          state: MediaLinkState.disconnected, callId: 'c1', epoch: 1, now: t0);
      r.onCallChanged(callId: 'c2', epoch: 2);
      expect(r.phase, RecoveryPhase.idle);
      expect(r.deadline, isNull);
      expect(r.iceRestartsUsed, 0);
      final d = r.onTick(callId: 'c2', epoch: 2, now: plus(const Duration(seconds: 60)));
      expect(d.action, RecoveryAction.keep,
          reason: "the old call's timer must not end the new call");
    });
  });

  group('user hangup wins', () {
    test('hangup during recovery ends the call immediately', () {
      r.onIceState(
          state: MediaLinkState.disconnected, callId: 'c1', epoch: 1, now: t0);
      final d = r.onUserHangup();
      expect(d.action, RecoveryAction.endCall);
      expect(d.reason, contains('user hangup'));
      expect(r.phase, RecoveryPhase.ended);
    });

    test('a late ICE event after hangup cannot revive anything', () {
      r.onUserHangup();
      final d = r.onIceState(
          state: MediaLinkState.connected, callId: 'c1', epoch: 1, now: t0);
      expect(d.action, RecoveryAction.stale);
      expect(r.phase, RecoveryPhase.ended);
    });
  });

  group('signaling never drives media recovery', () {
    test('signaling loss with healthy media does not restart ICE', () {
      final d = r.onSignaling(up: false, callId: 'c1', epoch: 1, now: t0);
      expect(d.action, RecoveryAction.awaitSignaling);
      expect(r.phase, RecoveryPhase.idle);
      expect(r.deadline, isNull);
      expect(r.iceRestartsUsed, 0);
      expect(r.signalingDown, isTrue);
    });

    test('signaling loss during media recovery is absorbed by media recovery', () {
      r.onIceState(
          state: MediaLinkState.disconnected, callId: 'c1', epoch: 1, now: t0);
      final d = r.onSignaling(up: false, callId: 'c1', epoch: 1, now: t0);
      expect(d.action, RecoveryAction.keep);
      expect(r.phase, RecoveryPhase.recovering);
    });

    test('signaling restored never touches the media lifecycle', () {
      r.onIceState(
          state: MediaLinkState.disconnected, callId: 'c1', epoch: 1, now: t0);
      final d = r.onSignaling(up: true, callId: 'c1', epoch: 1, now: t0);
      expect(d.action, RecoveryAction.keep);
      expect(r.phase, RecoveryPhase.recovering,
          reason: 'signaling recovery must not cancel a media grace period');
      expect(r.signalingDown, isFalse);
    });

    test('signaling events from another call are stale', () {
      final d = r.onSignaling(up: false, callId: 'other', epoch: 9, now: t0);
      expect(d.action, RecoveryAction.stale);
    });
  });

  group('simultaneous events', () {
    test('disconnected and failed in the same instant yield one grace period',
        () {
      r.onIceState(
          state: MediaLinkState.disconnected, callId: 'c1', epoch: 1, now: t0);
      final d = r.onIceState(
          state: MediaLinkState.failed, callId: 'c1', epoch: 1, now: t0);
      expect(d.action, RecoveryAction.keep);
      expect(r.deadline, plus(const Duration(seconds: 10)));
    });

    test('a hangup racing a grace tick still ends the call once', () {
      r.onIceState(
          state: MediaLinkState.disconnected, callId: 'c1', epoch: 1, now: t0);
      r.onUserHangup();
      final d = r.onTick(callId: 'c1', epoch: 1, now: plus(const Duration(seconds: 30)));
      expect(d.action, RecoveryAction.stale);
      expect(r.phase, RecoveryPhase.ended);
    });
  });

  group('global recovery budget (Stage 2C.3 pre-integration review)', () {
    test('the budget starts at the first loss and never moves', () {
      r.onIceState(
          state: MediaLinkState.disconnected, callId: 'c1', epoch: 1, now: t0);
      final budget = r.recoveryDeadline;
      expect(budget, plus(const Duration(seconds: 45)));
      // A second outage later in the same session must not extend it.
      r.onTick(callId: 'c1', epoch: 1, now: plus(const Duration(seconds: 11)));
      r.onIceState(
          state: MediaLinkState.failed, callId: 'c1', epoch: 1, now: plus(const Duration(seconds: 12)));
      expect(r.recoveryDeadline, budget);
    });

    test('repeated failures cannot push a call past the wall-clock budget', () {
      // maxIceRestarts is deliberately huge: only the budget may stop this.
      final big = P2PMediaRecovery(maxIceRestarts: 99);
      big.onCallChanged(callId: 'c1', epoch: 1);
      RecoveryAction end = RecoveryAction.keep;
      String reason = '';
      var now = t0;
      // 8 outages, each escalating to a restart, all inside 44 seconds.
      for (var i = 0; i < 8; i++) {
        big.onIceState(
            state: MediaLinkState.failed, callId: 'c1', epoch: 1, now: now);
        now = now.add(const Duration(seconds: 8));
        final d = big.onTick(callId: 'c1', epoch: 1, now: now);
        if (d.action == RecoveryAction.endCall) {
          end = d.action;
          reason = d.reason;
          break;
        }
      }
      expect(end, RecoveryAction.endCall,
          reason: 'a flapping link must not hold the call indefinitely');
      expect(reason, contains('budget'),
          reason: 'the wall-clock budget, not the restart count, must stop it');
      // The budget is evaluated at tick granularity, so the call may be ended
      // at most one tick after the deadline; what must hold is that no further
      // restart was granted past it.
      expect(big.iceRestartsUsed, lessThan(99));
      expect(now.isBefore(t0.add(const Duration(seconds: 45 + 8))), isTrue,
          reason: 'the call must end within one tick of the 45 s budget');
    });

    test('the budget is cleared once media recovers', () {
      r.onIceState(
          state: MediaLinkState.disconnected, callId: 'c1', epoch: 1, now: t0);
      expect(r.recoveryDeadline, isNotNull);
      r.onIceState(
          state: MediaLinkState.connected, callId: 'c1', epoch: 1, now: plus(const Duration(seconds: 2)));
      expect(r.recoveryDeadline, isNull);
      expect(r.deadline, isNull);
    });

    test('a new call starts with a fresh budget', () {
      r.onIceState(
          state: MediaLinkState.disconnected, callId: 'c1', epoch: 1, now: t0);
      r.onCallChanged(callId: 'c2', epoch: 2);
      expect(r.recoveryDeadline, isNull);
      expect(r.iceRestartsUsed, 0);
    });
  });

  group('Stage 2C.3.1 review regressions', () {
    test('R1 restarting with no ICE callback still ends at the budget', () {
      r.onIceState(
          state: MediaLinkState.failed, callId: 'c1', epoch: 1, now: t0);
      final go = r.onTick(
          callId: 'c1', epoch: 1, now: plus(const Duration(seconds: 11)));
      expect(go.action, RecoveryAction.requestIceRestart);
      expect(r.phase, RecoveryPhase.restarting);
      // restartIce() ran, but no ICE Connected ever arrives. `restarting` has
      // no grace deadline, so this used to return keep FOREVER.
      final stuck = r.onTick(
          callId: 'c1', epoch: 1, now: plus(const Duration(seconds: 20)));
      expect(stuck.action, RecoveryAction.keep,
          reason: 'inside the budget the call must survive');
      final ended = r.onTick(
          callId: 'c1', epoch: 1, now: plus(const Duration(seconds: 46)));
      expect(ended.action, RecoveryAction.endCall);
      expect(ended.reason, contains('was in restarting'));
    });

    test('R2 a grace deadline beyond the budget cannot delay the end', () {
      // Grace longer than the budget: the budget must win.
      final long = P2PMediaRecovery(grace: const Duration(seconds: 30));
      long.onCallChanged(callId: 'c1', epoch: 1);
      long.onIceState(
          state: MediaLinkState.failed, callId: 'c1', epoch: 1, now: t0);
      expect(long.deadline, plus(const Duration(seconds: 30)));
      final d = long.onTick(
          callId: 'c1', epoch: 1, now: plus(const Duration(seconds: 46)));
      expect(d.action, RecoveryAction.endCall);
      expect(d.reason, contains('budget'));
    });

    test('R3 a second outage after recovery gets a fresh restart budget', () {
      // Outage 1: consume both restarts.
      r.onIceState(
          state: MediaLinkState.failed, callId: 'c1', epoch: 1, now: t0);
      r.onTick(callId: 'c1', epoch: 1, now: plus(const Duration(seconds: 11)));
      r.onIceState(
          state: MediaLinkState.failed,
          callId: 'c1',
          epoch: 1,
          now: plus(const Duration(seconds: 12)));
      r.onTick(callId: 'c1', epoch: 1, now: plus(const Duration(seconds: 23)));
      expect(r.iceRestartsUsed, 2);
      expect(r.iceRestartsLeft, 0);

      // Media comes back: the outage is over.
      final back = r.onIceState(
          state: MediaLinkState.completed,
          callId: 'c1',
          epoch: 1,
          now: plus(const Duration(seconds: 26)));
      expect(back.action, RecoveryAction.recovered);
      expect(back.reason, contains('2 restart(s)'));
      expect(back.reason, contains('budget refreshed'));

      // Outage 2, independent: both attempts are available again.
      r.onIceState(
          state: MediaLinkState.failed,
          callId: 'c1',
          epoch: 1,
          now: plus(const Duration(seconds: 100)));
      expect(r.iceRestartsLeft, 2);
      final first = r.onTick(
          callId: 'c1', epoch: 1, now: plus(const Duration(seconds: 111)));
      expect(first.action, RecoveryAction.requestIceRestart);
      expect(first.restartNumber, 1);
    });

    test('R4 ICE and signaling lost together: no executable restart', () {
      r.onSignaling(up: false, callId: 'c1', epoch: 1, now: t0);
      r.onIceState(
          state: MediaLinkState.failed, callId: 'c1', epoch: 1, now: t0);
      final d = r.onTick(callId: 'c1', epoch: 1, now: plus(const Duration(seconds: 11)));
      expect(d.action, RecoveryAction.awaitSignaling,
          reason: 'an SDP cannot be sent without signaling');
      expect(r.iceRestartsUsed, 0, reason: 'no attempt may be burned');
      expect(r.recoveryDeadline, plus(const Duration(seconds: 45)),
          reason: 'waiting must not extend the session budget');
      // Signaling returns: now the restart becomes executable, same budget.
      r.onSignaling(up: true, callId: 'c1', epoch: 1, now: plus(const Duration(seconds: 12)));
      final go = r.onTick(callId: 'c1', epoch: 1, now: plus(const Duration(seconds: 13)));
      expect(go.action, RecoveryAction.requestIceRestart);
      expect(r.iceRestartsUsed, 1);
    });

    test('R5 a successful restartIce without ICE Connected ends finitely', () {
      r.onIceState(
          state: MediaLinkState.failed, callId: 'c1', epoch: 1, now: t0);
      r.onTick(callId: 'c1', epoch: 1, now: plus(const Duration(seconds: 11)));
      final ok = r.onIceRestartCompleted(
          restartNumber: 1, callId: 'c1', epoch: 1, succeeded: true);
      expect(ok.action, RecoveryAction.keep,
          reason: 'success is only believed when the transport confirms it');
      expect(r.phase, RecoveryPhase.restarting);
      var end = RecoveryAction.keep;
      for (var s = 15; s <= 60; s += 5) {
        final d =
            r.onTick(callId: 'c1', epoch: 1, now: plus(Duration(seconds: s)));
        if (d.action == RecoveryAction.endCall) {
          end = d.action;
          break;
        }
      }
      expect(end, RecoveryAction.endCall,
          reason: 'a silent transport must not hang the call forever');
    });

    test('R6 server end followed by ICE failed yields exactly one teardown', () {
      r.onIceState(
          state: MediaLinkState.disconnected, callId: 'c1', epoch: 1, now: t0);
      expect(r.recovering, isTrue);
      final ended = r.onCallEnded(reason: 'server ended the call');
      expect(ended.action, RecoveryAction.endCall);
      // Everything that follows belongs to a dead session.
      final late = r.onIceState(
          state: MediaLinkState.failed, callId: 'c1', epoch: 1, now: t0);
      expect(late.action, RecoveryAction.stale);
      final tick = r.onTick(
          callId: 'c1', epoch: 1, now: plus(const Duration(seconds: 60)));
      expect(tick.action, RecoveryAction.stale);
      final second = r.onCallEnded(reason: 'duplicate teardown attempt');
      expect(second.action, RecoveryAction.endCall,
          reason: 'teardown stays idempotent: one decision, no double free');
    });

    test('R7 a delayed result from the previous call cannot touch the new one',
        () {
      r.onCallChanged(callId: 'c1', epoch: 1);
      r.onIceState(
          state: MediaLinkState.failed, callId: 'c1', epoch: 1, now: t0);
      r.onTick(callId: 'c1', epoch: 1, now: plus(const Duration(seconds: 11)));
      // The next call starts while the old restart is still in flight.
      r.onCallChanged(callId: 'c2', epoch: 2);
      final late = r.onIceRestartCompleted(
          restartNumber: 1, callId: 'c1', epoch: 1, succeeded: true);
      expect(late.action, RecoveryAction.stale);
      expect(r.callId, 'c2');
      expect(r.phase, RecoveryPhase.idle,
          reason: 'the new call must not inherit the old recovery');
      final oldTick = r.onTick(
          callId: 'c1', epoch: 1, now: plus(const Duration(seconds: 99)));
      expect(oldTick.action, RecoveryAction.stale);
    });
  });

  group('invariants that must never break', () {
    test('exactly one recovery process exists per call', () {
      r.onIceState(
          state: MediaLinkState.disconnected, callId: 'c1', epoch: 1, now: t0);
      final deadline = r.deadline;
      for (var i = 0; i < 5; i++) {
        r.onIceState(
            state: MediaLinkState.disconnected,
            callId: 'c1',
            epoch: 1,
            now: plus(Duration(seconds: i)));
      }
      expect(r.deadline, deadline);
      expect(r.iceRestartsUsed, 0);
    });

    test('maxIceRestarts = 0 means the call ends at grace expiry', () {
      final none = P2PMediaRecovery(maxIceRestarts: 0);
      none.onCallChanged(callId: 'c1', epoch: 1);
      none.onIceState(
          state: MediaLinkState.failed, callId: 'c1', epoch: 1, now: t0);
      final d = none.onTick(
          callId: 'c1', epoch: 1, now: plus(const Duration(seconds: 11)));
      expect(d.action, RecoveryAction.endCall);
    });

    test('recovery never starts before a call is registered', () {
      final fresh = P2PMediaRecovery();
      final d = fresh.onTick(
          callId: 'unregistered', epoch: 7, now: plus(const Duration(seconds: 99)));
      // Tightened in Stage 2C.3.1: an event for a call that was never
      // registered is STALE, not merely harmless. Adopting its callId would let
      // any stray callback take ownership of the controller.
      expect(d.action, RecoveryAction.stale);
      expect(fresh.phase, RecoveryPhase.idle);
      expect(fresh.deadline, isNull);
      expect(fresh.callId, isNull,
          reason: 'a stray event must not become the owned call');
    });
  });
}