import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:grchat_client/src/call/dock_state.dart';

/// Self-preview geometry spec (final UX ТЗ §25–§43, §55–§62). The preview
/// reuses the Mini Call Card dock model (edge + normalized offset), so
/// these assertions pin the CONTRACT the overlay leans on.
void main() {
  // The overlay's own size and a roomy video area to dock in.
  const pip = Size(180, 240);
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
}
