import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:grchat_client/src/call/call_surface.dart';
import 'package:grchat_client/src/call/dock_state.dart';

/// Self-preview geometry spec (final UX ТЗ §25–§43, §55–§62). The preview
/// reuses the Mini Call Card dock model (edge + normalized offset), so
/// these assertions pin the CONTRACT the overlay leans on.
void main() {
  // The overlay's own size (16:9 aspect, default width per §34/§43) and a
  // roomy video area to dock in.
  final pip = Size(kSelfPipDefaultW, selfPipHeightFor(kSelfPipDefaultW));
  final area = Size(880, 560);

  test('default dock is RIGHT with a middle-ish offset', () {
    final r = dockRect(const DockSpot(DockEdge.right, 0.4), area, pip);
    // Flush to the right usable edge (margin inside), vertically along
    // the edge, fully inside the area.
    expect(r.right, closeTo(area.width - kDockMargin, 0.5));
    expect(r.top, greaterThanOrEqualTo(kDockMargin));
    expect(r.bottom, lessThanOrEqualTo(area.height - kDockMargin));
  });

  test('release near right-middle keeps RIGHT with vertical offset (§60)',
      () {
    // Mid-height, hugging the right edge (not corner-close).
    final mid = area.height / 2 - pip.height / 2;
    final rect = Rect.fromLTWH(
        area.width - kDockMargin - pip.width, mid, pip.width, pip.height);
    final spot = snapDock(rect, area, pip);
    expect(spot.edge, DockEdge.right);
    expect(spot.offset, inExclusiveRange(0.35, 0.65),
        reason: 'vertical position must be preserved, not pinned to a '
            'corner');
    // And the snap target corresponds: same vertical band.
    final snapped = dockRect(spot, area, pip);
    expect(snapped.top, closeTo(rect.top, area.height * 0.12));
  });

  test('release bottom-left snaps to the nearest edge, pinned end (§59)',
      () {
    final rect = Rect.fromLTWH(
        kDockMargin + 6, area.height - kDockMargin - pip.height, pip.width,
        pip.height);
    final spot = snapDock(rect, area, pip);
    // Corner magnet: the nearest edge wins (bottom is closer than left by
    // 14 vs 20 px) and the along-edge offset pins to the exact end — the
    // preview lands glued to the bottom-LEFT visually either way.
    expect(spot.edge, DockEdge.bottom);
    expect(spot.offset, 0.0);
    final snapped = dockRect(spot, area, pip);
    expect(snapped.bottom, closeTo(area.height - kDockMargin, 0.5));
    expect(snapped.left, closeTo(kDockMargin, 0.5));
  });

  test('window shrink clamps the stored position inside bounds (§62)', () {
    final stored = Offset(area.width - pip.width - 2,
        area.height - pip.height - 2);
    final small = Size(420, 300);
    final clamped = clampCardPos(stored, small, pip);
    expect(clamped.dx, greaterThanOrEqualTo(kDockMargin));
    expect(clamped.dy, greaterThanOrEqualTo(kDockMargin));
    expect(clamped.dx + pip.width,
        lessThanOrEqualTo(small.width - kDockMargin + 0.5));
    expect(clamped.dy + pip.height,
        lessThanOrEqualTo(small.height - kDockMargin + 0.5));
  });

  test('size policy: min is floored at 180 even in a tiny area (§34)',
      () {
    expect(selfPipWidthFor(const Size(200, 160), 80), kSelfPipMinW);
    expect(selfPipWidthFor(const Size(200, 160), 999), kSelfPipMinW);
  });

  test('size policy: hard cap 420 for a roomy area (§35)', () {
    final w = selfPipWidthFor(const Size(1200, 700), 999);
    expect(w, kSelfPipHardMaxW);
    expect(selfPipHeightFor(w), closeTo(w * 9 / 16, 0.01));
  });

  test('size policy: responsive max shrinks with the window (§36, §39)',
      () {
    // Spec §39 example: an 800×500 area caps at ~280 px, not 420.
    final w = selfPipWidthFor(const Size(800, 500), 999);
    expect(w, closeTo(800 * 0.35, 0.01));
    expect(selfPipHeightFor(w), lessThanOrEqualTo(500 * 0.4 + 0.01));
    // Smaller window → smaller max (§36).
    expect(w, lessThan(selfPipWidthFor(const Size(1200, 700), 999)));
  });

  test('size policy: user width survives, bad values clamp (§40–§42)',
      () {
    expect(selfPipWidthFor(const Size(1200, 700), 220), 220);
    expect(selfPipWidthFor(const Size(1200, 700), 160), 180,
        reason: 'user width below min floors to min');
    expect(selfPipWidthFor(const Size(1200, 700), 999), 420);
  });

  test('size policy: height never exceeds 40% of the area (§37)', () {
    final media = const Size(2400, 400); // width budget huge, height low
    final w = selfPipWidthFor(media, 999);
    final h = selfPipHeightFor(w);
    expect(h, lessThanOrEqualTo(media.height * 0.4 + 0.01));
    expect(w, greaterThanOrEqualTo(kSelfPipMinW));
  });

  test('size policy: default sits strictly between min and typical max',
      () {
    expect(kSelfPipMinW, lessThan(kSelfPipDefaultW));
    expect(kSelfPipDefaultW,
        lessThan(selfPipMaxWidthFor(const Size(1200, 700))));
  });

  test('zones: corners WIN over edges (§4)', () {
    expect(selfPipZoneFor(const Offset(2, 2), pip), SelfPipZone.topLeft);
    expect(selfPipZoneFor(Offset(pip.width - 2, pip.height - 2), pip),
        SelfPipZone.bottomRight);
    expect(selfPipZoneFor(Offset(2, pip.height / 2), pip),
        SelfPipZone.left);
    expect(selfPipZoneFor(Offset(pip.width / 2, pip.height / 2), pip),
        SelfPipZone.center);
  });

  test('resize anchors the OPPOSITE side (§13–§14): drag right edge '
      'on a left-docked preview keeps LEFT flush', () {
    final start = dockRect(
        const DockSpot(DockEdge.left, 0.5), area, pip);
    final r = selfPipResizedRect(
        start: start,
        pointerDelta: const Offset(60, 0),
        zone: SelfPipZone.right,
        dock: DockEdge.left,
        media: area);
    expect(r.left, closeTo(start.left, 0.01),
        reason: 'drag RIGHT edge → LEFT side anchored (§13)');
    expect(r.width, greaterThan(start.width));
    expect(selfPipHeightFor(r.width), closeTo(r.height, 0.01),
        reason: 'aspect ratio stays 16:9 (§11)');
  });

  test('resize honors the docked edge flush (§15): docked RIGHT stays '
      'right-flush while growing', () {
    final start = dockRect(
        const DockSpot(DockEdge.right, 0.4), area, pip);
    final r = selfPipResizedRect(
        start: start,
        pointerDelta: const Offset(-40, 0),
        zone: SelfPipZone.left,
        dock: DockEdge.right,
        media: area);
    expect(r.right, closeTo(start.right, 0.01),
        reason: 'docked RIGHT: the flush edge never moves (§15)');
    expect(r.width, greaterThan(start.width));
    expect(r.left, greaterThanOrEqualTo(kDockMargin - 0.5));
  });

  test('bottom edge resize is height-driven, width re-derives (§12)',
      () {
    final start = dockRect(
        const DockSpot(DockEdge.right, 0.4), area, pip);
    final r = selfPipResizedRect(
        start: start,
        pointerDelta: const Offset(0, 40),
        zone: SelfPipZone.bottom,
        dock: DockEdge.right,
        media: area);
    expect(r.height, greaterThan(start.height));
    expect(r.width, closeTo(r.height * 16 / 9, 0.01));
  });

  test('resize limits apply LIVE (§17–§18): max width = hard cap', () {
    // A wide-enough area where the 35% budget exceeds the hard cap so
    // the cap itself binds (§35: 420 needs ≥1200 usable width).
    final wide = Size(1200, 700);
    final start = dockRect(
        const DockSpot(DockEdge.left, 0.4), wide, pip);
    final r = selfPipResizedRect(
        start: start,
        pointerDelta: const Offset(100000, 0),
        zone: SelfPipZone.right,
        dock: DockEdge.left,
        media: wide);
    expect(r.width, kSelfPipHardMaxW);
    expect(r.right, lessThanOrEqualTo(wide.width - kDockMargin + 0.01));
  });

  test('resize min width floors at 180 (§18)', () {
    final start = dockRect(
        const DockSpot(DockEdge.right, 0.4), area, pip);
    final r = selfPipResizedRect(
        start: start,
        pointerDelta: const Offset(100000, 0),
        zone: SelfPipZone.left,
        dock: DockEdge.right,
        media: area);
    expect(r.width, kSelfPipMinW);
    expect(r.right, closeTo(start.right, 0.01),
        reason: 'anchored right side stays put even at the min');
  });

  test('size policy: matching spec §39 example 800×500 (§36, §39)', () {
    expect(selfPipWidthFor(const Size(800, 500), 999), 280.0);
    expect(selfPipHeightFor(selfPipWidthFor(const Size(800, 500), 999)),
        closeTo(280 * 9 / 16, 0.01));
  });
}
