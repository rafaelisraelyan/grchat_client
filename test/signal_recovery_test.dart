import 'package:flutter_test/flutter_test.dart';
import 'package:grchat_client/src/call/call_api.dart';
import 'package:grchat_client/src/call/signal_recovery.dart';
import 'package:grchat_client/src/transport/grchat_connection.dart';

CallSnapshot snap({String callId = 'c1', int epoch = 1}) => CallSnapshot(
      callId: callId,
      phase: 'active',
      video: false,
      members: 2,
      serverTimeMs: 0,
      recoveryEpoch: epoch,
      acceptedAtMs: 1,
      recovering: false,
    );

void main() {
  group('signaling recovery drives the resume exactly once per outage', () {
    test('no outage means no resume attempt', () async {
      var calls = 0;
      final r = SignalRecovery(resume: (_) async {
        calls++;
        return snap();
      });
      final out = await r.onStatus(ConnStatus.connected,
          callId: 'c1', localEnded: false, localRecoveryEpoch: 0);
      expect(out, SignalRecoveryOutcome.none);
      expect(calls, 0);
    });

    test('down then up resumes once and keeps the call', () async {
      var calls = 0;
      final r = SignalRecovery(resume: (_) async {
        calls++;
        return snap();
      });
      await r.onStatus(ConnStatus.connecting,
          callId: 'c1', localEnded: false, localRecoveryEpoch: 0);
      expect(r.signalingDown, isTrue);

      final out = await r.onStatus(ConnStatus.connected,
          callId: 'c1', localEnded: false, localRecoveryEpoch: 0);
      expect(out, SignalRecoveryOutcome.resumed);
      expect(calls, 1);

      // A repeated connected event must not resume again.
      final again = await r.onStatus(ConnStatus.connected,
          callId: 'c1', localEnded: false, localRecoveryEpoch: 1);
      expect(again, SignalRecoveryOutcome.none);
      expect(calls, 1, reason: 'no retry storm after a successful resume');
    });

    test('a second outage resumes again (bounded by maxAttempts)', () async {
      var calls = 0;
      final r = SignalRecovery(resume: (_) async {
        calls++;
        return snap();
      });
      for (var i = 0; i < 5; i++) {
        await r.onStatus(ConnStatus.offline,
            callId: 'c1', localEnded: false, localRecoveryEpoch: i);
        await r.onStatus(ConnStatus.connected,
            callId: 'c1', localEnded: false, localRecoveryEpoch: i);
      }
      expect(calls, 3, reason: 'attempts are hard-capped per outage window');
      expect(r.attempts, greaterThan(3));
    });

    test('no local call means nothing to resume', () async {
      var calls = 0;
      final r = SignalRecovery(resume: (_) async {
        calls++;
        return snap();
      });
      await r.onStatus(ConnStatus.offline,
          callId: null, localEnded: true, localRecoveryEpoch: 0);
      final out = await r.onStatus(ConnStatus.connected,
          callId: null, localEnded: true, localRecoveryEpoch: 0);
      expect(out, SignalRecoveryOutcome.noCall);
      expect(calls, 0);
    });
  });

  group('a refusal never resurrects and never ends', () {
    test('server refusal is reported, not retried', () async {
      var calls = 0;
      final r = SignalRecovery(resume: (_) async {
        calls++;
        return null; // server said no
      });
      await r.onStatus(ConnStatus.offline,
          callId: 'c1', localEnded: false, localRecoveryEpoch: 0);
      final out = await r.onStatus(ConnStatus.connected,
          callId: 'c1', localEnded: false, localRecoveryEpoch: 0);
      expect(out, SignalRecoveryOutcome.refused);
      expect(calls, 1);
      // and no immediate second try
      final again = await r.onStatus(ConnStatus.connected,
          callId: 'c1', localEnded: false, localRecoveryEpoch: 0);
      expect(again, SignalRecoveryOutcome.none);
      expect(calls, 1);
    });

    test('a locally ended call is never resumed even if the server has it',
        () async {
      var calls = 0;
      final r = SignalRecovery(resume: (_) async {
        calls++;
        return snap();
      });
      await r.onStatus(ConnStatus.offline,
          callId: 'c1', localEnded: true, localRecoveryEpoch: 0);
      final out = await r.onStatus(ConnStatus.connected,
          callId: 'c1', localEnded: true, localRecoveryEpoch: 0);
      expect(out, SignalRecoveryOutcome.refused);
      expect(calls, 0,
          reason: 'an ended call must not even be offered to the server');
    });

    test('a snapshot for another call is refused', () async {
      final r = SignalRecovery(resume: (_) async => snap(callId: 'other'));
      await r.onStatus(ConnStatus.offline,
          callId: 'c1', localEnded: false, localRecoveryEpoch: 0);
      final out = await r.onStatus(ConnStatus.connected,
          callId: 'c1', localEnded: false, localRecoveryEpoch: 0);
      expect(out, SignalRecoveryOutcome.refused);
    });

    test('a transport error during recovery is contained', () async {
      final r = SignalRecovery(resume: (_) async => throw StateError('socket'));
      await r.onStatus(ConnStatus.offline,
          callId: 'c1', localEnded: false, localRecoveryEpoch: 0);
      final out = await r.onStatus(ConnStatus.connected,
          callId: 'c1', localEnded: false, localRecoveryEpoch: 0);
      expect(out, SignalRecoveryOutcome.failed);
      expect(r.attempts, 1);
    });
  });

  group('outage state does not leak into the next call', () {
    test('reset clears the outage window for a new call', () async {
      var calls = 0;
      final r = SignalRecovery(resume: (_) async {
        calls++;
        return snap();
      });
      await r.onStatus(ConnStatus.offline,
          callId: 'c1', localEnded: false, localRecoveryEpoch: 0);
      r.reset();
      // A brand new call starts connected: it must NOT be resumed.
      final out = await r.onStatus(ConnStatus.connected,
          callId: 'c2', localEnded: false, localRecoveryEpoch: 0);
      expect(out, SignalRecoveryOutcome.none);
      expect(calls, 0);
    });
  });
}
