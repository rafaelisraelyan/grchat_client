// STAGE 2C / R4.7 - CONTROL 1 + CONTROL 4.
//
// Narrow diagnostic: does libwebrtc actually EXCHANGE relay candidates, and
// what do the candidate pairs look like? R4.6 proved local gathering succeeds
// on the Wi-Fi IPv4 TURN (192.168.31.21) but ICE stayed in `checking`.
//
// This file proves or disproves candidate EXCHANGE. Local gathering success is
// explicitly NOT accepted as evidence of remote exchange.
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

/// ICE ufrag of the CURRENT generation. The pwd attribute is a secret and is
/// deliberately never read or printed.
String? ufragOf(String? sdp) {
  if (sdp == null) return null;
  final m = RegExp(r'a=ice-ufrag:(\S+)').firstMatch(sdp);
  return m?.group(1);
}

int relayCount(String? sdp) {
  if (sdp == null) return 0;
  return RegExp(r'a=candidate:.* typ relay').allMatches(sdp).length;
}

int hostCount(String? sdp) {
  if (sdp == null) return 0;
  return RegExp(r'a=candidate:.* typ host').allMatches(sdp).length;
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  test('R4.7 C1+C4: relay candidate exchange and candidate-pair stats', () async {
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
    print('C1 SOURCES micA=${mics[0].label} micB=${mics[1].label} cam=${cams.first.label}');
    // ignore: avoid_print
    print('C1 CFG urls=turn:$turnHost:$turnPort?transport=udp policy=relay');

    final cfg = relayCfg();
    final pa = await createPeerConnection(cfg);
    final pb = await createPeerConnection(cfg);

    final toB = <RTCIceCandidate>[];
    final toA = <RTCIceCandidate>[];
    bool remoteOnB = false;
    bool remoteOnA = false;
    var addCandErrors = 0;

    Future<void> hand(RTCPeerConnection target, RTCIceCandidate c) async {
      try {
        await target.addCandidate(c);
      } catch (e) {
        addCandErrors++;
        // ignore: avoid_print
        print('C1 ADDERR ${e.runtimeType}');
      }
    }

    pa.onIceGatheringState = (s) {
      // ignore: avoid_print
      print('C1 GATHER A ${'$s'.split('.').last}');
    };
    pb.onIceGatheringState = (s) {
      // ignore: avoid_print
      print('C1 GATHER B ${'$s'.split('.').last}');
    };

    // Control 1: record what onIceCandidate ACTUALLY delivered, separately
    // from what the local SDP contains. These are different facts.
    var candEventsA = 0;
    var candEventsB = 0;
    var candRelayA = 0;
    var candRelayB = 0;
    var candNullA = 0;
    var candNullB = 0;
    void onCandA(RTCIceCandidate c) {
      if (c.candidate == null) {
        candNullA++;
      } else {
        candEventsA++;
        if (c.candidate!.contains(' typ relay')) candRelayA++;
      }
      if (remoteOnB) {
        hand(pb, c);
      } else {
        toB.add(c);
      }
    }

    void onCandB(RTCIceCandidate c) {
      if (c.candidate == null) {
        candNullB++;
      } else {
        candEventsB++;
        if (c.candidate!.contains(' typ relay')) candRelayB++;
      }
      if (remoteOnA) {
        hand(pa, c);
      } else {
        toA.add(c);
      }
    }

    pa.onIceCandidate = onCandA;
    pb.onIceCandidate = onCandB;

    // A owns the camera so the video m-line exists by construction.
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
      await hand(pb, c);
    }
    toB.clear();
    final answer = await pb.createAnswer();
    await pb.setLocalDescription(answer);
    await pa.setRemoteDescription(RTCSessionDescription(answer.sdp!, 'answer'));
    remoteOnA = true;
    for (final c in List<RTCIceCandidate>.from(toA)) {
      await hand(pa, c);
    }
    toA.clear();

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
        print('C1 STATE A=${sa.split('.').last}');
      }
      if (sb != lastB) {
        lastB = sb;
        // ignore: avoid_print
        print('C1 STATE B=${sb.split('.').last}');
      }
      if ((sa.contains('connected') || sa.contains('completed')) &&
          (sb.contains('connected') || sb.contains('completed'))) {
        up = true;
        break;
      }
      await Future.delayed(const Duration(milliseconds: 300));
    }

    // ---- CONTROL 1: local vs remote candidate facts ----
    final la = await pa.getLocalDescription();
    final lb = await pb.getLocalDescription();
    final ra = await pa.getRemoteDescription();
    final rb = await pb.getRemoteDescription();
    // ignore: avoid_print
    print('C1 LOCAL A ufrag=${ufragOf(la?.sdp)} relay=${relayCount(la?.sdp)} host=${hostCount(la?.sdp)}');
    // ignore: avoid_print
    print('C1 LOCAL B ufrag=${ufragOf(lb?.sdp)} relay=${relayCount(lb?.sdp)} host=${hostCount(lb?.sdp)}');
    // ignore: avoid_print
    print('C1 REMOTE A ufrag=${ufragOf(ra?.sdp)} relay=${relayCount(ra?.sdp)} host=${hostCount(ra?.sdp)}');
    // ignore: avoid_print
    print('C1 REMOTE B ufrag=${ufragOf(rb?.sdp)} relay=${relayCount(rb?.sdp)} host=${hostCount(rb?.sdp)}');
    // ignore: avoid_print
    print('C1 ONCAND eventsA=$candEventsA relayA=$candRelayA nullA=$candNullA '
        'eventsB=$candEventsB relayB=$candRelayB nullB=$candNullB addErrors=$addCandErrors');
    // ignore: avoid_print
    print('C1 UP=$up A=${lastA.split('.').last} B=${lastB.split('.').last}');

    // ---- CONTROL 4: full candidate / candidate-pair stats ----
    Future<void> dumpStats(RTCPeerConnection pc, String tag) async {
      final all = await pc.getStats();
      final byId = <String, Map<dynamic, dynamic>>{};
      for (final r in all.where((r) => r.type.contains('candidate'))) {
        byId[r.id] = r.values;
      }
      // ignore: avoid_print
      print('S4 $tag candidateRecords=${byId.length}');
      for (final e in byId.entries) {
        final v = e.value;
        // ignore: avoid_print
        print('S4 $tag cand id=${e.key} type=${v['candidateType']} '
            'proto=${v['protocol']} addrType=${v['addressType']} '
            'relayProto=${v['relayProtocol']} state=${v['state']}');
      }
      var pairs = 0;
      for (final r in all.where((r) => r.type == 'candidate-pair')) {
        pairs++;
        final v = r.values;
        final lc = byId[v['localCandidateId']] ?? <dynamic, dynamic>{};
        final rc = byId[v['remoteCandidateId']] ?? <dynamic, dynamic>{};
        // Missing fields are printed as ABSENT, never as false/zero.
        String g(String k) {
          final val = v[k];
          return val ?? '<absent>';
        }

        // ignore: avoid_print
        print('S4 $tag pair id=${r.id} nominated=${v['nominated'] ?? '<absent>'} '
            'state=${g('state')} localType=${lc['candidateType']} remoteType=${rc['candidateType']} '
            'reqSent=${g('requestsSent')} respRecv=${g('responsesReceived')} '
            'pktSent=${g('packetsSent')} pktRecv=${g('packetsReceived')} '
            'bytesSent=${g('bytesSent')} bytesRecv=${g('bytesReceived')}');
      }
      if (pairs == 0) {
        // ignore: avoid_print
        print('S4 $tag pairRecords=0 -> classification A: no candidate pairs created');
      }
      // ignore: avoid_print
      print('S4 $tag localStatsSelectedPairId=${all.where((r) => r.type == 'peer-connection').map((r) => r.values['selectedCandidatePairId']).toList()}');
    }

    await dumpStats(pa, 'A');
    await dumpStats(pb, 'B');

    // Real media check is only meaningful once a pair exists.
    var audioBytes = 0;
    var videoBytes = 0;
    var frames = 0;
    if (up) {
      final warm = DateTime.now().add(const Duration(seconds: 20));
      while (DateTime.now().isBefore(warm)) {
        final all = await pb.getStats();
        for (final r in all.where((r) => r.type == 'inbound-rtp')) {
          if (r.values['kind'] == 'audio') {
            audioBytes = ((r.values['bytesReceived'] as num?) ?? 0).toInt();
          } else if (r.values['kind'] == 'video') {
            videoBytes = ((r.values['bytesReceived'] as num?) ?? 0).toInt();
            frames = ((r.values['framesDecoded'] as num?) ?? 0).toInt();
          }
        }
        if (audioBytes > 0 && videoBytes > 0) break;
        await Future.delayed(const Duration(milliseconds: 500));
      }
    }
    // ignore: avoid_print
    print('C1 RTP audioBytes=$audioBytes videoBytes=$videoBytes framesDecoded=$frames');

    await pa.close();
    await pb.close();
    await video.dispose();
    await audioA.dispose();
    await audioB.dispose();

    // The diagnostic assertion is deliberately narrow: it asserts the FACT of
    // exchange, and records up=false rather than masking it.
    expect(relayCount(ra?.sdp), greaterThan(0),
        reason: 'relay candidates from B must reach A remoteDescription');
    expect(relayCount(rb?.sdp), greaterThan(0),
        reason: 'relay candidates from A must reach B remoteDescription');
    expect(addCandErrors, 0, reason: 'addCandidate must not throw');
    if (!up) {
      // ignore: avoid_print
      print('C1 RESULT ICE_NOT_CONNECTED (recorded, not skipped)');
    }
  }, timeout: const Timeout(Duration(minutes: 15)));
}