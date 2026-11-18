// STAGE 2C.4l - Diagnostic Cleanup.
//
// Three pure pieces are under test:
//   diagnosticsAllowed  - the gate that stops snapshots from reading a closed
//                         native PeerConnection;
//   classifyDiagnostics - the distinction between "transport is gone" (drop)
//                         and "the diagnostic broke during a live call"
//                         (report), which must never be silenced;
//   terminationLine     - the single structured line explaining why a call
//                         ended.
//
// The full CallState paths (hangup / remote end / link-loss) cannot be driven
// in a unit test: CallState needs live signalling and real media devices. That
// limitation is recorded in the report rather than papered over with a fake
// provider harness.

import 'package:flutter_test/flutter_test.dart';
import 'package:grchat_client/src/call/call_state.dart';

void main() {
  group('diagnosticsAllowed (§2C.4l)', () {
    test('a live transport with no teardown is allowed', () {
      expect(
        diagnosticsAllowed(hasTransport: true, tearingDown: false),
        isTrue,
      );
    });

    test('no transport blocks the snapshot', () {
      expect(
        diagnosticsAllowed(hasTransport: false, tearingDown: false),
        isFalse,
      );
    });

    test(
      'teardown blocks the snapshot even while the PC is still assigned',
      () {
        expect(
          diagnosticsAllowed(hasTransport: true, tearingDown: true),
          isFalse,
          reason:
              'this is exactly the window that produced '
              '"getSignalingState() peerConnection is null"',
        );
      },
    );

    test('both flags false blocks the snapshot', () {
      expect(
        diagnosticsAllowed(hasTransport: false, tearingDown: true),
        isFalse,
      );
    });
  });

  group('classifyDiagnostics (§2C.4l)', () {
    test('a live transport with a good summary is emitted', () {
      expect(
        classifyDiagnostics(
          summary: 'Platform: Windows',
          hasTransport: true,
          tearingDown: false,
        ),
        DiagnosticsOutcome.emit,
      );
    });

    test(
      'a diagnostic failure DURING a live call is reported, not silenced',
      () {
        expect(
          classifyDiagnostics(
            summary: 'stats failed: Exception: boom',
            hasTransport: true,
            tearingDown: false,
          ),
          DiagnosticsOutcome.reportFailure,
          reason: 'swallowing this would hide a real WebRTC problem',
        );
      },
    );

    test('a failure after teardown started is silently dropped', () {
      expect(
        classifyDiagnostics(
          summary: 'stats failed: peerConnection is null',
          hasTransport: true,
          tearingDown: true,
        ),
        DiagnosticsOutcome.drop,
      );
    });

    test('a failure with no transport is dropped', () {
      expect(
        classifyDiagnostics(
          summary: 'stats failed: peerConnection is null',
          hasTransport: false,
          tearingDown: false,
        ),
        DiagnosticsOutcome.drop,
      );
    });

    test('a good summary without transport is still dropped', () {
      expect(
        classifyDiagnostics(
          summary: 'Platform: Windows',
          hasTransport: false,
          tearingDown: false,
        ),
        DiagnosticsOutcome.drop,
      );
    });
  });

  group('terminationLine (§2C.4l)', () {
    test('local hangup is attributed to local', () {
      final l = terminationLine(
        callId: '08e45bbb11223344',
        epoch: 3,
        initiator: 'local',
        reason: 'hangup',
        teardown: true,
      );
      expect(l, contains('call=08e45bbb'));
      expect(l, contains('epoch=3'));
      expect(l, contains('initiator=local'));
      expect(l, contains('reason=hangup'));
      expect(l, contains('teardown=true'));
    });

    test('remote end is never reported as a local hangup', () {
      final l = terminationLine(
        callId: 'abcdef1234567890',
        epoch: 1,
        initiator: 'remote',
        reason: 'declined',
        teardown: true,
      );
      expect(l, contains('initiator=remote'));
      expect(l, isNot(contains('initiator=local')));
      expect(l, contains('reason=declined'));
    });

    test('link-loss is distinct from a plain hangup', () {
      final link = terminationLine(
        callId: 'x',
        epoch: 2,
        initiator: 'local',
        reason: 'link-loss',
        teardown: true,
      );
      final user = terminationLine(
        callId: 'x',
        epoch: 2,
        initiator: 'local',
        reason: 'hangup',
        teardown: true,
      );
      expect(link, isNot(user));
      expect(link, contains('reason=link-loss'));
    });

    test('an unknown initiator stays unknown instead of being guessed', () {
      final l = terminationLine(
        callId: 'x',
        epoch: 0,
        initiator: null,
        reason: null,
        teardown: false,
      );
      expect(l, contains('initiator=unknown'));
      expect(l, contains('reason=unknown'));
      expect(l, contains('teardown=false'));
    });

    test('a missing call id is reported as unknown, not as an empty token', () {
      final l = terminationLine(
        callId: null,
        epoch: 0,
        initiator: 'server',
        reason: 'timeout',
        teardown: true,
      );
      expect(l, contains('call=unknown'));
      expect(l, contains('initiator=server'));
    });
  });
}
