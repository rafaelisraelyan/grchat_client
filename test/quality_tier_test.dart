import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart' show StatsReport;
import 'package:grchat_client/src/call/quality_tier.dart';

/// The ladder decides how much CPU and uplink a call burns. Wrong
/// thresholds mean either wasted quality or a stuttering 1080p60 on a weak
/// link, so the behaviour is pinned down here.
void main() {
  final t0 = DateTime(2026, 10, 10, 12);
  const great = LinkMetrics(
      availableOutKbps: 20000, rttMs: 20, lossPct: 0, limitation: 'none');

  group('tierParams', () {
    test('1080p camera: 720p tier downscales by 1.5, 1080p tier does not', () {
      final hd = tierParams(videoTiers[1], captureHeight: 1080, captureFps: 60);
      expect(hd.scaleDownBy, closeTo(1.5, 1e-9));
      expect(hd.maxFramerate, 30);
      expect(hd.maxBitrate, 2500000);
      final max =
          tierParams(videoTiers[3], captureHeight: 1080, captureFps: 60);
      expect(max.scaleDownBy, 1.0);
      expect(max.maxFramerate, 60);
      expect(max.maxBitrate, 8000000);
    });

    test('720p camera is never upscaled or downscaled below itself', () {
      final p = tierParams(videoTiers[3], captureHeight: 720, captureFps: 30);
      expect(p.scaleDownBy, 1.0);
      expect(p.maxFramerate, 30, reason: 'camera cannot do 60');
      final hd = tierParams(videoTiers[1], captureHeight: 720, captureFps: 30);
      expect(hd.scaleDownBy, 1.0);
    });

    test('unknown capture size falls back to the tier values', () {
      final p = tierParams(videoTiers[2], captureHeight: 0, captureFps: 0);
      expect(p.scaleDownBy, 1.0);
      expect(p.maxFramerate, 30);
    });
  });

  group('QualityController', () {
    const badAvail = LinkMetrics(
        availableOutKbps: 200, rttMs: 30, lossPct: 0, limitation: 'none');

    LinkMetrics mV(double? bytes,
            {double? avail,
            double rtt = 20,
            double loss = 0,
            String limit = 'none',
            double fps = 30}) =>
        LinkMetrics(
            availableOutKbps: avail,
            rttMs: rtt,
            lossPct: loss,
            limitation: limit,
            videoBytesSent: bytes,
            framesPerSecond: bytes != null ? fps : null,
            videoOut: bytes != null);

    test('starts at 720p30', () {
      final c = QualityController();
      expect(c.tier.height, 720);
      expect(c.tier.fps, 30);
    });

    test('(a) shortage by estimate does not downgrade during warmup', () {
      final c = QualityController(startedAt: t0);
      for (var i = 0; i < 6; i++) {
        // t0+3 .. t0+18 s: all inside the 20 s warmup window.
        expect(c.update(badAvail, t0.add(Duration(seconds: 3 + 3 * i))),
            isNull,
            reason: 'no starvation verdict before t0+20s');
        expect(c.tier.name, 'hd');
      }
    });

    test('(b) after warmup the 50% shortage step-down works', () {
      final c = QualityController(startedAt: t0);
      for (var i = 0; i < 6; i++) {
        c.update(badAvail, t0.add(Duration(seconds: 3 + 3 * i)));
      }
      // t0+21 and t0+24: outside the warmup; 200 << 0.5*2500.
      VideoTier? changed;
      for (var i = 0; i < QualityController.downNeeded; i++) {
        changed = c.update(badAvail, t0.add(Duration(seconds: 21 + 3 * i)));
      }
      expect(changed?.name, 'eco');
    });

    test('the old 70% estimate step-down is gone after warmup', () {
      // 60% of the 2500 kbps hd ceiling: not a starvation signal anymore.
      final c = QualityController(startedAt: t0);
      const mild = LinkMetrics(
          availableOutKbps: 1500, rttMs: 30, lossPct: 0, limitation: 'none');
      // Skip the warmup ticks, then 10 more in the steady state.
      for (var i = 0; i < 17; i++) {
        expect(c.update(mild, t0.add(Duration(seconds: 21 + 3 * i))), isNull);
      }
      expect(c.tier.name, 'hd');
    });

    test('(c) saturation of the REAL send rate climbs to fhd', () {
      final c = QualityController();
      // Tier hd = 2500 kbps ceiling; 85% = 2125 kbps. 3 s per tick ->
      // 2125 * 1000 * 3 / 8 = 796875 bytes per tick.
      const deltaBytes = 796875.0;
      var now = t0;
      var bytes = 1000000.0;
      VideoTier? changed;
      for (var i = 0; i < 5; i++) {
        final r = c.update(mV(bytes), now);
        changed ??= r;
        bytes += deltaBytes;
        now = now.add(const Duration(seconds: 3));
      }
      // Tick 1 is the byte baseline (no delta); three saturated ticks climb.
      expect(changed?.name, 'fhd');
      expect(c.sentKbps, closeTo(2125, 1));
    });

    test('the estimate headroom path still works as an alternative', () {
      // No byte stats at all: the old estimate-only path must still climb.
      final c = QualityController();
      var now = t0;
      VideoTier? changed;
      for (var i = 0; i < QualityController.upNeeded; i++) {
        changed = c.update(great, now);
        now = now.add(const Duration(seconds: 3));
      }
      expect(changed?.name, 'fhd');
    });

    test('(d) saturation does not climb with loss >= 1.5%', () {
      final c = QualityController();
      const deltaBytes = 796875.0;
      var now = t0;
      var bytes = 1000000.0;
      for (var i = 0; i < 10; i++) {
        expect(c.update(mV(bytes, loss: 2), now), isNull,
            reason: 'loss >= 1.5% must block the upgrade');
        bytes += deltaBytes;
        now = now.add(const Duration(seconds: 3));
      }
      expect(c.tier.name, 'hd');
    });

    test('(e) no outgoing video freezes the controller', () {
      final c = QualityController();
      const frozen = 500000.0;
      var now = t0;
      for (var i = 0; i < 6; i++) {
        expect(c.update(mV(frozen, avail: 20000), now), isNull,
            reason: 'bytes do not grow - no tier decisions');
        now = now.add(const Duration(seconds: 3));
      }
      expect(c.tier.name, 'hd');
      expect(c.videoStalled, isTrue);
      // Bytes resume: control unfreezes and climbs on saturation again.
      const deltaBytes = 796875.0;
      var bytes = frozen + deltaBytes;
      now = now.add(const Duration(seconds: 3));
      var changed = c.update(mV(bytes, avail: 20000), now);
      expect(changed?.name, 'fhd',
          reason: 'the pre-stall good samples are kept, resume completes it');
      expect(c.videoStalled, isFalse);
    });

    test('(e2) an outbound video report with zero bytes freezes too', () {
      final c = QualityController();
      // What live stats show for a call whose encoder produces nothing:
      // the outbound video report exists, but bytesSent does not.
      const noFrames = LinkMetrics(
          availableOutKbps: 20000,
          rttMs: 20,
          lossPct: 0,
          limitation: 'none',
          videoOut: true);
      var now = t0;
      for (var i = 0; i < 5; i++) {
        expect(c.update(noFrames, now), isNull,
            reason: 'video present, bytes absent = no frames = no decisions');
        now = now.add(const Duration(seconds: 3));
      }
      expect(c.tier.name, 'hd');
      expect(c.videoStalled, isTrue);
    });

    test('(f) cooldown grows 15/30/60 across consecutive downgrades', () {
      final starve = LinkMetrics(
          availableOutKbps: 1000, rttMs: 30, lossPct: 0, limitation: 'none');

      // 15 s after the first downgrade.
      final c1 = QualityController(start: 2);
      c1.update(starve, t0);
      final d1 = c1.update(starve, t0.add(const Duration(seconds: 3)));
      expect(d1?.name, 'hd');
      // Blocked at t0+15 (still inside a 15 s cooldown from t0+3)...
      expect(c1.update(great, t0.add(const Duration(seconds: 15))), isNull);
      VideoTier? up1;
      for (var i = 0; i < 3; i++) {
        up1 = c1.update(great, t0.add(Duration(seconds: 18 + 3 * i)));
      }
      expect(up1?.name, 'fhd', reason: 'first cooldown is 15 s');

      // 30 s after the second downgrade.
      final c2 = QualityController(start: 2);
      c2.update(starve, t0);
      c2.update(starve, t0.add(const Duration(seconds: 3)));
      var d2 = c2.update(starve, t0.add(const Duration(seconds: 6)));
      d2 = c2.update(starve, t0.add(const Duration(seconds: 9)));
      expect(d2?.name, 'eco');
      expect(c2.update(great, t0.add(const Duration(seconds: 36))), isNull,
          reason: 'second cooldown (30 s from t0+9) still holds at t0+36');
      VideoTier? up2;
      for (var i = 0; i < 3; i++) {
        up2 = c2.update(great, t0.add(Duration(seconds: 39 + 3 * i)));
      }
      expect(up2?.name, 'hd', reason: 'second cooldown is 30 s (eco -> hd)');

      // 60 s cap after the third downgrade (max -> fhd -> hd -> eco).
      final c3 = QualityController(start: 3);
      for (final at in [0, 3, 6, 9, 12, 15]) {
        c3.update(starve, t0.add(Duration(seconds: at)));
      }
      expect(c3.tier.name, 'eco');
      expect(c3.update(great, t0.add(const Duration(seconds: 72))), isNull,
          reason: 'third cooldown (60 s from t0+15) still holds at t0+72');
      VideoTier? up3;
      for (var i = 0; i < 3; i++) {
        up3 = c3.update(great, t0.add(Duration(seconds: 75 + 3 * i)));
      }
      expect(up3?.name, 'hd', reason: 'cooldown caps at 60 s (eco -> hd)');
    });

    test('climbs one step per upNeeded good samples, up to 1080p60', () {
      final c = QualityController();
      var now = t0;
      VideoTier? changed;
      for (var i = 0; i < QualityController.upNeeded; i++) {
        changed = c.update(great, now);
        now = now.add(const Duration(seconds: 3));
      }
      expect(changed?.name, 'fhd');
      for (var i = 0; i < QualityController.upNeeded; i++) {
        changed = c.update(great, now);
        now = now.add(const Duration(seconds: 3));
      }
      expect(changed?.name, 'max');
      // Already at the top: nothing more to do.
      for (var i = 0; i < 10; i++) {
        expect(c.update(great, now), isNull);
      }
      expect(c.tier.name, 'max');
    });

    test('no upgrade without bandwidth headroom for the next tier', () {
      final c = QualityController();
      // Next tier needs 5000 * 1.25 = 6250 kbps.
      const tight = LinkMetrics(
          availableOutKbps: 5500, rttMs: 20, lossPct: 0, limitation: 'none');
      for (var i = 0; i < 20; i++) {
        expect(c.update(tight, t0.add(Duration(seconds: 3 * i))), isNull);
      }
      expect(c.tier.name, 'hd');
    });

    test('unknown metrics never upgrade', () {
      final c = QualityController();
      const unknown = LinkMetrics();
      for (var i = 0; i < 20; i++) {
        expect(c.update(unknown, t0.add(Duration(seconds: 3 * i))), isNull);
      }
      const noBwe = LinkMetrics(rttMs: 10, lossPct: 0);
      for (var i = 0; i < 20; i++) {
        expect(c.update(noBwe, t0.add(Duration(seconds: 3 * i))), isNull);
      }
      expect(c.tier.name, 'hd');
    });

    test('CPU limitation steps down and blocks climbing for a minute', () {
      final c = QualityController(start: 3);
      const cpu = LinkMetrics(
          availableOutKbps: 20000, rttMs: 20, lossPct: 0, limitation: 'cpu');
      var now = t0;
      VideoTier? changed;
      for (var i = 0; i < QualityController.downNeeded; i++) {
        changed = c.update(cpu, now);
        now = now.add(const Duration(seconds: 3));
      }
      expect(changed?.name, 'fhd');
      // Link looks great again, but the cooldown holds (~60 s).
      for (var i = 0; i < 10; i++) {
        expect(c.update(great, now), isNull,
            reason: 'cooldown at +${now.difference(t0).inSeconds}s');
        now = now.add(const Duration(seconds: 3));
      }
      expect(c.tier.name, 'fhd');
      // After the cooldown it may climb again.
      now = t0.add(const Duration(seconds: 70));
      VideoTier? up;
      for (var i = 0; i < QualityController.upNeeded; i++) {
        up = c.update(great, now);
        now = now.add(const Duration(seconds: 3));
      }
      expect(up?.name, 'max');
    });

    test('heavy loss steps down, never below eco', () {
      final c = QualityController();
      const lossy = LinkMetrics(
          availableOutKbps: 20000, rttMs: 30, lossPct: 12, limitation: 'none');
      var now = t0;
      for (var i = 0; i < 30; i++) {
        c.update(lossy, now);
        now = now.add(const Duration(seconds: 3));
      }
      expect(c.tier.name, 'eco');
    });

    test('a starved estimate (below 50% of the tier) steps down', () {
      final c = QualityController(start: 2);
      const starved = LinkMetrics(
          availableOutKbps: 2000, rttMs: 30, lossPct: 0, limitation: 'none');
      VideoTier? changed;
      for (var i = 0; i < QualityController.downNeeded; i++) {
        changed = c.update(starved, t0.add(Duration(seconds: 3 * i)));
      }
      expect(changed?.name, 'hd');
    });

    test('one bad sample alone does not flip the tier', () {
      final c = QualityController(start: 2);
      const spike = LinkMetrics(
          availableOutKbps: 20000, rttMs: 500, lossPct: 0, limitation: 'none');
      expect(c.update(spike, t0), isNull);
      expect(c.update(great, t0.add(const Duration(seconds: 3))), isNull);
      expect(c.tier.name, 'fhd');
    });
  });

  group('LinkMetrics.fromReports', () {
    StatsReport r(String id, String type, Map<String, dynamic> v) =>
        StatsReport(id, type, 0, v);

    test('reads bandwidth, rtt, loss and limitation', () {
      final m = LinkMetrics.fromReports([
        r('p1', 'candidate-pair', {
          'state': 'succeeded',
          'nominated': true,
          'availableOutgoingBitrate': 6000000,
          'currentRoundTripTime': 0.042,
        }),
        r('rin', 'remote-inbound-rtp',
            {'kind': 'video', 'fractionLost': 0.02}),
        r('out', 'outbound-rtp', {
          'kind': 'video',
          'qualityLimitationReason': 'bandwidth',
          'frameHeight': 720,
          'frameWidth': 1280,
          'bytesSent': 5400000,
          'framesPerSecond': 29.7,
        }),
        // Audio reports must not leak into the video numbers.
        r('ain', 'remote-inbound-rtp',
            {'kind': 'audio', 'fractionLost': 0.9}),
      ]);
      expect(m.availableOutKbps, closeTo(6000, 1e-6));
      expect(m.rttMs, closeTo(42, 1e-6));
      expect(m.lossPct, closeTo(2, 1e-6));
      expect(m.limitation, 'bandwidth');
      expect(m.frameHeight, 720);
      expect(m.frameWidth, 1280);
      expect(m.videoBytesSent, closeTo(5400000, 1e-6));
      expect(m.framesPerSecond, closeTo(29.7, 1e-6));
    });

    test('tolerates strings and missing sections', () {
      final m = LinkMetrics.fromReports([
        r('p', 'candidate-pair', {
          'state': 'succeeded',
          'availableOutgoingBitrate': '4000000',
        }),
      ]);
      expect(m.availableOutKbps, closeTo(4000, 1e-6));
      expect(m.rttMs, isNull);
      expect(m.lossPct, isNull);
      expect(LinkMetrics.fromReports([]).isEmpty, isTrue);
    });
  });
}
