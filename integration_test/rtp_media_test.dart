// Stage 2C.R1/R2 - REAL RTP FEASIBILITY (RTP-01..RTP-04).
//
// Proves, against the genuine native runtime, that:
//   RTP-01  a real remote audio track arrives
//   RTP-02  real inbound audio RTP counters grow
//   RTP-03  a real remote video track arrives
//   RTP-04  real inbound video RTP counters grow
//
// Shared setup lives in rtp_support.dart; the peer/candidate plumbing lives in
// rtp_harness.dart. This file holds one test on purpose - see rtp_support.dart
// for why each RTP test needs its own process.

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:integration_test/integration_test.dart';

import 'rtp_harness.dart';
import 'rtp_support.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  test('RTP-01..04: real remote tracks and growing inbound RTP', () async {
    final pair = await connectWorkingPair();
    addTearDown(pair.teardown);
    final a = pair.a;
    final b = pair.b;

    // ---- RTP-01 / RTP-03: remote tracks of the expected kind really arrived ----
    final bKinds = b.remoteTracks.map((t) => t.kind).toSet();
    final aKinds = a.remoteTracks.map((t) => t.kind).toSet();
    // ignore: avoid_print
    print('REMOTE TRACKS B=$bKinds A=$aKinds');
    expect(bKinds, containsAll(<String>['audio', 'video']),
        reason: 'answerer must receive real audio and video tracks');
    expect(aKinds, containsAll(<String>['audio', 'video']),
        reason: 'offerer must receive real audio and video tracks');

    // ---- RTP-02 / RTP-04: measured deltas on real counters ----
    final t0 = await inboundSnapshot(b);
    final outT0 = await statsOfType(a, 'outbound-rtp');
    await Future.delayed(const Duration(seconds: 3));
    final t1 = await inboundSnapshot(b);
    final outT1 = await statsOfType(a, 'outbound-rtp');

    num sum(List<StatsReport> rs, String key, String kind) => rs
        .where((r) => r.values['kind'] == kind)
        .fold<num>(0, (s, r) => s + (statValue(r, key) ?? 0));

    final dAudio = t1.audio - t0.audio;
    final dVideo = t1.video - t0.video;
    final dAudioOut = sum(outT1, 'bytesSent', 'audio') - sum(outT0, 'bytesSent', 'audio');
    final dVideoOut = sum(outT1, 'bytesSent', 'video') - sum(outT0, 'bytesSent', 'video');
    final dAudioPkts =
        sum(outT1, 'packetsSent', 'audio') - sum(outT0, 'packetsSent', 'audio');
    final dVideoPkts =
        sum(outT1, 'packetsSent', 'video') - sum(outT0, 'packetsSent', 'video');
    // ignore: avoid_print
    print('DELTA inbound audio=$dAudio video=$dVideo | '
        'outbound audio=$dAudioOut video=$dVideoOut | '
        'packetsSent audio=$dAudioPkts video=$dVideoPkts');

    // ignore: avoid_print
    print(await dumpEvidence(b, a, 'T1'));

    expect(dAudio, greaterThan(0), reason: 'real inbound audio RTP must grow');
    expect(dVideo, greaterThan(0), reason: 'real inbound video RTP must grow');
    expect(dAudioOut, greaterThan(0), reason: 'real outbound audio RTP must grow');
    expect(dVideoOut, greaterThan(0), reason: 'real outbound video RTP must grow');
    expect(dVideoPkts, greaterThan(0),
        reason: 'real outbound video packets must be sent');
  }, timeout: const Timeout(Duration(minutes: 15)));
}