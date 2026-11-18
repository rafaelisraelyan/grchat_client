// STAGE 2C / R4.7 - CONTROL 2: non-trickle SDP exchange.
//
// R4.7 Control 1 succeeded with trickle, after fixing a defect in the older
// harness. This control removes addCandidate entirely, so any candidate-queue
// error is excluded by construction. If non-trickle also succeeds, the old
// failure was purely a harness candidate-exchange bug.
//
// No drop. No TURN traffic control.

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:integration_test/integration_test.dart';

import 'rtp_harness.dart';

const String turnHost = '192.168.31.21';
const int turnPort = 34780;
const String turnUser = 'grchat';
const String turnPass = 'refpass123';

Map<String, dynamic> relayCfg() => <String, dynamic>{
      'iceServers': [
        {
          'urls': 'turn:$turnHost:$turnPort?transport=udp',
          'username': turnUser,
          'credential': turnPass,
        }
      ],
      'iceTransportPolicy': 'relay',
    };

int relayCount(String? sdp) {
  if (sdp == null) return 0;
  return RegExp(r'a=candidate:.* typ relay').allMatches(sdp).length;
}

String? ufragOf(String? sdp) =>
    sdp == null ? null : RegExp(r'a=ice-ufrag:(\S+)').firstMatch(sdp)?.group(1);

/// Waits for gathering to finish. Returns false on timeout so the caller can
/// record the failure instead of pretending it completed.
Future<bool> waitGathering(RTCPeerConnection pc, String tag) async {
  final deadline = DateTime.now().add(const Duration(seconds: 45));
  while (DateTime.now().isBefore(deadline)) {
    final s = '${await pc.getIceGatheringState()}'.toLowerCase();
    if (s.contains('complete')) {
      // ignore: avoid_print
      print('C2 GATHER $tag complete');
      return true;
    }
    await Future.delayed(const Duration(milliseconds: 200));
  }
  // ignore: avoid_print
  print('C2 GATHER $tag TIMEOUT');
  return false;
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  test('R4.7 C2: non-trickle SDP exchange over TURN relay', () async {
    final mics = await enumerateCapture('audioinput');
    expect(mics.length, greaterThanOrEqualTo(2));
    final audioA = await openCapture(
        audio: true, video: false, audioDeviceId: mics[0].deviceId);
    final audioB = await openCapture(
        audio: true, video: false, audioDeviceId: mics[1].deviceId);
    final cams = (await enumerateCapture('videoinput'))
      ..sort((a, b) => (a.deviceId.contains('usb#') ? 0 : 1)
          .compareTo(b.deviceId.contains('usb#') ? 0 : 1));
    final video = await openCapture(
        audio: false, video: true, videoDeviceId: cams.first.deviceId);
    // ignore: avoid_print
    print('C2 CFG urls=turn:$turnHost:$turnPort?transport=udp policy=relay trickle=OFF');

    final cfg = relayCfg();
    final pa = await createPeerConnection(cfg);
    final pb = await createPeerConnection(cfg);

    // addCandidate is deliberately NEVER called in this control.
    for (final t in video!.getTracks()) {
      await pa.addTrack(t, video);
    }
    for (final t in audioA!.getTracks()) {
      await pa.addTrack(t, audioA);
    }
    for (final t in audioB!.getTracks()) {
      await pb.addTrack(t, audioB);
    }

    // 1-4: offer, set, wait for COMPLETE gathering, then take the FINAL SDP.
    final offer = await pa.createOffer(
        <String, dynamic>{'offerToReceiveAudio': 1, 'offerToReceiveVideo': 1});
    await pa.setLocalDescription(offer);
    final aComplete = await waitGathering(pa, 'A');
    final offerFinal = await pa.getLocalDescription();
    // ignore: avoid_print
    print('C2 OFFER_FINAL relay=${relayCount(offerFinal?.sdp)} '
        'ufrag=${ufragOf(offerFinal?.sdp)} complete=$aComplete');

    // 5: B installs that final SDP.
    await pb.setRemoteDescription(
        RTCSessionDescription(offerFinal!.sdp!, 'offer'));

    // 6: B answers, sets, waits for ITS OWN complete gathering.
    final answer = await pb.createAnswer();
    await pb.setLocalDescription(answer);
    final bComplete = await waitGathering(pb, 'B');
    final answerFinal = await pb.getLocalDescription();
    // ignore: avoid_print
    print('C2 ANSWER_FINAL relay=${relayCount(answerFinal?.sdp)} '
        'ufrag=${ufragOf(answerFinal?.sdp)} complete=$bComplete');

    // 7: A installs the final answer.
    await pa.setRemoteDescription(
        RTCSessionDescription(answerFinal!.sdp!, 'answer'));

    final ra = await pa.getRemoteDescription();
    final rb = await pb.getRemoteDescription();
    // ignore: avoid_print
    print('C2 REMOTE A relay=${relayCount(ra?.sdp)} ufrag=${ufragOf(ra?.sdp)}');
    // ignore: avoid_print
    print('C2 REMOTE B relay=${relayCount(rb?.sdp)} ufrag=${ufragOf(rb?.sdp)}');

    var up = false;
    final deadline = DateTime.now().add(const Duration(seconds: 45));
    var lastA = '';
    var lastB = '';
    while (DateTime.now().isBefore(deadline)) {
      final sa = '${await pa.getIceConnectionState()}'.toLowerCase();
      final sb = '${await pb.getIceConnectionState()}'.toLowerCase();
      if (sa != lastA) {
        lastA = sa;
        // ignore: avoid_print
        print('C2 STATE A=${sa.split('.').last}');
      }
      if (sb != lastB) {
        lastB = sb;
        // ignore: avoid_print
        print('C2 STATE B=${sb.split('.').last}');
      }
      if ((sa.contains('connected') || sa.contains('completed')) &&
          (sb.contains('connected') || sb.contains('completed'))) {
        up = true;
        break;
      }
      await Future.delayed(const Duration(milliseconds: 300));
    }
    // ignore: avoid_print
    print('C2 UP=$up');

    String relayPair = 'NONE';
    if (up) {
      for (final pc in [pa, pb]) {
        final all = await pc.getStats();
        final cands = <String, Map<dynamic, dynamic>>{
          for (final r in all.where((r) => r.type.contains('candidate')))
            r.id: r.values,
        };
        for (final r in all.where((r) =>
            r.type == 'candidate-pair' && r.values['nominated'] == true)) {
          final l = cands[r.values['localCandidateId']] ?? <dynamic, dynamic>{};
          final rm = cands[r.values['remoteCandidateId']] ?? <dynamic, dynamic>{};
          if (l['candidateType'] == 'relay' && rm['candidateType'] == 'relay') {
            relayPair = 'relay/relay';
          }
        }
      }
    }

    var audioBytes = 0;
    var videoBytes = 0;
    var frames = 0;
    if (up) {
      final warm = DateTime.now().add(const Duration(seconds: 20));
      while (DateTime.now().isBefore(warm)) {
        for (final r in (await pb.getStats())
            .where((r) => r.type == 'inbound-rtp')) {
          if (r.values['kind'] == 'audio') {
            audioBytes = ((r.values['bytesReceived'] as num?) ?? 0).toInt();
          } else if (r.values['kind'] == 'video') {
            videoBytes = ((r.values['bytesReceived'] as num?) ?? 0).toInt();
            frames = ((r.values['framesDecoded'] as num?) ?? 0).toInt();
          }
        }
        if (audioBytes > 0 && videoBytes > 0 && frames > 0) break;
        await Future.delayed(const Duration(milliseconds: 500));
      }
    }
    // ignore: avoid_print
    print('C2 PAIR=$relayPair RTP audioBytes=$audioBytes '
        'videoBytes=$videoBytes framesDecoded=$frames');

    await pa.close();
    await pb.close();
    await video.dispose();
    await audioA.dispose();
    await audioB.dispose();

    expect(aComplete, isTrue, reason: 'A gathering must complete before the SDP is taken');
    expect(bComplete, isTrue, reason: 'B gathering must complete before the SDP is taken');
    expect(relayCount(offerFinal.sdp), greaterThan(0),
        reason: 'final offer SDP must carry relay candidates');
    expect(relayCount(answerFinal.sdp), greaterThan(0),
        reason: 'final answer SDP must carry relay candidates');
    expect(relayCount(rb?.sdp), greaterThan(0),
        reason: 'B must receive relay candidates through the SDP alone');
    expect(relayCount(ra?.sdp), greaterThan(0),
        reason: 'A must receive relay candidates through the SDP alone');
    expect(up, isTrue, reason: 'ICE must come up WITHOUT any addCandidate call');
    expect(relayPair, 'relay/relay');
    expect(frames, greaterThan(0));
  }, timeout: const Timeout(Duration(minutes: 15)));
}