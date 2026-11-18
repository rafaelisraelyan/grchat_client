// Stage 2C - shared support for the real-RTP tests.
//
// Why support code is split out and each RTP test lives in its OWN file:
// on this host, audioinput devices vanish from enumerateDevices() as soon as the
// first RTCPeerConnection exists, so the microphone streams must be opened
// before any PeerConnection is created. Two RTP tests in one file would starve
// the second test of audio. Separate files = separate app process = a clean
// microphone window for each test.
//
// Method notes, learned by experiment and each backed by a bisect file in this
// directory:
//   * ICE gathering never starts if the callback is wired after setLocalDescription
//     (see webrtc_poc_test.dart);
//   * reading getStats() immediately after ICE reports zero bytes and looks
//     like a dead camera - the encoder needs a few seconds;
//   * sharing ONE audio track between both peers WHILE also sharing the video
//     track wedges ICE gathering completely (rtp_bisect3_test.dart);
//   * each peer therefore gets its own microphone stream (rtp_bisect4_test.dart,
//     which passes as the very first pair in the process).

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

import 'rtp_harness.dart';

/// Per-attempt ICE budget inside the device walk: a dead host must not turn a
/// bounded walk into a multi-minute run.
const Duration _kAttemptIceBudget = Duration(seconds: 25);

/// Physical USB devices first: virtual cameras are installed on this host and
/// are only a last resort, because real hardware is stronger evidence.
int _physicalFirst(MediaSource d) => d.deviceId.contains('usb#') ? 0 : 1;

/// A pair proven to carry real RTP on both kinds.
class RtpPair {
  RtpPair(
    this.a,
    this.b,
    this.videoDevice,
    this.audioDeviceA,
    this.audioDeviceB,
    this.videoStream,
    this.audioStreamA,
    this.audioStreamB, {
    required this.videoDelta,
    required this.audioDelta,
  });

  final MediaPeer a;
  final MediaPeer b;
  final MediaSource videoDevice;
  final MediaSource audioDeviceA;
  final MediaSource audioDeviceB;
  final MediaStream videoStream;
  final MediaStream audioStreamA;
  final MediaStream audioStreamB;
  final num videoDelta;
  final num audioDelta;

  Future<void> teardown() async {
    await a.close();
    await b.close();
    await videoStream.dispose();
    await audioStreamA.dispose();
    await audioStreamB.dispose();
  }
}

/// Sums real inbound bytes per kind. Only genuine inbound-rtp reports count.
Future<({num audio, num video})> inboundSnapshot(MediaPeer p) async {
  final reports = await statsOfType(p, 'inbound-rtp');
  num audio = 0;
  num video = 0;
  for (final r in reports) {
    final bytes = statValue(r, 'bytesReceived') ?? 0;
    if (r.values['kind'] == 'audio') {
      audio += bytes;
    } else if (r.values['kind'] == 'video') {
      video += bytes;
    }
  }
  return (audio: audio, video: video);
}

/// Waits until inbound counters actually advance over [window].
Future<({num audio, num video})?> waitInboundGrowth(
  MediaPeer p, {
  required Duration window,
}) async {
  final s0 = await inboundSnapshot(p);
  final deadline = DateTime.now().add(window);
  ({num audio, num video}) last = s0;
  while (DateTime.now().isBefore(deadline)) {
    await Future.delayed(const Duration(milliseconds: 400));
    final s1 = await inboundSnapshot(p);
    last = s1;
    if (s1.audio > s0.audio && s1.video > s0.video) return s1;
  }
  // Report what did move, even if not everything: partial progress is a fact
  // the caller needs in order to pick a different device.
  if (last.audio > s0.audio || last.video > s0.video) return last;
  return null;
}

String _dumpKind(String tag, List<StatsReport> reports) {
  final buf = StringBuffer();
  for (final r in reports) {
    buf.writeln('$tag ${r.type} id=${r.id} kind=${r.values['kind']} '
        'ssrc=${r.values['ssrc']}');
    final keys = r.values.keys.map((k) => '$k=${r.values[k]}').toList()..sort();
    buf.writeln('    ${keys.join(' ')}');
  }
  return buf.toString();
}

/// Full stats evidence for the report.
Future<String> dumpEvidence(MediaPeer receiver, MediaPeer sender, String phase) async {
  final buf = StringBuffer();
  final inStats = await receiver.pc.getStats();
  final outStats = await sender.pc.getStats();
  buf.writeln('=== EVIDENCE[$phase] ===');
  buf.writeln('inbound types=${inStats.map((r) => r.type).toSet().toList()..sort()}');
  buf.writeln('outbound types=${outStats.map((r) => r.type).toSet().toList()..sort()}');
  buf.write(_dumpKind('INBOUND', inStats.where((r) => r.type == 'inbound-rtp').toList()));
  buf.write(_dumpKind('OUTBOUND', outStats.where((r) => r.type == 'outbound-rtp').toList()));
  for (final r in inStats.where((r) => r.type == 'candidate-pair' && r.values['nominated'] == true)) {
    buf.writeln('SELECTED PAIR id=${r.id} ${r.values.entries.map((e) => '${e.key}=${e.value}').toList()..sort()}');
  }
  return buf.toString();
}

/// Opens microphone streams BEFORE any PeerConnection exists.
///
/// Two proven necessities, both from native bisects:
///   * creating a RTCPeerConnection makes enumerateDevices() report zero
///     audioinput devices for the rest of the process, so every microphone
///     stream must be opened up front;
///   * sharing ONE audio track between both peers while ALSO sharing the video
///     track wedged ICE gathering completely (0 candidates, 0 errors). Giving
///     each peer its own microphone stream removes that failure - see
///     integration_test/rtp_bisect3_test.dart, case split-plus-video.
Future<List<(MediaStream, MediaSource)>> openMicrophonesFirst() async {
  final devices = await enumerateCapture('audioinput');
  final opened = <(MediaStream, MediaSource)>[];
  for (final d in devices.take(2)) {
    final s =
        await openCapture(audio: true, video: false, audioDeviceId: d.deviceId);
    if (s == null) {
      // ignore: avoid_print
      print('MIC open failed for ${d.label}');
      continue;
    }
    opened.add((s, d));
  }
  return opened;
}

/// One negotiation attempt with a specific camera.
Future<RtpPair?> tryCamera({
  required MediaStream audioStreamA,
  required MediaSource audioDeviceA,
  required MediaStream audioStreamB,
  required MediaSource audioDeviceB,
  required MediaSource videoDevice,
  required List<String> log,
}) async {
  final videoStream =
      await openCapture(audio: false, video: true, videoDeviceId: videoDevice.deviceId);
  if (videoStream == null) {
    log.add('video ${videoDevice.label}: capture open failed');
    return null;
  }

  final a = await MediaPeer.create('A');
  final b = await MediaPeer.create('B');
  a.wire();
  b.wire();
  // Attach AUDIO FIRST. This order is not cosmetic: with the proven
  // configuration attached video-first, ICE gathering never started on this
  // host (0 candidates, 0 errors). Audio-first is the sequence validated in
  // rtp_bisect3/rtp_bisect4.
  await a.attach(audioStreamA);
  await b.attach(audioStreamB);
  await a.attach(videoStream);
  await b.attach(videoStream);

  await negotiate(a, b);

  // Diagnose the negotiated SDP itself: an offer without media sections or
  // without ICE credentials would never start gathering, which from the
  // outside looks exactly like "0 candidates".
  Future<String> localSummary(MediaPeer p) async {
    try {
      final d = await p.pc.getLocalDescription();
      if (d == null) return 'null';
      final sdp = d.sdp ?? '';
      final sections = sdp.split('\r\n').where((l) => l.startsWith('m=')).toList();
      return 'type=${d.type} sections=${sections.length} [$sections] '
          'ufrag=${iceUfrag(d)} pwd=${sdp.contains('a=ice-pwd:')} '
          'candidates=${sdp.split('\r\n').where((l) => l.startsWith('a=candidate')).length}';
    } catch (e) {
      return 'throws($e)';
    }
  }

  // ignore: avoid_print
  print('NEGOTIATED ${videoDevice.label} A(local=${await localSummary(a)}) '
      'B(local=${await localSummary(b)}) received A=${a.candidatesReceived} B=${b.candidatesReceived}');

  final up = await waitForIceUp(a, b, timeout: _kAttemptIceBudget);
  if (!up) {
    log.add('${videoDevice.label}: ICE never came up '
        '(A received=${a.candidatesReceived} applied=${a.candidatesApplied} failed=${a.candidatesFailed} | '
        'B received=${b.candidatesReceived} applied=${b.candidatesApplied} failed=${b.candidatesFailed})');
    await a.close();
    await b.close();
    await videoStream.dispose();
    return null;
  }

  final growth = await waitInboundGrowth(b, window: const Duration(seconds: 10));
  final snapshot = await inboundSnapshot(b);
  // ignore: avoid_print
  print('ATTEMPT camera=${videoDevice.label} ice=up inboundAudio=${snapshot.audio} '
      'inboundVideo=${snapshot.video} growth=${growth != null} '
      'remoteTracks=${b.remoteTracks.map((t) => t.kind).toList()}');

  if (growth == null) {
    log.add('${videoDevice.label}: ICE up but no RTP growth '
        '(inbound audio=${snapshot.audio} video=${snapshot.video}, '
        'remote tracks=${b.remoteTracks.map((t) => t.kind).toList()})');
    await a.close();
    await b.close();
    await videoStream.dispose();
    return null;
  }

  final s0 = await inboundSnapshot(b);
  await Future.delayed(const Duration(seconds: 2));
  final s1 = await inboundSnapshot(b);

  final pair = RtpPair(
    a,
    b,
    videoDevice,
    audioDeviceA,
    audioDeviceB,
    videoStream,
    audioStreamA,
    audioStreamB,
    videoDelta: s1.video - s0.video,
    audioDelta: s1.audio - s0.audio,
  );
  // ignore: avoid_print
  print('PAIR OK video=${videoDevice.label} audioA=${audioDeviceA.label} '
      'audioB=${audioDeviceB.label} deltaAudio=${pair.audioDelta} deltaVideo=${pair.videoDelta}');
  return pair;
}

/// Walks real cameras until a pair carries real audio AND video RTP.
Future<RtpPair> connectWorkingPair() async {
  final log = <String>[];

  // MUST happen before the first PeerConnection: see openMicrophonesFirst.
  final mics = await openMicrophonesFirst();
  if (mics.length < 2) {
    fail('audio RTP needs one microphone stream per peer, but only '
        '${mics.length} could be opened before PeerConnection creation. '
        'Audio cannot be verified in this environment.');
  }
  final (audioStreamA, audioDeviceA) = mics[0];
  final (audioStreamB, audioDeviceB) = mics[1];
  // ignore: avoid_print
  print('MIC opened before any PeerConnection: A=${audioDeviceA.label} B=${audioDeviceB.label}');

  final videoDevices = (await enumerateCapture('videoinput'))
    ..sort((x, y) => _physicalFirst(x).compareTo(_physicalFirst(y)));
  // ignore: avoid_print
  print('CANDIDATES video=${videoDevices.map((d) => d.toString()).toList()}');

  var pair = await tryCamera(
      audioStreamA: audioStreamA,
      audioDeviceA: audioDeviceA,
      audioStreamB: audioStreamB,
      audioDeviceB: audioDeviceB,
      videoDevice: videoDevices.first,
      log: log);

  // A camera that opens but never delivers frames is common on this host
  // (documented in AGENTS.md), so walk the remaining cameras rather than
  // declaring video unprovable after the first attempt.
  for (var i = 1; pair == null && i < videoDevices.length && i < 4; i++) {
    pair = await tryCamera(
        audioStreamA: audioStreamA,
        audioDeviceA: audioDeviceA,
        audioStreamB: audioStreamB,
        audioDeviceB: audioDeviceB,
        videoDevice: videoDevices[i],
        log: log);
  }

  if (pair == null) {
    await audioStreamA.dispose();
    await audioStreamB.dispose();
    // ignore: avoid_print
    print('WALK FAILED:\n${log.join('\n')}');
    fail('no real audio+video RTP could be established. Attempts:\n${log.join('\n')}');
  }
  return pair;
}
