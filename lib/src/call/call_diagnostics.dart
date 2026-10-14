import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

import '../desktop/desktop_log.dart';

/// Structured WebRTC diagnostics (§8–§9, §25–§27).
///
/// Debug builds only: [dlog] prints nothing to the console in release.
/// Mirrors to the desktop log file so release testers can attach it. Never
/// logs TURN credentials — only candidate types and byte counters.
///
/// Every line carries the writing process id: BOTH windows of a two-window
/// test write the SAME desktop log, and without the tag the camera events of
/// two peers interleave into a story that cannot be attributed (2026-10-14:
/// a 4-click camera toggle was reconstructed by hand from track ids).
void dlog(String line) {
  final tag = '[webrtc ${_pidTag()}] $line';
  if (kDebugMode) {
    // ignore: avoid_print
    print(tag);
  }
  try {
    DesktopLog.write(tag);
  } catch (_) {}
}

/// `pid-1234`, resolved once per process.
String _pidTag() => _pid ??= 'pid-${pid.toString()}';
String? _pid;

String platformTag() {
  if (Platform.isWindows) return 'Windows';
  if (Platform.isMacOS) return 'macOS';
  if (Platform.isLinux) return 'Linux';
  if (Platform.isAndroid) return 'Android';
  if (Platform.isIOS) return 'iOS';
  return 'unknown';
}

/// SDP m-line inventory (§12): which media sections exist and in which
/// direction. Full SDP is never logged.
class SdpSummary {
  SdpSummary(
      {required this.hasAudio,
      required this.hasVideo,
      required this.audioDirs,
      required this.videoDirs});
  final bool hasAudio;
  final bool hasVideo;
  final List<String> audioDirs;
  final List<String> videoDirs;

  static SdpSummary parse(String sdp) {
    var hasAudio = false;
    var hasVideo = false;
    final audioDirs = <String>[];
    final videoDirs = <String>[];
    String? section;
    for (final raw in sdp.split('\n')) {
      final line = raw.trim();
      if (line.startsWith('m=audio')) {
        section = 'audio';
        hasAudio = true;
      } else if (line.startsWith('m=video')) {
        section = 'video';
        hasVideo = true;
      } else if (line.startsWith('m=')) {
        section = null;
      } else if (section != null &&
          (line == 'a=sendrecv' ||
              line == 'a=sendonly' ||
              line == 'a=recvonly' ||
              line == 'a=inactive')) {
        final dir = line.substring(2);
        if (section == 'audio') {
          audioDirs.add(dir);
        } else {
          videoDirs.add(dir);
        }
      }
    }
    return SdpSummary(
        hasAudio: hasAudio,
        hasVideo: hasVideo,
        audioDirs: audioDirs,
        videoDirs: videoDirs);
  }

  @override
  String toString() =>
      'audio=$hasAudio$audioDirs video=$hasVideo$videoDirs';
}

/// Pending remote ICE queue (§15): candidates arriving before
/// setRemoteDescription must wait, not drop. Pure logic, unit-tested;
/// CallState owns one instance per PeerConnection.
class IceBuffer<T> {
  final _queue = <T>[];

  void add(T candidate) => _queue.add(candidate);

  List<T> drain() {
    final out = List<T>.of(_queue);
    _queue.clear();
    return out;
  }

  void clear() => _queue.clear();

  int get length => _queue.length;
  bool get isEmpty => _queue.isEmpty;
}

/// getStats digest (§25–§26): RTP byte/packet counters, the selected
/// candidate-pair's local type (host/srflx/relay) plus live quality:
/// RTT, inbound jitter/loss, decoded vs dropped video frames and the
/// received frame size. Missing keys stay zero — never guessed.
class StatsSummary {
  StatsSummary(
      {required this.outboundAudioBytes,
      required this.outboundVideoBytes,
      required this.inboundAudioBytes,
      required this.inboundVideoBytes,
      required this.outboundAudioPackets,
      required this.outboundVideoPackets,
      required this.inboundAudioPackets,
      required this.inboundVideoPackets,
      required this.selectedCandidateType,
      required this.rttMs,
      required this.inboundAudioJitterMs,
      required this.inboundAudioLost,
      required this.inboundVideoLost,
      required this.videoFramesDecoded,
      required this.videoFramesDropped,
      required this.videoWidth,
      required this.videoHeight});

  final int outboundAudioBytes;
  final int outboundVideoBytes;
  final int inboundAudioBytes;
  final int inboundVideoBytes;
  final int outboundAudioPackets;
  final int outboundVideoPackets;
  final int inboundAudioPackets;
  final int inboundVideoPackets;

  /// host/srflx/relay/unknown.
  final String selectedCandidateType;

  /// Selected pair round-trip, ms. -1 when the pair reports none.
  final int rttMs;

  /// Inbound audio jitter, ms. -1 when unreported.
  final int inboundAudioJitterMs;
  final int inboundAudioLost;
  final int inboundVideoLost;
  final int videoFramesDecoded;
  final int videoFramesDropped;
  final int videoWidth;
  final int videoHeight;

  static int _num(Map<dynamic, dynamic> v, String key) {
    final n = v[key];
    if (n is num) return n.toInt();
    return int.tryParse(n?.toString() ?? '') ?? 0;
  }

  /// Seconds-valued stat (jitter, RTT) → whole ms, -1 when absent.
  static int _ms(Map<dynamic, dynamic> v, String key) {
    final n = v[key];
    if (n is num) return (n * 1000).round();
    final d = double.tryParse(n?.toString() ?? '');
    return d == null ? -1 : (d * 1000).round();
  }

  static StatsSummary summarize(List<StatsReport> reports) {
    var outAudioB = 0;
    var outVideoB = 0;
    var inAudioB = 0;
    var inVideoB = 0;
    var outAudioP = 0;
    var outVideoP = 0;
    var inAudioP = 0;
    var inVideoP = 0;
    var audioJitter = -1;
    var audioLost = 0;
    var videoLost = 0;
    var framesDec = 0;
    var framesDrop = 0;
    var width = 0;
    var height = 0;
    final byId = <String, StatsReport>{};
    for (final r in reports) {
      byId[r.id] = r;
      final media = r.values['kind']?.toString() ??
          r.values['mediaType']?.toString();
      if (r.type == 'outbound-rtp') {
        if (media == 'audio') {
          outAudioB += _num(r.values, 'bytesSent');
          outAudioP += _num(r.values, 'packetsSent');
        } else if (media == 'video') {
          outVideoB += _num(r.values, 'bytesSent');
          outVideoP += _num(r.values, 'packetsSent');
        }
      } else if (r.type == 'inbound-rtp') {
        if (media == 'audio') {
          inAudioB += _num(r.values, 'bytesReceived');
          inAudioP += _num(r.values, 'packetsReceived');
          audioJitter = _ms(r.values, 'jitter');
          audioLost += _num(r.values, 'packetsLost');
        } else if (media == 'video') {
          inVideoB += _num(r.values, 'bytesReceived');
          inVideoP += _num(r.values, 'packetsReceived');
          videoLost += _num(r.values, 'packetsLost');
          framesDec += _num(r.values, 'framesDecoded');
          framesDrop += _num(r.values, 'framesDropped');
          final w = _num(r.values, 'frameWidth');
          final h = _num(r.values, 'frameHeight');
          if (w > width) width = w;
          if (h > height) height = h;
        }
      }
    }
    var selected = 'unknown';
    var rtt = -1;
    for (final r in reports) {
      if (r.type == 'candidate-pair' &&
          (r.values['selected'] == true ||
              r.values['nominated'] == true ||
              r.values['state'] == 'succeeded')) {
        final localId = r.values['localCandidateId']?.toString();
        final local = localId == null ? null : byId[localId];
        final type = local?.values['candidateType']?.toString();
        if (type != null && type.isNotEmpty) {
          selected = type;
          rtt = _ms(r.values, 'currentRoundTripTime');
          break;
        }
      }
    }
    return StatsSummary(
        outboundAudioBytes: outAudioB,
        outboundVideoBytes: outVideoB,
        inboundAudioBytes: inAudioB,
        inboundVideoBytes: inVideoB,
        outboundAudioPackets: outAudioP,
        outboundVideoPackets: outVideoP,
        inboundAudioPackets: inAudioP,
        inboundVideoPackets: inVideoP,
        selectedCandidateType: selected,
        rttMs: rtt,
        inboundAudioJitterMs: audioJitter,
        inboundAudioLost: audioLost,
        inboundVideoLost: videoLost,
        videoFramesDecoded: framesDec,
        videoFramesDropped: framesDrop,
        videoWidth: width,
        videoHeight: height);
  }
}

/// Compact per-call debug summary (§27). No credentials inside.
String buildDebugSummary({
  required String platform,
  required String callId,
  required String role,
  required int localAudioTracks,
  required int localVideoTracks,
  required String signalingState,
  required String iceGatheringState,
  required String iceConnectionState,
  required String connectionState,
  required bool remoteAudio,
  required bool remoteVideo,
  required StatsSummary stats,
}) {
  final short =
      callId.length > 8 ? callId.substring(0, 8) : callId;
  return 'Platform: $platform Role: $role call=$short\n'
      'Local: audio tracks=$localAudioTracks video tracks=$localVideoTracks\n'
      'Peer: signaling=$signalingState iceGathering=$iceGatheringState '
      'ice=$iceConnectionState connection=$connectionState\n'
      'Remote: audio=${remoteAudio ? 'yes' : 'no'} '
      'video=${remoteVideo ? 'yes' : 'no'}\n'
      'RTP out: audio=${stats.outboundAudioBytes}B/${stats.outboundAudioPackets}p '
      'video=${stats.outboundVideoBytes}B/${stats.outboundVideoPackets}p\n'
      'RTP in: audio=${stats.inboundAudioBytes}B/${stats.inboundAudioPackets}p '
      'video=${stats.inboundVideoBytes}B/${stats.inboundVideoPackets}p\n'
      'Selected ICE: ${stats.selectedCandidateType} '
      'rtt=${stats.rttMs}ms\n'
      'Quality in: audio jitter=${stats.inboundAudioJitterMs}ms '
      'lost=${stats.inboundAudioLost}p, '
      'video lost=${stats.inboundVideoLost}p '
      'frames=${stats.videoFramesDecoded}dec/${stats.videoFramesDropped}drop '
      '${stats.videoWidth}x${stats.videoHeight}';
}

/// Short ICE candidate digest: protocol + type + host/family.
/// Host addresses are LAN by construction; public IPs are reduced to
/// the family. No credentials, no ports.
String iceDigest(String? candidate) {
  final c = candidate ?? '';
  final typ =
      RegExp(r'typ\s+(\S+)').firstMatch(c)?.group(1) ?? '?';
  final proto =
      RegExp(r'^\S+\s+\d+\s+(\S+)').firstMatch(c)?.group(1) ?? '?';
  if (typ == '?' && proto == '?') return '?/?/?';
  if (typ == 'host') {
    final parts = c.split(RegExp(r'\s+'));
    final host = parts.length >= 5 ? parts[4] : '?';
    return '$proto/$typ/$host';
  }
  final v6 = RegExp(r'([0-9a-fA-F]{0,4}:){2,}').hasMatch(c);
  return '$proto/$typ/${v6 ? 'v6' : 'v4'}';
}
