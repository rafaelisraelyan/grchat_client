// Stage 2C.1 - FEASIBILITY PROOF / DIAGNOSTIC (native WebRTC runtime, no GUI).
//
// Runs inside the REAL Flutter engine on Windows via
//   flutter test -d windows integration_test/webrtc_poc_test.dart
// so RTCPeerConnection is the genuine plugin driving the genuine bundled
// libwebrtc. Nothing here is mocked.
//
// Design rule learned from the first failed attempt: dump EVERY piece of
// evidence BEFORE asserting anything, so a single run yields a diagnosis even
// when the run fails.
//
// Root-cause facts this harness corrects (all verified in plugin source):
//   * rtc_peerconnection_impl.dart:154-156 - `_iceConnectionState` is written
//     ONLY from a native 'iceConnectionState' event; it is never initialised in
//     the constructor. Reading the field after no event arrived yields `null`.
//     -> we poll the native truth via getIceConnectionState() instead.
//   * The previous run assigned `onIceCandidate` AFTER setLocalDescription, so
//     every candidate emitted during gathering was dropped on the floor.
//     -> all callbacks are wired before any SDP operation here.
//   * addCandidate on a peer without a remote description throws; the old
//     flush() swallowed it inside unawaited(). -> candidates are queued until
//     the target has a remote description, and errors are logged.
//
// Privacy: candidate addresses, ufrag/fingerprint and datachannel payloads are
// masked/redacted in all output. No secrets are printed.

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:integration_test/integration_test.dart';

const Duration _kGatherBudget = Duration(seconds: 30);
const Duration _kIceBudget = Duration(seconds: 45);

/// Hides the last octet of IPv4 addresses and any mDNS hostname.
String _maskAddress(String input) {
  var out = input.replaceAllMapped(
      RegExp(r'\b(\d{1,3}\.\d{1,3}\.\d{1,3})\.\d{1,3}\b'), (m) => '${m[1]}.x');
  out = out.replaceAllMapped(
      RegExp(r'\b[a-f0-9]{6,}(?:-[a-f0-9]{6,})*\.local\b'), (_) => '<mdns>.local');
  return out;
}

/// Keeps only the candidate "type" plus a masked address, dropping ports,
/// foundations and priorities that are irrelevant to the diagnosis.
String _candidateSummary(RTCIceCandidate c) {
  final raw = c.candidate ?? '';
  final type = RegExp(r'typ (\w+)').firstMatch(raw)?.group(1) ?? '?';
  final addr = RegExp(r'candidate:\S+ \d+ \S+ \d+ (\S+)').firstMatch(raw)?.group(1) ?? '?';
  return '$type@${_maskAddress(addr)}';
}

String _ufrag(String? sdp) {
  if (sdp == null) return '<none>';
  return RegExp(r'a=ice-ufrag:(\S+)').firstMatch(sdp)?.group(1) ?? '<none>';
}

String _redactUfrag(String? sdp) {
  final u = _ufrag(sdp);
  return u == '<none>' ? u : '${u.substring(0, u.length < 8 ? u.length : 8)}…';
}

/// Compact, privacy-safe SDP summary: which sections exist and whether the
/// mandatory fingerprint/ice attributes are present.
String _sdpSummary(String? sdp, String tag) {
  if (sdp == null) return 'SDP[$tag] null';
  final lines = sdp.split('\r\n').where((l) => l.trim().isNotEmpty);
  final sections = lines.where((l) => l.startsWith('m=')).toList();
  final buf = StringBuffer()
    ..writeln('SDP[$tag] bytes=${sdp.length} sections=${sections.length}');
  for (final s in sections) {
    buf.writeln('SDP[$tag]   $s');
  }
  buf.writeln('SDP[$tag] ice-ufrag=${_redactUfrag(sdp)} '
      'ice-pwd=${sdp.contains('a=ice-pwd:')} '
      'fingerprint=${sdp.contains('a=fingerprint:')}');
  return buf.toString();
}

/// One direction of candidate delivery: candidates are buffered until the
/// target peer has a remote description, then applied in order.
class _CandidateLink {
  _CandidateLink(this.name, this.targetName);

  final String name;
  final String targetName;
  final List<RTCIceCandidate> queue = [];
  final List<String> log = [];
  bool remoteSet = false;
  RTCPeerConnection? target;

  int applied = 0;
  int failed = 0;

  Future<void> offerCandidate(RTCIceCandidate c) async {
    queue.add(c);
    await _drain();
  }

  Future<void> _drain() async {
    if (!remoteSet || target == null) return;
    while (queue.isNotEmpty) {
      final c = queue.removeAt(0);
      try {
        await target!.addCandidate(c);
        applied++;
        log.add('applied ${_candidateSummary(c)}');
      } catch (e) {
        failed++;
        // Deliberately keep this visible: a silent candidate drop is exactly
        // the failure mode that made the first attempt undiagnosable.
        log.add('FAILED ${_candidateSummary(c)}: $e');
      }
    }
  }

  String describe() => '$name->$targetName received=${queue.length + applied + failed} '
      'applied=$applied failed=$failed pending=${queue.length}';
}

/// getLocalDescription() THROWS when no local description exists yet, so it
/// cannot be used as a null check. This helper reports instead of throwing.
Future<String> _safeLocalDescription(RTCPeerConnection pc) async {
  try {
    final d = await pc.getLocalDescription();
    return d == null ? 'null' : 'type=${d.type} bytes=${d.sdp?.length}';
  } catch (e) {
    return 'throws($e)';
  }
}

bool _isIceUp(RTCIceConnectionState? s) {
  final t = (s?.toString() ?? '').toLowerCase();
  return t.contains('connected') || t.contains('completed');
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  test('native WebRTC: ICE connect, DataChannel, ICE restart, rollback probe',
      () async {
    final events = <String>[];
    final candidatesA = <String>[];
    final candidatesB = <String>[];

    // Wired before any SDP operation: the 'didOpenDataChannel' native event is
    // delivered once and lost if nobody is listening yet.
    final received = Completer<String>();
    RTCDataChannel? bChannel;

    void wire(RTCPeerConnection pc, String tag) {
      pc.onSignalingState = (s) => events.add('$tag signaling=$s');
      pc.onIceGatheringState =
          (s) => events.add('$tag gathering=$s');
      pc.onIceConnectionState =
          (s) => events.add('$tag ice=$s');
      pc.onConnectionState = (s) => events.add('$tag conn=$s');
      pc.onIceCandidate = (c) => events.add('$tag cand=${_candidateSummary(c)}');
      pc.onRenegotiationNeeded = () => events.add('$tag renegotiation-needed');
    }

    // ---- 1. create both peers, wire callbacks, create the datachannel ----
    // iceServers is intentionally empty: this isolates host-candidate ICE from
    // any STUN/TURN reachability question, per the agreed diagnostic plan.
    final a = await createPeerConnection({'iceServers': []});
    final b = await createPeerConnection({'iceServers': []});
    wire(a, 'A');
    wire(b, 'B');

    b.onDataChannel = (channel) {
      bChannel = channel;
      events.add('B onDataChannel fired label=${channel.label}');
      channel.messageStream.listen((m) {
        if (!received.isCompleted) received.complete(m.text.toString());
      });
    };

    final toB = _CandidateLink('A', 'B')..target = b;
    final toA = _CandidateLink('B', 'A')..target = a;
    a.onIceCandidate = (c) {
      candidatesA.add(_candidateSummary(c));
      unawaited(toB.offerCandidate(c));
    };
    b.onIceCandidate = (c) {
      candidatesB.add(_candidateSummary(c));
      unawaited(toA.offerCandidate(c));
    };

    // DataChannel is created BEFORE createOffer so the offer certainly carries
    // an application section and ICE gathering is definitely triggered.
    final dc = await a.createDataChannel('poc', RTCDataChannelInit());
    events.add('A datachannel created label=${dc.label}');

    // ---- 2. offer / answer ----
    // Decisive probe #1: try a rollback while the peer is still STABLE (no
    // local offer yet). If the native stack parses the SDP type at all, it must
    // reject this with a wrong-state error. If it succeeds, the type string is
    // being ignored outright - which means "rollback" is an unvalidated no-op.
    String rollbackWhileStable = '<not-attempted>';
    try {
      await a.setLocalDescription(RTCSessionDescription('', 'rollback'));
      rollbackWhileStable = '<accepted>';
    } catch (e) {
      rollbackWhileStable = '$e';
    }
    // ignore: avoid_print
    print('--- ROLLBACK(stable) --- $rollbackWhileStable '
        'localDescription=${await _safeLocalDescription(a)}');

    final offer = await a.createOffer({'offerToReceiveAudio': 1});
    // ignore: avoid_print
    print(_sdpSummary(offer.sdp, 'offer'));
    await a.setLocalDescription(offer);
    await b.setRemoteDescription(offer);
    toA.remoteSet = true;
    await toA._drain();

    final answer = await b.createAnswer();
    // ignore: avoid_print
    print(_sdpSummary(answer.sdp, 'answer'));
    await b.setLocalDescription(answer);
    await a.setRemoteDescription(answer);
    toB.remoteSet = true;
    await toB._drain();

    // ---- 3. wait for gathering, then for ICE, polling the NATIVE state ----
    Future<void> waitGathering(RTCPeerConnection pc, String tag) async {
      final end = DateTime.now().add(_kGatherBudget);
      while (DateTime.now().isBefore(end)) {
        final g = await pc.getIceGatheringState();
        if ((g?.toString() ?? '').toLowerCase().contains('complete')) return;
        await Future.delayed(const Duration(milliseconds: 300));
      }
      // ignore: avoid_print
      print('TIMEOUT gathering $tag state=${await pc.getIceGatheringState()}');
    }

    await waitGathering(a, 'A');
    await waitGathering(b, 'B');

    var iceA = await a.getIceConnectionState();
    var iceB = await b.getIceConnectionState();
    final iceDeadline = DateTime.now().add(_kIceBudget);
    while (DateTime.now().isBefore(iceDeadline) &&
        !(_isIceUp(iceA) && _isIceUp(iceB))) {
      await Future.delayed(const Duration(milliseconds: 300));
      iceA = await a.getIceConnectionState();
      iceB = await b.getIceConnectionState();
    }

    final connA = await a.getConnectionState();
    final connB = await b.getConnectionState();

    // ---- 4. FULL EVIDENCE DUMP (before any assertion) ----
    // ignore: avoid_print
    print('--- EVENTS ---\n${events.join('\n')}');
    // ignore: avoid_print
    print('--- CANDIDATES --- A: ${candidatesA.length} ${candidatesA.toList()}');
    // ignore: avoid_print
    print('--- CANDIDATES --- B: ${candidatesB.length} ${candidatesB.toList()}');
    // ignore: avoid_print
    print('--- LINKS --- ${toA.describe()} | ${toB.describe()}');
    if (toA.log.isNotEmpty || toB.log.isNotEmpty) {
      // ignore: avoid_print
      print('--- LINK LOG ---\n${[...toA.log, ...toB.log].join('\n')}');
    }
    // ignore: avoid_print
    print('--- NATIVE STATE --- A ice=$iceA conn=$connA '
        'gather=${await a.getIceGatheringState()} sg=${a.signalingState}');
    // ignore: avoid_print
    print('--- NATIVE STATE --- B ice=$iceB conn=$connB '
        'gather=${await b.getIceGatheringState()} sg=${b.signalingState}');

    // ---- 5. DataChannel: send a REAL message over the negotiated path ----
    // Payload is a fixed non-secret probe string; only length + match is
    // printed, never the payload itself.
    const probe = 'poc-probe';
    var sendErrors = 0;
    final sendDeadline = DateTime.now().add(const Duration(seconds: 30));
    while (!received.isCompleted && DateTime.now().isBefore(sendDeadline)) {
      try {
        await dc.send(RTCDataChannelMessage(probe));
      } catch (e) {
        sendErrors++;
        events.add('A send failed: $e');
      }
      await Future.delayed(const Duration(milliseconds: 400));
    }
    final gotMessage = await received.future
        .timeout(const Duration(seconds: 2), onTimeout: () => '<none>');
    // ignore: avoid_print
    print('--- DATACHANNEL --- bChannel=${bChannel != null} '
        'sendErrors=$sendErrors received=${gotMessage.length} chars '
        'match=${gotMessage == probe}');
    // ignore: avoid_print
    print('--- EVENTS AFTER --- \n${events.join('\n')}');

    // ---- 6. selected candidate pair from real stats ----
    final statsA = await a.getStats();
    final statsB = await b.getStats();
    String pairDump(List<StatsReport> rs) => rs
        .where((r) => r.type == 'candidate-pair')
        .map((r) => 'state=${r.values['state']} '
            'nominated=${r.values['nominated']} '
            'bytesSent=${r.values['bytesSent']} bytesReceived=${r.values['bytesReceived']}')
        .join(' | ');
    // ignore: avoid_print
    print('--- STATS A --- kinds=${statsA.map((e) => e.type).toSet().toList()..sort()}');
    // ignore: avoid_print
    print('--- STATS A pairs --- ${pairDump(statsA)}');
    // ignore: avoid_print
    print('--- STATS B --- kinds=${statsB.map((e) => e.type).toSet().toList()..sort()}');
    // ignore: avoid_print
    print('--- STATS B pairs --- ${pairDump(statsB)}');

    // ---- 7. ICE restart: ufrag must change (new ICE generation) ----
    final ufragBefore = _redactUfrag(offer.sdp);
    String restartError = '<none>';
    String ufragAfter = '<not-attempted>';
    String iceAfterRestart = '<not-attempted>';
    try {
      await a.restartIce();
      final offer2 = await a.createOffer({'iceRestart': true});
      await a.setLocalDescription(offer2);
      await b.setRemoteDescription(offer2);
      toA.remoteSet = true;
      final answer2 = await b.createAnswer();
      await b.setLocalDescription(answer2);
      await a.setRemoteDescription(answer2);
      toB.remoteSet = true;
      ufragAfter = _redactUfrag(offer2.sdp);
      final end = DateTime.now().add(const Duration(seconds: 20));
      while (DateTime.now().isBefore(end)) {
        final s = await a.getIceConnectionState();
        iceAfterRestart = '$s';
        if (_isIceUp(s)) break;
        await Future.delayed(const Duration(milliseconds: 300));
      }
    } catch (e) {
      restartError = '$e';
    }
    // ignore: avoid_print
    print('--- ICE RESTART --- ufrag before=$ufragBefore after=$ufragAfter '
        'ice=$iceAfterRestart error=$restartError');

    // ---- 8. GLARE / ROLLBACK probe on the native runtime ----
    // A real rollback: A holds a pending local offer, then a rollback is applied.
    String glareApplyError = '<not-attempted>';
    String rollbackError = '<not-attempted>';
    String stateAfterRollback = '<not-attempted>';
    try {
      final glareOfferA = await a.createOffer({'iceRestart': true});
      await a.setLocalDescription(glareOfferA);
      // ignore: avoid_print
      print('--- GLARE --- A signaling=${a.signalingState}');

      // B independently offers -> genuine glare.
      final glareOfferB = await b.createOffer({'iceRestart': true});
      await b.setLocalDescription(glareOfferB);
      // ignore: avoid_print
      print('--- GLARE --- B signaling=${b.signalingState}');

      // Cross-apply A's offer while A itself has a pending local offer.
      try {
        await a.setRemoteDescription(glareOfferB);
        glareApplyError = '<accepted>';
      } catch (e) {
        glareApplyError = '$e';
      }
      // ignore: avoid_print
      print('--- GLARE --- cross-apply remote offer into have-local-offer: $glareApplyError');

      try {
        await a.setLocalDescription(RTCSessionDescription('', 'rollback'));
        rollbackError = '<accepted>';
      } catch (e) {
        rollbackError = '$e';
      }
      stateAfterRollback = await _safeLocalDescription(a);

      // Decisive probe #2: if the rollback really discarded A's pending offer,
      // A is now stable and MUST accept B's offer. A refusal quoting
      // "have-local-offer" proves the rollback was a silent no-op.
      String applyAfterRollback = '<not-attempted>';
      try {
        await a.setRemoteDescription(glareOfferB);
        applyAfterRollback = '<accepted>';
      } catch (e) {
        applyAfterRollback = '$e';
      }
      // ignore: avoid_print
      print('--- ROLLBACK --- apply remote offer afterwards: $applyAfterRollback');
    } catch (e) {
      rollbackError = 'setup failed: $e';
    }
    // ignore: avoid_print
    print('--- ROLLBACK --- error=$rollbackError after=$stateAfterRollback '
        'signalingField=${a.signalingState} (field is event-fed; '
        'native truth above is authoritative) '
        'ice=${await a.getIceConnectionState()}');

    await a.close();
    await b.close();

    // ---- 9. Assertions, only after all evidence is on record ----
    expect(_isIceUp(iceA) && _isIceUp(iceB), isTrue,
        reason: 'ICE must reach connected/completed on both peers');
    expect(toA.applied + toB.applied, greaterThan(0),
        reason: 'at least one candidate must be applied');
    expect(gotMessage == probe, isTrue,
        reason: 'a real message must traverse the datachannel');
    expect(ufragAfter != ufragBefore, isTrue,
        reason: 'ICE restart must produce a new ICE generation (new ufrag)');
  }, timeout: const Timeout(Duration(minutes: 8)));
}