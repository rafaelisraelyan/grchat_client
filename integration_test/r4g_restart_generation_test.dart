// STAGE 2C.4g - regression for the ICE restart sequence.
//
// The production defect was: createOffer(iceRestart: true) was called and its
// result DISCARDED, then getLocalDescription() was read. Because nothing
// applied the new offer, getLocalDescription() still returned the PREVIOUS
// generation, so the peer received stale ICE credentials.
//
// This test pins the invariant that makes the fix correct:
//   the offer returned by createOffer(iceRestart: true) carries a NEW ufrag,
//   and after setLocalDescription the APPLIED description carries that same
//   NEW ufrag - not the old one.
//
// Host candidates are enough: no TURN is involved, and this test makes no claim
// about media, only about ICE generation.

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:integration_test/integration_test.dart';

String? ufragOf(String? sdp) =>
    sdp == null ? null : RegExp(r'a=ice-ufrag:(\S+)').firstMatch(sdp)?.group(1);

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  test('R4.9g: apply the restart offer so the peer gets a NEW ICE generation',
      () async {
    final a = await createPeerConnection(<String, dynamic>{});
    final b = await createPeerConnection(<String, dynamic>{});
    addTearDown(() async {
      await a.close();
      await b.close();
    });

    // A minimal negotiate so the transport exists.
    final dc = await a.createDataChannel('probe', RTCDataChannelInit());
    final toB = <RTCIceCandidate>[];
    final toA = <RTCIceCandidate>[];
    var remoteOnB = false;
    var remoteOnA = false;
    a.onIceCandidate = (c) => remoteOnB ? b.addCandidate(c) : toB.add(c);
    b.onIceCandidate = (c) => remoteOnA ? a.addCandidate(c) : toA.add(c);

    final offer = await a.createOffer({});
    await a.setLocalDescription(offer);
    await b.setRemoteDescription(RTCSessionDescription(offer.sdp!, 'offer'));
    remoteOnB = true;
    for (final c in List<RTCIceCandidate>.from(toB)) {
      await b.addCandidate(c);
    }
    toB.clear();
    final answer = await b.createAnswer();
    await b.setLocalDescription(answer);
    await a.setRemoteDescription(RTCSessionDescription(answer.sdp!, 'answer'));
    remoteOnA = true;
    for (final c in List<RTCIceCandidate>.from(toA)) {
      await a.addCandidate(c);
    }
    toA.clear();
    dc.close();

    final oldUfrag = ufragOf((await a.getLocalDescription())?.sdp);
    // ignore: avoid_print
    print('G oldUfrag=$oldUfrag');
    expect(oldUfrag, isNotNull, reason: 'a local description must exist');

    // ---- the production sequence, in the fixed order ----
    await a.restartIce();
    final restartOffer = await a.createOffer(<String, dynamic>{'iceRestart': true});
    final offerUfrag = ufragOf(restartOffer.sdp);
    // ignore: avoid_print
    print('G offerUfrag=$offerUfrag');

    // BEFORE applying, the local description must still be the OLD one. This is
    // exactly what the broken code sent to the peer.
    final beforeApply = ufragOf((await a.getLocalDescription())?.sdp);
    // ignore: avoid_print
    print('G beforeApply(ufrag)=$beforeApply');
    expect(beforeApply, oldUfrag,
        reason: 'this is the state the old code shipped to the peer');

    await a.setLocalDescription(restartOffer);
    final appliedUfrag = ufragOf((await a.getLocalDescription())?.sdp);
    // ignore: avoid_print
    print('G appliedUfrag=$appliedUfrag');

    expect(offerUfrag, isNot(oldUfrag),
        reason: 'createOffer(iceRestart) must mint a new generation');
    expect(appliedUfrag, offerUfrag,
        reason: 'the APPLIED description must be the restart offer, and the '
            'peer must receive this one - not the pre-restart SDP');

    // The peer must accept the new generation and answer it.
    await b.setRemoteDescription(
        RTCSessionDescription(restartOffer.sdp!, 'offer'));
    final restartAnswer = await b.createAnswer();
    await b.setLocalDescription(restartAnswer);
    await a.setRemoteDescription(
        RTCSessionDescription(restartAnswer.sdp!, 'answer'));

    final answerUfrag = ufragOf((await b.getLocalDescription())?.sdp);
    // ignore: avoid_print
    print('G peerAnswerUfrag=$answerUfrag');
    expect(answerUfrag, isNotNull);
    expect(
        '${await a.getSignalingState()}', contains('Stable'),
        reason: 'the restart round must leave signaling stable');

    // A second restart must still mint a fresh generation: the sequence is
    // repeatable and never reuses credentials.
    await a.restartIce();
    final second = await a.createOffer(<String, dynamic>{'iceRestart': true});
    await a.setLocalDescription(second);
    final secondUfrag = ufragOf((await a.getLocalDescription())?.sdp);
    // ignore: avoid_print
    print('G secondUfrag=$secondUfrag');
    expect(secondUfrag, isNot(appliedUfrag),
        reason: 'each restart must use a new generation');
  }, timeout: const Timeout(Duration(minutes: 5)));
}