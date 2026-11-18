// STAGE 2C / R4.7 - CONTROL 5: mixed relay/host.
//
// Diagnostic only. Peer A is relay-only (must use TURN); peer B offers host
// candidates as well. Question: can A reach B through the TURN relay when B
// has a direct host candidate available?
//
// This is NOT an R4 acceptance run: the R4 gate requires two relay
// allocations, and this test deliberately has only one.
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

Map<String, dynamic> cfgWith(String policy) => <String, dynamic>{
      'iceServers': [
        {
          'urls': 'turn:$turnHost:$turnPort?transport=udp',
          'username': turnUser,
          'credential': turnPass,
        }
      ],
      'iceTransportPolicy': policy,
    };

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  test('R4.7 C5: A relay-only vs B all', () async {
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
    print('C5 CFG A=relay B=all url=turn:$turnHost:$turnPort?transport=udp');

    final pa = await createPeerConnection(cfgWith('relay'));
    final pb = await createPeerConnection(cfgWith('all'));

    final toB = <RTCIceCandidate>[];
    final toA = <RTCIceCandidate>[];
    bool remoteOnB = false;
    bool remoteOnA = false;
    pa.onIceCandidate = (c) {
      remoteOnB ? pb.addCandidate(c) : toB.add(c);
    };
    pb.onIceCandidate = (c) {
      remoteOnA ? pa.addCandidate(c) : toA.add(c);
    };

    for (final t in video!.getTracks()) {
      await pa.addTrack(t, video);
    }
    for (final t in audioA!.getTracks()) {
      await pa.addTrack(t, audioA);
    }
    for (final t in audioB!.getTracks()) {
      await pb.addTrack(t, audioB);
    }

    final offer = await pa.createOffer(
        <String, dynamic>{'offerToReceiveAudio': 1, 'offerToReceiveVideo': 1});
    await pa.setLocalDescription(offer);
    await pb.setRemoteDescription(RTCSessionDescription(offer.sdp!, 'offer'));
    remoteOnB = true;
    for (final c in List<RTCIceCandidate>.from(toB)) {
      await pb.addCandidate(c);
    }
    toB.clear();
    final answer = await pb.createAnswer();
    await pb.setLocalDescription(answer);
    await pa.setRemoteDescription(RTCSessionDescription(answer.sdp!, 'answer'));
    remoteOnA = true;
    for (final c in List<RTCIceCandidate>.from(toA)) {
      await pa.addCandidate(c);
    }
    toA.clear();

    var up = false;
    final deadline = DateTime.now().add(const Duration(seconds: 45));
    while (DateTime.now().isBefore(deadline)) {
      final sa = '${await pa.getIceConnectionState()}'.toLowerCase();
      final sb = '${await pb.getIceConnectionState()}'.toLowerCase();
      if ((sa.contains('connected') || sa.contains('completed')) &&
          (sb.contains('connected') || sb.contains('completed'))) {
        up = true;
        break;
      }
      await Future.delayed(const Duration(milliseconds: 300));
    }
    // ignore: avoid_print
    print('C5 UP=$up A=${await pa.getIceConnectionState()} '
        'B=${await pb.getIceConnectionState()}');

    // A is relay-only, so a localType=relay pair proves the traffic went
    // through TURN; B may legitimately show a host remote candidate.
    String pairA = 'NONE';
    String pairB = 'NONE';
    if (up) {
      for (final e in {0: pa, 1: pb}.entries) {
        final all = await e.value.getStats();
        final cands = <String, Map<dynamic, dynamic>>{
          for (final r in all.where((r) => r.type.contains('candidate')))
            r.id: r.values,
        };
        for (final r in all.where((r) =>
            r.type == 'candidate-pair' && r.values['nominated'] == true)) {
          final l = cands[r.values['localCandidateId']] ?? <dynamic, dynamic>{};
          final rm =
              cands[r.values['remoteCandidateId']] ?? <dynamic, dynamic>{};
          final line = '${l['candidateType']}/${rm['candidateType']} '
              'state=${r.values['state']} sent=${r.values['bytesSent']} '
              'recv=${r.values['bytesReceived']}';
          if (e.key == 0) {
            pairA = line;
          } else {
            pairB = line;
          }
        }
      }
    }
    // ignore: avoid_print
    print('C5 PAIR A=$pairA');
    // ignore: avoid_print
    print('C5 PAIR B=$pairB');

    var frames = 0;
    var videoBytes = 0;
    if (up) {
      final warm = DateTime.now().add(const Duration(seconds: 20));
      while (DateTime.now().isBefore(warm)) {
        for (final r in (await pb.getStats())
            .where((r) => r.type == 'inbound-rtp')) {
          if (r.values['kind'] == 'video') {
            videoBytes = ((r.values['bytesReceived'] as num?) ?? 0).toInt();
            frames = ((r.values['framesDecoded'] as num?) ?? 0).toInt();
          }
        }
        if (frames > 0) break;
        await Future.delayed(const Duration(milliseconds: 500));
      }
    }
    // ignore: avoid_print
    print('C5 RTP videoBytes=$videoBytes framesDecoded=$frames');

    await pa.close();
    await pb.close();
    await video.dispose();
    await audioA.dispose();
    await audioB.dispose();

    expect(up, isTrue, reason: 'A relay-only must connect to B all');
    expect(pairA, startsWith('relay/'),
        reason: 'A is relay-only: the pair MUST be localType=relay');
    expect(frames, greaterThan(0), reason: 'real video through the mixed path');
  }, timeout: const Timeout(Duration(minutes: 15)));
}