// Stage 2C - RTP BISECT #4: is the working configuration order-dependent?
//
// bisect3 proved split audio + shared video works (11620 / 52576 bytes both
// ways), but it was the FOURTH PeerConnection pair created in that process.
// rtp_media_test uses the identical configuration as the FIRST pair and gets
// zero ICE candidates.
//
// This file runs the proven configuration as the very first pair. If it fails
// here, the capability depends on prior PeerConnection creation (a warm-up
// effect); if it succeeds, the difference lies in rtp_media_test's own code.

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:integration_test/integration_test.dart';

import 'rtp_harness.dart';

const Duration _kIceBudget = Duration(seconds: 20);

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  test('bisect4: split audio + shared video as the FIRST pair', () async {
    // --- everything opened before any PeerConnection exists ---
    final micDevices = await enumerateCapture('audioinput');
    // ignore: avoid_print
    print('PRE audioinput=${micDevices.length}');

    final mics = <MediaStream>[];
    for (final d in micDevices.take(2)) {
      final s = await openCapture(audio: true, video: false, audioDeviceId: d.deviceId);
      if (s == null) {
        // ignore: avoid_print
        print('PRE mic open failed ${d.label}');
        continue;
      }
      mics.add(s);
    }
    final mic1 = mics.isNotEmpty ? mics[0] : null;
    final mic2 = mics.length > 1 ? mics[1] : null;

    final videoDevices = (await enumerateCapture('videoinput'))
      ..sort((x, y) => (x.deviceId.contains('usb#') ? 0 : 1)
          .compareTo(y.deviceId.contains('usb#') ? 0 : 1));
    MediaStream? video;
    if (videoDevices.isNotEmpty) {
      video = await openCapture(audio: false, video: true, videoDeviceId: videoDevices.first.deviceId);
    }
    // ignore: avoid_print
    print('PRE mic1=${mic1 != null} mic2=${mic2 != null} video=${video != null} '
        'device=${videoDevices.isEmpty ? 'none' : videoDevices.first.label}');

    final a = await MediaPeer.create('A');
    final b = await MediaPeer.create('B');
    a.wire();
    b.wire();
    if (mic1 != null) await a.attach(mic1);
    if (mic2 != null) await b.attach(mic2);
    if (video != null) {
      await a.attach(video);
      await b.attach(video);
    }

    await negotiate(a, b);
    final up = await waitForIceUp(a, b, timeout: _kIceBudget);
    await Future.delayed(const Duration(seconds: 4));

    final inbound = await statsOfType(b, 'inbound-rtp');
    final outbound = await statsOfType(a, 'outbound-rtp');
    // ignore: avoid_print
    print('RESULT up=$up A(received=${a.candidatesReceived} applied=${a.candidatesApplied} '
        'failed=${a.candidatesFailed} gather=${await a.pc.getIceGatheringState()}) '
        'B(received=${b.candidatesReceived} applied=${b.candidatesApplied})');
    // ignore: avoid_print
    print('MEDIA inbound=${inbound.map((r) => '${r.values['kind']}:${r.values['bytesReceived']}').toList()} '
        'outbound=${outbound.map((r) => '${r.values['kind']}:${r.values['bytesSent']}').toList()} '
        'remoteTracksA=${a.remoteTracks.map((t) => t.kind).toList()} '
        'remoteTracksB=${b.remoteTracks.map((t) => t.kind).toList()}');

    await a.close();
    await b.close();
    for (final s in [mic1, mic2, video]) {
      if (s != null) await s.dispose();
    }
    // ignore: avoid_print
    print('BISECT4 DONE');
  }, timeout: const Timeout(Duration(minutes: 8)));
}