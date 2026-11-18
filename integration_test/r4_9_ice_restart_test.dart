// STAGE 2C / R4.9 - ETAP 3: LONG DROP -> NATIVE ICE RESTART -> MEDIA RECOVERY.
//
// What is REAL here:
//   - two real RTCPeerConnections, relay-only, through the controlled turnsrv
//   - real audio and video tracks
//   - NATIVE ICE connection-state events (no synthetic failed/disconnected)
//   - the REAL production P2PMediaRecovery controller (imported, not copied)
//   - a real pc.restartIce() with a real iceRestart offer/answer
//
// What is NOT here (and is therefore NOT integration acceptance):
//   - CallState. This harness owns the PeerConnection directly, so
//     CALLSTATE RECOVERY is NOT verified by this file. See the report.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:integration_test/integration_test.dart';

import 'package:grchat_client/src/call/p2p_media_recovery.dart';

import 'rtp_harness.dart';

const String turnHost = '192.168.31.21';
const int turnPort = 34780;
const String controlBase = 'http://127.0.0.1:34781';

const String callId = 'r4.9-call';
const int epoch = 1;

/// Long enough for native ICE to leave `connected` on its own and for the
/// recovery grace period to expire NATURALLY. Nothing is injected.
const Duration dropHold = Duration(seconds: 30);

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

MediaLinkState? mapIce(RTCIceConnectionState s) {
  final n = '$s'.toLowerCase();
  if (n.contains('checking')) return MediaLinkState.checking;
  if (n.contains('connected')) return MediaLinkState.connected;
  if (n.contains('completed')) return MediaLinkState.completed;
  if (n.contains('disconnected')) return MediaLinkState.disconnected;
  if (n.contains('failed')) return MediaLinkState.failed;
  if (n.contains('closed')) return MediaLinkState.closed;
  return null;
}

String? ufrag(String? sdp) =>
    sdp == null ? null : RegExp(r'a=ice-ufrag:(\S+)').firstMatch(sdp)?.group(1);

int relayCount(String? sdp) => sdp == null
    ? 0
    : RegExp(r'a=candidate:.* typ relay').allMatches(sdp).length;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  test('R4.9 E3: long drop, native ICE restart, media recovery', () async {
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

    final cfg = <String, dynamic>{
      'iceServers': [
        {
          'urls': 'turn:$turnHost:$turnPort?transport=udp',
          'username': 'grchat',
          'credential': 'refpass123',
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

    for (final t in video!.getTracks()) {
      await pa.addTrack(t, video);
    }
    for (final t in audioA!.getTracks()) {
      await pa.addTrack(t, audioA);
    }
    for (final t in audioB!.getTracks()) {
      await pb.addTrack(t, audioB);
    }

    // ---- REAL controller, default production parameters ----
    final recovery = P2PMediaRecovery();
    recovery.onCallChanged(callId: callId, epoch: epoch);
    // ignore: avoid_print
    print('E3 CONTROLLER grace=${recovery.grace.inSeconds}s '
        'maxIceRestarts=${recovery.maxIceRestarts} '
        'budget=${recovery.recoveryBudget.inSeconds}s');

    // Native events go straight into the production controller.
    final nativeIceLog = <String>[];
    pa.onIceConnectionState = (s) {
      final mapped = mapIce(s) ?? MediaLinkState.checking;
      nativeIceLog.add('${DateTime.now().toIso8601String()} A=${'$s'}');
      // ignore: avoid_print
      print('E3 NATIVE-ICE A=$s -> ${mapped.name}');
      final d = recovery.onIceState(
          state: mapped, callId: callId, epoch: epoch, now: DateTime.now());
      // ignore: avoid_print
      print('E3 DECISION ${d.action.name} phase=${d.phase.name} reason=${d.reason}');
    };
    pb.onIceConnectionState = (s) {
      // ignore: avoid_print
      print('E3 NATIVE-ICE B=$s');
    };

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
    expect(up, isTrue, reason: 'relay/relay ICE must be up before the long drop');

    await Future.delayed(const Duration(seconds: 5));
    final ufragBefore = ufrag((await pa.getLocalDescription())?.sdp);
    final turnBefore = await turnStats();
    final before = await _media(pb);
    // ignore: avoid_print
    print('E3 BEFORE ufragA=$ufragBefore relay=${relayCount((await pa.getLocalDescription())?.sdp)} '
        'audio=${before.$1} video=${before.$2} frames=${before.$3} '
        'allocations=${turnBefore['allocations']} pair=${await _pair(pb)}');
    expect(before.$3, greaterThan(0));

    // ---- LONG DROP: 30 s, nothing injected ----
    await setDrop(true);
    // ignore: avoid_print
    print('E3 DROP ON at ${DateTime.now().toIso8601String()} hold=${dropHold.inSeconds}s');

    var restartsObserved = 0;
    String? ufragAfterRestart;
    var phaseSeen = <String>{};
    var actionsSeen = <String>{};
    var ended = false;

    final dropEnd = DateTime.now().add(dropHold);
    while (DateTime.now().isBefore(dropEnd)) {
      final now = DateTime.now();
      recovery.observe(now);
      final d = recovery.onTick(callId: callId, epoch: epoch, now: now);
      actionsSeen.add(d.action.name);
      phaseSeen.add(d.phase.name);
      if (d.action == RecoveryAction.requestIceRestart) {
        restartsObserved++;
        // This is the SAME sequence production CallState performs:
        // restartIce() -> iceRestart offer -> setLocal -> send -> answer.
        // ignore: avoid_print
        print('E3 RESTART #${d.restartNumber} requested phase=${d.phase.name} '
            'iceRestartsUsed=${recovery.iceRestartsUsed} '
            'deadline=${recovery.deadline?.toIso8601String()} '
            'budgetEnd=${recovery.recoveryDeadline?.toIso8601String()}');
        try {
          await pa.restartIce();
          final ro = await pa.createOffer(<String, dynamic>{'iceRestart': true});
          await pa.setLocalDescription(ro);
          final restartSdp = (await pa.getLocalDescription())?.sdp ?? '';
          ufragAfterRestart = ufrag(restartSdp);
          // ignore: avoid_print
          print('E3 RESTART offer relay=${relayCount(restartSdp)} '
              'newUfrag=$ufragAfterRestart oldUfrag=$ufragBefore');
          await pb.setRemoteDescription(
              RTCSessionDescription(restartSdp, 'offer'));
          final ra = await pb.createAnswer();
          await pb.setLocalDescription(ra);
          await pa.setRemoteDescription(
              RTCSessionDescription(ra.sdp!, 'answer'));
          // ignore: avoid_print
          print('E3 RESTART signaling complete; '
              'signalingDown=${recovery.signalingDown}');
          final rd = recovery.onIceRestartCompleted(
              restartNumber: d.restartNumber ?? 1,
              callId: callId,
              epoch: epoch,
              succeeded: true);
          // ignore: avoid_print
          print('E3 RESTART recorded -> ${rd.action.name} phase=${rd.phase.name}');
        } catch (e) {
          // ignore: avoid_print
          print('E3 RESTART FAILED ${e.runtimeType}: $e');
          final rd = recovery.onIceRestartCompleted(
              restartNumber: d.restartNumber ?? 1,
              callId: callId,
              epoch: epoch,
              succeeded: false);
          // ignore: avoid_print
          print('E3 RESTART failure recorded -> ${rd.action.name}');
        }
      } else if (d.action == RecoveryAction.endCall) {
        ended = true;
        // ignore: avoid_print
        print('E3 ENDCALL reason=${d.reason}');
      }
      await Future.delayed(const Duration(milliseconds: 400));
    }

    final nativeDuringDrop = nativeIceLog.length;
    // ignore: avoid_print
    print('E3 DROP HELD nativeEvents=$nativeDuringDrop '
        'phases=$phaseSeen actions=$actionsSeen restarts=$restartsObserved '
        'used=${recovery.iceRestartsUsed} ended=$ended');

    // ---- FORWARD back ----
    await setDrop(false);
    // ignore: avoid_print
    print('E3 DROP OFF at ${DateTime.now().toIso8601String()}');

    final recoverDeadline = DateTime.now().add(const Duration(seconds: 45));
    var after = await _media(pb);
    while (DateTime.now().isBefore(recoverDeadline)) {
      after = await _media(pb);
      if (after.$1 > before.$1 && after.$2 > before.$2 && after.$3 > before.$3) {
        break;
      }
      await Future.delayed(const Duration(milliseconds: 500));
    }
    // A single +1 frame right after reconnect would be a weak claim. Let the
    // restarted transport carry media for a real window and measure the delta.
    final settled = await _media(pb);
    await Future.delayed(const Duration(seconds: 3));
    after = await _media(pb);
    var pairAfter = await _pair(pb);
    final pairDeadline = DateTime.now().add(const Duration(seconds: 15));
    while (pairAfter == 'NONE' && DateTime.now().isBefore(pairDeadline)) {
      await Future.delayed(const Duration(milliseconds: 500));
      pairAfter = await _pair(pb);
    }
    final ufragAfter = ufrag((await pa.getLocalDescription())?.sdp);
    final turnAfter = await turnStats();
    // ignore: avoid_print
    print('E3 SETTLED audio=${settled.$1}->${after.$1} '
        'video=${settled.$2}->${after.$2} frames=${settled.$3}->${after.$3} '
        '(3s window after recovery)');
    // ignore: avoid_print
    print('E3 AFTER ufragA=$ufragAfter audio=${after.$1} video=${after.$2} '
        'frames=${after.$3} pair=$pairAfter '
        'allocations=${turnAfter['allocations']} '
        'iceA=${await pa.getIceConnectionState()} '
        'iceB=${await pb.getIceConnectionState()}');

    // ---- teardown (observable, §plugin-dispose-quirk order) ----
    await _teardown('E3', [
      (pc: pa, streams: [video, audioA]),
      (pc: pb, streams: [audioB]),
    ]);

    // ---- verdict assertions ----
    expect(nativeIceLog, isNotEmpty,
        reason: 'native ICE events must be observed, not injected');
    expect(restartsObserved, greaterThan(0),
        reason: 'long drop must escalate to a real ICE restart');
    expect(ufragAfterRestart, isNotNull);
    expect(ufragAfterRestart, isNot(ufragBefore),
        reason: 'a real restart must generate new ICE credentials');
    expect(ufragAfter, ufragAfterRestart,
        reason: 'message section must keep the restarted generation');
    expect(after.$1, greaterThan(before.$1),
        reason: 'audio RTP must resume after restart');
    expect(after.$2, greaterThan(before.$2),
        reason: 'video RTP must resume after restart');
    expect(after.$3, greaterThan(before.$3),
        reason: 'new decoded frames must arrive after restart');
  }, timeout: const Timeout(Duration(minutes: 25)));
}

Future<(int, int, int)> _media(RTCPeerConnection pc) async {
  var a = 0, v = 0, f = 0;
  for (final r in (await pc.getStats()).where((r) => r.type == 'inbound-rtp')) {
    if (r.values['kind'] == 'audio') {
      a = ((r.values['bytesReceived'] as num?) ?? 0).toInt();
    } else if (r.values['kind'] == 'video') {
      v = ((r.values['bytesReceived'] as num?) ?? 0).toInt();
      f = ((r.values['framesDecoded'] as num?) ?? 0).toInt();
    }
  }
  return (a, v, f);
}

Future<String> _pair(RTCPeerConnection pc) async {
  final all = await pc.getStats();
  final cands = <String, Map<dynamic, dynamic>>{
    for (final r in all.where((r) => r.type.contains('candidate'))) r.id: r.values,
  };
  final out = <String>[];
  for (final r in all.where((r) =>
      r.type == 'candidate-pair' &&
      (r.values['nominated'] == true || r.values['selected'] == true))) {
    final l = cands[r.values['localCandidateId']] ?? <dynamic, dynamic>{};
    final rm = cands[r.values['remoteCandidateId']] ?? <dynamic, dynamic>{};
    out.add('${l['candidateType']}/${rm['candidateType']}:${r.values['state']}');
  }
  return out.isEmpty ? 'NONE' : out.join(',');
}

/// Same observable teardown contract as the R4.8 fix: stop -> removeTrack ->
/// close -> dispose, with a hard fail if any step did not complete.
Future<void> _teardown(
    String tag, List<({RTCPeerConnection pc, List<MediaStream> streams})> peers) async {
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
      await step('stop ${t.kind} peer $i', () => t.stop());
    }
    for (final t in all) {
      final senders = await peers[i].pc.getSenders();
      for (final s in senders.where((s) => s.track?.id == t.id)) {
        await step('removeTrack ${t.kind} peer $i', () => peers[i].pc.removeTrack(s));
      }
    }
  }
  for (var i = 0; i < peers.length; i++) {
    await step('close peer $i', () => peers[i].pc.close());
  }
  final seen = <String>{};
  for (final p in peers) {
    for (final s in p.streams) {
      if (!seen.add(s.id)) continue;
      await step('dispose stream ${s.id}', () => s.dispose());
    }
  }
  // ignore: avoid_print
  print('$tag TEARDOWN done failures=${failures.length}');
  if (failures.isNotEmpty) {
    fail('$tag teardown incomplete: ${failures.join(' | ')}');
  }
}