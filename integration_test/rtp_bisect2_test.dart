// Stage 2C - RTP BISECT #2: isolate audio's effect on ICE gathering.
//
// Established facts so far:
//   * video-only pair                       -> ICE up, 2 candidates, remote video track
//   * microphone opened first, audio attached -> ICE never gathers (0 candidates)
//   * no media at all                        -> no m-lines, so no gathering (expected)
//
// The open question: is audio harmful because the MICROPHONE STREAM is open, or
// because an AUDIO TRACK is attached to the PeerConnection? The answer decides
// whether real audio RTP is verifiable here at all.
//
//   CASE control-video    video attached, microphone never opened   (known good)
//   CASE mic-open-only    microphone opened, audio NOT attached
//   CASE mic-attached     microphone opened AND audio attached
//
// Every case re-enumerates devices, because creating a PeerConnection destroys
// audioinput enumeration on this host.

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:integration_test/integration_test.dart';

import 'rtp_harness.dart';

const Duration _kIceBudget = Duration(seconds: 20);

Future<String> deviceSummary() async {
  final all = await navigator.mediaDevices.enumerateDevices();
  return 'videoinput=${all.where((d) => d.kind == 'videoinput').length} '
      'audioinput=${all.where((d) => d.kind == 'audioinput').length}';
}

Future<void> runCase(
  String label, {
  required bool openMic,
  required bool attachAudio,
  required bool attachVideo,
}) async {
  // ignore: avoid_print
  print('CASE $label START devices=${await deviceSummary()}');

  MediaStream? micStream;
  MediaSource? micDevice;
  if (openMic) {
    final devices = await enumerateCapture('audioinput');
    if (devices.isEmpty) {
      // ignore: avoid_print
      print('CASE $label no audio device visible');
    } else {
      micDevice = devices.first;
      micStream = await openCapture(audio: true, video: false, audioDeviceId: micDevice.deviceId);
      // ignore: avoid_print
      print('CASE $label mic opened=${micDevice.label} stream=${micStream != null} '
          'tracks=${micStream?.getTracks().length}');
    }
  }

  MediaStream? videoStream;
  if (attachVideo) {
    final devices = (await enumerateCapture('videoinput'))
      ..sort((x, y) => (x.deviceId.contains('usb#') ? 0 : 1)
          .compareTo(y.deviceId.contains('usb#') ? 0 : 1));
    if (devices.isEmpty) {
      // ignore: avoid_print
      print('CASE $label no video device visible');
    } else {
      videoStream =
          await openCapture(audio: false, video: true, videoDeviceId: devices.first.deviceId);
      // ignore: avoid_print
      print('CASE $label video opened=${devices.first.label} stream=${videoStream != null}');
    }
  }

  final a = await MediaPeer.create('A');
  final b = await MediaPeer.create('B');
  a.wire();
  b.wire();
  if (attachVideo && videoStream != null) {
    await a.attach(videoStream);
    await b.attach(videoStream);
  }
  if (attachAudio && micStream != null) {
    await a.attach(micStream);
    await b.attach(micStream);
  }

  try {
    await negotiate(a, b);
  } catch (e) {
    // ignore: avoid_print
    print('CASE $label NEGOTIATE THREW $e');
  }

  final up = await waitForIceUp(a, b, timeout: _kIceBudget);
  // Give any media a moment to produce stats.
  await Future.delayed(const Duration(seconds: 3));
  final inbound = await statsOfType(b, 'inbound-rtp');
  final outbound = await statsOfType(a, 'outbound-rtp');
  // ignore: avoid_print
  print('CASE $label RESULT up=$up '
      'A(received=${a.candidatesReceived} applied=${a.candidatesApplied} '
      'gather=${await a.pc.getIceGatheringState()} conn=${await a.pc.getConnectionState()}) '
      'B(received=${b.candidatesReceived} applied=${b.candidatesApplied})');
  // ignore: avoid_print
  print('CASE $label MEDIA '
      'inbound=${inbound.map((r) => '${r.values['kind']}:bytes=${r.values['bytesReceived']}').toList()} '
      'outbound=${outbound.map((r) => '${r.values['kind']}:bytes=${r.values['bytesSent']}').toList()} '
      'remoteTracks=${b.remoteTracks.map((t) => t.kind).toList()}');

  await a.close();
  await b.close();
  if (videoStream != null) await videoStream.dispose();
  if (micStream != null) await micStream.dispose();
  // ignore: avoid_print
  print('CASE $label END devices=${await deviceSummary()}');
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  test('bisect2: is audio harmful by being open or by being attached', () async {
    await runCase('control-video',
        openMic: false, attachAudio: false, attachVideo: true);
    await runCase('mic-open-only',
        openMic: true, attachAudio: false, attachVideo: true);
    await runCase('mic-attached',
        openMic: true, attachAudio: true, attachVideo: false);
    // ignore: avoid_print
    print('BISECT2 DONE');
  }, timeout: const Timeout(Duration(minutes: 10)));
}