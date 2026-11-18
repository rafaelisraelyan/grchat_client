// STAGE 2C / R5.2 - MINIMAL NATIVE RTP BASELINE (control, BEFORE any glare work).
//
// Purpose: restore diagnostic trust. Everything R5.1 produced was suspect
// because the transition journal was empty while media flowed. This file is
// written from scratch with no reuse of the R5/R5.1 drivers, so a mistake there
// cannot silently carry over.
//
// Step 1 - structured journal. Every SDP operation is recorded with:
//   elapsed ms, endpoint, operation, negotiation token, authoritative
//   description state before/after, and the outcome.
//   The authoritative state comes from getLocalDescription()/getRemoteDescription(),
//   NOT from pc.signalingState (event-fed, proven unreliable in this host) and
//   NOT from transceiver.currentDirection (throws UnimplementedError).
//   An assertion requires the expected operations to be present.
//
// Step 2 - raw stats. Every report keeps its original id, type and the full
//   values map, so field names are observed rather than assumed. Values are
//   read per report type from that type's own fields; nothing is defaulted to a
//   fabricated false - a missing key stays missing.
//
// Step 3 - the minimum real baseline: 2 microphones, 1 camera, audio A<->B and
//   video A->B, with inbound RTP growth on the receiver proven from real
//   RTCStatsReports.
//
// Nothing here is weakened or skipped: if RTP does not grow, the test fails.

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:integration_test/integration_test.dart';

import 'package:grchat_client/src/call/perfect_negotiation.dart';

import 'rtp_harness.dart';

final Stopwatch _clock = Stopwatch()..start();

/// One structured journal record.
class Step {
  Step(this.endpoint, this.op, this.token, this.before, this.after, this.result);

  final String endpoint;
  final String op;
  final int token;
  final String before;
  final String after;
  final String result;

  @override
  String toString() => 't=${_clock.elapsedMilliseconds}ms $endpoint $op '
      'token=$token before[$before] after[$after] $result';
}

final List<Step> journal = <Step>[];

void record(String endpoint, String op, int token, String before, String after,
    String result) {
  journal.add(Step(endpoint, op, token, before, after, result));
}

/// Authoritative signaling description state, read from the native getters.
/// These throw when unset, which is itself a fact worth reporting.
Future<String> descState(RTCPeerConnection pc) async {
  Future<String> kind(Future<RTCSessionDescription?> Function() f) async {
    try {
      final d = await f();
      return d == null ? 'none' : '${d.type}(${(d.sdp ?? '').length}b)';
    } catch (e) {
      return 'unset';
    }
  }

  return 'local=${await kind(pc.getLocalDescription)} '
      'remote=${await kind(pc.getRemoteDescription)}';
}

/// One raw stats report, preserving its native identity and every value.
class RawReport {
  RawReport(this.id, this.type, this.values);
  final String id;
  final String type;
  final Map<dynamic, dynamic> values;

  @override
  String toString() {
    final keys = values.keys.map((k) => '$k').toList()..sort();
    return '  id=$id type=$type '
        '{${keys.map((k) => '$k=${values[k]}').join(' ')}}';
  }
}

Future<List<RawReport>> rawStats(RTCPeerConnection pc) async {
  final all = await pc.getStats();
  return all.map((r) => RawReport(r.id, r.type, r.values)).toList();
}

/// Hides addresses in candidate reports: the report is proven to exist, but the
/// host's private addresses are not published.
String sanitize(RawReport r) {
  if (r.type != 'local-candidate' && r.type != 'remote-candidate') return r.toString();
  final masked = <dynamic, dynamic>{};
  r.values.forEach((k, v) {
    final s = '$v';
    masked[k] = s
        .replaceAllMapped(RegExp(r'\b(\d{1,3}\.\d{1,3}\.\d{1,3})\.\d{1,3}\b'),
            (m) => '${m[1]}.x')
        .replaceAllMapped(RegExp(r'[a-f0-9]{8,}(?:-[a-f0-9]{4,})*\.local'),
            (_) => '<mdns>.local');
  });
  return '  id=${r.id} type=${r.type} {${masked.entries.map((e) => '${e.key}=${e.value}').join(' ')}}';
}

/// Reads one numeric field. A missing key yields null and is NEVER coerced to 0.
num? field(RawReport r, String key) {
  final v = r.values[key];
  return v is num ? v : null;
}

/// Turns a missing report into a loud failure instead of a fabricated zero.
RawReport require(RawReport? r, String what) {
  if (r == null) fail('$what report is missing');
  return r;
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  test('R5.2: minimal native RTP baseline is trustworthy', () async {
    // ---------------- sources, opened before any PeerConnection ----------------
    final micDevices = (await enumerateCapture('audioinput'))
      ..sort((a, b) => (a.label.toLowerCase().contains('headset') || a.label.contains('Головной') ? 1 : 0)
          .compareTo(b.label.toLowerCase().contains('headset') || b.label.contains('Головной') ? 1 : 0));
    expect(micDevices.length, greaterThanOrEqualTo(2));
    final audioA =
        await openCapture(audio: true, video: false, audioDeviceId: micDevices[0].deviceId);
    final audioB =
        await openCapture(audio: true, video: false, audioDeviceId: micDevices[1].deviceId);
    final camDevices = (await enumerateCapture('videoinput'))
      ..sort((a, b) => (a.deviceId.contains('usb#') ? 0 : 1)
          .compareTo(b.deviceId.contains('usb#') ? 0 : 1));
    final videoA = await openCapture(
        audio: false, video: true, videoDeviceId: camDevices.first.deviceId);
    expect(audioA, isNotNull, reason: 'mic A');
    expect(audioB, isNotNull, reason: 'mic B');
    expect(videoA, isNotNull, reason: 'camera A');
    // ignore: avoid_print
    print('SOURCES micA=${micDevices[0].label} micB=${micDevices[1].label} '
        'camA=${camDevices.first.label}');

    // ---------------- peers ----------------
    final pa = await createPeerConnection(<String, dynamic>{'iceServers': <dynamic>[]});
    final pb = await createPeerConnection(<String, dynamic>{'iceServers': <dynamic>[]});

    // Candidates are tagged with the token of the description in force, and are
    // buffered until the target has a remote description.
    var tokenA = 0;
    var tokenB = 0;
    final bufferA = <({int token, RTCIceCandidate c})>[];
    final bufferB = <({int token, RTCIceCandidate c})>[];
    bool remoteDescOnA = false;
    bool remoteDescOnB = false;

    Future<void> flushA() async {
      while (remoteDescOnA && bufferA.isNotEmpty) {
        final i = bufferA.removeAt(0);
        try {
          await pa.addCandidate(i.c);
          record('A', 'addCandidate', i.token, '-', '-', 'ok');
        } catch (e) {
          record('A', 'addCandidate', i.token, '-', '-', 'FAILED $e');
        }
      }
    }

    Future<void> flushB() async {
      while (remoteDescOnB && bufferB.isNotEmpty) {
        final i = bufferB.removeAt(0);
        try {
          await pb.addCandidate(i.c);
          record('B', 'addCandidate', i.token, '-', '-', 'ok');
        } catch (e) {
          record('B', 'addCandidate', i.token, '-', '-', 'FAILED $e');
        }
      }
    }

    pa.onIceCandidate = (c) {
      if (remoteDescOnB) {
        unawaited(pb.addCandidate(c));
        record('A', 'emitCandidate', tokenA, '-', '-', 'forwarded');
      } else {
        bufferB.add((token: tokenA, c: c));
        record('A', 'emitCandidate', tokenA, '-', '-', 'buffered(${bufferB.length})');
      }
    };
    pb.onIceCandidate = (c) {
      if (remoteDescOnA) {
        unawaited(pa.addCandidate(c));
        record('B', 'emitCandidate', tokenB, '-', '-', 'forwarded');
      } else {
        bufferA.add((token: tokenB, c: c));
        record('B', 'emitCandidate', tokenB, '-', '-', 'buffered(${bufferA.length})');
      }
    };

    // ---------------- tracks: audio A<->B, video A->B ----------------
    final tracksA = <RTCRtpSender>[];
    for (final t in videoA!.getTracks()) {
      tracksA.add(await pa.addTrack(t, videoA));
    }
    for (final t in audioA!.getTracks()) {
      tracksA.add(await pa.addTrack(t, audioA));
    }
    final tracksB = <RTCRtpSender>[];
    for (final t in audioB!.getTracks()) {
      tracksB.add(await pb.addTrack(t, audioB));
    }
    // ignore: avoid_print
    print('TRACKS A=${tracksA.map((s) => s.track?.kind ?? 'NO-TRACK').toList()} '
        'B=${tracksB.map((s) => s.track?.kind ?? 'NO-TRACK').toList()}');

    // ---------------- negotiation, every step journalled ----------------
    // ---------------- negotiation, every step journalled ----------------
    // A holds the camera, so A offers. This is not cosmetic: the legacy
    // `offerToReceiveVideo` constraint does NOT create a video m-line in this
    // plugin version (measured: offer contained m=audio only), and an answer can
    // never add a section the offer lacked - so an offerer without a video
    // track can never get video negotiated at all.
    final beforeOffer = await descState(pa);
    final offer = await pa.createOffer(
        <String, dynamic>{'offerToReceiveAudio': 1, 'offerToReceiveVideo': 1});
    final offerSdp = offer.sdp ?? '';
    record('A', 'createOffer', 1, beforeOffer, await descState(pa),
        'sections=${offerSdp.split('\r\n').where((l) => l.startsWith('m=')).toList()}');
    expect(offerSdp.contains('m=audio'), isTrue, reason: 'offer must carry m=audio');
    expect(offerSdp.contains('m=video'), isTrue, reason: 'offer must carry m=video');
    final ufragOffer = iceUfragOf(offerSdp);

    await pa.setLocalDescription(offer);
    tokenA = 1;
    record('A', 'setLocalDescription(offer)', 1, '-', await descState(pa),
        'ufrag=$ufragOffer');

    await pb.setRemoteDescription(RTCSessionDescription(offerSdp, 'offer'));
    remoteDescOnB = true;
    record('B', 'setRemoteDescription(offer)', 1, '-', await descState(pb), 'ok');
    await flushB();

    final answer = await pb.createAnswer();
    final answerSdp = answer.sdp ?? '';
    record('B', 'createAnswer', 1, '-', await descState(pb),
        'sections=${answerSdp.split('\r\n').where((l) => l.startsWith('m=')).toList()}');
    expect(answerSdp.contains('m=audio'), isTrue, reason: 'answer must keep m=audio');
    expect(answerSdp.contains('m=video'), isTrue, reason: 'answer must keep m=video');
    // ignore: avoid_print
    print('SDP DIRECTIONS offer=${_directions(offerSdp)} answer=${_directions(answerSdp)}');

    await pb.setLocalDescription(answer);
    tokenB = 1;
    record('B', 'setLocalDescription(answer)', 1, '-', await descState(pb),
        'ufrag=${iceUfragOf(answerSdp)}');

    await pa.setRemoteDescription(RTCSessionDescription(answerSdp, 'answer'));
    remoteDescOnA = true;
    record('A', 'setRemoteDescription(answer)', 1, '-', await descState(pa), 'ok');
    await flushA();

    // ---- STEP 1 ASSERTION: the journal must actually contain the operations ----
    final ops = journal.map((s) => '${s.endpoint}:${s.op}').toSet();
    for (final required in <String>[
      'A:createOffer',
      'A:setLocalDescription(offer)',
      'B:setRemoteDescription(offer)',
      'B:createAnswer',
      'B:setLocalDescription(answer)',
      'A:setRemoteDescription(answer)',
    ]) {
      expect(ops, contains(required),
          reason: 'journal must record $required; got $ops');
    }
    expect(journal.length, greaterThan(6), reason: 'journal must not be empty');
    // ignore: avoid_print
    print('JOURNAL\n${journal.join('\n')}');

    // ---------------- ICE ----------------
    var iceA = '';
    var iceB = '';
    final iceDeadline = DateTime.now().add(const Duration(seconds: 45));
    while (DateTime.now().isBefore(iceDeadline)) {
      iceA = '${await pa.getIceConnectionState()}';
      iceB = '${await pb.getIceConnectionState()}';
      if (iceA.toLowerCase().contains('connected') ||
          iceA.toLowerCase().contains('completed')) {
        if (iceB.toLowerCase().contains('connected') ||
            iceB.toLowerCase().contains('completed')) {
          break;
        }
      }
      await Future.delayed(const Duration(milliseconds: 300));
    }
    // ignore: avoid_print
    print('ICE A=$iceA B=$iceB gatherA=${await pa.getIceGatheringState()} '
        'gatherB=${await pb.getIceGatheringState()}');
    expect(iceA.toLowerCase(), anyOf(contains('connected'), contains('completed')),
        reason: 'ICE A');
    expect(iceB.toLowerCase(), anyOf(contains('connected'), contains('completed')),
        reason: 'ICE B');

    // ---------------- STEP 2: raw stats before and after ----------------
    Future<void> dump(String phase) async {
      final ra = await rawStats(pa);
      final rb = await rawStats(pb);
      // ignore: avoid_print
      print('=== RAW STATS [$phase] A types=${ra.map((r) => r.type).toSet().toList()..sort()}');
      for (final r in ra) {
        // ignore: avoid_print
        print(sanitize(r));
      }
      // ignore: avoid_print
      print('=== RAW STATS [$phase] B types=${rb.map((r) => r.type).toSet().toList()..sort()}');
      for (final r in rb) {
        // ignore: avoid_print
        print(sanitize(r));
      }
    }

    Future<RawReport?> find(List<RawReport> rs, String type, String kind) async {
      for (final r in rs) {
        if (r.type == type && r.values['kind'] == kind) return r;
      }
      return null;
    }

    // Media needs a moment to start: reading immediately shows zeros and looks
    // exactly like a dead source.
    final warmDeadline = DateTime.now().add(const Duration(seconds: 30));
    var audioIn0 = 0;
    var videoIn0 = 0;
    while (DateTime.now().isBefore(warmDeadline)) {
      final rb = await rawStats(pb);
      final a = await find(rb, 'inbound-rtp', 'audio');
      final v = await find(rb, 'inbound-rtp', 'video');
      audioIn0 = a == null ? 0 : (field(a, 'bytesReceived') ?? 0).toInt();
      videoIn0 = v == null ? 0 : (field(v, 'bytesReceived') ?? 0).toInt();
      if (audioIn0 > 0 && videoIn0 > 0) break;
      await Future.delayed(const Duration(milliseconds: 500));
    }
    await dump('T0-after-warmup');

    final rb0 = await rawStats(pb);
    final aIn0 = await find(rb0, 'inbound-rtp', 'audio');
    final vIn0 = await find(rb0, 'inbound-rtp', 'video');

    await Future.delayed(const Duration(seconds: 4));

    final rb1 = await rawStats(pb);
    final ra1 = await rawStats(pa);
    await dump('T1');

    final aIn1 = await find(rb1, 'inbound-rtp', 'audio');
    final vIn1 = await find(rb1, 'inbound-rtp', 'video');

    // ignore: avoid_print
    print('INBOUND audio T0=$aIn0');
    // ignore: avoid_print
    print('INBOUND audio T1=$aIn1');
    // ignore: avoid_print
    print('INBOUND video T0=$vIn0');
    // ignore: avoid_print
    print('INBOUND video T1=$vIn1');
    // ignore: avoid_print
    print('OUTBOUND A T1=${ra1.where((r) => r.type == 'outbound-rtp').toList()}');

    // ---- Step 2 finding: are bytes and packets read from distinct fields? ----
    if (aIn0 != null && aIn1 != null) {
      // ignore: avoid_print
      print('FIELD CHECK audio bytesReceived '
          '${field(aIn0, 'bytesReceived')} -> ${field(aIn1, 'bytesReceived')} | '
          'packetsReceived ${field(aIn0, 'packetsReceived')} -> '
          '${field(aIn1, 'packetsReceived')} | '
          'headerBytesReceived ${field(aIn1, 'headerBytesReceived')} | '
          'hasActive=${aIn1.values.containsKey('active')} '
          'active=${aIn1.values['active']}');
    }

    // ---------------- assertions: real inbound RTP on both kinds ----------------
    expect(aIn1, isNotNull, reason: 'real inbound audio RTP report must exist');
    expect(vIn1, isNotNull, reason: 'real inbound video RTP report must exist');
    final aIn = require(aIn1, 'inbound audio');
    final vIn = require(vIn1, 'inbound video');
    final aInBase = aIn0 ?? aIn;
    final vInBase = vIn0 ?? vIn;
    final dAudioBytes =
        (field(aIn, 'bytesReceived') ?? 0) - (field(aInBase, 'bytesReceived') ?? 0);
    final dAudioPackets =
        (field(aIn, 'packetsReceived') ?? 0) - (field(aInBase, 'packetsReceived') ?? 0);
    final dVideoBytes =
        (field(vIn, 'bytesReceived') ?? 0) - (field(vInBase, 'bytesReceived') ?? 0);
    final dVideoPackets =
        (field(vIn, 'packetsReceived') ?? 0) - (field(vInBase, 'packetsReceived') ?? 0);
    // ignore: avoid_print
    print('DELTA audio bytes=$dAudioBytes packets=$dAudioPackets | '
        'video bytes=$dVideoBytes packets=$dVideoPackets');

    expect(dAudioBytes, greaterThan(0), reason: 'inbound audio bytes must grow');
    expect(dAudioPackets, greaterThan(0), reason: 'inbound audio packets must grow');
    expect(dVideoBytes, greaterThan(0), reason: 'inbound video bytes must grow');
    expect(dVideoPackets, greaterThan(0), reason: 'inbound video packets must grow');
    // Reality check, based on what this runtime actually reports rather than on a
    // field I assumed: real codec packets are multi-byte. R5.1 saw
    // bytes == packets == 1247, which is the signature of a non-media stream.
    // Here bytes are an order of magnitude above packets, and the header bytes
    // counter is present, which only a parsed RTP stream produces.
    final aBytes = field(aIn, 'bytesReceived') ?? 0;
    final aPackets = field(aIn, 'packetsReceived') ?? 0;
    expect(aBytes, greaterThan(aPackets),
        reason: 'real RTP packets are multi-byte; bytes must exceed packets');
    expect(field(aIn, 'headerBytesReceived'), isNotNull,
        reason: 'headerBytesReceived proves the packets were parsed as RTP');
    expect(aIn.values.containsKey('active'), isFalse,
        reason: 'active is not reported for inbound-rtp in this runtime; a '
            'previous driver defaulted it to false, which was fabricated');
    final fDec = field(vIn, 'framesDecoded');
    if (fDec != null) {
      final fDec0 = field(vInBase, 'framesDecoded') ?? 0;
      // ignore: avoid_print
      print('FRAMES decoded $fDec0 -> $fDec');
      expect(fDec, greaterThan(fDec0), reason: 'decoded video frames must grow');
    }

    // ---------------- full teardown, so the run is repeatable ----------------
    pa.onIceCandidate = null;
    pb.onIceCandidate = null;
    await pa.close();
    await pb.close();
    for (final s in [videoA, audioA, audioB]) {
      await s.dispose();
    }
    // ignore: avoid_print
    print('R5.2 BASELINE DONE');
  }, timeout: const Timeout(Duration(minutes: 15)));
}

/// Media direction per m-line, read from SDP because currentDirection throws.
String _directions(String sdp) {
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
}
