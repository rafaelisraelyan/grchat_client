// Stage 2C - RTP BISECT DIAGNOSTIC.
//
// Facts established by the previous run that this file explains:
//   * with real capture attached, ICE gathering never started at all
//     (gather=New, conn=New, 0 candidates emitted, 0 errors);
//   * after the first attempt that opened a MICROPHONE, audioinput devices
//     disappeared from enumerateDevices() for the rest of the process.
//
// Both symptoms point at the capture layer, not at signaling. This bisect runs
// three isolated cases to find which media kind is responsible:
//   CASE 0  no media at all      -> is negotiation alone healthy?
//   CASE 1  video only           -> does camera capture keep ICE alive?
//   CASE 2  audio only           -> does microphone capture break it?
//
// Each case gets fresh PeerConnections and re-enumerates devices, because the
// failure mode includes permanent loss of audio device enumeration.

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:integration_test/integration_test.dart';

import 'rtp_harness.dart';

const Duration _kIceBudget = Duration(seconds: 20);

Future<String> deviceSummary() async {
  final all = await navigator.mediaDevices.enumerateDevices();
  final v = all.where((d) => d.kind == 'videoinput').length;
  final a = all.where((d) => d.kind == 'audioinput').length;
  return 'videoinput=$v audioinput=$a';
}

/// Runs one case and reports everything without asserting anything: this is a
/// diagnostic, and an assertion here would hide the very state we came to see.
Future<void> runCase(String label, {required bool withVideo, required bool withAudio}) async {
  // ignore: avoid_print
  print('CASE $label START devices=${await deviceSummary()}');

  MediaStream? stream;
  MediaSource? videoDevice;
  MediaSource? audioDevice;

  if (withVideo) {
    final devices = (await enumerateCapture('videoinput'))
      ..sort((x, y) => (x.deviceId.contains('usb#') ? 0 : 1)
          .compareTo(y.deviceId.contains('usb#') ? 0 : 1));
    if (devices.isEmpty) {
      // ignore: avoid_print
      print('CASE $label no video device');
    } else {
      videoDevice = devices.first;
      stream = await openCapture(audio: false, video: true, videoDeviceId: videoDevice.deviceId);
      // ignore: avoid_print
      print('CASE $label opened video=${videoDevice.label} stream=${stream != null}');
    }
  } else if (withAudio) {
    final devices = await enumerateCapture('audioinput');
    if (devices.isEmpty) {
      // ignore: avoid_print
      print('CASE $label no audio device visible');
    } else {
      audioDevice = devices.first;
      stream = await openCapture(audio: true, video: false, audioDeviceId: audioDevice.deviceId);
      // ignore: avoid_print
      print('CASE $label opened audio=${audioDevice.label} stream=${stream != null}');
    }
  }

  final a = await MediaPeer.create('A');
  final b = await MediaPeer.create('B');
  a.wire();
  b.wire();
  if (stream != null) {
    await a.attach(stream);
    await b.attach(stream);
  }

  final sw = Stopwatch()..start();
  try {
    await negotiate(a, b);
    // ignore: avoid_print
    print('CASE $label negotiated in ${sw.elapsedMilliseconds}ms');
  } catch (e) {
    // ignore: avoid_print
    print('CASE $label NEGOTIATE THREW $e');
    await a.close();
    await b.close();
    if (stream != null) await stream.dispose();
    return;
  }

  final up = await waitForIceUp(a, b, timeout: _kIceBudget);
  final inbound = await statsOfType(b, 'inbound-rtp');
  final outbound = await statsOfType(a, 'outbound-rtp');
  // ignore: avoid_print
  print('CASE $label RESULT up=$up '
      'A(received=${a.candidatesReceived} applied=${a.candidatesApplied} failed=${a.candidatesFailed} '
      'gather=${await a.pc.getIceGatheringState()} conn=${await a.pc.getConnectionState()}) '
      'B(received=${b.candidatesReceived} applied=${b.candidatesApplied} failed=${b.candidatesFailed} '
      'gather=${await b.pc.getIceGatheringState()} conn=${await b.pc.getConnectionState()})');
  // ignore: avoid_print
  print('CASE $label MEDIA inbound=${inbound.map((r) => '${r.values['kind']}:${r.values['bytesReceived']}').toList()} '
      'outbound=${outbound.map((r) => '${r.values['kind']}:${r.values['bytesSent']}').toList()} '
      'remoteTracks=${b.remoteTracks.map((t) => t.kind).toList()}');
  if (inbound.isNotEmpty) {
    for (final r in inbound) {
      // ignore: avoid_print
      print('CASE $label INBOUND-RAW ${r.values.entries.map((e) => '${e.key}=${e.value}').toList()..sort()}');
    }
  }

  await a.close();
  await b.close();
  if (stream != null) await stream.dispose();
  // ignore: avoid_print
  print('CASE $label END devices=${await deviceSummary()}');
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  test('bisect: which media kind breaks ICE gathering', () async {
    await runCase('0-no-media', withVideo: false, withAudio: false);
    await runCase('1-video-only', withVideo: true, withAudio: false);
    await runCase('2-audio-only', withVideo: false, withAudio: true);
    await runCase('3-audio-then-video', withVideo: false, withAudio: true);
    // ignore: avoid_print
    print('BISECT DONE');
  }, timeout: const Timeout(Duration(minutes: 10)));
}