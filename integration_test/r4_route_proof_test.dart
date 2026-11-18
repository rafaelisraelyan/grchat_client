// STAGE 2C / R4 - ROUTE PROOF ONLY.
//
// Purpose is narrow and deliberately so: prove that libwebrtc actually routes
// through the local Pion TURN server, i.e. that the selected candidate pair on
// BOTH peers is relay/relay. Without that proof every later drop experiment
// would be meaningless, because the peers would still be talking host-to-host
// and the drop would break nothing.
//
// This test performs NO drop. It either proves the route or it fails as INVALID.

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:integration_test/integration_test.dart';

import 'rtp_harness.dart';

// R4.6: the TURN server must live on a REAL interface IPv4, not on loopback.
// libwebrtc was observed to never contact a loopback TURN listener.
const String turnHost = '192.168.31.21';
const int turnPort = 34780;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  test('R4 route proof: media must traverse the local TURN relay', () async {
    // Sources first: on this host audioinput disappears from
    // enumerateDevices() once the first PeerConnection exists.
    final mics = await enumerateCapture('audioinput');
    expect(mics.length, greaterThanOrEqualTo(2));
    final audioA =
        await openCapture(audio: true, video: false, audioDeviceId: mics[0].deviceId);
    final audioB =
        await openCapture(audio: true, video: false, audioDeviceId: mics[1].deviceId);
    final cams = (await enumerateCapture('videoinput'))
      ..sort((a, b) => (a.deviceId.contains('usb#') ? 0 : 1)
          .compareTo(b.deviceId.contains('usb#') ? 0 : 1));
    final video = await openCapture(
        audio: false, video: true, videoDeviceId: cams.first.deviceId);
    expect(audioA, isNotNull);
    expect(audioB, isNotNull);
    expect(video, isNotNull);
    // ignore: avoid_print
    print('SOURCES micA=${mics[0].label} micB=${mics[1].label} cam=${cams.first.label}');

    // relay-only: no host or srflx fallback is permitted.
    final cfg = <String, dynamic>{
      'iceServers': [
        {
          // STRING form, not a list: many native RTCConfiguration parsers
          // reject a list and then never contact the TURN server at all.
          'urls': 'turn:$turnHost:$turnPort?transport=udp',
          'username': 'grchat',
          'credential': 'refpass123',
        }
      ],
      'iceTransportPolicy': 'relay',
    };

    final pa = await createPeerConnection(cfg);
    final pb = await createPeerConnection(cfg);

    // R4.6: the effective configuration is recorded verbatim (credentials are
    // NOT printed) so the report can state what native actually received.
    // ignore: avoid_print
    print('CFG urls=${(cfg['iceServers'] as List).first['urls']} '
        // ignore: avoid_print
        'user=${(cfg['iceServers'] as List).first['username']} '
        // ignore: avoid_print
        'policy=${cfg['iceTransportPolicy']}');

    // ICE gathering is logged explicitly: the route proof is worthless if the
    // agent never even started gathering.
    // ignore: avoid_print
    pa.onIceGatheringState = (s) => print('GATHER A $s');
    // ignore: avoid_print
    pb.onIceGatheringState = (s) => print('GATHER B $s');
    final toB = <RTCIceCandidate>[];
    final toA = <RTCIceCandidate>[];
    bool remoteOnA = false;
    bool remoteOnB = false;
    // R4.6: every candidate is PRINTED as it arrives, in addition to being
    // queued. An earlier version overwrote the logging handler with the
    // queueing one, so the observed candidate set was never actually recorded.
    final seenA = <String>[];
    final seenB = <String>[];
    void logCand(RTCIceCandidate c, String tag, List<String> seen) {
      if (c.candidate == null) {
        // ignore: avoid_print
        print('CAND $tag end-of-candidates');
        return;
      }
      // Print only the type/protocol part: no addresses, no credentials.
      final type = c.candidate!.contains(' typ relay')
          ? 'relay'
          : c.candidate!.contains(' typ srflx')
              ? 'srflx'
              : 'host';
      final line = 'CAND $tag typ=$type';
      seen.add(line);
      // ignore: avoid_print
      print(line);
    }

    // R4.7: candidates must go to the OPPOSITE peer. The R4.6 version of this
    // handler added each peer's candidates to ITSELF (A->pa, B->pb), so the
    // remote side never received them by trickle and the remote SDP was built
    // before gathering finished. That defect, not ICE, is what kept R4.6 in
    // `checking`.
    pa.onIceCandidate = (c) {
      logCand(c, 'A', seenA);
      remoteOnB ? pb.addCandidate(c) : toB.add(c);
    };
    pb.onIceCandidate = (c) {
      logCand(c, 'B', seenB);
      remoteOnA ? pa.addCandidate(c) : toA.add(c);
    };

    // A owns the camera, so A offers and the video m-line exists by
    // construction (R5.2 proved the legacy offerToReceiveVideo does not work).
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
    while (toB.isNotEmpty) {
      await pb.addCandidate(toB.removeAt(0));
    }
    final answer = await pb.createAnswer();
    await pb.setLocalDescription(answer);
    await pa.setRemoteDescription(RTCSessionDescription(answer.sdp!, 'answer'));
    remoteOnA = true;
    while (toA.isNotEmpty) {
      await pa.addCandidate(toA.removeAt(0));
    }

    final deadline = DateTime.now().add(const Duration(seconds: 60));
    var up = false;
    String lastA = '';
    String lastB = '';
    while (DateTime.now().isBefore(deadline)) {
      final sa = '${await pa.getIceConnectionState()}'.toLowerCase();
      final sb = '${await pb.getIceConnectionState()}'.toLowerCase();
      // R4.6: ICE state transitions are recorded as they happen, not only the
      // final state, so a stall is distinguishable from a wrong transition.
      if (sa != lastA) {
        lastA = sa;
        // ignore: avoid_print
        print('ICESTATE A=$sa');
      }
      if (sb != lastB) {
        lastB = sb;
        // ignore: avoid_print
        print('ICESTATE B=$sb');
      }
      if ((sa.contains('connected') || sa.contains('completed')) &&
          (sb.contains('connected') || sb.contains('completed'))) {
        up = true;
        break;
      }
      await Future.delayed(const Duration(milliseconds: 300));
    }
    // ignore: avoid_print
    print('ICE up=$up A=${await pa.getIceConnectionState()} '
        'B=${await pb.getIceConnectionState()}');
    expect(up, isTrue, reason: 'relay-only ICE must come up through Pion TURN');

    // ---- THE PROOF: selected pair must be relay/relay on BOTH peers ----
    Future<List<String>> pairDump(RTCPeerConnection pc, String tag) async {
      final all = await pc.getStats();
      final cands = <String, Map<dynamic, dynamic>>{
        for (final r in all.where((r) => r.type.contains('candidate')))
          r.id: r.values,
      };
      final out = <String>[];
      for (final r in all.where((r) =>
          r.type == 'candidate-pair' && r.values['nominated'] == true)) {
        final local = cands[r.values['localCandidateId']] ?? <dynamic, dynamic>{};
        final remote = cands[r.values['remoteCandidateId']] ?? <dynamic, dynamic>{};
        out.add('$tag pair=${r.id} state=${r.values['state']} '
            'localType=${local['candidateType']} remoteType=${remote['candidateType']} '
            'relayProto=${r.values['relayProtocol']} '
            'sent=${r.values['bytesSent']} recv=${r.values['bytesReceived']}');
      }
      out.add('$tag candidateTypes='
          '${cands.values.map((v) => v['candidateType']).toSet().toList()}');
      return out;
    }

    final dumpA = await pairDump(pa, 'A');
    final dumpB = await pairDump(pb, 'B');
    // ignore: avoid_print
    print('ROUTE ${dumpA.join(" | ")}');
    // ignore: avoid_print
    print('ROUTE ${dumpB.join(" | ")}');

    // ---- confirm real RTP is flowing over the proven route ----
    var audioBytes = 0;
    var videoBytes = 0;
    var frames = 0;
    final warm = DateTime.now().add(const Duration(seconds: 30));
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
    // ignore: avoid_print
    print('RTP over relay: audioBytes=$audioBytes videoBytes=$videoBytes '
        'framesDecoded=$frames');

    final isRelay = dumpA.any((l) => l.contains('localType=relay')) &&
        dumpB.any((l) => l.contains('localType=relay'));

    // R4.7 acceptance also requires that the peers and media tracks SURVIVE:
    // an ICE pair that collapses a second later would not prove anything about
    // a later outage experiment.
    await Future.delayed(const Duration(seconds: 5));
    final holdA = '${await pa.getIceConnectionState()}'.toLowerCase();
    final holdB = '${await pb.getIceConnectionState()}'.toLowerCase();
    var audioAfter = 0;
    var videoAfter = 0;
    var framesAfter = 0;
    for (final r in (await pb.getStats())
        .where((r) => r.type == 'inbound-rtp')) {
      if (r.values['kind'] == 'audio') {
        audioAfter = ((r.values['bytesReceived'] as num?) ?? 0).toInt();
      } else if (r.values['kind'] == 'video') {
        videoAfter = ((r.values['bytesReceived'] as num?) ?? 0).toInt();
        framesAfter = ((r.values['framesDecoded'] as num?) ?? 0).toInt();
      }
    }
    // ignore: avoid_print
    print('PERSIST after5s A=${holdA.split('.').last} B=${holdB.split('.').last} '
        'audioBytes=$audioAfter videoBytes=$videoAfter framesDecoded=$framesAfter');
    final alive = (holdA.contains('connected') || holdA.contains('completed')) &&
        (holdB.contains('connected') || holdB.contains('completed'));
    final growing = audioAfter > audioBytes &&
        videoAfter > videoBytes &&
        framesAfter > frames;

    await pa.close();
    await pb.close();
    await video.dispose();
    await audioA.dispose();
    await audioB.dispose();

    expect(isRelay, isTrue,
        reason: 'INVALID: the selected pair is not relay/relay, so a TURN drop '
            'would break nothing and the outage experiment would be meaningless');
    expect(audioBytes, greaterThan(0), reason: 'real audio RTP over the relay');
    expect(videoBytes, greaterThan(0), reason: 'real video RTP over the relay');
    expect(frames, greaterThan(0), reason: 'real decoded video frames');
    expect(alive, isTrue, reason: 'both peers must stay connected, not collapse');
    expect(growing, isTrue,
        reason: 'inbound RTP and decoded frames must KEEP growing over time');
  }, timeout: const Timeout(Duration(minutes: 15)));
}