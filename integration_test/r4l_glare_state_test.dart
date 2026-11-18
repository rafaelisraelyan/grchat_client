// STAGE 2C.4l - deterministic native glare test with a REAL media baseline.
//
// Gate: no glare verdict is meaningful unless BOTH directions carried real
// audio RTP BEFORE the collision. Without that gate an "RTP after glare = 0"
// result cannot distinguish "rollback lost media" from "media never flowed".
//
// Native WebRTC + the existing PerfectNegotiation policy. NOT production
// CallState.

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:integration_test/integration_test.dart';

import 'package:grchat_client/src/call/perfect_negotiation.dart';

import 'rtp_harness.dart';

Future<String> st(RTCPeerConnection pc) async =>
    '${await pc.getSignalingState()}'
        .replaceAll('RTCSignalingState', '')
        .replaceAll('.', '')
        .toLowerCase();

/// One media direction, resolved from the stats report by kind + ssrc.
class Side {
  const Side({
    required this.outBytes,
    required this.outPackets,
    required this.inBytes,
    required this.inPackets,
    required this.inSsrc,
    required this.dirs,
  });

  final int outBytes;
  final int outPackets;
  final int inBytes;
  final int inPackets;
  final String inSsrc;
  final List<String> dirs;

  @override
  String toString() =>
      'out=${outBytes}B/${outPackets}p in=${inBytes}B/${inPackets}p '
      'ssrc=$inSsrc dirs=$dirs';
}

Future<List<String>> currentDirs(RTCPeerConnection pc) async {
  final out = <String>[];
  try {
    for (final t in await pc.getTransceivers()) {
      out.add('${t.mid}:${await t.getCurrentDirection()}');
    }
  } catch (e) {
    out.add('dirs-unavailable:${e.runtimeType}');
  }
  return out;
}

Future<Side> side(RTCPeerConnection pc) async {
  var ob = 0, op = 0, ib = 0, ip = 0;
  var ssrc = 'absent';
  for (final r in await pc.getStats()) {
    if (r.type == 'outbound-rtp' && r.values['kind'] == 'audio') {
      ob = ((r.values['bytesSent'] as num?) ?? 0).toInt();
      op = ((r.values['packetsSent'] as num?) ?? 0).toInt();
    } else if (r.type == 'inbound-rtp' && r.values['kind'] == 'audio') {
      ib = ((r.values['bytesReceived'] as num?) ?? 0).toInt();
      ip = ((r.values['packetsReceived'] as num?) ?? 0).toInt();
      ssrc = '${r.values['ssrc'] ?? 'absent'}';
    }
  }
  return Side(
      outBytes: ob,
      outPackets: op,
      inBytes: ib,
      inPackets: ip,
      inSsrc: ssrc,
      dirs: await currentDirs(pc));
}

/// Audio only: the direction letter of each m= line in an SDP.
List<String> mlineDirs(String? sdp) {
  if (sdp == null) return const [];
  final lines = sdp.split(RegExp(r'\r?\n'));
  final out = <String>[];
  var inAudio = false;
  for (final l in lines) {
    if (l.startsWith('m=')) {
      inAudio = l.startsWith('m=audio');
      out.add(inAudio ? 'audio:' : 'other:');
    } else if (inAudio && (l == 'a=sendrecv' || l == 'a=recvonly' ||
        l == 'a=sendonly' || l == 'a=inactive')) {
      out[out.length - 1] = '${out.last}${l.substring(2)}';
    }
  }
  return out;
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  late MediaStream micA;
  late MediaStream micB;
  late bool sameSource;

  setUpAll(() async {
    // Capture BEFORE any PeerConnection exists: on this runtime audioinput
    // disappears from enumerateDevices() after the first PC is created.
    final mics = await enumerateCapture('audioinput');
    // ignore: avoid_print
    print('BASELINE mics=${mics.length}');
    micA = (await openCapture(
        audio: true, video: false, audioDeviceId: mics.first.deviceId))!;
    sameSource = true;
    MediaStream? second;
    if (mics.length >= 2) {
      try {
        second = await openCapture(
            audio: true, video: false, audioDeviceId: mics[1].deviceId);
        sameSource = false;
      } catch (_) {
        second = null;
      }
    }
    if (second != null && second.getAudioTracks().isNotEmpty) {
      micB = second;
    } else {
      // Honest fallback: one physical source on this machine.
      micB = micA;
      sameSource = true;
    }
    // ignore: avoid_print
    print('BASELINE sameSource=$sameSource '
        'tracksA=${micA.getTracks().length} tracksB=${micB.getTracks().length}');
  });

  tearDownAll(() async {
    try {
      await micA.dispose();
      if (!sameSource) await micB.dispose();
    } catch (_) {}
  });

  Future<({RTCPeerConnection a, RTCPeerConnection b})> connectedPair() async {
    final cfg = <String, dynamic>{};
    final a = await createPeerConnection(cfg);
    final b = await createPeerConnection(cfg);
    for (final t in micA.getTracks()) {
      await a.addTrack(t, micA);
    }
    for (final t in micB.getTracks()) {
      await b.addTrack(t, micB);
    }
    final toB = <RTCIceCandidate>[];
    final toA = <RTCIceCandidate>[];
    var onB = false, onA = false;
    a.onIceCandidate = (c) => onB ? b.addCandidate(c) : toB.add(c);
    b.onIceCandidate = (c) => onA ? a.addCandidate(c) : toA.add(c);

    final offer = await a.createOffer({});
    await a.setLocalDescription(offer);
    await b.setRemoteDescription(RTCSessionDescription(offer.sdp!, 'offer'));
    onB = true;
    for (final c in List<RTCIceCandidate>.from(toB)) {
      await b.addCandidate(c);
    }
    toB.clear();
    final answer = await b.createAnswer();
    await b.setLocalDescription(answer);
    await a.setRemoteDescription(RTCSessionDescription(answer.sdp!, 'answer'));
    onA = true;
    for (final c in List<RTCIceCandidate>.from(toA)) {
      await a.addCandidate(c);
    }
    toA.clear();

    final deadline = DateTime.now().add(const Duration(seconds: 40));
    while (DateTime.now().isBefore(deadline)) {
      final ca = '${await a.getIceConnectionState()}'.toLowerCase();
      final cb = '${await b.getIceConnectionState()}'.toLowerCase();
      final sa = await st(a), sb = await st(b);
      if (sa == 'stable' &&
          sb == 'stable' &&
          (ca.contains('connected') || ca.contains('completed')) &&
          (cb.contains('connected') || cb.contains('completed'))) {
        break;
      }
      await Future.delayed(const Duration(milliseconds: 200));
    }
    return (a: a, b: b);
  }

  /// Real two-way audio must be flowing, otherwise the run is INVALID.
  Future<void> requireBaseline(RTCPeerConnection a, RTCPeerConnection b,
      String tag) async {
    final s0 = (a: await side(a), b: await side(b));
    await Future.delayed(const Duration(seconds: 3));
    final s1 = (a: await side(a), b: await side(b));
    // ignore: avoid_print
    print('BASELINE[$tag] A ${s0.a} -> ${s1.a}');
    // ignore: avoid_print
    print('BASELINE[$tag] B ${s0.b} -> ${s1.b}');
    // ignore: avoid_print
    print('BASELINE[$tag] sdp A local=${mlineDirs((await a.getLocalDescription())?.sdp)} '
        'remote=${mlineDirs((await a.getRemoteDescription())?.sdp)}');
    final ok = s1.a.inPackets > s0.a.inPackets &&
        s1.a.outPackets > s0.a.outPackets &&
        s1.b.inPackets > s0.b.inPackets &&
        s1.b.outPackets > s0.b.outPackets;
    if (!ok) {
      fail('BASELINE INVALID[$tag]: two-way audio RTP is not flowing, so no '
          'conclusion about glare is possible. A=$s0.a->${s1.a} '
          'B=$s0.b->${s1.b}');
    }
  }

  Future<void> requireGrowth(
      RTCPeerConnection a, RTCPeerConnection b, String tag) async {
    final s0 = (a: await side(a), b: await side(b));
    await Future.delayed(const Duration(seconds: 3));
    final s1 = (a: await side(a), b: await side(b));
    // ignore: avoid_print
    print('AFTER[$tag] A ${s0.a} -> ${s1.a}');
    // ignore: avoid_print
    print('AFTER[$tag] B ${s0.b} -> ${s1.b}');
    expect(s1.a.inPackets, greaterThan(s0.a.inPackets),
        reason: 'inbound audio must still flow to A after glare');
    expect(s1.b.inPackets, greaterThan(s0.b.inPackets),
        reason: 'inbound audio must still flow to B after glare');
  }

  test('glare A: both offers applied locally before collision', () async {
    final pair = await connectedPair();
    final a = pair.a, b = pair.b;
    await requireBaseline(a, b, 'A');

    final pnA = PerfectNegotiation(localEndpointKey: 'a', remoteEndpointKey: 'b');
    final pnB = PerfectNegotiation(localEndpointKey: 'b', remoteEndpointKey: 'a');

    final offerA = await a.createOffer({});
    pnA.beginLocalOffer();
    await a.setLocalDescription(offerA);
    final offerB = await b.createOffer({});
    pnB.beginLocalOffer();
    await b.setLocalDescription(offerB);

    expect(await st(a), 'havelocaloffer');
    expect(await st(b), 'havelocaloffer');

    final vA = pnA.onRemoteDescription(
        type: PnDescriptionType.offer,
        signalingState: PnSignalingState.haveLocalOffer,
        sdp: offerB.sdp!);
    final vB = pnB.onRemoteDescription(
        type: PnDescriptionType.offer,
        signalingState: PnSignalingState.haveLocalOffer,
        sdp: offerA.sdp!);
    // ignore: avoid_print
    print('A verdicts: verA=${vA.action.name} verB=${vB.action.name}');

    final politePc = vA.action == PnAction.rollbackThenAcceptOffer ? a : b;
    final impolitePc = identical(politePc, a) ? b : a;
    final politeOffer = identical(politePc, a) ? offerB : offerA;

    await politePc.setLocalDescription(RTCSessionDescription('', 'rollback'));
    expect(await st(politePc), 'stable', reason: 'rollback -> stable');
    await politePc
        .setRemoteDescription(RTCSessionDescription(politeOffer.sdp!, 'offer'));
    expect(await st(politePc), 'haveremoteoffer',
        reason: 'applied remote offer -> have-remote-offer');
    // ignore: avoid_print
    print('A polite dirs before answer: ${await currentDirs(politePc)}');
    final ans = await politePc.createAnswer();
    await politePc.setLocalDescription(ans);
    expect(await st(politePc), 'stable', reason: 'answer -> stable');
    // ignore: avoid_print
    print('A polite dirs after answer: ${await currentDirs(politePc)}');
    // ignore: avoid_print
    print('A polite answer sdp dirs: ${mlineDirs((await politePc.getLocalDescription())?.sdp)}');
    await impolitePc
        .setRemoteDescription(RTCSessionDescription(ans.sdp!, 'answer'));
    expect(await st(impolitePc), 'stable');

    await requireGrowth(a, b, 'A');
    await a.close();
    await b.close();
  }, timeout: const Timeout(Duration(minutes: 5)));

  test('glare B: remote offer between createOffer and setLocalDescription',
      () async {
    final pair = await connectedPair();
    final a = pair.a, b = pair.b;
    await requireBaseline(a, b, 'B');

    final offerA = await a.createOffer({});
    await a.setLocalDescription(offerA);
    expect(await st(a), 'havelocaloffer');
    final offerB = await b.createOffer({});
    expect(await st(b), 'stable', reason: 'B has not applied its offer yet');

    await b.setRemoteDescription(RTCSessionDescription(offerA.sdp!, 'offer'));
    final afterRemote = await st(b);
    // ignore: avoid_print
    print('B after incoming offer: $afterRemote');

    var deferredThrew = false;
    try {
      await b.setLocalDescription(offerB);
    } catch (_) {
      deferredThrew = true;
    }
    final afterDeferred = await st(b);
    // ignore: avoid_print
    print('B after deferred local offer: $afterDeferred threw=$deferredThrew');
    expect(afterDeferred, isNot('havelocaloffer'),
        reason: 'a stale deferred offer must not replace the accepted state');

    if (afterDeferred == 'haveremoteoffer') {
      final ans = await b.createAnswer();
      await b.setLocalDescription(ans);
      await a.setRemoteDescription(RTCSessionDescription(ans.sdp!, 'answer'));
    }
    expect(await st(b), 'stable');
    expect(await st(a), 'stable');
    await requireGrowth(a, b, 'B');
    await a.close();
    await b.close();
  }, timeout: const Timeout(Duration(minutes: 5)));

  test('glare C: reverse delivery order is symmetric', () async {
    final pair = await connectedPair();
    final a = pair.a, b = pair.b;
    await requireBaseline(a, b, 'C');

    final pnA = PerfectNegotiation(localEndpointKey: 'a', remoteEndpointKey: 'b');
    final pnB = PerfectNegotiation(localEndpointKey: 'b', remoteEndpointKey: 'a');

    final offerB = await b.createOffer({});
    pnB.beginLocalOffer();
    await b.setLocalDescription(offerB);
    final offerA = await a.createOffer({});
    pnA.beginLocalOffer();
    await a.setLocalDescription(offerA);

    final vB = pnB.onRemoteDescription(
        type: PnDescriptionType.offer,
        signalingState: PnSignalingState.haveLocalOffer,
        sdp: offerA.sdp!);
    final vA = pnA.onRemoteDescription(
        type: PnDescriptionType.offer,
        signalingState: PnSignalingState.haveLocalOffer,
        sdp: offerB.sdp!);
    // ignore: avoid_print
    print('C verdicts: verA=${vA.action.name} verB=${vB.action.name}');

    expect(
        [vA, vB]
            .where((v) => v.action == PnAction.rollbackThenAcceptOffer)
            .length,
        1,
        reason: 'exactly one polite side must roll back');
    expect(
        [vA, vB].where((v) => v.action == PnAction.ignoreCollidingOffer).length,
        1,
        reason: 'exactly one impolite side must ignore');
    await a.close();
    await b.close();
  }, timeout: const Timeout(Duration(minutes: 5)));
}