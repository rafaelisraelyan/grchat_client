// STAGE 2C / R5.4 - SDP GLARE & RTP ROOT CAUSE.
//
// Experiments A, B and C each start from a FRESH PeerConnection pair, so the
// state left by one experiment can never influence the next - the R5.0 run
// could not make that claim.
//
// Media layout is the one proven stable in R5.3: two microphones, ONE camera,
// audio A<->B and video A->B, with A (the camera owner) as the offerer so the
// video m-line exists by construction. The legacy offerToReceiveVideo key is
// never used as evidence that an m-line was created.

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:integration_test/integration_test.dart';

import 'package:grchat_client/src/call/perfect_negotiation.dart';

import 'rtp_harness.dart';

final Stopwatch _clock = Stopwatch()..start();

String descOf(RTCSessionDescription? d, int Function(String)? len) {
  if (d == null) return 'none';
  final sdp = d.sdp ?? '';
  final ms = sdp.split('\r\n').where((l) => l.startsWith('m=')).toList();
  return '${d.type}[${ms.join(' ')}] ufrag=${iceUfragOf(sdp)}';
}

/// Authoritative description state from native getters, never from the
/// event-backed nullable field.
Future<String> state(RTCPeerConnection pc) async {
  Future<String> k(Future<RTCSessionDescription?> Function() f) async {
    try {
      return descOf(await f(), null);
    } catch (_) {
      return 'unset';
    }
  }

  return 'L=${await k(pc.getLocalDescription)} R=${await k(pc.getRemoteDescription)}';
}

/// Per-SSRC counters, key presence always explicit.
Future<List<String>> rtpRows(RTCPeerConnection pc, {required bool inbound}) async {
  final all = await pc.getStats();
  final out = <String>[];
  for (final r in all) {
    if (r.type != (inbound ? 'inbound-rtp' : 'outbound-rtp')) continue;
    String v(String k) => r.values.containsKey(k) ? '${r.values[k]}' : '<absent>';
    out.add('${r.values['kind']}/ssrc=${v('ssrc')} '
        'pkts=${v(inbound ? 'packetsReceived' : 'packetsSent')} '
        'bytes=${v(inbound ? 'bytesReceived' : 'bytesSent')} '
        'frames=${v(inbound ? 'framesDecoded' : 'framesEncoded')} '
        'active=${v('active')}');
  }
  return out;
}

Future<int> pairBytes(RTCPeerConnection pc) async {
  final all = await pc.getStats();
  int t = 0;
  for (final r in all) {
    if (r.type == 'candidate-pair' && r.values['nominated'] == true) {
      t += ((r.values['bytesSent'] as num?)?.toInt() ?? 0) +
          ((r.values['bytesReceived'] as num?)?.toInt() ?? 0);
    }
  }
  return t;
}

/// One endpoint of an experiment.
class Ep {
  Ep(this.name, this.polite) {
    policy = PerfectNegotiation(
      localEndpointKey: polite ? 'zzz' : 'aaa',
      remoteEndpointKey: polite ? 'aaa' : 'zzz',
    );
  }

  final String name;
  final bool polite;
  late final PerfectNegotiation policy;
  late final RTCPeerConnection pc;
  Ep? remote;
  final List<String> log = <String>[];
  final List<({int token, RTCIceCandidate c})> buffer = [];
  final Set<int> rejectedTokens = {};
  bool remoteSet = false;
  int token = 0;
  int nextToken = 0;
  final List<RTCRtpSender> senders = [];
  int applied = 0;
  int dropped = 0;

  void j(String op, int tk, String before, String after, String result) {
    log.add('t=${_clock.elapsedMilliseconds}ms $name $op token=$tk '
        'before[$before] after[$after] $result');
  }

  Future<void> init() async {
    pc = await createPeerConnection(<String, dynamic>{'iceServers': <dynamic>[]});
    pc.onIceCandidate = (c) => unawaited(onCand(c));
  }

  Future<void> attach(MediaStream? s) async {
    if (s == null) return;
    for (final t in s.getTracks()) {
      senders.add(await pc.addTrack(t, s));
    }
  }

  Future<void> onCand(RTCIceCandidate c) async {
    final r = remote;
    if (r == null) return;
    if (r.rejectedTokens.contains(token)) {
      r.dropped++;
      r.j('dropCandidate', token, '-', '-', 'rejectedGeneration');
      return;
    }
    if (!r.remoteSet) {
      r.buffer.add((token: token, c: c));
      return;
    }
    try {
      await r.pc.addCandidate(c);
      r.applied++;
    } catch (e) {
      r.dropped++;
      r.j('addCandidate', token, '-', '-', 'FAILED $e');
    }
  }

  /// Re-validates buffered candidates right before use: a candidate buffered
  /// before a collision may belong to the generation that lost.
  Future<void> flush() async {
    if (!remoteSet) return;
    while (buffer.isNotEmpty) {
      final i = buffer.removeAt(0);
      if (rejectedTokens.contains(i.token)) {
        dropped++;
        j('flushDrop', i.token, '-', '-', 'rejectedWhileBuffered');
        continue;
      }
      try {
        await pc.addCandidate(i.c);
        applied++;
      } catch (e) {
        dropped++;
        j('flushDrop', i.token, '-', '-', 'FAILED $e');
      }
    }
  }

  Future<bool> offer({int? forceToken}) async {
    final b = policy.beginLocalOffer();
    if (b.generation < 0) {
      j('createOffer', -1, await state(pc), '-', 'REFUSED ${b.reason}');
      return false;
    }
    final before = await state(pc);
    final o = await pc.createOffer(<String, dynamic>{});
    token = forceToken ?? (nextToken++);
    await pc.setLocalDescription(o);
    policy.endLocalOffer();
    j('createOffer+setLocal(offer)', token, before, await state(pc),
        'ufrag=${iceUfragOf(o.sdp)}');
    await remote!.receive(PnDescriptionType.offer, (await pc.getLocalDescription())!.sdp!,
        tkn: token);
    return true;
  }

  Future<void> receive(PnDescriptionType type, String sdp, {required int tkn}) async {
    final before = await state(pc);
    final d = policy.onRemoteDescription(
      type: type,
      signalingState: _map(pc.signalingState?.toString()),
      sdp: sdp,
    );
    switch (d.action) {
      case PnAction.ignoreCollidingOffer:
        rejectedTokens.add(tkn);
        j('setRemote(offer)', tkn, before, await state(pc),
            'IGNORED colliding (impolite) ufrag=${iceUfragOf(sdp)}');
        return;
      case PnAction.rollbackThenAcceptOffer:
        j('ROLLBACK-before', tkn, before, '-', 'pending rollback');
        await pc.setLocalDescription(RTCSessionDescription('', 'rollback'));
        j('ROLLBACK-after', tkn, '-', await state(pc), 'ok');
        await accept(sdp, tkn);
        return;
      case PnAction.acceptOffer:
        await accept(sdp, tkn);
        return;
      case PnAction.acceptAnswer:
        await pc.setRemoteDescription(RTCSessionDescription(sdp, 'answer'));
        remoteSet = true;
        await flush();
        j('setRemote(answer)', tkn, before, await state(pc), 'ok');
        return;
      case PnAction.ignoreStaleAnswer:
        j('setRemote(answer)', tkn, before, await state(pc),
            'IGNORED stale (${d.reason})');
        return;
      case PnAction.none:
      case PnAction.ignoreStaleCandidate:
        j('noop', tkn, before, await state(pc), d.reason);
        return;
    }
  }

  Future<void> accept(String sdp, int tkn) async {
    final before = await state(pc);
    await pc.setRemoteDescription(RTCSessionDescription(sdp, 'offer'));
    remoteSet = true;
    await flush();
    final a = await pc.createAnswer();
    await pc.setLocalDescription(a);
    token = nextToken++;
    j('setRemote(offer)+createAnswer+setLocal(answer)', tkn, before, await state(pc),
        'ok ufrag=${iceUfragOf(a.sdp)}');
    await remote!.receive(PnDescriptionType.answer, (await pc.getLocalDescription())!.sdp!,
        tkn: token);
  }

  static PnSignalingState _map(String? raw) {
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

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  test('R5.4: baseline vs renegotiation vs glare, each from a fresh pair',
      () async {
    // ---- sources, opened before ANY PeerConnection (R5.3 fact) ----
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

    /// Builds an independent, fully connected pair.
    Future<(Ep, Ep)> freshPair(String tag) async {
      final a = Ep('$tag-polite', true);
      final b = Ep('$tag-impolite', false);
      a.remote = b;
      b.remote = a;
      await a.init();
      await b.init();
      // Camera owner (A) also sends its microphone; B sends only audio.
      await a.attach(video);
      await a.attach(audioA);
      await b.attach(audioB);
      await a.offer(); // A offers, so the video m-line exists by construction.
      final deadline = DateTime.now().add(const Duration(seconds: 45));
      var up = false;
      while (DateTime.now().isBefore(deadline)) {
        final sa = '${await a.pc.getIceConnectionState()}'.toLowerCase();
        final sb = '${await b.pc.getIceConnectionState()}'.toLowerCase();
        if ((sa.contains('connected') || sa.contains('completed')) &&
            (sb.contains('connected') || sb.contains('completed'))) {
          up = true;
          break;
        }
        await Future.delayed(const Duration(milliseconds: 300));
      }
      expect(up, isTrue, reason: '$tag: ICE must come up');
      // Warm up: encoders need seconds before counters mean anything.
      final warm = DateTime.now().add(const Duration(seconds: 30));
      while (DateTime.now().isBefore(warm)) {
        final v = await rtpRows(b.pc, inbound: true);
        if (v.any((r) => r.contains('video'))) break;
        await Future.delayed(const Duration(milliseconds: 500));
      }
      return (a, b);
    }

    /// Waits for growth of BOTH kinds and returns the per-kind deltas.
    Future<(bool, String)> measure(Ep b, Duration window) async {
      final t0 = await rtpRows(b.pc, inbound: true);
      int bytesOf(List<String> rows, String kind) {
        for (final r in rows) {
          if (!r.startsWith('$kind/')) continue;
          final m = RegExp(r'bytes=(\S+)').firstMatch(r);
          final v = m?.group(1);
          if (v != null && v != '<absent>') return int.parse(v);
        }
        return -1;
      }

      int pktsOf(List<String> rows, String kind) {
        for (final r in rows) {
          if (!r.startsWith('$kind/')) continue;
          final m = RegExp(r'pkts=(\S+)').firstMatch(r);
          final v = m?.group(1);
          if (v != null && v != '<absent>') return int.parse(v);
        }
        return -1;
      }

      final a0 = bytesOf(t0, 'audio');
      final v0 = bytesOf(t0, 'video');
      final ap0 = pktsOf(t0, 'audio');
      final vp0 = pktsOf(t0, 'video');
      final end = DateTime.now().add(window);
      while (DateTime.now().isBefore(end)) {
        await Future.delayed(const Duration(milliseconds: 500));
        final now = await rtpRows(b.pc, inbound: true);
        if (bytesOf(now, 'audio') > a0 && bytesOf(now, 'video') > v0) {
          return (true, 'audio $ap0->${pktsOf(now, 'audio')} pkts '
              '(${bytesOf(t0, 'audio')}->${bytesOf(now, 'audio')} B), '
              'video $vp0->${pktsOf(now, 'video')} pkts '
              '(${bytesOf(t0, 'video')}->${bytesOf(now, 'video')} B)');
        }
      }
      final now = await rtpRows(b.pc, inbound: true);
      return (false, 'STALLED audio $ap0->${pktsOf(now, 'audio')} '
          'video $vp0->${pktsOf(now, 'video')} | rows=$now');
    }

    // ================= EXPERIMENT A: healthy baseline =================
    {
      final (a, b) = await freshPair('A');
      // ignore: avoid_print
      print('===== EXPERIMENT A: healthy baseline =====');
      // ignore: avoid_print
      print('A log:\n${a.log.join('\n')}');
      // ignore: avoid_print
      print('B log:\n${b.log.join('\n')}');
      // ignore: avoid_print
      print('A sender stats: ${await rtpRows(a.pc, inbound: false)}');
      // ignore: avoid_print
      print('B inbound stats: ${await rtpRows(b.pc, inbound: true)}');
      final (grew, detail) = await measure(b, const Duration(seconds: 12));
      // ignore: avoid_print
      print('A RESULT grew=$grew $detail');
      expect(grew, isTrue, reason: 'A: baseline must show growth on both kinds');
      await a.close();
      await b.close();
    }

    // ================= EXPERIMENT B: renegotiation WITHOUT glare =================
    {
      final (a, b) = await freshPair('B');
      // ignore: avoid_print
      print('===== EXPERIMENT B: renegotiation without glare =====');
      final before = await rtpRows(b.pc, inbound: true);
      final tracksBefore =
          a.senders.map((s) => s.track?.id ?? 'NO-TRACK').toSet();
      // Only the camera owner renegotiates: no local track is touched.
      await a.offer();
      await Future.delayed(const Duration(seconds: 2));
      // ignore: avoid_print
      print('B log after renegotiate:\n${b.log.join('\n')}');
      final (grew, detail) = await measure(b, const Duration(seconds: 15));
      // ignore: avoid_print
      print('B RESULT grew=$grew $detail');
      // ignore: avoid_print
      print('B stats before=$before after=${await rtpRows(b.pc, inbound: true)}');
      // ignore: avoid_print
      print('B pair bytes=${await pairBytes(b.pc)} '
          'tracks before=$tracksBefore after=${a.senders.map((s) => s.track?.id ?? 'NO-TRACK').toSet()}');
      expect(grew, isTrue,
          reason: 'B: renegotiation without glare must not stop RTP');
      await a.close();
      await b.close();
    }

    // ================= EXPERIMENT C: simultaneous offer WITH glare =================
    {
      final (a, b) = await freshPair('C');
      // ignore: avoid_print
      print('===== EXPERIMENT C: simultaneous offer (glare) =====');
      final tracksBefore =
          a.senders.map((s) => s.track?.id ?? 'NO-TRACK').toSet();
      // Truly simultaneous: neither awaits the other.
      await Future.wait([a.offer(), b.offer()]);
      await Future.delayed(const Duration(seconds: 2));
      // ignore: avoid_print
      print('C polite log:\n${a.log.join('\n')}');
      // ignore: avoid_print
      print('C impolite log:\n${b.log.join('\n')}');
      // ignore: avoid_print
      print('C state A=${await state(a.pc)}');
      // ignore: avoid_print
      print('C state B=${await state(b.pc)}');
      final (grew, detail) = await measure(b, const Duration(seconds: 20));
      // ignore: avoid_print
      print('C RESULT grew=$grew $detail');
      // ignore: avoid_print
      print('C A outbound=${await rtpRows(a.pc, inbound: false)}');
      // ignore: avoid_print
      print('C B inbound=${await rtpRows(b.pc, inbound: true)}');
      // ignore: avoid_print
      print('C pair bytes=${await pairBytes(b.pc)} '
          'iceB=${await b.pc.getIceConnectionState()}');
      // ignore: avoid_print
      print('C tracks before=$tracksBefore '
          'after=${a.senders.map((s) => s.track?.id ?? 'NO-TRACK').toSet()} '
          'candidates A=${a.applied}/${a.dropped} B=${b.applied}/${b.dropped}');
      expect(grew, isTrue,
          reason: 'C: real audio AND video RTP must keep flowing after glare');
      await a.close();
      await b.close();
    }

    for (final s in [video, audioA, audioB]) {
      await s!.dispose();
    }
    // ignore: avoid_print
    print('R5.4 DONE');
  }, timeout: const Timeout(Duration(minutes: 25)));
}