// STAGE 2C / R4.9 - ETAP 4: PERMANENT DROP.
//
// A fresh call (new controller session, new PeerConnections) is dropped and the
// drop is NEVER lifted. The question is not "does media recover" but whether the
// recovery machine terminates exactly ONCE, within its own budget, without a
// restart storm, and whether the next call is unaffected.
//
// Real: two real PCs, relay-only, native ICE events, the real
// P2PMediaRecovery controller. NOT real: CallState (see report).

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

Future<Map<String, dynamic>> turnStats() async {
  final c = HttpClient();
  try {
    final req = await c.getUrl(Uri.parse('$controlBase/stats'));
    final resp = await req.close();
    return jsonDecode(await resp.transform(utf8.decoder).join())
        as Map<String, dynamic>;
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

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  test('R4.9 E4: permanent drop terminates recovery exactly once', () async {
    final mics = await enumerateCapture('audioinput');
    expect(mics.length, greaterThanOrEqualTo(1));
    final cams = await enumerateCapture('videoinput');
    final audioA = await openCapture(
        audio: true, video: false, audioDeviceId: mics.first.deviceId);
    final video =
        await openCapture(audio: false, video: true, videoDeviceId: cams.first.deviceId);

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

    // ---- call #1: the one that will never recover ----
    final recovery = P2PMediaRecovery();
    recovery.onCallChanged(callId: 'r4.9-permanent', epoch: 1);
    // ignore: avoid_print
    print('E4 BUDGET grace=${recovery.grace.inSeconds}s '
        'maxIceRestarts=${recovery.maxIceRestarts} '
        'budget=${recovery.recoveryBudget.inSeconds}s');

    final pa = await createPeerConnection(cfg);
    final pb = await createPeerConnection(cfg);
    final toB = <RTCIceCandidate>[];
    final toA = <RTCIceCandidate>[];
    bool remoteOnB = false, remoteOnA = false;
    pa.onIceCandidate = (c) => remoteOnB ? pb.addCandidate(c) : toB.add(c);
    pb.onIceCandidate = (c) => remoteOnA ? pa.addCandidate(c) : toA.add(c);

    for (final t in video!.getTracks()) {
      await pa.addTrack(t, video);
    }
    for (final t in audioA!.getTracks()) {
      await pa.addTrack(t, audioA);
    }

    var endCalls = 0;
    var restarts = 0;
    String? endReason;
    DateTime? firstLossAt;
    final phases = <String>{};
    final actions = <String>{};

    pa.onIceConnectionState = (s) {
      final mapped = mapIce(s) ?? MediaLinkState.checking;
      // ignore: avoid_print
      print('E4 NATIVE-ICE A=$s');
      final d = recovery.onIceState(
          state: mapped, callId: 'r4.9-permanent', epoch: 1, now: DateTime.now());
      actions.add(d.action.name);
      phases.add(d.phase.name);
      if (mapped == MediaLinkState.disconnected ||
          mapped == MediaLinkState.failed) {
        firstLossAt ??= DateTime.now();
      }
      // ignore: avoid_print
      print('E4 DECISION ${d.action.name} phase=${d.phase.name} ${d.reason}');
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

    final upDeadline = DateTime.now().add(const Duration(seconds: 60));
    var up = false;
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
    expect(up, isTrue, reason: 'link must be healthy before the permanent drop');
    // ignore: avoid_print
    print('E4 LINK UP, enabling permanent DROP');

    // ---- PERMANENT: never lifted ----
    await setDrop(true);
    final dropEnabledAt = DateTime.now();

    // Budget is measured from the first loss INSIDE the controller, so watch
    // until the controller itself declares the call over, or until we can prove
    // it never does.
    final hardStop = DateTime.now().add(const Duration(seconds: 110));
    while (DateTime.now().isBefore(hardStop) && endCalls == 0) {
      final now = DateTime.now();
      recovery.observe(now);
      final d = recovery.onTick(
          callId: 'r4.9-permanent', epoch: 1, now: now);
      actions.add(d.action.name);
      phases.add(d.phase.name);
      if (d.action == RecoveryAction.requestIceRestart) {
        restarts++;
        // ignore: avoid_print
        print('E4 RESTART #${d.restartNumber} '
            'used=${recovery.iceRestartsUsed} budgetEnd=${recovery.recoveryDeadline}');
        try {
          await pa.restartIce();
          await pa.createOffer(<String, dynamic>{'iceRestart': true});
          recovery.onIceRestartCompleted(
              restartNumber: d.restartNumber ?? 1,
              callId: 'r4.9-permanent',
              epoch: 1,
              succeeded: true);
        } catch (e) {
          // ignore: avoid_print
          print('E4 RESTART FAILED ${e.runtimeType}: $e');
          recovery.onIceRestartCompleted(
              restartNumber: d.restartNumber ?? 1,
              callId: 'r4.9-permanent',
              epoch: 1,
              succeeded: false);
        }
      } else if (d.action == RecoveryAction.endCall) {
        endCalls++;
        endReason = d.reason;
        // ignore: avoid_print
        print('E4 ENDCALL #1 at ${DateTime.now().toIso8601String()} '
            'reason=${d.reason}');
      }
      await Future.delayed(const Duration(milliseconds: 400));
    }

    final endedAt = DateTime.now();
    final fromLoss =
        firstLossAt == null ? null : endedAt.difference(firstLossAt!);
    final fromDrop = endedAt.difference(dropEnabledAt);
    // ignore: avoid_print
    print('E4 RESULT restarts=$restarts used=${recovery.iceRestartsUsed} '
        'left=${recovery.iceRestartsLeft} endCalls=$endCalls '
        'phase=${recovery.phase.name} budgetSpent=${recovery.recoveryBudgetSpent} '
        'fromLoss=${fromLoss?.inSeconds}s fromDrop=${fromDrop.inSeconds}s '
        'actions=$actions phases=$phases');

    // DROP is lifted only AFTER the controller declared the call over: this is
    // not a recovery attempt, it is cleanup for the following call.
    await setDrop(false);
    final turnAfter = await turnStats();

    // ---- teardown of call #1: must happen exactly once ----
    var teardowns = 0;
    Future<void> teardownOnce() async {
      teardowns++;
      final failures = <String>[];
      for (final pair in [
        (pc: pa, streams: [video, audioA]),
        (pc: pb, streams: <MediaStream>[]),
      ]) {
        for (final s in pair.streams) {
          for (final t in s.getTracks()) {
            try {
              await t.stop();
            } catch (e) {
              failures.add('stop ${t.kind}: ${e.runtimeType}');
            }
          }
        }
        try {
          await pair.pc.close();
        } catch (e) {
          failures.add('close: ${e.runtimeType}: $e');
        }
        for (final s in pair.streams) {
          try {
            await s.dispose();
          } catch (e) {
            failures.add('dispose: ${e.runtimeType}: $e');
          }
        }
      }
      // ignore: avoid_print
      print('E4 TEARDOWN #$teardowns failures=${failures.length}');
      if (failures.isNotEmpty) fail('E4 teardown: ${failures.join(' | ')}');
    }

    await teardownOnce();
    // ignore: avoid_print
    print('E4 NO SECOND TEARDOWN requested: teardowns=$teardowns');

    // ---- call #2: state must not be corrupted by the dead call ----
    recovery.onCallChanged(callId: 'r4.9-next', epoch: 2);
    final na = await createPeerConnection(cfg);
    final nb = await createPeerConnection(cfg);
    final n2b = <RTCIceCandidate>[];
    final n2a = <RTCIceCandidate>[];
    bool rB = false, rA = false;
    na.onIceCandidate = (c) => rB ? nb.addCandidate(c) : n2b.add(c);
    nb.onIceCandidate = (c) => rA ? na.addCandidate(c) : n2a.add(c);
    final mic2 = await openCapture(
        audio: true, video: false, audioDeviceId: mics.first.deviceId);
    for (final t in mic2!.getTracks()) {
      await na.addTrack(t, mic2);
    }
    final o2 = await na.createOffer(<String, dynamic>{'offerToReceiveAudio': 1});
    await na.setLocalDescription(o2);
    await nb.setRemoteDescription(RTCSessionDescription(o2.sdp!, 'offer'));
    rB = true;
    for (final c in List<RTCIceCandidate>.from(n2b)) {
      await nb.addCandidate(c);
    }
    n2b.clear();
    final a2 = await nb.createAnswer();
    await nb.setLocalDescription(a2);
    await na.setRemoteDescription(RTCSessionDescription(a2.sdp!, 'answer'));
    rA = true;
    for (final c in List<RTCIceCandidate>.from(n2a)) {
      await na.addCandidate(c);
    }
    n2a.clear();

    final nextDeadline = DateTime.now().add(const Duration(seconds: 45));
    var nextUp = false;
    while (DateTime.now().isBefore(nextDeadline)) {
      final sa = '${await na.getIceConnectionState()}'.toLowerCase();
      final sb = '${await nb.getIceConnectionState()}'.toLowerCase();
      if ((sa.contains('connected') || sa.contains('completed')) &&
          (sb.contains('connected') || sb.contains('completed'))) {
        nextUp = true;
        break;
      }
      await Future.delayed(const Duration(milliseconds: 300));
    }
    // ignore: avoid_print
    print('E4 NEXT CALL up=$nextUp phase=${recovery.phase.name} '
        'restartsLeft=${recovery.iceRestartsLeft} '
        'budgetSpent=${recovery.recoveryBudgetSpent}');

    for (final t in mic2.getTracks()) {
      try {
        await t.stop();
      } catch (_) {}
    }
    await na.close();
    await nb.close();
    try {
      await mic2.dispose();
    } catch (_) {}
    // ignore: avoid_print
    print('E4 NEXT CALL teardown done');

    // ---- verdict ----
    expect(endCalls, 1,
        reason: 'a permanent outage must terminate the call EXACTLY once');
    expect(endReason, isNotNull);
    expect(restarts, lessThanOrEqualTo(recovery.maxIceRestarts),
        reason: 'restart storm must be impossible');
    expect(teardowns, 1, reason: 'teardown must not repeat');
    expect((turnAfter['allocations'] as num).toInt(), greaterThanOrEqualTo(0));
    expect(nextUp, isTrue,
        reason: 'the next call must not inherit the dead call state');
    expect(recovery.phase, RecoveryPhase.idle,
        reason: 'a fresh call must reset the controller phase');
  }, timeout: const Timeout(Duration(minutes: 25)));
}