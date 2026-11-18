// Stage 2C - RTP BISECT #3: does audio break ICE, and does it depend on how
// many senders consume the microphone track?
//
// Facts established so far:
//   * video-only pair  -> ICE up, real RTP both ways (36718 bytes each)
//   * reading stats immediately after ICE looks like "no frames" and is WRONG;
//     the encoder needs a couple of seconds, so always sample late
//   * enumerateDevices() reports zero audioinput after the FIRST
//     PeerConnection is created, so every microphone stream this test needs
//     must be opened before any PeerConnection exists
//
// Untested question: run4 attached an open microphone track to BOTH peers and
// ICE never gathered. Is that audio itself, or two senders sharing one track?
//
//   CASE audio-single   one microphone stream, attached to A only
//   CASE audio-shared   one microphone stream, attached to A and B
//   CASE audio-split    two microphone streams, one per peer
//   CASE split-plus-video  split audio plus video, the real call shape
//
// Each case prints state instead of asserting, so a surprising result stays
// visible rather than collapsing into a single failure.

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:integration_test/integration_test.dart';

import 'rtp_harness.dart';

const Duration _kIceBudget = Duration(seconds: 20);
/// Encoders need time: sampling immediately after ICE reports zero bytes and
/// looks like a dead camera.
const Duration _kMediaSettle = Duration(seconds: 4);

Future<String> deviceSummary() async {
  final all = await navigator.mediaDevices.enumerateDevices();
  return 'videoinput=${all.where((d) => d.kind == 'videoinput').length} '
      'audioinput=${all.where((d) => d.kind == 'audioinput').length}';
}

Future<void> runCase(
  String label, {
  required MediaStream? micA,
  required MediaStream? micB,
  required MediaStream? video,
}) async {
  // ignore: avoid_print
  print('CASE $label START devices=${await deviceSummary()}');

  final a = await MediaPeer.create('A');
  final b = await MediaPeer.create('B');
  a.wire();
  b.wire();
  try {
    if (micA != null) await a.attach(micA);
    if (micB != null) await b.attach(micB);
    if (video != null) {
      await a.attach(video);
      await b.attach(video);
    }
    await negotiate(a, b);
  } catch (e) {
    // ignore: avoid_print
    print('CASE $label SETUP THREW $e');
  }

  final up = await waitForIceUp(a, b, timeout: _kIceBudget);
  await Future.delayed(_kMediaSettle);
  final inbound = await statsOfType(b, 'inbound-rtp');
  final outbound = await statsOfType(a, 'outbound-rtp');
  // ignore: avoid_print
  print('CASE $label RESULT up=$up '
      'A(received=${a.candidatesReceived} applied=${a.candidatesApplied} failed=${a.candidatesFailed} '
      'gather=${await a.pc.getIceGatheringState()} conn=${await a.pc.getConnectionState()}) '
      'B(received=${b.candidatesReceived} applied=${b.candidatesApplied})');
  // ignore: avoid_print
  print('CASE $label MEDIA '
      'inbound=${inbound.map((r) => '${r.values['kind']}:bytes=${r.values['bytesReceived']}').toList()} '
      'outbound=${outbound.map((r) => '${r.values['kind']}:bytes=${r.values['bytesSent']}').toList()} '
      'remoteTracksA=${a.remoteTracks.map((t) => t.kind).toList()} '
      'remoteTracksB=${b.remoteTracks.map((t) => t.kind).toList()}');
  for (final r in inbound) {
    // ignore: avoid_print
    print('CASE $label INBOUND-RAW ${r.values.entries.map((e) => '${e.key}=${e.value}').toList()..sort()}');
  }

  await a.close();
  await b.close();
  // ignore: avoid_print
  print('CASE $label END devices=${await deviceSummary()}');
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  test('bisect3: audio vs ICE and sender sharing', () async {
    // ---- every microphone stream must exist before the first PeerConnection ----
    final micDevices = await enumerateCapture('audioinput');
    // ignore: avoid_print
    print('PRE devices=${await deviceSummary()} micCandidates=${micDevices.length}');

    MediaStream? mic1;
    MediaStream? mic2;
    for (final d in micDevices.take(2)) {
      final s = await openCapture(audio: true, video: false, audioDeviceId: d.deviceId);
      if (s == null) {
        // ignore: avoid_print
        print('PRE mic open failed ${d.label}');
        continue;
      }
      if (mic1 == null) {
        mic1 = s;
        // ignore: avoid_print
        print('PRE mic1=${d.label}');
      } else if (mic2 == null) {
        mic2 = s;
        // ignore: avoid_print
        print('PRE mic2=${d.label}');
      }
    }

    final videoDevices = (await enumerateCapture('videoinput'))
      ..sort((x, y) => (x.deviceId.contains('usb#') ? 0 : 1)
          .compareTo(y.deviceId.contains('usb#') ? 0 : 1));
    MediaStream? video;
    if (videoDevices.isNotEmpty) {
      video = await openCapture(
          audio: false, video: true, videoDeviceId: videoDevices.first.deviceId);
      // ignore: avoid_print
      print('PRE video=${videoDevices.first.label} stream=${video != null}');
    }

    await runCase('audio-single', micA: mic1, micB: null, video: null);
    await runCase('audio-shared', micA: mic1, micB: mic1, video: null);
    await runCase('audio-split', micA: mic1, micB: mic2, video: null);
    await runCase('split-plus-video', micA: mic1, micB: mic2, video: video);

    for (final s in [mic1, mic2, video]) {
      if (s != null) await s.dispose();
    }
    // ignore: avoid_print
    print('BISECT3 DONE');
  }, timeout: const Timeout(Duration(minutes: 12)));
}