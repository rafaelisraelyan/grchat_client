// §reconnect: the link-loss state machine is pure (clock injected), so the
// whole grace-period contract is testable without a PeerConnection.
// §camera-busy: the wording a blocked camera gets is a decision, not a
// string literal scattered across call sites.
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart' show RTCPeerConnectionState;

import 'package:grchat_client/src/call/call_state.dart';
import 'package:grchat_client/src/call/camera_notice.dart';
import 'package:grchat_client/src/call/reconnect_watch.dart';

void main() {
  final t0 = DateTime(2026, 10, 14, 18, 0, 0);

  group('reconnect grace period (§reconnect)', () {
    test('healthy call: nothing happens', () {
      final w = ReconnectWatch();
      expect(
        w.onState(
          state: LinkState.connected,
          epoch: 1,
          callId: 'a',
          now: t0,
        ),
        LinkVerdict.none,
      );
      expect(w.reconnecting, isFalse);
      expect(w.onTick(epoch: 1, callId: 'a', now: t0), LinkVerdict.none);
    });

    test('the startup phase (new/connecting/checking) is NOT a failure', () {
      // Regression, 2026-10-14: answering produced Connecting 14 ms before
      // Connected; the machine read it as a definitive failure and hung up a
      // perfectly good call (user saw «нет сети» / «нет ответа»).
      final w = ReconnectWatch();
      for (final s in [LinkState.connecting, LinkState.connecting]) {
        expect(
          w.onState(state: s, epoch: 1, callId: 'a', now: t0),
          LinkVerdict.none,
        );
      }
      expect(w.reconnecting, isFalse);
      expect(
        w.onTick(epoch: 1, callId: 'a', now: t0.add(const Duration(seconds: 30))),
        LinkVerdict.none,
        reason: 'a slow startup must never hit the grace timer',
      );
      // And it still connects normally afterwards.
      expect(
        w.onState(
          state: LinkState.connected,
          epoch: 1,
          callId: 'a',
          now: t0.add(const Duration(seconds: 1)),
        ),
        LinkVerdict.none,
      );
    });

    test('transient loss: banner + grace, no end', () {
      final w = ReconnectWatch(grace: const Duration(seconds: 10));
      expect(
        w.onState(
          state: LinkState.disconnected,
          epoch: 1,
          callId: 'a',
          now: t0,
        ),
        LinkVerdict.enterReconnecting,
      );
      expect(w.reconnecting, isTrue);
      expect(w.deadline, t0.add(const Duration(seconds: 10)));
      // Repeated disconnected events must not restart or extend the period.
      expect(
        w.onState(
          state: LinkState.disconnected,
          epoch: 1,
          callId: 'a',
          now: t0.add(const Duration(seconds: 3)),
        ),
        LinkVerdict.none,
      );
      // Halfway through: still nothing to end.
      expect(
        w.onTick(epoch: 1, callId: 'a', now: t0.add(const Duration(seconds: 5))),
        LinkVerdict.none,
      );
    });

    test('recovery inside the period cancels the end and keeps the session',
        () {
      final w = ReconnectWatch();
      w.onState(
        state: LinkState.disconnected,
        epoch: 1,
        callId: 'a',
        now: t0,
      );
      expect(
        w.onState(
          state: LinkState.connected,
          epoch: 1,
          callId: 'a',
          now: t0.add(const Duration(seconds: 2)),
        ),
        LinkVerdict.recovered,
      );
      expect(w.reconnecting, isFalse);
      // The (cancelled) deadline can no longer end anything.
      expect(
        w.onTick(epoch: 1, callId: 'a', now: t0.add(const Duration(seconds: 99))),
        LinkVerdict.none,
      );
    });

    test('grace expiry ends the call', () {
      final w = ReconnectWatch();
      w.onState(
        state: LinkState.disconnected,
        epoch: 1,
        callId: 'a',
        now: t0,
      );
      expect(
        w.onTick(epoch: 1, callId: 'a', now: t0.add(const Duration(seconds: 10))),
        LinkVerdict.endNow,
      );
      expect(w.reconnecting, isFalse);
      // Idempotent afterwards.
      expect(
        w.onTick(epoch: 1, callId: 'a', now: t0.add(const Duration(seconds: 20))),
        LinkVerdict.none,
      );
    });

    test('definitive states end immediately (WebRTC semantics)', () {
      final w = ReconnectWatch();
      expect(
        w.onState(state: LinkState.failed, epoch: 1, callId: 'a', now: t0),
        LinkVerdict.endNow,
      );
      final w2 = ReconnectWatch();
      expect(
        w2.onState(state: LinkState.closed, epoch: 1, callId: 'a', now: t0),
        LinkVerdict.endNow,
      );
    });

    test('a late event from a FINISHED call never touches the new one', () {
      // The exact stale-timer class this machine exists for: call 'a' lost
      // the link, the call ended, call 'b' started (new epoch), and the old
      // grace timer fires.
      final w = ReconnectWatch();
      w.onState(
        state: LinkState.disconnected,
        epoch: 1,
        callId: 'a',
        now: t0,
      );
      w.reset(); // call 'a' torn down
      w.onState(
        state: LinkState.disconnected,
        epoch: 2,
        callId: 'b',
        now: t0.add(const Duration(seconds: 1)),
      );
      // The OLD timer (epoch 1, call 'a') fires: ignored, not ended.
      expect(
        w.onTick(epoch: 1, callId: 'a', now: t0.add(const Duration(seconds: 11))),
        LinkVerdict.stale,
      );
      expect(w.reconnecting, isTrue, reason: "call 'b' keeps its own period");
      // And the current call's own deadline still works.
      expect(
        w.onTick(epoch: 2, callId: 'b', now: t0.add(const Duration(seconds: 12))),
        LinkVerdict.endNow,
      );
    });

    test('an event for another call while reconnecting is ignored', () {
      final w = ReconnectWatch();
      w.onState(
        state: LinkState.disconnected,
        epoch: 1,
        callId: 'a',
        now: t0,
      );
      expect(
        w.onState(
          state: LinkState.connected,
          epoch: 2,
          callId: 'b',
          now: t0.add(const Duration(seconds: 1)),
        ),
        LinkVerdict.stale,
      );
      expect(w.reconnecting, isTrue);
    });
  });

  group('transport state → link verdict mapping', () {
    // This mapping is the exact place where the 2026-10-14 outage lived:
    // `Connecting` (normal startup, 14 ms before Connected) was folded into
    // "closed" and hung up healthy calls. Every state is pinned here.
    test('connected is connected', () {
      expect(
        CallState.linkStateFor(
          RTCPeerConnectionState.RTCPeerConnectionStateConnected,
        ),
        LinkState.connected,
      );
    });

    test('connecting / new are the startup phase, NOT a failure', () {
      expect(
        CallState.linkStateFor(
          RTCPeerConnectionState.RTCPeerConnectionStateConnecting,
        ),
        LinkState.connecting,
      );
      expect(
        CallState.linkStateFor(
          RTCPeerConnectionState.RTCPeerConnectionStateNew,
        ),
        LinkState.connecting,
      );
    });

    test('disconnected and failed stay distinct', () {
      expect(
        CallState.linkStateFor(
          RTCPeerConnectionState.RTCPeerConnectionStateDisconnected,
        ),
        LinkState.disconnected,
      );
      expect(
        CallState.linkStateFor(
          RTCPeerConnectionState.RTCPeerConnectionStateFailed,
        ),
        LinkState.failed,
      );
    });

    test('closed is closed', () {
      expect(
        CallState.linkStateFor(
          RTCPeerConnectionState.RTCPeerConnectionStateClosed,
        ),
        LinkState.closed,
      );
    });

    test('the full startup sequence never ends a call', () {
      // new -> connecting -> connected: the path every call walks.
      final w = ReconnectWatch();
      for (final s in [
        RTCPeerConnectionState.RTCPeerConnectionStateNew,
        RTCPeerConnectionState.RTCPeerConnectionStateConnecting,
        RTCPeerConnectionState.RTCPeerConnectionStateConnected,
      ]) {
        expect(
          w.onState(
            state: CallState.linkStateFor(s),
            epoch: 1,
            callId: 'a',
            now: t0,
          ),
          isNot(LinkVerdict.endNow),
        );
      }
    });
  });

  group('camera block wording (§camera-busy)', () {
    test('another grchat window is stated as fact (the lock proves it)', () {
      expect(
        cameraBlockNotice(CameraBlock.anotherInstance),
        'Камера занята другим окном grchat',
      );
    });

    test('a silent device only gets a hedged guess, never an assertion', () {
      final text = cameraBlockNotice(CameraBlock.deviceDead);
      expect(text, contains('Возможно'));
      expect(text, isNot(contains('занята другим окном grchat')));
    });

    test('permission denial is a definite, different reason', () {
      expect(
        cameraBlockNotice(CameraBlock.permissions),
        'Нет доступа к камере. Проверьте разрешения системы.',
      );
    });

    test('unknown failure stays neutral', () {
      expect(cameraBlockNotice(CameraBlock.none), 'Не удалось включить камеру.');
    });

    test('an access-denied error classifies as permissions', () {
      expect(classifyCaptureError('Camera access denied by the system'), CameraBlock.permissions);
      expect(
        classifyCaptureError('Unable to RTCPeerConnection::addTrack: permission denied'),
        CameraBlock.permissions,
      );
    });

    test('other failures are NOT claimed as permissions', () {
      expect(classifyCaptureError('device busy'), isNot(CameraBlock.permissions));
      expect(classifyCaptureError(null), isNot(CameraBlock.permissions));
    });
  });
}