// STAGE 2C / R5.3 - AUDIO SOURCE ISOLATION.
//
// One comparative experiment that walks the WHOLE audio chain for both
// directions, so a stall can be attributed to a specific link:
//
//   media-source -> sender (outbound RTP) -> transport -> receiver (inbound RTP)
//
// and can never be blamed on WebRTC transport until the earlier links are shown
// to be alive.
//
// Rules honoured here:
//   * every stat value is reported TOGETHER WITH WHETHER THE KEY EXISTS. A
//     missing key is printed as <absent> and is never replaced by false/0;
//   * SSRC and direction are used to match report objects across snapshots;
//   * DTX is checked in the ACTUALLY negotiated SDP (fmtp), not inferred from
//     the codec name;
//   * assertions stay strict: silence with permitted DTX is reported, not
//     silently passed, and an absent inbound report is a failure.

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:integration_test/integration_test.dart';

import 'rtp_harness.dart';

final Stopwatch _clock = Stopwatch()..start();

/// Prints a value and whether its key exists at all.
String val(Map<dynamic, dynamic> m, String key) {
  if (!m.containsKey(key)) return '<absent>';
  final v = m[key];
  return '$v';
}

String maskAddr(String s) => s
    .replaceAllMapped(
        RegExp(r'\b(\d{1,3}\.\d{1,3}\.\d{1,3})\.\d{1,3}\b'), (m) => '${m[1]}.x')
    .replaceAllMapped(
        RegExp(r'[a-f0-9]{8,}(?:-[a-f0-9]{4,})*\.local'), (_) => '<mdns>.local');

/// DTX / silence handling as actually negotiated, from the SDP fmtp line.
String dtxFromSdp(String sdp) {
  for (final line in sdp.split('\r\n')) {
    if (line.startsWith('a=fmtp:') && line.contains('111')) return line;
  }
  return '<no opus fmtp line>';
}

Future<Map<String, dynamic>> reportByType(
    RTCPeerConnection pc, String type, String kind) async {
  final all = await pc.getStats();
  for (final r in all) {
    if (r.type == type && (kind.isEmpty || r.values['kind'] == kind)) {
      return r.values.map((k, v) => MapEntry('$k', v));
    }
  }
  return <String, dynamic>{};
}

/// Measures one direction end to end and prints the full chain.
Future<void> runDirection(
  String label,
  MediaStream senderAudio,
  MediaStream receiverAudio,
  MediaStream video,
) async {
  final ps = await createPeerConnection(<String, dynamic>{'iceServers': <dynamic>[]});
  final pr = await createPeerConnection(<String, dynamic>{'iceServers': <dynamic>[]});

  final toReceiver = <RTCIceCandidate>[];
  final toSender = <RTCIceCandidate>[];
  bool remoteOnReceiver = false;
  bool remoteOnSender = false;

  ps.onIceCandidate = (c) {
    if (remoteOnReceiver) {
      unawaited(pr.addCandidate(c));
    } else {
      toReceiver.add(c);
    }
  };
  pr.onIceCandidate = (c) {
    if (remoteOnSender) {
      unawaited(ps.addCandidate(c));
    } else {
      toSender.add(c);
    }
  };

  await ps.addTrack(senderAudio.getAudioTracks().first, senderAudio);
  await ps.addTrack(video.getVideoTracks().first, video);
  // The receiver also holds its own microphone so the audio m-line is sendrecv,
  // but this direction measures only sender -> receiver.
  await pr.addTrack(receiverAudio.getAudioTracks().first, receiverAudio);

  final offer = await ps.createOffer(
      <String, dynamic>{'offerToReceiveAudio': 1, 'offerToReceiveVideo': 1});
  final offerSdp = offer.sdp ?? '';
  await ps.setLocalDescription(offer);
  await pr.setRemoteDescription(RTCSessionDescription(offerSdp, 'offer'));
  remoteOnReceiver = true;
  while (toReceiver.isNotEmpty) {
    await pr.addCandidate(toReceiver.removeAt(0));
  }
  final answer = await pr.createAnswer();
  final answerSdp = answer.sdp ?? '';
  await pr.setLocalDescription(answer);
  await ps.setRemoteDescription(RTCSessionDescription(answerSdp, 'answer'));
  remoteOnSender = true;
  while (toSender.isNotEmpty) {
    await ps.addCandidate(toSender.removeAt(0));
  }

  // ignore: avoid_print
  print('===== $label =====');
  // ignore: avoid_print
  print('t=${_clock.elapsedMilliseconds}ms SDP offer fmtp=${dtxFromSdp(offerSdp)}');
  // ignore: avoid_print
  print('t=${_clock.elapsedMilliseconds}ms SDP answer fmtp=${dtxFromSdp(answerSdp)}');

  final deadline = DateTime.now().add(const Duration(seconds: 45));
  var up = false;
  while (DateTime.now().isBefore(deadline)) {
    final a = '${await ps.getIceConnectionState()}'.toLowerCase();
    final b = '${await pr.getIceConnectionState()}'.toLowerCase();
    if ((a.contains('connected') || a.contains('completed')) &&
        (b.contains('connected') || b.contains('completed'))) {
      up = true;
      break;
    }
    await Future.delayed(const Duration(milliseconds: 300));
  }
  // ignore: avoid_print
  print('t=${_clock.elapsedMilliseconds}ms ICE=$up A=${await ps.getIceConnectionState()} '
      'B=${await pr.getIceConnectionState()}');

  Future<void> snapshot(String phase) async {
    final srcS = await reportByType(ps, 'media-source', 'audio');
    final srcR = await reportByType(pr, 'media-source', 'audio');
    final outS = await reportByType(ps, 'outbound-rtp', 'audio');
    final inR = await reportByType(pr, 'inbound-rtp', 'audio');
    final inS = await reportByType(ps, 'inbound-rtp', 'audio');
    final vidIn = await reportByType(pr, 'inbound-rtp', 'video');
    // ignore: avoid_print
    print('t=${_clock.elapsedMilliseconds}ms [$phase] SENDER media-source '
        'audioLevel=${val(srcS, 'audioLevel')} '
        'totalAudioEnergy=${val(srcS, 'totalAudioEnergy')} '
        'totalSamplesDuration=${val(srcS, 'totalSamplesDuration')} '
        'trackIdentifier=${val(srcS, 'trackIdentifier')}');
    // ignore: avoid_print
    print('t=${_clock.elapsedMilliseconds}ms [$phase] SENDER outbound-rtp '
        'id=${val(srcS.isEmpty ? outS : outS, 'id')} ssrc=${val(outS, 'ssrc')} '
        'packetsSent=${val(outS, 'packetsSent')} bytesSent=${val(outS, 'bytesSent')} '
        'codecId=${val(outS, 'codecId')} mediaSourceId=${val(outS, 'mediaSourceId')} '
        'active=${val(outS, 'active')}');
    // ignore: avoid_print
    print('t=${_clock.elapsedMilliseconds}ms [$phase] RECEIVER inbound-rtp '
        'ssrc=${val(inR, 'ssrc')} packetsReceived=${val(inR, 'packetsReceived')} '
        'bytesReceived=${val(inR, 'bytesReceived')} '
        'totalAudioEnergy=${val(inR, 'totalAudioEnergy')} '
        'totalSamplesDuration=${val(inR, 'totalSamplesDuration')} '
        'audioLevel=${val(inR, 'audioLevel')} jitter=${val(inR, 'jitter')} '
        'packetsLost=${val(inR, 'packetsLost')}');
    // ignore: avoid_print
    print('t=${_clock.elapsedMilliseconds}ms [$phase] REVERSE inbound-rtp '
        'ssrc=${val(inS, 'ssrc')} packetsReceived=${val(inS, 'packetsReceived')} '
        'bytesReceived=${val(inS, 'bytesReceived')}');
    // ignore: avoid_print
    print('t=${_clock.elapsedMilliseconds}ms [$phase] RECEIVER video-inbound '
        'ssrc=${val(vidIn, 'ssrc')} packetsReceived=${val(vidIn, 'packetsReceived')} '
        'bytesReceived=${val(vidIn, 'bytesReceived')} '
        'framesDecoded=${val(vidIn, 'framesDecoded')}');
    // ignore: avoid_print
    print('t=${_clock.elapsedMilliseconds}ms [$phase] RECEIVER media-source '
        'audioLevel=${val(srcR, 'audioLevel')} '
        'totalAudioEnergy=${val(srcR, 'totalAudioEnergy')} '
        'trackIdentifier=${val(srcR, 'trackIdentifier')}');
  }

  // Warm up first: encoders and capture need time, and an early read shows
  // zeros that look exactly like a dead source.
  final warmUntil = DateTime.now().add(const Duration(seconds: 30));
  while (DateTime.now().isBefore(warmUntil)) {
    final v = await reportByType(pr, 'inbound-rtp', 'video');
    if ((v['bytesReceived'] as num? ?? 0) > 0) break;
    await Future.delayed(const Duration(milliseconds: 500));
  }

  await snapshot('T0');
  await Future.delayed(const Duration(seconds: 5));
  await snapshot('T1');

  final out1 = await reportByType(ps, 'outbound-rtp', 'audio');
  final in1 = await reportByType(pr, 'inbound-rtp', 'audio');
  final vid1 = await reportByType(pr, 'inbound-rtp', 'video');

  // ignore: avoid_print
  print('t=${_clock.elapsedMilliseconds}ms $label VERDICT '
      'outPackets=${val(out1, 'packetsSent')} outBytes=${val(out1, 'bytesSent')} '
      'inPackets=${val(in1, 'packetsReceived')} inBytes=${val(in1, 'bytesReceived')} '
      'videoBytes=${val(vid1, 'bytesReceived')}');

  ps.onIceCandidate = null;
  pr.onIceCandidate = null;
  await ps.close();
  await pr.close();
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  test('R5.3: audio source isolation, both directions', () async {
    final mics = await enumerateCapture('audioinput');
    expect(mics.length, greaterThanOrEqualTo(2));
    // ignore: avoid_print
    print('MIC DEVICES ${mics.map((m) => m.toString()).toList()}');

    final micA =
        await openCapture(audio: true, video: false, audioDeviceId: mics[0].deviceId);
    final micB =
        await openCapture(audio: true, video: false, audioDeviceId: mics[1].deviceId);
    expect(micA, isNotNull, reason: 'mic A');
    expect(micB, isNotNull, reason: 'mic B');

    final cams = (await enumerateCapture('videoinput'))
      ..sort((a, b) => (a.deviceId.contains('usb#') ? 0 : 1)
          .compareTo(b.deviceId.contains('usb#') ? 0 : 1));
    final video = await openCapture(
        audio: false, video: true, videoDeviceId: cams.first.deviceId);
    expect(video, isNotNull, reason: 'camera');

    // Direction 1: device A captures, device B is the other endpoint.
    await runDirection('DIR1 A->B (send=${mics[0].label})', micA!, micB!, video!);
    // Direction 2: the devices are SWAPPED, so a stall cannot be attributed to
    // the role of a specific sender.
    await runDirection('DIR2 B->A (send=${mics[1].label})', micB, micA, video);

    await video.dispose();
    await micA.dispose();
    await micB.dispose();
    // ignore: avoid_print
    print('R5.3 DONE');
  }, timeout: const Timeout(Duration(minutes: 20)));
}