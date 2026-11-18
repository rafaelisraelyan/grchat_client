// Stage 2C / R5 - unit tests for the Perfect Negotiation policy.
//
// These are pure tests: no PeerConnection, no transport, no async. They pin the
// rules that the current production path does not implement at all (there is no
// rollback, no collision detection and no polite/impolite role anywhere in
// lib/src/call/call_state.dart), which is what makes them RED before the module
// exists.
import 'package:flutter_test/flutter_test.dart';

import 'package:grchat_client/src/call/perfect_negotiation.dart';

/// Builds an SDP fragment carrying a specific ICE ufrag, so generation-scoped
/// candidate filtering can be tested the way the real wire behaves.
String sdpWithUfrag(String ufrag, {bool offer = true}) =>
    'v=0\r\n'
    'a=ice-ufrag:$ufrag\r\n'
    'a=ice-pwd:secretpwd\r\n'
    '${offer ? 'a=setup:actpass\r\n' : ''}';

void main() {
  group('role assignment', () {
    test('exactly one of the two peers is polite', () {
      final a = PerfectNegotiation(localEndpointKey: 'u1', remoteEndpointKey: 'u2');
      final b = PerfectNegotiation(localEndpointKey: 'u2', remoteEndpointKey: 'u1');
      expect(a.polite, isNot(b.polite), reason: 'roles must be complementary');
      expect(a.polite || b.polite, isTrue);
    });

    test('the assignment is deterministic and stable across resets', () {
      final n1 = PerfectNegotiation(localEndpointKey: 'alice', remoteEndpointKey: 'bob');
      final n2 = PerfectNegotiation(localEndpointKey: 'alice', remoteEndpointKey: 'bob');
      expect(n1.polite, n2.polite);
      n1.reset();
      expect(n1.polite, n2.polite);
    });

    test('finer endpoint keys split roles for the same user on two devices',
        () {
      // Both devices belong to user "u1"; the peer's key comes from from_id
      // plus its own device identity, so the tie is broken by device.
      final phone = PerfectNegotiation(
          localEndpointKey: 'u1:phone', remoteEndpointKey: 'u2:desktop');
      final desktop = PerfectNegotiation(
          localEndpointKey: 'u2:desktop', remoteEndpointKey: 'u1:phone');
      expect(phone.polite, isNot(desktop.polite));
    });

    test('an endpoint cannot negotiate with itself', () {
      expect(() => PerfectNegotiation(
          localEndpointKey: 'u1', remoteEndpointKey: 'u1'),
          throwsA(isA<AssertionError>()));
    });
  });

  group('clean negotiation', () {
    test('an offer arriving in stable is accepted and bumps the generation', () {
      final n = PerfectNegotiation(localEndpointKey: 'a', remoteEndpointKey: 'b');
      final d = n.onRemoteDescription(
        type: PnDescriptionType.offer,
        signalingState: PnSignalingState.stable,
        sdp: sdpWithUfrag('remote1'),
      );
      expect(d.action, PnAction.acceptOffer);
      expect(n.generation, 1);
    });

    test('an answer to our own offer is accepted', () {
      final n = PerfectNegotiation(localEndpointKey: 'a', remoteEndpointKey: 'b');
      n.beginLocalOffer();
      n.endLocalOffer();
      expect(n.pendingLocalOffer, isNotNull);
      final d = n.onRemoteDescription(
        type: PnDescriptionType.answer,
        signalingState: PnSignalingState.haveLocalOffer,
        sdp: sdpWithUfrag('remote1', offer: false),
      );
      expect(d.action, PnAction.acceptAnswer);
      expect(n.pendingLocalOffer, isNull, reason: 'offer is now answered');
    });

    test('a second local offer is refused while one is unanswered', () {
      final n = PerfectNegotiation(localEndpointKey: 'a', remoteEndpointKey: 'b');
      n.beginLocalOffer();
      n.endLocalOffer();
      final again = n.beginLocalOffer();
      expect(again.action, PnAction.none);
      expect(again.reason, contains('awaiting an answer'));
      expect(n.generation, 1, reason: 'no new generation for a refused offer');
    });

    test('a local offer is refused while another is still being created', () {
      final n = PerfectNegotiation(localEndpointKey: 'a', remoteEndpointKey: 'b');
      n.beginLocalOffer();
      final again = n.beginLocalOffer();
      expect(again.action, PnAction.none);
      expect(again.reason, contains('already in flight'));
    });
  });

  group('offer collision (glare)', () {
    test('impolite peer ignores the colliding offer', () {
      final n = PerfectNegotiation(localEndpointKey: 'a', remoteEndpointKey: 'b');
      expect(n.polite, isFalse);
      n.beginLocalOffer();
      n.endLocalOffer();
      final d = n.onRemoteDescription(
        type: PnDescriptionType.offer,
        signalingState: PnSignalingState.haveLocalOffer,
        sdp: sdpWithUfrag('peerOffer'),
      );
      expect(d.action, PnAction.ignoreCollidingOffer);
      expect(n.pendingLocalOffer, isNotNull,
          reason: 'our own offer must survive: we won the collision');
    });

    test('polite peer rolls back its offer and accepts the peer\'s', () {
      final n = PerfectNegotiation(localEndpointKey: 'b', remoteEndpointKey: 'a');
      expect(n.polite, isTrue);
      n.beginLocalOffer();
      n.endLocalOffer();
      final d = n.onRemoteDescription(
        type: PnDescriptionType.offer,
        signalingState: PnSignalingState.haveLocalOffer,
        sdp: sdpWithUfrag('peerOffer'),
      );
      expect(d.action, PnAction.rollbackThenAcceptOffer);
      expect(n.pendingLocalOffer, isNull,
          reason: 'the abandoned offer must not stay pending');
    });

    test('collision while createOffer is still running also counts', () {
      // The peer\'s offer lands before our setLocalDescription finished:
      // makingOffer alone must be enough to detect the collision.
      final n = PerfectNegotiation(localEndpointKey: 'a', remoteEndpointKey: 'b');
      n.beginLocalOffer();
      // makingOffer is still true here - no endLocalOffer() yet.
      final d = n.onRemoteDescription(
        type: PnDescriptionType.offer,
        signalingState: PnSignalingState.stable,
        sdp: sdpWithUfrag('peerOffer'),
      );
      expect(d.action, PnAction.ignoreCollidingOffer);
    });

    test('polite peer accepts directly when it has nothing to roll back', () {
      // Collision flagged by signalingState, but no local offer of ours:
      // rollback would be wrong (and the native stack rejects it in stable).
      final n = PerfectNegotiation(localEndpointKey: 'b', remoteEndpointKey: 'a');
      final d = n.onRemoteDescription(
        type: PnDescriptionType.offer,
        signalingState: PnSignalingState.haveRemoteOffer,
        sdp: sdpWithUfrag('peerOffer'),
      );
      expect(d.action, PnAction.acceptOffer);
      expect(d.reason, contains('no local offer to roll back'));
    });

    test('a polite peer never rolls back in stable without a collision', () {
      final n = PerfectNegotiation(localEndpointKey: 'b', remoteEndpointKey: 'a');
      final d = n.onRemoteDescription(
        type: PnDescriptionType.offer,
        signalingState: PnSignalingState.stable,
        sdp: sdpWithUfrag('peerOffer'),
      );
      expect(d.action, PnAction.acceptOffer);
      expect(d.action, isNot(PnAction.rollbackThenAcceptOffer));
    });

    test('a closed signaling channel accepts no renegotiation', () {
      final n = PerfectNegotiation(localEndpointKey: 'a', remoteEndpointKey: 'b');
      final d = n.onRemoteDescription(
        type: PnDescriptionType.offer,
        signalingState: PnSignalingState.closed,
        sdp: sdpWithUfrag('x'),
      );
      expect(d.action, PnAction.none);
      expect(d.reason, contains('closed'));
    });
  });

  group('generation-scoped candidates', () {
    test('candidates of the rejected generation are dropped', () {
      final n = PerfectNegotiation(localEndpointKey: 'a', remoteEndpointKey: 'b');
      n.beginLocalOffer();
      n.endLocalOffer();
      n.onRemoteDescription(
        type: PnDescriptionType.offer,
        signalingState: PnSignalingState.haveLocalOffer,
        sdp: sdpWithUfrag('rejectedUfrag'),
      );
      expect(n.rejectedUfrags, contains('rejectedUfrag'));
      final d = n.onRemoteCandidate(ufrag: 'rejectedUfrag');
      expect(d.action, PnAction.ignoreStaleCandidate);
    });

    test('a glare does NOT cause candidates of other generations to be dropped',
        () {
      // The explicit anti-pattern from the brief: never blacklist candidates
      // just because a glare happened once.
      final n = PerfectNegotiation(localEndpointKey: 'a', remoteEndpointKey: 'b');
      n.beginLocalOffer();
      n.endLocalOffer();
      n.onRemoteDescription(
        type: PnDescriptionType.offer,
        signalingState: PnSignalingState.haveLocalOffer,
        sdp: sdpWithUfrag('rejectedUfrag'),
      );
      final fresh = n.onRemoteCandidate(ufrag: 'brandNewUfrag');
      expect(fresh.action, PnAction.none);
    });

    test('candidates without a ufrag are accepted, not blanket-rejected', () {
      // A peer may legitimately send candidates before its description.
      final n = PerfectNegotiation(localEndpointKey: 'a', remoteEndpointKey: 'b');
      final d = n.onRemoteCandidate(ufrag: null);
      expect(d.action, PnAction.none);
    });

    test('candidates of an accepted generation survive the glare', () {
      final polite = PerfectNegotiation(localEndpointKey: 'b', remoteEndpointKey: 'a');
      polite.beginLocalOffer();
      polite.endLocalOffer();
      polite.onRemoteDescription(
        type: PnDescriptionType.offer,
        signalingState: PnSignalingState.haveLocalOffer,
        sdp: sdpWithUfrag('winnerUfrag'),
      );
      expect(polite.onRemoteCandidate(ufrag: 'winnerUfrag').action, PnAction.none);
    });
  });

  group('stale answers', () {
    test('an answer with no outstanding offer is ignored', () {
      final n = PerfectNegotiation(localEndpointKey: 'a', remoteEndpointKey: 'b');
      final d = n.onRemoteDescription(
        type: PnDescriptionType.answer,
        signalingState: PnSignalingState.haveLocalOffer,
        sdp: sdpWithUfrag('remote1', offer: false),
      );
      expect(d.action, PnAction.ignoreStaleAnswer);
    });

    test('the answer to an offer abandoned by a collision is ignored', () {
      // Polite peer rolled back; the answer to its old offer arrives late and
      // must not be applied to the negotiation that replaced it.
      final n = PerfectNegotiation(localEndpointKey: 'b', remoteEndpointKey: 'a');
      n.beginLocalOffer();
      n.endLocalOffer();
      n.onRemoteDescription(
        type: PnDescriptionType.offer,
        signalingState: PnSignalingState.haveLocalOffer,
        sdp: sdpWithUfrag('winnerUfrag'),
      );
      final late = n.onRemoteDescription(
        type: PnDescriptionType.answer,
        signalingState: PnSignalingState.haveRemoteOffer,
        sdp: sdpWithUfrag('winnerUfrag', offer: false),
      );
      expect(late.action, PnAction.ignoreStaleAnswer);
      expect(late.reason, contains('no outstanding local offer'));
    });

    test('an answer whose ufrag differs is STILL accepted', () {
      // The peer may restart its own ICE at any time, including in reply to
      // ours. Its answer therefore carries a new ufrag, and rejecting the answer
      // on that basis would silently break every ICE restart.
      final n = PerfectNegotiation(localEndpointKey: 'a', remoteEndpointKey: 'b');
      n.onRemoteDescription(
        type: PnDescriptionType.offer,
        signalingState: PnSignalingState.stable,
        sdp: sdpWithUfrag('acceptedUfrag'),
      );
      n.beginLocalOffer();
      n.endLocalOffer();
      final d = n.onRemoteDescription(
        type: PnDescriptionType.answer,
        signalingState: PnSignalingState.haveLocalOffer,
        sdp: sdpWithUfrag('peerRestartedUfrag', offer: false),
      );
      expect(d.action, PnAction.acceptAnswer);
      expect(d.reason, contains('regardless of ufrag'));
    });

    test('pranswer and rollback are not part of the GRChat protocol', () {
      final n = PerfectNegotiation(localEndpointKey: 'a', remoteEndpointKey: 'b');
      for (final t in [PnDescriptionType.pranswer, PnDescriptionType.rollback]) {
        final d = n.onRemoteDescription(
          type: t,
          signalingState: PnSignalingState.stable,
        );
        expect(d.action, PnAction.ignoreStaleAnswer, reason: t.name);
      }
    });
  });

  group('lifecycle', () {
    test('reset clears pending state so a new call is not poisoned', () {
      final n = PerfectNegotiation(localEndpointKey: 'a', remoteEndpointKey: 'b');
      n.beginLocalOffer();
      n.endLocalOffer();
      n.onRemoteDescription(
        type: PnDescriptionType.offer,
        signalingState: PnSignalingState.haveLocalOffer,
        sdp: sdpWithUfrag('rejected'),
      );
      n.reset();
      expect(n.pendingLocalOffer, isNull);
      expect(n.generation, 0);
      expect(n.rejectedUfrags, isEmpty);
      // A fresh answer in the new call must be acceptable.
      n.beginLocalOffer();
      n.endLocalOffer();
      final d = n.onRemoteDescription(
        type: PnDescriptionType.answer,
        signalingState: PnSignalingState.haveLocalOffer,
        sdp: sdpWithUfrag('fresh', offer: false),
      );
      expect(d.action, PnAction.acceptAnswer);
    });

    test('generations increase monotonically across a long negotiation', () {
      final n = PerfectNegotiation(localEndpointKey: 'a', remoteEndpointKey: 'b');
      final seen = <int>[];
      for (var i = 0; i < 5; i++) {
        n.onRemoteDescription(
          type: PnDescriptionType.offer,
          signalingState: PnSignalingState.stable,
          sdp: sdpWithUfrag('u$i'),
        );
        seen.add(n.generation);
      }
      for (var i = 1; i < seen.length; i++) {
        expect(seen[i], greaterThan(seen[i - 1]));
      }
    });
  });

  group('ufrag parsing', () {
    test('reads the first ice-ufrag', () {
      expect(iceUfragOf(sdpWithUfrag('abc')), 'abc');
    });

    test('returns null when there is no ufrag', () {
      expect(iceUfragOf('v=0\r\n'), isNull);
      expect(iceUfragOf(null), isNull);
    });
  });
}