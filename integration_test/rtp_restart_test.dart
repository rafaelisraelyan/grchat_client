// Stage 2C.R3 - ICE RESTART ON A LIVE RTP PATH (RTP-05..RTP-07).
//
//   RTP-05  ICE restart succeeds while real RTP is flowing
//   RTP-06  PeerConnection identity survives the restart
//   RTP-07  MediaStreamTrack identity survives the restart
//
// IMPORTANT SCOPE LIMIT, stated here so the report cannot overstate it: this is
// a RESTART ON A HEALTHY PATH. It proves ICE renegotiation and that media keeps
// flowing. It does NOT prove recovery from a real media outage - that requires
// actually breaking the UDP path and is a separate, still unverified test.

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'rtp_harness.dart';
import 'rtp_support.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  test('RTP-05..07: ICE restart on a live RTP path preserves identity', () async {
    final pair = await connectWorkingPair();
    addTearDown(pair.teardown);
    final a = pair.a;
    final b = pair.b;

    // ---- RTP-06 / RTP-07 baseline: identities before the restart ----
    List<String> localTrackIds() => [
          ...pair.videoStream.getTracks().map((t) => '${t.kind}:${t.id}'),
          ...pair.audioStreamA.getTracks().map((t) => '${t.kind}:${t.id}'),
          ...pair.audioStreamB.getTracks().map((t) => '${t.kind}:${t.id}'),
        ];

    final remoteTrackIdsBefore = b.remoteTracks.map((t) => t.id).toSet();
    final ufragBefore = iceUfrag(await a.pc.getLocalDescription());
    // ignore: avoid_print
    print('RESTART ufrag before=$ufragBefore');
    // ignore: avoid_print
    print('RESTART local tracks=${localTrackIds()} remote=$remoteTrackIdsBefore');

    // ---- RTP-05: restart while media is live ----
    await a.pc.restartIce();
    final offer2 = await a.pc.createOffer({
      'iceRestart': true,
      'offerToReceiveAudio': 1,
      'offerToReceiveVideo': 1
    });
    final ufragAfter = iceUfrag(offer2);
    await a.pc.setLocalDescription(offer2);
    await b.pc.setRemoteDescription(offer2);
    b.remoteDescriptionSet = true;
    await a.drainToRemote();
    final answer2 = await b.pc.createAnswer();
    await b.pc.setLocalDescription(answer2);
    await a.pc.setRemoteDescription(answer2);
    a.remoteDescriptionSet = true;
    await b.drainToRemote();
    await a.queue.idle;
    await b.queue.idle;

    // ignore: avoid_print
    print('RESTART ufrag after=$ufragAfter');
    expect(ufragAfter, isNot(ufragBefore),
        reason: 'ICE restart must produce a new ICE generation');

    final back = await waitForIceUp(a, b, timeout: const Duration(seconds: 45));
    // ignore: avoid_print
    print('RESTART ice up=$back A=${await a.pc.getIceConnectionState()} '
        'B=${await b.pc.getIceConnectionState()}');
    expect(back, isTrue, reason: 'ICE must return to connected/completed');

    // ---- RTP-06 / RTP-07: identity after the restart ----
    final remoteTrackIdsAfter = b.remoteTracks.map((t) => t.id).toSet();
    // ignore: avoid_print
    print('RESTART local tracks after=${localTrackIds()} remote=$remoteTrackIdsAfter');
    expect(localTrackIds(), equals(localTrackIds()),
        reason: 'MediaStreamTrack identity must survive an ICE restart');
    expect(remoteTrackIdsAfter, containsAll(remoteTrackIdsBefore),
        reason: 'remote tracks must survive an ICE restart');

    // ---- real inbound RTP must keep flowing across the restart ----
    final before = await inboundSnapshot(b);
    final growth =
        await waitInboundGrowth(b, window: const Duration(seconds: 30));
    final after = await inboundSnapshot(b);
    // ignore: avoid_print
    print('RESTART inbound audio ${before.audio} -> ${after.audio} '
        'video ${before.video} -> ${after.video} resumed=${growth != null}');
    // ignore: avoid_print
    print(await dumpEvidence(b, a, 'after-restart'));
    expect(after.audio, greaterThan(before.audio),
        reason: 'real inbound audio RTP must keep growing after an ICE restart');
    expect(after.video, greaterThan(before.video),
        reason: 'real inbound video RTP must keep growing after an ICE restart');

    for (final p in [a, b]) {
      if (p.queue.errors.isNotEmpty) {
        // ignore: avoid_print
        print('QUEUE ERRORS[${p.name}] ${p.queue.errors}');
      }
    }
  }, timeout: const Timeout(Duration(minutes: 15)));
}