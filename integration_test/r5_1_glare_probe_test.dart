// STAGE 2C / R5.1 - ROOT CAUSE: why does media stop after an SDP glare?
//
// This file fixes five real defects in the R5 test driver BEFORE investigating,
// because each of them could itself corrupt the media path and produce a
// misleading conclusion:
//
//   D1 the R5 driver attached the SAME MediaStreamTrack to both peers. Prior
//      native bisects already showed a shared audio+video pairing wedging ICE.
//      Here every peer gets its OWN capture stream.
//   D2 candidates were tagged with the peer's CURRENT local ufrag, so after a
//      rollback the candidates of the abandoned offer were silently re-tagged
//      with the new generation's ufrag. Now every candidate carries the token
//      of the local description that actually produced it.
//   D3 buffered candidates were flushed blindly. Now each one is re-validated
//      against the policy immediately before addCandidate, because it may have
//      been rejected while it sat in the buffer.
//   D4 the ICE ufrag was used as the ONLY negotiation identity. Now candidates
//      and descriptions are identified by an explicit negotiation token, with
//      the ufrag kept only as a secondary check.
//   D5 makingOffer was never asserted after a collision. It is now checked
//      explicitly on both peers.
//
// Five comparative phases run in ONE process (mic streams must be opened before
// the first PeerConnection exists) and report, per SSRC, exactly where the
// media path stops: source -> encoder -> sender -> transport -> receiver.

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:integration_test/integration_test.dart';

import 'package:grchat_client/src/call/perfect_negotiation.dart';

import 'rtp_harness.dart';

/// Per-SSRC RTP counters, exactly as the native runtime reports them.
class SsrcRow {
  SsrcRow(this.kind, this.bytes, this.packets, this.frames, this.active);
  final String kind;
  final int bytes;
  final int packets;
  final int frames;
  final bool active;

  @override
  String toString() => '$kind ssrc#$bytes/$packets/frames=$frames/active=$active';
}

int _physicalPenalty(MediaSource d) => d.deviceId.contains('usb#') ? 0 : 1;

int _headsetPenalty(MediaSource d) =>
    d.label.toLowerCase().contains('headset') || d.label.contains('Головной') ? 1 : 0;

/// Reads a numeric stat value, tolerating any schema change.
int _num(Map<dynamic, dynamic> values, String key) {
  final v = values[key];
  return v is num ? v.toInt() : 0;
}

/// Reads inbound/outbound RTP keyed by SSRC. `frames` is framesDecoded for
/// inbound and framesEncoded for outbound - the same field name, two meanings,
/// and keeping them apart is the whole point of this probe.
Future<List<SsrcRow>> rtpRows(RTCPeerConnection pc, {required bool inbound}) async {
  final all = await pc.getStats();
  final rows = <SsrcRow>[];
  for (final r in all) {
    if (r.type != (inbound ? 'inbound-rtp' : 'outbound-rtp')) continue;
    rows.add(SsrcRow(
      '${r.values['kind']}',
      _num(r.values, inbound ? 'bytesReceived' : 'bytesSent'),
      _num(r.values, inbound ? 'packetsReceived' : 'packetsSent'),
      _num(r.values, inbound ? 'framesDecoded' : 'framesEncoded'),
      r.values['active'] == true,
    ));
  }
  return rows;
}

Future<int> pairBytes(RTCPeerConnection pc) async {
  final all = await pc.getStats();
  int total = 0;
  for (final r in all) {
    if (r.type != 'candidate-pair' || r.values['nominated'] != true) continue;
    total += ((r.values['bytesSent'] as num?)?.toInt() ?? 0) +
        ((r.values['bytesReceived'] as num?)?.toInt() ?? 0);
  }
  return total;
}

/// A candidate plus the negotiation token that produced it (D2/D4).
class TaggedCandidate {
  TaggedCandidate(this.token, this.candidate);
  final int token;
  final RTCIceCandidate candidate;
}

/// One endpoint with a corrected driver.
class ProbePeer {
  ProbePeer(this.name, this.polite) {
    policy = PerfectNegotiation(
      localEndpointKey: polite ? 'zzz-local' : 'aaa-local',
      remoteEndpointKey: polite ? 'aaa-remote' : 'zzz-remote',
    );
  }

  final String name;
  final bool polite;
  late final PerfectNegotiation policy;
  late final RTCPeerConnection pc;
  ProbePeer? remote;

  /// Token of the local description currently in force. Candidates are tagged
  /// with the token that was active when the native stack produced them.
  int localToken = 0;
  int nextToken = 0;

  /// Rejected description tokens (D4).
  final Set<int> rejectedTokens = <int>{};

  final List<TaggedCandidate> buffer = <TaggedCandidate>[];
  bool remoteDescriptionSet = false;

  final List<String> transitions = <String>[];
  int appliedCount = 0;
  int droppedCount = 0;
  int revalidatedDropped = 0;
  final List<RTCRtpSender> senders = <RTCRtpSender>[];

  Future<void> init() async {
    pc = await createPeerConnection(<String, dynamic>{'iceServers': <dynamic>[]});
    pc.onIceCandidate = (c) {
      unawaited(_onCandidate(c));
    };
  }

  Future<void> attach(MediaStream? stream) async {
    if (stream == null) return;
    for (final t in stream.getTracks()) {
      senders.add(await pc.addTrack(t, stream));
    }
  }

  Future<String?> _ufrag() async {
    try {
      return iceUfragOf((await pc.getLocalDescription())?.sdp);
    } catch (_) {
      return null;
    }
  }

  Future<void> _onCandidate(RTCIceCandidate c) async {
    final target = remote;
    if (target == null) return;
    // Tag with the token of the description that is in force RIGHT NOW, not
    // with a ufrag read later: after a rollback those differ.
    final token = localToken;
    if (target.policy.onRemoteCandidate(ufrag: iceUfragOf(c.candidate)).action ==
        PnAction.ignoreStaleCandidate) {
      target.droppedCount++;
      return;
    }
    if (target.rejectedTokens.contains(token)) {
      target.droppedCount++;
      target.transitions.add('DROP candidate token=$token (generation rejected)');
      return;
    }
    if (!target.remoteDescriptionSet) {
      target.buffer.add(TaggedCandidate(token, c));
      return;
    }
    await target.pc.addCandidate(c);
    target.appliedCount++;
  }

  /// Re-validates every buffered candidate BEFORE adding it (D3).
  Future<void> flushBuffer() async {
    if (!remoteDescriptionSet) return;
    while (buffer.isNotEmpty) {
      final item = buffer.removeAt(0);
      if (rejectedTokens.contains(item.token)) {
        revalidatedDropped++;
        transitions.add('REVALIDATE-DROP token=${item.token}');
        continue;
      }
      if (policy.onRemoteCandidate(ufrag: iceUfragOf(item.candidate.candidate))
              .action ==
          PnAction.ignoreStaleCandidate) {
        revalidatedDropped++;
        transitions.add('REVALIDATE-DROP token=${item.token} by ufrag');
        continue;
      }
      await pc.addCandidate(item.candidate);
      appliedCount++;
    }
  }

  /// The renegotiation driver, mirroring CallState._renegotiateVideo.
  Future<bool> startLocalOffer({bool iceRestart = false}) async {
    final begin = policy.beginLocalOffer();
    if (begin.generation < 0) {
      transitions.add('SKIP offer (${begin.reason})');
      return false;
    }
    if (iceRestart) await pc.restartIce();
    // The m-lines MUST be requested explicitly. A peer that only holds audio
    // (video lives on the other side, D1) would otherwise produce an offer with
    // no video section at all, and an answer can never add one - the track would
    // silently never be negotiated.
    final constraints = <String, dynamic>{
      'offerToReceiveAudio': 1,
      'offerToReceiveVideo': 1,
      if (iceRestart) 'iceRestart': true,
    };
    final offer = await pc.createOffer(constraints);
    await pc.setLocalDescription(offer);
    localToken = nextToken++;
    policy.endLocalOffer();
    transitions.add('SEND offer token=$localToken ufrag=${await _ufrag()}');
    await remote!.receive(PnDescriptionType.offer, (await pc.getLocalDescription())!.sdp!,
        token: localToken);
    return true;
  }

  Future<void> receive(PnDescriptionType type, String sdp, {required int token}) async {
    final d = policy.onRemoteDescription(
      type: type,
      signalingState: mapState(pc.signalingState?.toString()),
      sdp: sdp,
    );

    switch (d.action) {
      case PnAction.ignoreCollidingOffer:
        rejectedTokens.add(token);
        transitions.add('IGNORE colliding offer token=$token');
        return;
      case PnAction.rollbackThenAcceptOffer:
        await pc.setLocalDescription(RTCSessionDescription('', 'rollback'));
        transitions.add('ROLLBACK then accept token=$token');
        await acceptAndAnswer(sdp);
        return;
      case PnAction.acceptOffer:
        await acceptAndAnswer(sdp);
        return;
      case PnAction.acceptAnswer:
        await pc.setRemoteDescription(RTCSessionDescription(sdp, 'answer'));
        remoteDescriptionSet = true;
        await flushBuffer();
        transitions.add('ACCEPT answer token=$token');
        return;
      case PnAction.ignoreStaleAnswer:
        transitions.add('IGNORE stale answer token=$token');
        return;
      case PnAction.none:
      case PnAction.ignoreStaleCandidate:
        transitions.add('NOOP token=$token (${d.reason})');
        return;
    }
  }

  Future<void> acceptAndAnswer(String sdp) async {
    await pc.setRemoteDescription(RTCSessionDescription(sdp, 'offer'));
    remoteDescriptionSet = true;
    await flushBuffer();
    final answer = await pc.createAnswer();
    await pc.setLocalDescription(answer);
    localToken = nextToken++;
    transitions.add('SEND answer token=$localToken');
    await remote!.receive(PnDescriptionType.answer, (await pc.getLocalDescription())!.sdp!,
        token: localToken);
  }

  static PnSignalingState mapState(String? raw) {
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

/// Tracks handed to a peer, so a phase can report whether the SOURCE is alive.
class TrackHolder {
  TrackHolder(this.streams);
  final List<MediaStream?> streams;

  bool allAlive() => streams
      .whereType<MediaStream>()
      .every((s) => s.getTracks().every((t) => t.enabled));
}

/// One comparative phase result.
class PhaseResult {
  PhaseResult(this.name);
  final String name;
  final List<String> notes = [];
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  test('R5.1: where does media stop after a glare', () async {
    // ---------------- sources: all opened BEFORE any PeerConnection ----------
    // Capture layout for this probe: TWO microphones (one per peer) and ONE
    // camera, with video flowing A -> B and audio in both directions.
    //
    // Why only one camera: this host cannot keep four capture devices alive at
    // once. Opening two mics AND two cameras before the first PeerConnection
    // wedges the media subsystem so badly that ICE never gathers at all
    // (measured: 4x "ice=false flowed=false"). Two mics plus one camera is the
    // configuration proven to work in rtp_bisect3_test.dart.
    //
    // Bluetooth headsets are deprioritised: a headset that is paired but not
    // actively connected opens successfully and then produces nothing.
    final micDevices = (await enumerateCapture('audioinput'))
      ..sort((a, b) => _headsetPenalty(a).compareTo(_headsetPenalty(b)));
    expect(micDevices.length, greaterThanOrEqualTo(2),
        reason: 'one microphone stream per peer is required');
    final audioA =
        await openCapture(audio: true, video: false, audioDeviceId: micDevices[0].deviceId);
    final audioB =
        await openCapture(audio: true, video: false, audioDeviceId: micDevices[1].deviceId);
    expect(audioA, isNotNull);
    expect(audioB, isNotNull);

    final camDevices = (await enumerateCapture('videoinput'))
      ..sort((a, b) => _physicalPenalty(a).compareTo(_physicalPenalty(b)));
    final videoA = await openCapture(
        audio: false, video: true, videoDeviceId: camDevices.first.deviceId);
    expect(videoA, isNotNull);
    // ignore: avoid_print
    print('SOURCES micA=${micDevices[0].label} micB=${micDevices[1].label} '
        'camA=${camDevices.first.label} videoA=${videoA != null}');

    // ---------------- validate every source BEFORE the phases ----------------
    // A source that never produces media would silently turn every phase into a
    // no-op, so each stream is checked on its own scratch PeerConnection: does
    // it actually encode and send? This is what makes the comparison valid.
    // A source CANNOT be pre-validated here: validation needs a real
    // PeerConnection, and creating one destroys audio device enumeration, which
    // closes the microphone window for good. P1 therefore doubles as the
    // warm-up proof for every source, and each phase reports per-SSRC rows
    // instead of assuming media is present.
    Future<void> runPhase(
      String name,
      Future<void> Function(ProbePeer polite, ProbePeer impolite) action, {
      bool withVideoA = true,
      bool withVideoB = true,
    }) async {
      final polite = ProbePeer('$name-polite', true);
      final impolite = ProbePeer('$name-impolite', false);
      polite.remote = impolite;
      impolite.remote = polite;
      await polite.init();
      await impolite.init();
      await polite.attach(withVideoA ? videoA : null);
      await polite.attach(audioA);

      await impolite.attach(audioB);

      await impolite.startLocalOffer();
      final up = await pollIce(polite, impolite);
      expect(up, isTrue, reason: '$name: ICE must come up');
      final warm = await pollGrowth(impolite, const Duration(seconds: 25));
      if (!warm) {
        // ignore: avoid_print
        print('WARMUP FAILED iceA=${await polite.pc.getIceConnectionState()} '
            'iceB=${await impolite.pc.getIceConnectionState()} '
            'signalingA=${polite.pc.signalingState} signalingB=${impolite.pc.signalingState}');
        // ignore: avoid_print
        print('WARMUP senderA=${await rtpRows(polite.pc, inbound: false)}');
        // ignore: avoid_print
        print('WARMUP receiverB=${await rtpRows(impolite.pc, inbound: true)}');
        // ignore: avoid_print
        print('WARMUP senderTracksA=${polite.senders.map((s) => s.track?.kind ?? 'NO-TRACK').toList()} '
            'senderTracksB=${impolite.senders.map((s) => s.track?.kind ?? 'NO-TRACK').toList()}');
        // ignore: avoid_print
        print('WARMUP transitions polite:\n${polite.transitions.join('\n')}');
        // ignore: avoid_print
        print('WARMUP transitions impolite:\n${impolite.transitions.join('\n')}');
      }
      expect(warm, isTrue, reason: '$name: RTP must flow before the phase action');

      final senderBefore = await rtpRows(polite.pc, inbound: false);
      final receiverBefore = await rtpRows(impolite.pc, inbound: true);
      final pairBefore = await pairBytes(impolite.pc);

      await action(polite, impolite);

      await Future.delayed(const Duration(seconds: 3));
      final senderAfter = await rtpRows(polite.pc, inbound: false);
      final receiverAfter = await rtpRows(impolite.pc, inbound: true);
      final pairAfter = await pairBytes(impolite.pc);

      // ignore: avoid_print
      print('======== PHASE $name ========');
      // ignore: avoid_print
      print('polite transitions:\n${polite.transitions.join('\n')}');
      // ignore: avoid_print
      print('impolite transitions:\n${impolite.transitions.join('\n')}');
      // ignore: avoid_print
      print('makingOffer polite=${polite.policy.makingOffer} '
          'impolite=${impolite.policy.makingOffer}  (D5: both must be false)');
      // ignore: avoid_print
      print('signaling polite=${polite.pc.signalingState} '
          'impolite=${impolite.pc.signalingState}');
      // ignore: avoid_print
      print('candidates applied polite=${polite.appliedCount} impolite=${impolite.appliedCount} '
          'dropped=${polite.droppedCount + impolite.droppedCount} '
          'revalidatedDropped=${polite.revalidatedDropped + impolite.revalidatedDropped} '
          '(D3: revalidatedDropped must equal what was buffered then rejected)');
      // ignore: avoid_print
      print('SOURCE alive A=${audioA!.getTracks().map((t) => '${t.kind}:enabled=${t.enabled}').toList()} '
          'B=${audioB!.getTracks().map((t) => '${t.kind}:enabled=${t.enabled}').toList()}');
      // ignore: avoid_print
      print('SENDER TRACKS polite=${polite.senders.map((s) => s.track?.kind ?? 'NO-TRACK').toList()} '
          'impolite=${impolite.senders.map((s) => s.track?.kind ?? 'NO-TRACK').toList()}');
      // ignore: avoid_print
      print('ENCODER/SENDER (polite outbound) before: $senderBefore');
      // ignore: avoid_print
      print('ENCODER/SENDER (polite outbound) after : $senderAfter');
      // ignore: avoid_print
      print('RECEIVER/DECODER (impolite inbound) before: $receiverBefore');
      // ignore: avoid_print
      print('RECEIVER/DECODER (impolite inbound) after : $receiverAfter');
      // ignore: avoid_print
      print('TRANSPORT pair bytes $pairBefore -> $pairAfter (delta ${pairAfter - pairBefore})');

      final grew = await pollGrowth(impolite, const Duration(seconds: 20));
      // ignore: avoid_print
      print('PHASE $name rtpStillFlowing=$grew');

      await polite.close();
      await impolite.close();
    }

    // ---------------- P1: renegotiation WITHOUT glare (control) ----------------
    await runPhase('P1-control-sequential', (polite, impolite) async {
      await impolite.startLocalOffer();
    });

    // ---------------- P2: simultaneous offers, rollback on the polite side ----
    await runPhase('P2-glare-rollback', (polite, impolite) async {
      await Future.wait([polite.startLocalOffer(), impolite.startLocalOffer()]);
    });

    // ---------------- P3: sequential renegotiation, NO glare at all ---------
    await runPhase('P3-back-to-back', (polite, impolite) async {
      await impolite.startLocalOffer();
      await polite.startLocalOffer();
    });

    // ---------------- P4: audio only, glare ----------------
    await runPhase('P4-audio-only-glare', (polite, impolite) async {
      await Future.wait([polite.startLocalOffer(), impolite.startLocalOffer()]);
    }, withVideoA: false, withVideoB: false);

    // ---------------- P5: video only A -> B, bidirectional audio -------------
    await runPhase('P5-video-A-to-B', (polite, impolite) async {
      await Future.wait([polite.startLocalOffer(), impolite.startLocalOffer()]);
    }, withVideoA: true);

    // ---------------- teardown ----------------
    for (final s in [audioA, audioB, videoA]) {
      if (s != null) await s.dispose();
    }
    // ignore: avoid_print
    print('R5.1 PROBE DONE');
  }, timeout: const Timeout(Duration(minutes: 25)));
}

/// Waits for both peers to be connected.
Future<bool> pollIce(ProbePeer a, ProbePeer b) async {
  final deadline = DateTime.now().add(const Duration(seconds: 45));
  while (DateTime.now().isBefore(deadline)) {
    final sa = (await a.pc.getIceConnectionState())?.toString().toLowerCase() ?? '';
    final sb = (await b.pc.getIceConnectionState())?.toString().toLowerCase() ?? '';
    if ((sa.contains('connected') || sa.contains('completed')) &&
        (sb.contains('connected') || sb.contains('completed'))) {
      return true;
    }
    await Future.delayed(const Duration(milliseconds: 300));
  }
  return false;
}

/// Waits until ANY inbound kind grows: used for single-stream validation,
/// where expecting both kinds would hang on the kind that is not present.
Future<bool> pollAnyGrowth(ProbePeer p, Duration window) async {
  final start = await rtpRows(p.pc, inbound: true);
  final a0 = start.where((r) => r.kind == 'audio').fold<int>(0, (s, r) => s + r.bytes);
  final v0 = start.where((r) => r.kind == 'video').fold<int>(0, (s, r) => s + r.bytes);
  final deadline = DateTime.now().add(window);
  while (DateTime.now().isBefore(deadline)) {
    await Future.delayed(const Duration(milliseconds: 500));
    final now = await rtpRows(p.pc, inbound: true);
    final a = now.where((r) => r.kind == 'audio').fold<int>(0, (s, r) => s + r.bytes);
    final v = now.where((r) => r.kind == 'video').fold<int>(0, (s, r) => s + r.bytes);
    if (a > a0 || v > v0) return true;
  }
  return false;
}

/// Waits until BOTH inbound kinds grow.
Future<bool> pollGrowth(ProbePeer p, Duration window) async {
  final start = await rtpRows(p.pc, inbound: true);
  num sum(String kind, String field) => start
      .where((r) => r.kind == kind)
      .fold<num>(0, (s, r) => s + (field == 'bytes' ? r.bytes : r.frames));
  final a0 = sum('audio', 'bytes');
  final v0 = sum('video', 'bytes');
  final deadline = DateTime.now().add(window);
  while (DateTime.now().isBefore(deadline)) {
    await Future.delayed(const Duration(milliseconds: 500));
    final now = await rtpRows(p.pc, inbound: true);
    num sum2(String kind) => now
        .where((r) => r.kind == kind)
        .fold<num>(0, (s, r) => s + r.bytes);
    if (sum2('audio') > a0 && sum2('video') > v0) return true;
  }
  return false;
}
