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

  test('release near right-middle keeps RIGHT with vertical offset (§60)', () {
    // Mid-height, hugging the right edge (not corner-close).
    final mid = area.height / 2 - pip.height / 2;
    final rect = Rect.fromLTWH(
      area.width - kDockMargin - pip.width,
      mid,
      pip.width,
      pip.height,
    );
    final spot = snapDock(rect, area, pip);
    expect(spot.edge, DockEdge.right);
    expect(
      spot.offset,
      inExclusiveRange(0.35, 0.65),
      reason:
          'vertical position must be preserved, not pinned to a '
          'corner',
    );
    // And the snap target corresponds: same vertical band.
    final snapped = dockRect(spot, area, pip);
    expect(snapped.top, closeTo(rect.top, area.height * 0.12));
  });

  test('release bottom-left snaps to the nearest edge, pinned end (§59)', () {
    final rect = Rect.fromLTWH(
      kDockMargin + 6,
      area.height - kDockMargin - pip.height,
      pip.width,
      pip.height,
    );
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
    final stored = Offset(
      area.width - pip.width - 2,
      area.height - pip.height - 2,
    );
    final small = Size(420, 300);
    final clamped = clampCardPos(stored, small, pip);
    expect(clamped.dx, greaterThanOrEqualTo(kDockMargin));
    expect(clamped.dy, greaterThanOrEqualTo(kDockMargin));
    expect(
      clamped.dx + pip.width,
      lessThanOrEqualTo(small.width - kDockMargin + 0.5),
    );
    expect(
      clamped.dy + pip.height,
      lessThanOrEqualTo(small.height - kDockMargin + 0.5),
    );
  });

  test('size policy: min is floored at 180 even in a tiny area (§34)', () {
    expect(selfPipWidthFor(const Size(200, 160), 80), kSelfPipMinW);
    expect(selfPipWidthFor(const Size(200, 160), 999), kSelfPipMinW);
  });

  test('size policy: hard cap 420 for a roomy area (§35)', () {
    final w = selfPipWidthFor(const Size(1200, 700), 999);
    expect(w, kSelfPipHardMaxW);
    expect(selfPipHeightFor(w), closeTo(w * 9 / 16, 0.01));
  });

  test('size policy: responsive max shrinks with the window (§36, §39)', () {
    // Spec §39 example: an 800×500 area caps at ~280 px, not 420.
    final w = selfPipWidthFor(const Size(800, 500), 999);
    expect(w, closeTo(800 * 0.35, 0.01));
    expect(selfPipHeightFor(w), lessThanOrEqualTo(500 * 0.4 + 0.01));
    // Smaller window → smaller max (§36).
    expect(w, lessThan(selfPipWidthFor(const Size(1200, 700), 999)));
  });

  test('size policy: user width survives, bad values clamp (§40–§42)', () {
    expect(selfPipWidthFor(const Size(1200, 700), 220), 220);
    expect(
      selfPipWidthFor(const Size(1200, 700), 160),
      180,
      reason: 'user width below min floors to min',
    );
    expect(selfPipWidthFor(const Size(1200, 700), 999), 420);
  });

  test('size policy: height never exceeds 40% of the area (§37)', () {
    final media = const Size(2400, 400); // width budget huge, height low
    final w = selfPipWidthFor(media, 999);
    final h = selfPipHeightFor(w);
    expect(h, lessThanOrEqualTo(media.height * 0.4 + 0.01));
    expect(w, greaterThanOrEqualTo(kSelfPipMinW));
  });

  test('resize anchors the OPPOSITE corner precisely (§10/§13): '
      'bottomLeft grab on right-dock grows LEFT ONLY', () {
    // THE regression test for the right-escape: docked RIGHT, grab the
    // bottom-left (FREE) corner — the fixed corner is the top-right
    // (flush edge corner) and the rect grows toward the pointer's side,
    // NEVER rightward past the viewport.
    final start = dockRect(
        const DockSpot(DockEdge.right, 0.4), area, pip);
    final r = selfPipResizedRect(
        start: start,
        pointerDelta: const Offset(-60, 60),
        zone: SelfPipZone.bottomLeft,
        dock: DockEdge.right,
        media: area);
    expect(r.right, closeTo(start.right, 0.01),
        reason: 'flush side stays flush: rect never extends rightward');
    expect(r.top, closeTo(start.top, 0.01),
        reason: 'fixed corner (top-right) vertical stays');
    expect(r.width, greaterThan(start.width));
    expect(r.height, greaterThan(start.height));
    expect(r.left, greaterThanOrEqualTo(kDockMargin - 0.5),
        reason: 'inside the safe margin');
    expect(r.bottom, lessThanOrEqualTo(area.height - kDockMargin + 0.01));
  });

  test('resize anchors the OPPOSITE corner precisely (§10/§13): '
      'topRight grab on left-dock grows RIGHT ONLY', () {
    final start = dockRect(
        const DockSpot(DockEdge.left, 0.4), area, pip);
    final r = selfPipResizedRect(
        start: start,
        pointerDelta: const Offset(40, -40),
        zone: SelfPipZone.topRight,
        dock: DockEdge.left,
        media: area);
    expect(r.left, closeTo(start.left, 0.01),
        reason: 'flush left stays flush');
    expect(r.bottom, closeTo(start.bottom, 0.01),
        reason: 'fixed bottom-left corner vertical stays');
    expect(r.width, greaterThan(start.width));
    expect(r.height, greaterThan(start.height));
  });

  test('resize anchors the OPPOSITE corner precisely (§10/§13): '
      'bottomRight grab on left-dock keeps topLeft fixed', () {
    final start = dockRect(
        const DockSpot(DockEdge.left, 0.4), area, pip);
    final r = selfPipResizedRect(
        start: start,
        pointerDelta: const Offset(60, 60),
        zone: SelfPipZone.bottomRight,
        dock: DockEdge.left,
        media: area);
    expect(r.topLeft, start.topLeft,
        reason: 'fixed opposite corner pixel-exact');
    expect(r.width, greaterThan(start.width));
    expect(r.height, greaterThan(start.height));
  });

  test('size policy: default sits strictly between min and typical max', () {
    expect(kSelfPipMinW, lessThan(kSelfPipDefaultW));
    expect(
      kSelfPipDefaultW,
      lessThan(selfPipMaxWidthFor(const Size(1200, 700))),
    );
  });

  test('zones: corners-only resize, edges are plain drag (§1–§5, §32)', () {
    expect(selfPipZoneFor(const Offset(2, 2), pip), SelfPipZone.topLeft);
    expect(
      selfPipZoneFor(Offset(pip.width - 2, pip.height - 2), pip),
      SelfPipZone.bottomRight,
    );
    // Straight edges — even 2px from the border — are DRAG, not resize.
    expect(selfPipZoneFor(Offset(2, pip.height / 2), pip), SelfPipZone.center);
    expect(
      selfPipZoneFor(Offset(pip.width - 2, pip.height / 2), pip),
      SelfPipZone.center,
    );
    expect(selfPipZoneFor(Offset(pip.width / 2, 2), pip), SelfPipZone.center);
    // Corner zone is SMALL (12px): a bit deeper inside — plain grab.
    expect(selfPipZoneFor(const Offset(14, 14), pip), SelfPipZone.center);
  });

  test('FLUSH corner (docked RIGHT + topRight): flush corner anchored, '
      'grows down-left (§15 over §10, §20–§22)', () {
    final start = dockRect(const DockSpot(DockEdge.right, 0.4), area, pip);
    final r = selfPipResizedRect(
      start: start,
      pointerDelta: const Offset(20, 30),
      zone: SelfPipZone.topRight,
      dock: DockEdge.right,
      media: area,
    );
    // Grabbing the TOP-right corner and pulling DOWN shrinks the height
    // (the corner follows the pointer, the bottom stays), floor by minW
    // -> aspect-only floor: h = minW*9/16 = 101.25.
    expect(r.bottom, closeTo(start.bottom, 0.01));
    expect(r.right, closeTo(start.right, 0.01));
    expect(r.height, closeTo(kSelfPipMinW * kSelfPipAspect, 0.6));
    expect(r.width, kSelfPipMinW);
    expect(r.top, greaterThan(start.top));
    expect(selfPipHeightFor(r.width), closeTo(r.height, 0.01));
  });

  test('FREE corner (topLeft on right-dock): opposite corner fixed '
      '(§10/§13), one diagonal projection (§9), pull up-left grows BOTH '
      'axes with ONE formula (no dominant-axis switching, §G)', () {
    final start = dockRect(const DockSpot(DockEdge.right, 0.4), area, pip);
    // The TL corner travels WITH the pointer: pulling up-left (-,-) moves
    // the top-left corner up-left → the rect GROWS; pulling down-right
    // shrinks it. One projection scalar, no axis switching.
    final r = selfPipResizedRect(
      start: start,
      pointerDelta: const Offset(-40, -60),
      zone: SelfPipZone.topLeft,
      dock: DockEdge.right,
      media: area,
    );
    expect(
      r.width,
      greaterThan(start.width),
      reason: 'pulling the top-left corner up-left grows the rect '
          '(corner follows the pointer, §9)',
    );
    expect(r.height, greaterThan(start.height));
    // Fixed opposite corner: bottom-right stays pixel-exact (§10, §F).
    expect(r.right, closeTo(start.right, 0.01));
    expect(r.bottom, closeTo(start.bottom, 0.01));
    expect(selfPipHeightFor(r.width), closeTo(r.height, 0.01));
    // Reverse pull (down-right): shrink on both axes (§G).
    final back = selfPipResizedRect(
      start: start,
      pointerDelta: const Offset(60, 60),
      zone: SelfPipZone.topLeft,
      dock: DockEdge.right,
      media: area,
    );
    expect(back.width, lessThan(start.width));
    expect(back.height, lessThan(start.height));
  });

  test('resize limits LIVE (§17–§21): max width caps, fixed corner stays', () {
    final wide = Size(1200, 700);
    final start = dockRect(const DockSpot(DockEdge.right, 0.4), wide, pip);
    // Grab TOP-LEFT corner (free side): fixed = bottom-right; dragging far
    // left-up must clamp at the responsive/hard caps WITHOUT moving the
    // fixed corner (§20).
    final r = selfPipResizedRect(
      start: start,
      pointerDelta: const Offset(-100000, -100000),
      zone: SelfPipZone.topLeft,
      dock: DockEdge.right,
      media: wide,
    );
    expect(r.width, lessThanOrEqualTo(kSelfPipHardMaxW + 0.01));
    expect(r.width, lessThanOrEqualTo(wide.width * 0.35 + 0.01));
    expect(
      r.right,
      closeTo(start.right, 0.01),
      reason: 'fixed corner (bottom-right) stays at the docked edge',
    );
    expect(
      r.bottom,
      closeTo(start.bottom, 0.01),
      reason: 'fixed corner (bottom-right) stays vertical too',
    );
  });

  test('min width floors at 180, fixed corner intact (§18/§20)', () {
    final start = dockRect(const DockSpot(DockEdge.right, 0.4), area, pip);
    // Pull down-right from topLeft: projection goes negative → min.
    final r = selfPipResizedRect(
      start: start,
      pointerDelta: const Offset(100000, 100000),
      zone: SelfPipZone.topLeft,
      dock: DockEdge.right,
      media: area,
    );
    expect(r.width, kSelfPipMinW);
    expect(
      r.right,
      closeTo(start.right, 0.01),
      reason: 'fixed corner stays put even at the min (no bounce)',
    );
    expect(r.bottom, closeTo(start.bottom, 0.01));
  });

  test('size policy: matching spec §39 example 800×500 (§36, §39)', () {
    expect(selfPipWidthFor(const Size(800, 500), 999), 280.0);
    expect(
      selfPipHeightFor(selfPipWidthFor(const Size(800, 500), 999)),
      closeTo(280 * 9 / 16, 0.01),
    );
  });
}
