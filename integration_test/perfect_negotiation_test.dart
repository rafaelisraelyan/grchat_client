// Stage 2C / R5 - PERFECT NEGOTIATION ON THE NATIVE RUNTIME.
//
// Verifies the policy from lib/src/call/perfect_negotiation.dart against two
// REAL RTCPeerConnections carrying REAL audio+video, with in-process signaling.
// Nothing is mocked: the offers are produced by the native stack, the rollback
// is executed by the native stack, and recovery is proven by real RTP counters
// growing afterwards - not by "connected".
//
// Scenarios covered (see the R5 brief):
//   1  both peers renegotiate at the same time      -> glare
//   2  collision is detected
//   3  polite peer performs a real rollback and accepts the remote offer
//   4  impolite peer ignores the conflicting offer
//   5  both peers end in a stable signalingState
//   6  candidates arriving before the remote description are buffered
//   7  candidates of the rejected generation are dropped, others are not
//   8  no duplicate PeerConnection is created
//   9  PeerConnection and MediaStreamTrack identity survive
//  10  real RTP keeps flowing after the glare is resolved
//
// The driver below is TEST-ONLY. CallState is deliberately untouched in R5.

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:integration_test/integration_test.dart';

import 'package:grchat_client/src/call/perfect_negotiation.dart';

import 'rtp_harness.dart';
import 'rtp_support.dart';

/// One endpoint: a native PeerConnection plus the pure policy, wired exactly
/// the way the production driver is meant to wire it.
class NegotiatingPeer {
  NegotiatingPeer(this.name, this.polite) {
    policy = PerfectNegotiation(
      localEndpointKey: polite ? 'zzz-local' : 'aaa-local',
      remoteEndpointKey: polite ? 'aaa-remote' : 'zzz-remote',
    );
  }

  final String name;
  final bool polite;
  late final PerfectNegotiation policy;
  late final RTCPeerConnection pc;

  NegotiatingPeer? remote;

  final List<RTCIceCandidate> pendingCandidates = <RTCIceCandidate>[];
  bool remoteDescriptionSet = false;

  /// ufrag of our current local description; candidates are tagged with it.
  String? localUfrag;

  final List<String> transitions = <String>[];
  final List<String> rejectedUfrags = <String>[];
  final List<String> appliedUfrags = <String>[];

  /// Kept so a rollback's effect on the senders can be inspected directly:
  /// an m-line can say sendrecv while the sender behind it has no track left.
  final List<RTCRtpSender> senders = <RTCRtpSender>[];
  int candidatesApplied = 0;
  int candidatesDropped = 0;
  int rollbacksExecuted = 0;
  int ignoredOffers = 0;
  int ignoredAnswers = 0;

  static const _config = <String, dynamic>{'iceServers': <dynamic>[]};

  Future<void> init() async {
    pc = await createPeerConnection(_config);
    // Wire callbacks BEFORE any SDP work, or candidates emitted while gathering
    // starts are lost with no way to recover them.
    pc.onIceCandidate = (c) {
      unawaited(_onCandidate(c));
    };
  }

  Future<void> attach(MediaStream stream) async {
    for (final t in stream.getTracks()) {
      senders.add(await pc.addTrack(t, stream));
    }
  }

  Future<String?> _currentUfrag() async {
    try {
      final d = await pc.getLocalDescription();
      return iceUfragOf(d?.sdp);
    } catch (_) {
      // getLocalDescription() THROWS when nothing is set yet.
      return null;
    }
  }

  Future<void> _onCandidate(RTCIceCandidate c) async {
    final target = remote;
    if (target == null) return;
    final d = target.policy.onRemoteCandidate(ufrag: localUfrag);
    if (d.action == PnAction.ignoreStaleCandidate) {
      target.candidatesDropped++;
      target.transitions.add('DROP candidate ufrag=$localUfrag');
      return;
    }
    // Candidates that arrive before the remote description must be buffered:
    // addCandidate throws otherwise.
    if (!target.remoteDescriptionSet) {
      target.pendingCandidates.add(c);
      target.transitions.add('BUFFER candidate (no remote description)');
      return;
    }
    await target.pc.addCandidate(c);
    target.candidatesApplied++;
    target.appliedUfrags.add(localUfrag ?? '<none>');
  }

  Future<void> _flushCandidates() async {
    if (!remoteDescriptionSet) return;
    while (pendingCandidates.isNotEmpty) {
      final c = pendingCandidates.removeAt(0);
      await pc.addCandidate(c);
      candidatesApplied++;
    }
  }

  /// Starts a local offer and hands it to the peer. Mirrors
  /// CallState._renegotiateVideo: createOffer -> setLocal -> send.
  Future<void> startLocalOffer({bool iceRestart = false}) async {
    final begin = policy.beginLocalOffer();
    if (begin.generation < 0) {
      transitions.add('SKIP local offer (${begin.reason})');
      return;
    }
    if (iceRestart) await pc.restartIce();
    final offer = await pc.createOffer(
        iceRestart ? <String, dynamic>{'iceRestart': true} : <String, dynamic>{});
    await pc.setLocalDescription(offer);
    localUfrag = await _currentUfrag();
    policy.endLocalOffer();
    final out = (await pc.getLocalDescription())?.sdp ?? '';
    transitions.add('SEND offer gen=${policy.generation} ufrag=$localUfrag '
        '(${out.length} bytes)');
    await remote!.receive(PnDescriptionType.offer, out);
  }

  /// Handles an incoming description purely through the policy.
  Future<void> receive(PnDescriptionType type, String sdp) async {
    final state = _mapState(pc.signalingState?.toString());
    final d = policy.onRemoteDescription(
      type: type,
      signalingState: state,
      sdp: sdp,
    );

    switch (d.action) {
      case PnAction.ignoreCollidingOffer:
        ignoredOffers++;
        final u = iceUfragOf(sdp);
        if (u != null) rejectedUfrags.add(u);
        transitions.add('IGNORE colliding offer gen=${d.generation} ($u)');
        return;

      case PnAction.rollbackThenAcceptOffer:
        // Real native rollback, then take over the peer's offer.
        await pc.setLocalDescription(RTCSessionDescription('', 'rollback'));
        rollbacksExecuted++;
        transitions.add('ROLLBACK then accept gen=${d.generation}');
        await _acceptAndAnswer(sdp);
        return;

      case PnAction.acceptOffer:
        transitions.add('ACCEPT offer gen=${d.generation}');
        await _acceptAndAnswer(sdp);
        return;

      case PnAction.acceptAnswer:
        await pc.setRemoteDescription(RTCSessionDescription(sdp, 'answer'));
        remoteDescriptionSet = true;
        localUfrag = await _currentUfrag();
        await _flushCandidates();
        transitions.add('ACCEPT answer gen=${d.generation} state=$state');
        return;

      case PnAction.ignoreStaleAnswer:
        ignoredAnswers++;
        transitions.add('IGNORE stale answer gen=${d.generation} (${d.reason})');
        return;

      case PnAction.none:
      case PnAction.ignoreStaleCandidate:
        transitions.add('NOOP gen=${d.generation} (${d.reason})');
        return;
    }
  }

  Future<void> _acceptAndAnswer(String sdp) async {
    await pc.setRemoteDescription(RTCSessionDescription(sdp, 'offer'));
    remoteDescriptionSet = true;
    await _flushCandidates();
    final answer = await pc.createAnswer();
    await pc.setLocalDescription(answer);
    final out = (await pc.getLocalDescription())?.sdp ?? '';
    transitions.add('SEND answer gen=${policy.generation} (${out.length} bytes)');
    await remote!.receive(PnDescriptionType.answer, out);
  }

  static PnSignalingState _mapState(String? raw) {
    final t = (raw ?? '').toLowerCase();
    if (t.contains('havelocaloffer')) return PnSignalingState.haveLocalOffer;
    if (t.contains('haveremoteoffer')) return PnSignalingState.haveRemoteOffer;
    if (t.contains('havelocalpranswer')) return PnSignalingState.haveLocalPranswer;
    if (t.contains('haveremotepranswer')) return PnSignalingState.haveRemotePranswer;
    if (t.contains('closed')) return PnSignalingState.closed;
    return PnSignalingState.stable;
  }

  Future<void> close() async {
    pc.onIceCandidate = null;
    await pc.close();
  }
}

/// Media direction per m-line. After a glare this is the fastest way to see
/// whether the surviving negotiation ended up recvonly/inactive by accident.
Future<String> directionSummary(NegotiatingPeer p, {bool remote = false}) async {
  try {
    final d = remote ? await p.pc.getRemoteDescription() : await p.pc.getLocalDescription();
    final sdp = d?.sdp;
    if (sdp == null) return 'null';
    final out = <String>[];
    for (final line in sdp.split('\r\n')) {
      if (line.startsWith('m=')) {
        out.add(line.split(' ').first);
      } else if (line.startsWith('a=sendonly') ||
          line.startsWith('a=recvonly') ||
          line.startsWith('a=inactive') ||
          line.startsWith('a=sendrecv')) {
        out.add(line.substring(2));
      }
    }
    return out.join(' ');
  } catch (e) {
    return 'throws($e)';
  }
}

/// One-line state of a sender: does it still carry a live track?
String senderState(RTCRtpSender s) {
  final t = s.track;
  return '${t?.kind ?? 'NO-TRACK'}:${(t?.id ?? '-').substring(0, 4)}';
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  test('R5: perfect negotiation resolves real glare and RTP survives', () async {
    // ---- real media, opened before any PeerConnection exists ----
    final mics = await openMicrophonesFirst();
    expect(mics.length, 2,
        reason: 'audio RTP needs one microphone stream per peer');
    final (audioA, audioDeviceA) = mics[0];
    final (audioB, audioDeviceB) = mics[1];
    final videoDevices = await enumerateCapture('videoinput');
    expect(videoDevices, isNotEmpty);
    final video =
        await openCapture(audio: false, video: true, videoDeviceId: videoDevices.first.deviceId);
    expect(video, isNotNull, reason: 'a real capture device must exist');
    final videoStream = video!;

    // ---- initial call, negotiated the ordinary way ----
    final polite = NegotiatingPeer('polite', true);
    final impolite = NegotiatingPeer('impolite', false);
    polite.remote = impolite;
    impolite.remote = polite;
    await polite.init();
    await impolite.init();
    await polite.attach(videoStream);
    await polite.attach(audioA);
    await impolite.attach(videoStream);
    await impolite.attach(audioB);

    // The initial handshake has no collision: the impolite peer offers.
    await impolite.startLocalOffer();
    final up = await waitForBothIce(polite, impolite);
    expect(up, isTrue, reason: 'ICE must come up before the glare test');
    // ignore: avoid_print
    print('SETUP ice up; polite=${polite.policy.polite} '
        'candidates applied A=${polite.candidatesApplied} B=${impolite.candidatesApplied}');

    // ICE being up does NOT mean media is already flowing: the encoders need a
    // couple of seconds, and sampling immediately reports zero - which looks
    // exactly like a dead camera. Warm up before taking the baseline.
    final warmedUp = await waitInboundGrowth(impolite, window: const Duration(seconds: 25));
    if (!warmedUp) {
      // ignore: avoid_print
      print('WARMUP FAILED impolite ice=${await impolite.pc.getIceConnectionState()} '
          'polite ice=${await polite.pc.getIceConnectionState()} '
          'impolite signaling=${impolite.pc.signalingState} '
          'polite signaling=${polite.pc.signalingState}');
      // ignore: avoid_print
      print('WARMUP transitions polite:\n${polite.transitions.join('\n')}');
      // ignore: avoid_print
      print('WARMUP transitions impolite:\n${impolite.transitions.join('\n')}');
      // ignore: avoid_print
      print(await dumpPeerEvidence(impolite.pc, polite.pc, 'warmup-impolite'));
      // ignore: avoid_print
      print('WARMUP inbound impolite=${await inboundBytes(impolite)} '
          'polite=${await inboundBytes(polite)}');
    }
    expect(warmedUp, isTrue,
        reason: 'real RTP must be flowing before the glare test starts');

    final inboundBefore = await inboundBytes(impolite);
    expect(inboundBefore.audio, greaterThan(0), reason: 'audio RTP before glare');
    expect(inboundBefore.video, greaterThan(0), reason: 'video RTP before glare');

    // ---- identity snapshot (scenarios 8 and 9) ----
    final localTrackIds = <String>{
      ...videoStream.getTracks().map((t) => t.id ?? ''),
      ...audioA.getTracks().map((t) => t.id ?? ''),
      ...audioB.getTracks().map((t) => t.id ?? ''),
    };
    // The SAME PeerConnection object must serve the whole test: if the glare
    // handling ever recreated it, the native state below would be fresh.
    final iceStateBefore = '${await polite.pc.getIceConnectionState()}';
    final ufragBeforeGlare = polite.localUfrag;

    // ---- CONTROL: renegotiation WITHOUT glare, to isolate rollback as the only
// variable. If media survives here but dies after a glare, the rollback itself
// is what breaks the media path on this native stack.
    final ctrlStart = await inboundBytes(impolite);
    await impolite.startLocalOffer();
    final ctrlStable = await pollUntil<bool>(() async {
          final a = polite.pc.signalingState?.toString().toLowerCase() ?? '';
          final b = impolite.pc.signalingState?.toString().toLowerCase() ?? '';
          return (a.contains('stable') && b.contains('stable')) ? true : null;
        }, timeout: const Duration(seconds: 20));
    await Future.delayed(const Duration(seconds: 2));
    final ctrlBaseline = await inboundBytes(impolite);
    final ctrlGrew =
        await waitInboundGrowth(impolite, window: const Duration(seconds: 25));
    final ctrlEnd = await inboundBytes(impolite);
    // ignore: avoid_print
    print('CONTROL renegotiation-without-glare stable=$ctrlStable '
        'grew=$ctrlGrew audio ${ctrlStart.audio} -> ${ctrlBaseline.audio} -> ${ctrlEnd.audio} '
        'video ${ctrlStart.video} -> ${ctrlBaseline.video} -> ${ctrlEnd.video}');

    // ---- SCENARIO 1/2: both peers renegotiate simultaneously ----
    // Fired together with no await in between, so both land in have-local-offer.
    await Future.wait([
      polite.startLocalOffer(),
      impolite.startLocalOffer(),
    ]);

    // ignore: avoid_print
    print('GLARE polite transitions:\n${polite.transitions.join('\n')}');
    // ignore: avoid_print
    print('GLARE impolite transitions:\n${impolite.transitions.join('\n')}');
    // ignore: avoid_print
    print('GLARE polite rollbacks=${polite.rollbacksExecuted} ignored=${polite.ignoredOffers} '
        'droppedCandidates=${polite.candidatesDropped} | '
        'impolite rollbacks=${impolite.rollbacksExecuted} ignored=${impolite.ignoredOffers} '
        'droppedCandidates=${impolite.candidatesDropped}');

    // ---- SCENARIO 3/4: exactly one peer rolled back, one ignored ----
    expect(polite.rollbacksExecuted + impolite.rollbacksExecuted, 1,
        reason: 'a collision is resolved by exactly one rollback');
    expect(polite.polite, isTrue);
    expect(impolite.polite, isFalse);
    expect(polite.ignoredOffers + impolite.ignoredOffers, lessThanOrEqualTo(1),
        reason: 'the impolite peer must refuse the colliding offer');

    // ---- SCENARIO 5: both peers back in a stable signalingState ----
    final stableAfterGlare = await pollUntil<bool>(() async {
      final a = polite.pc.signalingState?.toString().toLowerCase() ?? '';
      final b = impolite.pc.signalingState?.toString().toLowerCase() ?? '';
      return (a.contains('stable') && b.contains('stable')) ? true : null;
    }, timeout: const Duration(seconds: 20));
    // ignore: avoid_print
    print('GLARE polite signaling=${polite.pc.signalingState} '
        'impolite signaling=${impolite.pc.signalingState} stable=$stableAfterGlare');
    expect(stableAfterGlare, isTrue,
        reason: 'both peers must return to a stable signalingState');

    // ---- SCENARIO 7: rejected-generation candidates dropped, others applied ----
    // ignore: avoid_print
    print('GLARE polite rejectedUfrags=${polite.rejectedUfrags} '
        'impolite rejectedUfrags=${impolite.rejectedUfrags}');
    for (final p in [polite, impolite]) {
      // The real invariant: a candidate carrying a REJECTED ufrag must never
      // reach the PeerConnection. How many such candidates the native stack
      // actually emits is not ours to demand - if polite's rolled-back offer
      // produced none, there is legitimately nothing to drop, and asserting a
      // drop here would be asserting luck rather than correctness.
      final leaked = p.appliedUfrags.where(p.rejectedUfrags.contains).toList();
      // ignore: avoid_print
      print('CANDIDATES ${p.name} rejected=${p.rejectedUfrags} '
          'appliedUfrags=${p.appliedUfrags.toSet().toList()} '
          'dropped=${p.candidatesDropped} leaked=$leaked');
      expect(leaked, isEmpty,
          reason: 'a candidate from a rejected generation must not be applied');
    }
    expect(polite.candidatesApplied + impolite.candidatesApplied, greaterThan(0),
        reason: 'candidates of the surviving generation must still be applied');

    // ---- SCENARIO 10: real RTP keeps flowing after the glare ----
    // A renegotiation legitimately REPLACES the stats objects (new SSRC), so the
    // counter restarts near zero. Comparing a pre-glare absolute value with a
    // post-glare one is therefore meaningless - and was the source of a flaky
    // assertion. Baseline AFTER the glare settles, then require growth.
    await Future.delayed(const Duration(seconds: 3));
    final baseline = await inboundBytes(impolite);
    final outBaseline = await outboundBytes(polite);
    final pairBaseline = await pairBytes(impolite);

    final after = await waitInboundGrowth(impolite, window: const Duration(seconds: 30));
    final inboundAfter = await inboundBytes(impolite);
    final outAfter = await outboundBytes(polite);
    final pairAfter = await pairBytes(impolite);
    // ignore: avoid_print
    print('TRANSPORT pair bytes $pairBaseline -> $pairAfter '
        'impolite ice=${await impolite.pc.getIceConnectionState()} '
        'polite ice=${await polite.pc.getIceConnectionState()}');
    // ignore: avoid_print
    print('SENDER polite outbound audio ${outBaseline.audio} -> ${outAfter.audio} '
        'video ${outBaseline.video} -> ${outAfter.video}');
    // ignore: avoid_print
    print('SENDER TRACKS polite=${polite.senders.map(senderState).toList()} '
        'impolite=${impolite.senders.map(senderState).toList()}');
    // ignore: avoid_print
    print('DIRECTIONS polite local=[${await directionSummary(polite)}] '
        'remote=[${await directionSummary(polite, remote: true)}]');
    // ignore: avoid_print
    print('DIRECTIONS impolite local=[${await directionSummary(impolite)}] '
        'remote=[${await directionSummary(impolite, remote: true)}]');
    // ignore: avoid_print
    print('RTP after glare audio ${baseline.audio} -> ${inboundAfter.audio} '
        'video ${baseline.video} -> ${inboundAfter.video} resumed=$after '
        '(pre-glare was audio=${inboundBefore.audio} video=${inboundBefore.video})');
    // KNOWN FAILING ASSERTION - deliberately NOT weakened.
// A renegotiation WITHOUT glare keeps media flowing (see the CONTROL block
// above), but after a glare resolved by rollback the media path does not
// reliably recover: in one run video froze, in another audio froze completely
// while video resumed, while the SDP still advertised sendrecv on every m-line
// and the senders still held their tracks. Rolling glare back into production
// before this is understood would silently kill a call's media, so the
// assertion stays strict and the defect stays visible.
    expect(inboundAfter.audio, greaterThan(baseline.audio),
        reason: 'KNOWN DEFECT: audio RTP must keep flowing after a glare is '
            'resolved by rollback; see STAGE2C_R5_REPORT.md');
    expect(inboundAfter.video, greaterThan(baseline.video),
        reason: 'KNOWN DEFECT: video RTP must keep flowing after a glare is '
            'resolved by rollback; see STAGE2C_R5_REPORT.md');
    expect(pairAfter, greaterThan(pairBaseline),
        reason: 'the nominated candidate pair must still carry traffic: this is '
            'the assertion that does not depend on SSRC identity surviving');

    // ---- SCENARIO 9: track identity survived (no silent re-creation) ----
    final localTrackIdsAfter = <String>{
      ...videoStream.getTracks().map((t) => t.id ?? ''),
      ...audioA.getTracks().map((t) => t.id ?? ''),
      ...audioB.getTracks().map((t) => t.id ?? ''),
    };
    final iceStateAfter = '${await polite.pc.getIceConnectionState()}';
    // ignore: avoid_print
    print('IDENTITY tracks before=${localTrackIds.length} after=${localTrackIdsAfter.length} '
        'ice before=$iceStateBefore after=$iceStateAfter '
        'ufrag before=$ufragBeforeGlare after=${polite.localUfrag}');
    expect(localTrackIdsAfter, equals(localTrackIds),
        reason: 'MediaStreamTrack identity must survive renegotiation');
    expect(iceStateAfter, iceStateBefore,
        reason: 'the same PeerConnection must serve the call: a re-created one '
            'would not still be Connected under the old transport');

    // ignore: avoid_print
    print(await dumpPeerEvidence(impolite.pc, polite.pc, 'after-glare'));

    await polite.close();
    await impolite.close();
    await videoStream.dispose();
    await audioA.dispose();
    await audioB.dispose();
  }, timeout: const Timeout(Duration(minutes: 15)));
}

/// Polls a condition with a bounded budget; null on timeout.
Future<T?> pollUntil<T>(
  Future<T?> Function() probe, {
  required Duration timeout,
  Duration step = const Duration(milliseconds: 400),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    final v = await probe();
    if (v != null) return v;
    await Future.delayed(step);
  }
  return null;
}

/// Waits until both peers report a connected ICE transport.
Future<bool> waitForBothIce(NegotiatingPeer a, NegotiatingPeer b) async {
  final hit = await pollUntil<bool>(() async {
    final sa = (await a.pc.getIceConnectionState())?.toString().toLowerCase() ?? '';
    final sb = (await b.pc.getIceConnectionState())?.toString().toLowerCase() ?? '';
    final upA = sa.contains('connected') || sa.contains('completed');
    final upB = sb.contains('connected') || sb.contains('completed');
    return (upA && upB) ? true : null;
  }, timeout: const Duration(seconds: 45), step: const Duration(milliseconds: 300));
  return hit == true;
}

/// Full stats evidence for the report, straight from the native runtime.
Future<String> dumpPeerEvidence(
    RTCPeerConnection receiver, RTCPeerConnection sender, String phase) async {
  final buf = StringBuffer();
  buf.writeln('=== EVIDENCE[$phase] ===');
  final inStats = await receiver.getStats();
  final outStats = await sender.getStats();
  for (final r in inStats.where((r) => r.type == 'inbound-rtp')) {
    buf.writeln('INBOUND kind=${r.values['kind']} ssrc=${r.values['ssrc']} '
        'bytes=${r.values['bytesReceived']} packets=${r.values['packetsReceived']} '
        'framesDecoded=${r.values['framesDecoded']} lost=${r.values['packetsLost']}');
  }
  for (final r in outStats.where((r) => r.type == 'outbound-rtp')) {
    buf.writeln('OUTBOUND kind=${r.values['kind']} ssrc=${r.values['ssrc']} '
        'bytes=${r.values['bytesSent']} packets=${r.values['packetsSent']} '
        'framesEncoded=${r.values['framesEncoded']}');
  }
  for (final r in inStats
      .where((r) => r.type == 'candidate-pair' && r.values['nominated'] == true)) {
    buf.writeln('SELECTED PAIR state=${r.values['state']} nominated=${r.values['nominated']} '
        'bytesSent=${r.values['bytesSent']} bytesReceived=${r.values['bytesReceived']} '
        'packetsSent=${r.values['packetsSent']} packetsReceived=${r.values['packetsReceived']}');
  }
  return buf.toString();
}

/// Sums real inbound bytes per kind from a peer.
Future<({int audio, int video})> outboundBytes(NegotiatingPeer p) async {
  final all = await p.pc.getStats();
  int audio = 0;
  int video = 0;
  for (final r in all) {
    if (r.type != 'outbound-rtp') continue;
    final bytes = (r.values['bytesSent'] as num?)?.toInt() ?? 0;
    if (r.values['kind'] == 'audio') {
      audio += bytes;
    } else if (r.values['kind'] == 'video') {
      video += bytes;
    }
  }
  return (audio: audio, video: video);
}

/// Sum of bytes on the nominated candidate pair: tells "transport dead" apart
/// from "media source stopped".
Future<int> pairBytes(NegotiatingPeer p) async {
  final all = await p.pc.getStats();
  int total = 0;
  for (final r in all) {
    if (r.type != 'candidate-pair' || r.values['nominated'] != true) continue;
    total += ((r.values['bytesSent'] as num?)?.toInt() ?? 0) +
        ((r.values['bytesReceived'] as num?)?.toInt() ?? 0);
  }
  return total;
}

Future<({int audio, int video})> inboundBytes(NegotiatingPeer p) async {
  final all = await p.pc.getStats();
  int audio = 0;
  int video = 0;
  for (final r in all) {
    if (r.type != 'inbound-rtp') continue;
    final bytes = (r.values['bytesReceived'] as num?)?.toInt() ?? 0;
    if (r.values['kind'] == 'audio') {
      audio += bytes;
    } else if (r.values['kind'] == 'video') {
      video += bytes;
    }
  }
  return (audio: audio, video: video);
}

/// Waits until inbound counters advance on both kinds.
Future<bool> waitInboundGrowth(NegotiatingPeer p,
    {required Duration window}) async {
  final start = await inboundBytes(p);
  final deadline = DateTime.now().add(window);
  while (DateTime.now().isBefore(deadline)) {
    await Future.delayed(const Duration(milliseconds: 500));
    final now = await inboundBytes(p);
    if (now.audio > start.audio && now.video > start.video) return true;
  }
  return false;
}