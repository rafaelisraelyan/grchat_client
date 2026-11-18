// STAGE 2C / R4.8 - CONTROLLED TURN PACKET LOSS (2 s drop).
//
// Purpose: prove that a REAL, controlled interruption of the relay data path
// produces real packet loss in real WebRTC media, and that a short outage
// recovers WITHOUT any ICE restart.
//
// Run three times independently:
//   flutter test -d windows integration_test/r4_8_drop_test.dart --dart-define=R4_8_RUN=1
//
// Every run creates fresh PeerConnections, fresh TURN allocations and takes
// its own before/after statistics. No result is carried over between runs.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:integration_test/integration_test.dart';

import 'rtp_harness.dart';

const String turnHost = '192.168.31.21';
const int turnPort = 34780;
const String turnUser = 'grchat';
const String turnPass = 'refpass123';
const String controlBase = 'http://127.0.0.1:34781';

const Duration dropHold = Duration(seconds: 2);

/// Run index comes from --dart-define so each repetition is a separate
/// process with separate media devices and separate allocations.
const int runIndex = int.fromEnvironment('R4_8_RUN', defaultValue: 1);

Future<Map<String, dynamic>> turnStats() async {
  final c = HttpClient();
  try {
    final req = await c.getUrl(Uri.parse('$controlBase/stats'));
    final resp = await req.close();
    final body = await resp.transform(utf8.decoder).join();
    return jsonDecode(body) as Map<String, dynamic>;
  } finally {
    c.close(force: true);
  }
}

Future<void> setDrop(bool on) async {
  final c = HttpClient();
  try {
    final req = await c.getUrl(Uri.parse('$controlBase/drop?on=${on ? 1 : 0}'));
    final resp = await req.close();
    await resp.drain<void>();
  } finally {
    c.close(force: true);
  }
}

/// R4.9: teardown that is OBSERVABLE and that cannot silently pass.
///
/// R4.8 run 3 died between the last measurement and the end of the test, i.e.
/// inside close/dispose, and the runner reported only
/// "did not complete" + a flutter_tools temp-dir PathNotFoundException. The
/// native frame was never surfaced to Dart, so the crash has to be LOCALISED by
/// logging every step: if a step is the last line printed, that step is the one
/// that took the process down.
///
/// Order follows the project's own §plugin-dispose-quirk contract: stop() the
/// track while it is still in a known stream, THEN removeTrack(), and only then
/// dispose the stream and close the connection. Disposing a stream whose tracks
/// are still attached to a live connection is exactly the ordering that quirk
/// warns about.
Future<void> teardownObservable({
  required String tag,
  required List<({RTCPeerConnection pc, List<MediaStream> streams})> peers,
}) async {
  final failures = <String>[];
  Future<void> step(String name, Future<void> Function() body) async {
    try {
      await body();
      // ignore: avoid_print
      print('$tag TEARDOWN ok: $name');
    } catch (e) {
      failures.add('$name: ${e.runtimeType}: $e');
      // ignore: avoid_print
      print('$tag TEARDOWN FAILED: $name -> ${e.runtimeType}: $e');
    }
  }

  for (var i = 0; i < peers.length; i++) {
    final all = <MediaStreamTrack>[
      for (final s in peers[i].streams) ...s.getTracks(),
    ];
    for (final t in all) {
      await step('stop track ${t.kind} on peer $i', () async {
        await t.stop();
      });
    }
    for (final t in all) {
      final senders = await peers[i].pc.getSenders();
      for (final s in senders.where((s) => s.track?.id == t.id)) {
        await step('removeTrack ${t.kind} on peer $i', () async {
          await peers[i].pc.removeTrack(s);
        });
      }
    }
  }
  for (var i = 0; i < peers.length; i++) {
    await step('close peer $i', () async {
      await peers[i].pc.close();
    });
  }
  final seen = <String>{};
  for (var i = 0; i < peers.length; i++) {
    for (final s in peers[i].streams) {
      if (!seen.add(s.id)) continue;
      await step('dispose stream ${s.id}', () async {
        await s.dispose();
      });
    }
  }
  // ignore: avoid_print
  print('$tag TEARDOWN done failures=${failures.length}');
  if (failures.isNotEmpty) {
    // Never let an incomplete teardown masquerade as a pass.
    fail('$tag teardown incomplete: ${failures.join(' | ')}');
  }
}

/// Reads everything the report needs in one pass. Missing numeric fields are
/// reported as null, never substituted with 0.
Future<({int? audioBytes, int? videoBytes, int? frames, String? audioSsrc,
    String? videoSsrc, List<String> relayPair, String iceA, String iceB,
    String? localIdA, String? localIdB, String? remoteIdA, String? remoteIdB})>
    readMedia(RTCPeerConnection a, RTCPeerConnection b) async {
  final all = await b.getStats();
  final cands = <String, Map<dynamic, dynamic>>{
    for (final r in all.where((r) => r.type.contains('candidate'))) r.id: r.values,
  };
  final pairs = <String>[];
  for (final r in all.where((r) =>
      r.type == 'candidate-pair' && r.values['nominated'] == true)) {
    final l = cands[r.values['localCandidateId']] ?? <dynamic, dynamic>{};
    final rm = cands[r.values['remoteCandidateId']] ?? <dynamic, dynamic>{};
    pairs.add('${l['candidateType']}/${rm['candidateType']}:'
        '${r.values['state']}');
  }
  int? audio;
  int? video;
  int? framesV;
  String? aSsrc;
  String? vSsrc;
  for (final r in all.where((r) => r.type == 'inbound-rtp')) {
    if (r.values['kind'] == 'audio') {
      audio = ((r.values['bytesReceived'] as num?) ?? 0).toInt();
      aSsrc = '${r.values['ssrc']}';
    } else if (r.values['kind'] == 'video') {
      video = ((r.values['bytesReceived'] as num?) ?? 0).toInt();
      framesV = ((r.values['framesDecoded'] as num?) ?? 0).toInt();
      vSsrc = '${r.values['ssrc']}';
    }
  }
  return (
    audioBytes: audio,
    videoBytes: video,
    frames: framesV,
    audioSsrc: aSsrc,
    videoSsrc: vSsrc,
    relayPair: pairs,
    iceA: '${await a.getIceConnectionState()}'.split('.').last,
    iceB: '${await b.getIceConnectionState()}'.split('.').last,
    localIdA: await a
        .getLocalDescription()
        .then((d) => RegExp(r'a=ice-ufrag:(\S+)').firstMatch(d?.sdp ?? '')?.group(1)),
    localIdB: await b.getLocalDescription().then((d) => RegExp(r'a=ice-ufrag:(\S+)').firstMatch(d!.sdp!)?.group(1)),
    remoteIdA: await a.getRemoteDescription().then((d) => RegExp(r'a=ice-ufrag:(\S+)').firstMatch(d!.sdp!)?.group(1)),
    remoteIdB: await b.getRemoteDescription().then((d) => RegExp(r'a=ice-ufrag:(\S+)').firstMatch(d!.sdp!)?.group(1)),
  );
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  test('R4.8 run $runIndex: controlled 2s TURN relay drop', () async {
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
    expect(video, isNotNull);

    // Track identity is captured BEFORE any drop and re-checked after, so a
    // silent renegotiation that replaced the camera track would be visible.
    final camTrackId = video!.getTracks().first.id;
    final micTrackIdA = audioA!.getTracks().first.id;
    // ignore: avoid_print
    print('D$runIndex TRACKS cam=$camTrackId micA=$micTrackIdA kind=${video.getTracks().first.kind}');

    final cfg = <String, dynamic>{
      'iceServers': [
        {
          'urls': 'turn:$turnHost:$turnPort?transport=udp',
          'username': turnUser,
          'credential': turnPass,
        }
      ],
      'iceTransportPolicy': 'relay',
    };
    final pa = await createPeerConnection(cfg);
    final pb = await createPeerConnection(cfg);

    final toB = <RTCIceCandidate>[];
    final toA = <RTCIceCandidate>[];
    bool remoteOnB = false;
    bool remoteOnA = false;
    pa.onIceCandidate = (c) => remoteOnB ? pb.addCandidate(c) : toB.add(c);
    pb.onIceCandidate = (c) => remoteOnA ? pa.addCandidate(c) : toA.add(c);

    for (final t in video.getTracks()) {
      await pa.addTrack(t, video);
    }
    for (final t in audioA.getTracks()) {
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

    // ---- PHASE 0: prove the relay/relay route before touching the switch ----
    var up = false;
    final upDeadline = DateTime.now().add(const Duration(seconds: 60));
    while (DateTime.now().isBefore(upDeadline)) {
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
    print('D$runIndex ICE up=$up A=${await pa.getIceConnectionState()} '
        'B=${await pb.getIceConnectionState()}');

    // let encoders start and media become measurable
    await Future.delayed(const Duration(seconds: 5));
    final before = await readMedia(pa, pb);
    final turnBefore = await turnStats();
    // ignore: avoid_print
    print('D$runIndex BEFORE pair=${before.relayPair} '
        'audio=${before.audioBytes} video=${before.videoBytes} frames=${before.frames} '
        'ssrcA=${before.audioSsrc} ssrcV=${before.videoSsrc} '
        'ufragA=${before.localIdA} ufragB=${before.localIdB}');
    // ignore: avoid_print
    print('D$runIndex TURN BEFORE allocations=${turnBefore['allocations']} '
        'refreshes=${turnBefore['refreshes']} fwdIn=${turnBefore['forwardedIn']} '
        'fwdOut=${turnBefore['forwardedOut']} dropIn=${turnBefore['droppedIn']} '
        'dropOut=${turnBefore['droppedOut']} relaySockets=${turnBefore['relaySockets']}');

    expect(up, isTrue, reason: 'ICE must be up before any drop');
    expect(before.relayPair.any((p) => p.startsWith('relay/relay')), isTrue,
        reason: 'ETAP 3: selected pair must be relay/relay before DROP');
    expect((turnBefore['allocations'] as num).toInt(), greaterThanOrEqualTo(4),
        reason: 'ETAP 3: four TURN allocations expected in this configuration');
    expect(before.frames, greaterThan(0));
    expect(before.videoBytes, greaterThan(0));

    // A self-calibrating baseline of the SAME 2 s window, measured with FORWARD
    // still on. Without it the inbound assertion would be a magic number.
    final rate1 = await turnStats();
    await Future.delayed(dropHold);
    final rate2 = await turnStats();
    final baselineBytesIn =
        (rate2['relayBytesIn'] as num).toInt() - (rate1['relayBytesIn'] as num).toInt();
    final baselineBytesOut =
        (rate2['relayBytesOut'] as num).toInt() - (rate1['relayBytesOut'] as num).toInt();
    // ignore: avoid_print
    print('D$runIndex BASELINE(forward, ${dropHold.inSeconds}s) '
        'relayBytesIn=$baselineBytesIn relayBytesOut=$baselineBytesOut');

    // ---- PHASE 1: DROP on, hold 2 s, prove loss, restore ----
    await setDrop(true);
    final statsAtStart = await turnStats();
    final droppedAtStart = (statsAtStart['dropped'] as num).toInt();
    final bytesInAtStart = (statsAtStart['relayBytesIn'] as num).toInt();
    final bytesOutAtStart = (statsAtStart['relayBytesOut'] as num).toInt();
    final socketsAtStart = (statsAtStart['relaySockets'] as num).toInt();
    // ignore: avoid_print
    print('D$runIndex DROP ON dropped=$droppedAtStart '
        'relayBytesIn=$bytesInAtStart relayBytesOut=$bytesOutAtStart '
        'relaySockets=$socketsAtStart refreshes=${statsAtStart['refreshes']}');

    final lossDeadline = DateTime.now().add(const Duration(seconds: 4));
    while (DateTime.now().isBefore(lossDeadline)) {
      final s = await turnStats();
      if (((s['dropped'] as num).toInt()) > droppedAtStart) break;
      await Future.delayed(const Duration(milliseconds: 200));
    }
    final duringStats = await turnStats();
    // ignore: avoid_print
    print('D$runIndex DURING DROP allocations=${duringStats['allocations']} '
        'refreshes=${duringStats['refreshes']} dropIn=${duringStats['droppedIn']} '
        'dropOut=${duringStats['droppedOut']} allocErrors=${duringStats['allocErrors']} '
        'relaySockets=${duringStats['relaySockets']}');

    await Future.delayed(dropHold);
    final atEnd = await turnStats();
    final bytesInDuringDrop =
        (atEnd['relayBytesIn'] as num).toInt() - bytesInAtStart;
    final bytesOutDuringDrop =
        (atEnd['relayBytesOut'] as num).toInt() - bytesOutAtStart;
    // ignore: avoid_print
    print('D$runIndex DROP HELD ${dropHold.inSeconds}s dropIn=${atEnd['droppedIn']} '
        'dropOut=${atEnd['droppedOut']} bytesInDelta=$bytesInDuringDrop '
        'bytesOutDelta=$bytesOutDuringDrop dropBytesIn=${atEnd['dropBytesIn']} '
        'dropBytesOut=${atEnd['dropBytesOut']} allocations=${atEnd['allocations']} '
        'relaySockets=${atEnd['relaySockets']} refreshes=${atEnd['refreshes']}');

    await setDrop(false);
    // ignore: avoid_print
    print('D$runIndex DROP OFF');

    // ---- PHASE 2: recovery ----
    var after = await readMedia(pa, pb);
    final recDeadline = DateTime.now().add(const Duration(seconds: 45));
    while (DateTime.now().isBefore(recDeadline)) {
      after = await readMedia(pa, pb);
      final grew = (after.audioBytes ?? 0) > (before.audioBytes ?? 0) &&
          (after.videoBytes ?? 0) > (before.videoBytes ?? 0) &&
          (after.frames ?? 0) > (before.frames ?? 0);
      if (grew) break;
      await Future.delayed(const Duration(milliseconds: 500));
    }
    final turnAfter = await turnStats();
    // ignore: avoid_print
    print('D$runIndex AFTER pair=${after.relayPair} '
        'audio=${after.audioBytes} video=${after.videoBytes} frames=${after.frames} '
        'iceA=${after.iceA} iceB=${after.iceB}');
    // ignore: avoid_print
    print('D$runIndex TURN AFTER fwdIn=${turnAfter['forwardedIn']} '
        'fwdOut=${turnAfter['forwardedOut']} allocations=${turnAfter['allocations']} '
        'refreshes=${turnAfter['refreshes']} allocErrors=${turnAfter['allocErrors']}');

    final camTrackAfter = video.getTracks().first;
    // ignore: avoid_print
    print('D$runIndex IDENTITY camBefore=$camTrackId camAfter=${camTrackAfter.id} '
        'kind=${camTrackAfter.kind} enabled=${camTrackAfter.enabled} micA=$micTrackIdA '
        'pairAfter=${after.relayPair}');

    await teardownObservable(
      tag: 'D$runIndex',
      peers: [
        (pc: pa, streams: [video, audioA]),
        (pc: pb, streams: [audioB]),
      ],
    );

    // ---- assertions ----
    expect(((duringStats['dropped'] as num).toInt()), greaterThan(droppedAtStart),
        reason: 'DROP must discard real relayed packets');
    expect(((duringStats['droppedIn'] as num).toInt()) +
            ((duringStats['droppedOut'] as num).toInt()),
        greaterThan(0),
        reason: 'loss must be visible in the relayed data path, by direction');
    expect(((atEnd['allocations'] as num).toInt()),
        greaterThanOrEqualTo((duringStats['allocations'] as num).toInt()),
        reason: 'DROP must NOT destroy allocations');
    expect(((atEnd['relaySockets'] as num).toInt()), socketsAtStart,
        reason: 'DROP must NOT close relay sockets');
    // Inbound direction. With a global switch, blocking every peer egress
    // starves the ingress path, so droppedIn can legitimately stay 0 while the
    // INBOUND byte counter stops advancing. That stall is the proof that the
    // peer->client direction was withheld too.
    expect(baselineBytesIn, greaterThan(0),
        reason: 'relay ingress must carry data before the drop, else the '
            'comparison is meaningless');
    expect(bytesInDuringDrop, lessThan(baselineBytesIn ~/ 4),
        reason: 'relay INBOUND bytes must stall while DROP is on: '
            'baseline=$baselineBytesIn during=$bytesInDuringDrop');
    expect(bytesOutDuringDrop, lessThan(baselineBytesOut ~/ 4),
        reason: 'relay OUTBOUND bytes must stall while DROP is on');
    expect((after.audioBytes ?? 0), greaterThan(before.audioBytes ?? 0),
        reason: 'inbound audio RTP must resume after FORWARD returns');
    expect((after.videoBytes ?? 0), greaterThan(before.videoBytes ?? 0),
        reason: 'inbound video RTP must resume after FORWARD returns');
    expect((after.frames ?? 0), greaterThan(before.frames ?? 0),
        reason: 'decoded frames must keep growing after the drop');
    expect(after.iceA.toLowerCase().contains('connected') ||
            after.iceA.toLowerCase().contains('completed'),
        isTrue,
        reason: 'peer A must stay connected');
    expect(after.iceB.toLowerCase().contains('connected') ||
            after.iceB.toLowerCase().contains('completed'),
        isTrue,
        reason: 'peer B must stay connected');
    expect(camTrackAfter.id, camTrackId, reason: 'camera track identity');
    expect(camTrackAfter.enabled, isTrue,
        reason: 'camera track must stay enabled and must NOT be released');
    expect(before.localIdA, after.localIdA,
        reason: 'ICE ufrag must NOT change: no ICE restart happened');
    expect(before.localIdB, after.localIdB,
        reason: 'ICE ufrag must NOT change: no ICE restart happened');
  }, timeout: const Timeout(Duration(minutes: 20)));
}