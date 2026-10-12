import 'package:flutter_webrtc/flutter_webrtc.dart' show StatsReport;

/// Adaptive P2P video quality: the sender walks a ladder of tiers up to
/// 1080p/60 when the link AND the machine can carry it, and steps back down
/// when either cannot. Pure logic, no engine calls: the call engine feeds it
/// [LinkMetrics] every few seconds and applies the returned tier.
///
/// The camera is captured once at the best resolution it offers; tiers only
/// change what is SENT (downscale factor, fps cap, bitrate cap), so a tier
/// switch never restarts capture or renegotiates.
class VideoTier {
  const VideoTier(this.name, this.height, this.fps, this.kbps);

  final String name;

  /// Target sent height (width follows the aspect ratio).
  final int height;
  final int fps;

  /// Send ceiling in kbit/s. WebRTC's own bandwidth estimation still picks
  /// the actual rate below this ceiling.
  final int kbps;

  @override
  String toString() => '$name ${height}p$fps ${kbps}kbps';
}

/// Low to high. Index 1 is where every call starts.
const videoTiers = <VideoTier>[
  VideoTier('eco', 540, 30, 1000),
  VideoTier('hd', 720, 30, 2500),
  VideoTier('fhd', 1080, 30, 5000),
  VideoTier('max', 1080, 60, 8000),
];

const videoStartTier = 1;

/// What to hand to RTCRtpEncoding for [t] given the real capture size.
class TierParams {
  const TierParams(
      {required this.scaleDownBy,
      required this.maxFramerate,
      required this.maxBitrate});

  /// >= 1.0. 1.0 = send at capture resolution.
  final double scaleDownBy;
  final int maxFramerate;

  /// bit/s.
  final int maxBitrate;
}

/// [captureHeight]/[captureFps] come from the track settings; 0 = unknown.
/// A tier never upscales and never asks for more fps than the camera gives.
TierParams tierParams(VideoTier t,
    {required int captureHeight, required double captureFps}) {
  final scale = captureHeight > t.height ? captureHeight / t.height : 1.0;
  final cam = captureFps.floor();
  final fps = captureFps > 0 && cam < t.fps ? (cam < 1 ? 1 : cam) : t.fps;
  return TierParams(
      scaleDownBy: scale, maxFramerate: fps, maxBitrate: t.kbps * 1000);
}

/// One sample of the outgoing path. Null = the platform did not report it;
/// an unknown value never triggers an upgrade.
class LinkMetrics {
  const LinkMetrics(
      {this.availableOutKbps,
      this.rttMs,
      this.lossPct,
      this.limitation,
      this.frameHeight,
      this.frameWidth,
      this.videoBytesSent,
      this.framesPerSecond,
      this.videoOut = false});

  /// Height of the video frames actually being SENT right now (outbound-rtp
  /// frameHeight). With no downscale applied this is the real capture
  /// height: desktop getSettings() only echoes what was requested, not what
  /// the camera really delivered.
  final double? frameHeight;

  /// Width of the same frames (outbound-rtp frameWidth), for frame=WxH logs.
  final double? frameWidth;

  /// Cumulative bytes of the outgoing video stream (outbound-rtp bytesSent).
  /// The controller derives the actual send rate from consecutive samples;
  /// a frozen value means the encoder is producing nothing.
  final double? videoBytesSent;

  /// True when an outbound-rtp video report was present in the dump at all.
  /// Splits "video exists but produced nothing" (bytesSent absent/zero) from
  /// "no outbound video stats whatsoever" — the two need different handling.
  final bool videoOut;

  /// Frames per second actually sent (outbound-rtp framesPerSecond).
  final double? framesPerSecond;

  /// Sender-side bandwidth estimate (candidate-pair availableOutgoingBitrate).
  final double? availableOutKbps;
  final double? rttMs;

  /// Loss reported back by the peer for our video, in percent.
  final double? lossPct;

  /// outbound-rtp qualityLimitationReason: none | bandwidth | cpu | other.
  final String? limitation;

  bool get isEmpty =>
      availableOutKbps == null &&
      rttMs == null &&
      lossPct == null &&
      limitation == null;

  static double? _d(Object? v) {
    if (v is num) return v.toDouble();
    return double.tryParse(v?.toString() ?? '');
  }

  /// Pull the numbers we need out of a getStats() dump.
  static LinkMetrics fromReports(List<StatsReport> reports) {
    double? avail;
    double? rtt;
    double? loss;
    String? limitation;
    double? frameHeight;
    double? frameWidth;
    double? videoBytesSent;
    double? framesPerSecond;
    var videoOut = false;

    // Selected pair: nominated+succeeded, else any succeeded.
    StatsReport? pair;
    for (final r in reports) {
      if (r.type != 'candidate-pair') continue;
      if (r.values['state'] != 'succeeded') continue;
      if (r.values['nominated'] == true || r.values['selected'] == true) {
        pair = r;
        break;
      }
      pair ??= r;
    }
    if (pair != null) {
      final a = _d(pair.values['availableOutgoingBitrate']);
      if (a != null) avail = a / 1000;
      final s = _d(pair.values['currentRoundTripTime']);
      if (s != null) rtt = s * 1000;
    }

    for (final r in reports) {
      final kind =
          r.values['kind']?.toString() ?? r.values['mediaType']?.toString();
      if (r.type == 'remote-inbound-rtp' && kind == 'video') {
        var f = _d(r.values['fractionLost']);
        if (f != null) {
          if (f > 1) f = f / 256; // raw RTCP 0..255 scale on some builds
          loss = f * 100;
        }
        rtt ??= (() {
          final s = _d(r.values['roundTripTime']);
          return s == null ? null : s * 1000;
        })();
      } else if (r.type == 'outbound-rtp' && kind == 'video') {
        videoOut = true;
        final l = r.values['qualityLimitationReason']?.toString();
        if (l != null && l.isNotEmpty) limitation = l;
        final h = _d(r.values['frameHeight']);
        if (h != null && h > 0) frameHeight = h;
        final w = _d(r.values['frameWidth']);
        if (w != null && w > 0) frameWidth = w;
        final b = _d(r.values['bytesSent']);
        if (b != null && b > 0) videoBytesSent = b;
        final f = _d(r.values['framesPerSecond']);
        if (f != null && f > 0) framesPerSecond = f;
      }
    }
    return LinkMetrics(
        availableOutKbps: avail,
        rttMs: rtt,
        lossPct: loss,
        limitation: limitation,
        frameHeight: frameHeight,
        frameWidth: frameWidth,
        videoBytesSent: videoBytesSent,
        framesPerSecond: framesPerSecond,
        videoOut: videoOut);
  }
}

/// Hysteresis over [LinkMetrics]: quick to back off, slow to climb, and a
/// cooldown after a downgrade so a marginal link does not flap.
class QualityController {
  QualityController({int start = videoStartTier, DateTime? startedAt})
      : _index = start.clamp(0, videoTiers.length - 1) {
    _startedAt = startedAt;
  }
  /// Consecutive good samples before one step up (3 x 3 s = ~9 s).
  static const upNeeded = 3;

  /// Consecutive bad samples before one step down (2 x 3 s = ~6 s).
  static const downNeeded = 2;

  /// Step up only with this much estimated headroom over the next tier.
  static const headroom = 1.25;

  /// The bandwidth estimate is not trustworthy right after "connected": it
  /// starts at a dummy ~300 kbit/s and would read as starved. A shortfall
  /// by estimate is judged only after this much time on the connection.
  static const warmup = Duration(seconds: 20);

  /// "Shortfall" = the estimate is below this share of the tier ceiling
  /// (was 0.7; the adaptive-tier ceiling is a limit, not a target).
  static const starvedShare = 0.5;

  /// Two consecutive ticks without outgoing video (frozen bytesSent) freeze
  /// the controller: the camera is busy or delivers nothing, so tier
  /// decisions would be noise.
  static const stallTicks = 2;

  /// Saturated send: climbing requires the REAL send rate (bytes between
  /// ticks) at or above this share of the current ceiling.
  static const saturatedShare = 0.8;

  /// Cooldown sizes after bandwidth downgrades: 15 s, 30 s, then 60 s cap
  /// (exponential per consecutive downgrade within the reset window).
  /// A CPU-bound downgrade always uses the 60 s cooldown.
  static const cdFirst = 15;
  static const cdCap = 60;
  static const cpuCooldown = Duration(seconds: 60);

  /// The cooldown ladder resets after this long with no downgrades.
  static const streakReset = Duration(minutes: 2);

  /// Warn once when the camera cannot hold its fps for this long.
  static const lowFpsBar = 20.0;
  static const lowFpsHorizon = Duration(seconds: 10);

  DateTime? _startedAt;
  int _index;
  int _good = 0;
  int _bad = 0;
  int _bwStreak = 0;
  DateTime? _noUpUntil;
  DateTime? _lastDown;

  // Outgoing video bookkeeping (bytes between ticks).
  double? _lastBytes;
  DateTime? _lastBytesAt;
  double? _sentKbps;
  int _stall = 0;

  // Low-fps episode state.
  DateTime? _lowFpsSince;
  bool _lowFpsWarned = false;
  String? _pendingLowFps;

  VideoTier get tier => videoTiers[_index];
  int get index => _index;

  /// Actual send rate derived from the byte delta of the last two ticks.
  double? get sentKbps => _sentKbps;

  /// True while outgoing video is considered frozen.
  bool get videoStalled => _stall >= stallTicks;

  /// Re-arm the warmup clock (also used after an ICE restart, where the
  /// estimate starts over at its dummy value).
  void markConnected(DateTime now) => _startedAt = now;

  bool _warming(DateTime now) =>
      _startedAt != null && now.isBefore(_startedAt!.add(warmup));

  void _trackVideo(LinkMetrics m, DateTime now) {
    final b = m.videoBytesSent;
    if (m.videoOut && b == null) {
      // The outbound video report IS present but carried no bytes: the
      // encoder produces nothing. That is the "camera busy / no frames"
      // case — count it as a tick without outgoing video.
      _stall++;
      _sentKbps = null;
      _lastBytes = null;
      _lastBytesAt = null;
      return;
    }
    if (b == null) {
      // No outbound video stats at all: no opinion, do not accumulate
      // stall (the tier must still react to estimate/loss/rtt signals).
      _lastBytes = null;
      _lastBytesAt = null;
      _sentKbps = null;
      _stall = 0;
      return;
    }
    final last = _lastBytes;
    final lastAt = _lastBytesAt;
    if (last == null || lastAt == null) {
      _stall = 0;
      _sentKbps = null;
    } else if (b > last) {
      final ms = now.difference(lastAt).inMilliseconds;
      _stall = 0;
      _sentKbps = ms > 0 ? (b - last) * 8 / (ms / 1000) / 1000 : null;
    } else {
      // Cumulative byte counters never shrink: a non-growing value means
      // no frames are leaving the machine.
      _stall++;
      _sentKbps = null;
    }
    _lastBytes = b;
    _lastBytesAt = now;
  }

  void _trackFps(LinkMetrics m, DateTime now) {
    final f = m.framesPerSecond;
    final dipping = f != null && f < lowFpsBar && tier.fps >= 30;
    if (!dipping) {
      _lowFpsSince = null;
      _lowFpsWarned = false;
      return;
    }
    _lowFpsSince ??= now;
    if (!_lowFpsWarned && now.difference(_lowFpsSince!) >= lowFpsHorizon) {
      _pendingLowFps = 'camera delivers ~${f.round()} fps';
      _lowFpsWarned = true;
    }
  }

  /// Warning text for the camera being slow, or null. Reported once per
  /// low-fps episode; it re-arms after the camera recovers.
  String? consumeLowFpsWarning() {
    final w = _pendingLowFps;
    _pendingLowFps = null;
    return w;
  }

  /// Feed one sample. Returns the new tier when it changed, else null.
  VideoTier? update(LinkMetrics m, DateTime now) {
    _trackVideo(m, now);
    if (m.isEmpty) {
      _good = 0;
      _bad = 0;
      return null;
    }
    if (videoStalled) {
      // No outgoing video: tier decisions would be pure noise. Freeze the
      // whole state; when bytes start moving again the episode is over.
      return null;
    }
    _trackFps(m, now);
    final cpu = m.limitation == 'cpu';
    final loss = m.lossPct ?? 0;
    final rtt = m.rttMs ?? 0;
    final avail = m.availableOutKbps;

    // Estimate-based shortfall waits out the warmup, and eco has nowhere
    // to step down to anyway.
    final starved = !_warming(now) &&
        avail != null &&
        avail < tier.kbps * starvedShare &&
        _index > 0;
    final bad = cpu || loss > 6 || rtt > 350 || starved;

    if (bad) {
      _good = 0;
      _bad++;
      if (_bad >= downNeeded && _index > 0) {
        _index--;
        _bad = 0;
        if (cpu) {
          // A CPU-bound encoder will not get better in a few seconds.
          _noUpUntil = now.add(cpuCooldown);
        } else {
          if (_lastDown != null &&
              now.difference(_lastDown!) >= streakReset) {
            _bwStreak = 0;
          }
          _bwStreak++;
          final secs = (cdFirst << (_bwStreak - 1)).clamp(cdFirst, cdCap);
          _noUpUntil = now.add(Duration(seconds: secs));
          _lastDown = now;
        }
        return tier;
      }
      return null;
    }

    final canGoUp = _index < videoTiers.length - 1;
    final next = canGoUp ? videoTiers[_index + 1] : null;
    final lossRttOk = loss < 1.5 && rtt < 150;
    // Alternative A: the estimate already carries the next tier's load.
    final byEstimate = canGoUp &&
        avail != null &&
        avail >= next!.kbps * headroom;
    // Alternative B: the REAL send rate saturates the current ceiling.
    final bySend = canGoUp &&
        _sentKbps != null &&
        _sentKbps! >= tier.kbps * saturatedShare &&
        m.limitation == 'none';

    final good = canGoUp && lossRttOk && (byEstimate || bySend);

    _bad = 0;
    final blocked = _noUpUntil != null && now.isBefore(_noUpUntil!);
    if (!good || blocked) {
      // During the cooldown good samples do not count: after it ends the
      // link must prove itself for a full upNeeded samples.
      _good = 0;
      return null;
    }
    _good++;
    if (_good >= upNeeded) {
      _index++;
      _good = 0;
      return tier;
    }
    return null;
  }
}
