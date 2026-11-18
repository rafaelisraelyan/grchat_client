// STAGE 2C / R4.2b - corrected gathering isolation.
//
// CORRECTION of r4_gathering_isolation_test: that probe created an offer
// WITHOUT attaching any media, so the SDP carried no m-line, so no ICE
// transport was created, so gathering never started. Zero candidates there said
// nothing about the plugin. This file repeats the isolation WITH real tracks,
// which is what R5.4 proved is required on this host.
//
//   CFG-A  no servers, policy all  -> baseline host gathering
//   CFG-B  local TURN, policy all  -> do relay candidates appear at all?
//   CFG-C  local TURN, policy relay-> what the route proof actually uses
//
// Server-side TURN counters are the ground truth: did any packet arrive?
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:integration_test/integration_test.dart';

import 'rtp_harness.dart';

const String turnUrl = 'turn:127.0.0.1:34780?transport=udp';

/// One connection with real media, probed for candidate types.
Future<Map<String, int>> probeWithMedia(
  String label,
  Map<String, dynamic> cfg,
  MediaStream audio,
  MediaStream video,
) async {
  final pc = await createPeerConnection(cfg);
  final types = <String, int>{};
  var gatherEnd = false;

  pc.onIceGatheringState = (s) {
    final t = s.toString().toLowerCase();
    // ignore: avoid_print
    print('GATHER $label $t');
    if (t.contains('complete')) gatherEnd = true;
  };
  pc.onIceCandidate = (c) {
    final raw = c.candidate ?? '';
    if (raw.isEmpty) return;
    final t = RegExp(r'typ (\w+)').firstMatch(raw)?.group(1) ?? '?';
    types[t] = (types[t] ?? 0) + 1;
  };

  for (final t in video.getTracks()) {
    await pc.addTrack(t, video);
  }
  for (final t in audio.getTracks()) {
    await pc.addTrack(t, audio);
  }

  // A offers and A holds the camera, so the video m-line exists by
  // construction. The legacy offerToReceive* constraints do NOT create one.
  final offer = await pc.createOffer(<String, dynamic>{});
  final sdp = offer.sdp ?? '';
  final sections =
      sdp.split('\r\n').where((l) => l.startsWith('m=')).toList();
  // ignore: avoid_print
  print('PROBE $label offerSections=$sections');

  await pc.setLocalDescription(offer);
  final deadline = DateTime.now().add(const Duration(seconds: 25));
  while (DateTime.now().isBefore(deadline) && !gatherEnd) {
    await Future.delayed(const Duration(milliseconds: 200));
  }
  await Future.delayed(const Duration(seconds: 1));

  var sdpCandidates = 0;
  try {
    final d = await pc.getLocalDescription();
    sdpCandidates = (d?.sdp ?? '')
        .split('\r\n')
        .where((l) => l.startsWith('a=candidate'))
        .length;
  } catch (_) {
    sdpCandidates = -1;
  }
  // ignore: avoid_print
  print('PROBE $label types=$types gatherComplete=$gatherEnd '
      'candidatesInLocalSdp=$sdpCandidates');
  await pc.close();
  return types;
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  test('R4.2b: gathering isolation with real media', () async {
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

    final turnServers = [
      {
        'urls': turnUrl,
        'username': 'grchat',
        'credential': 'grchat-r4-testonly',
      }
    ];

    // CFG-A: baseline. R5.4 showed host candidates here.
    final a = await probeWithMedia(
        'CFG-A-no-servers-all',
        <String, dynamic>{'iceServers': <dynamic>[], 'iceTransportPolicy': 'all'},
        audioA!,
        video!);
    // ignore: avoid_print
    print('RESULT CFG-A host=${a['host'] ?? 0} relay=${a['relay'] ?? 0}');

    // CFG-B: TURN present but policy all, so host candidates still appear.
    final b = await probeWithMedia(
        'CFG-B-turn-all',
        <String, dynamic>{
          'iceServers': turnServers,
          'iceTransportPolicy': 'all',
        },
        audioA,
        video);
    // ignore: avoid_print
    print('RESULT CFG-B host=${b['host'] ?? 0} relay=${b['relay'] ?? 0}');

    // CFG-C: relay-only, exactly what the route proof uses.
    final c = await probeWithMedia(
        'CFG-C-turn-relay',
        <String, dynamic>{
          'iceServers': turnServers,
          'iceTransportPolicy': 'relay',
        },
        audioA,
        video);
    // ignore: avoid_print
    print('RESULT CFG-C host=${c['host'] ?? 0} relay=${c['relay'] ?? 0}');

    for (final s in [video, audioA, audioB]) {
      await s?.dispose();
    }
    // ignore: avoid_print
    print('R4.2b DONE');
  }, timeout: const Timeout(Duration(minutes: 12)));
}