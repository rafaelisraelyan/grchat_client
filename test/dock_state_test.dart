import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:grchat_client/src/call/dock_state.dart';

/// Docking math (§57): snap positions, resize survival, corner pins.
void main() {
  const app = Size(1280, 720);
  const card = Size(300, 224);

  group('dockRect', () {
    test('initial is top-right with margin', () {
      final r = dockRect(DockSpot.initial, app, card);
      expect(r.right, closeTo(1280 - 14, 1e-9));
      expect(r.top, closeTo(14, 1e-9));
      expect(r.size, card);
    });

    test('right-middle parks mid-edge, not a corner', () {
      final r = dockRect(
          const DockSpot(DockEdge.right, 0.5), app, card);
      expect(r.right, closeTo(1280 - 14, 1e-9));
      expect(r.top, closeTo(14 + 0.5 * (720 - 28 - 224), 1e-9));
    });

    test('resize keeps the edge and relative offset', () {
      const spot = DockSpot(DockEdge.right, 0.5);
      final before = dockRect(spot, app, card);
      final after = dockRect(spot, const Size(900, 600), card);
      // Still right-docked with margin…
      expect(after.right, closeTo(900 - 14, 1e-9));
      // …still mid-edge and fully on-screen, never stranded.
      expect(after.top, greaterThan(14));
      expect(after.bottom, lessThanOrEqualTo(600 - 14));
      expect(after.top, lessThan(before.top));
    });

    test('tiny window clamps inside, card stays reachable', () {
      final r = dockRect(
          const DockSpot(DockEdge.right, 1.0), const Size(200, 200), card);
      expect(r.left, greaterThanOrEqualTo(14));
      expect(r.top, greaterThanOrEqualTo(14));
    });
  });

  group('snapDock', () {
    test('right side keeps vertical position', () {
      final s = snapDock(
          const Rect.fromLTWH(900, 300, 300, 224), app, card);
      expect(s.edge, DockEdge.right);
      expect(s.offset, greaterThan(0.3));
      expect(s.offset, lessThan(0.7));
    });

    test('near corner pins to the exact end', () {
      final s = snapDock(
          const Rect.fromLTWH(950, 480, 300, 224), app, card);
      // Bottom-right corner either way: edge + end offset describes it.
      expect(s.offset, 1.0);
      expect(s.edge == DockEdge.right || s.edge == DockEdge.bottom,
          isTrue);
      // And it really lands in the corner.
      final r = dockRect(s, app, card);
      expect(r.right, closeTo(1280 - 14, 1e-9));
      expect(r.bottom, closeTo(720 - 14, 1e-9));
    });

    test('top edge keeps horizontal offset, not a corner', () {
      final s = snapDock(
          const Rect.fromLTWH(500, 20, 300, 224), app, card);
      expect(s.edge, DockEdge.top);
      expect(s.offset, greaterThan(0.2));
      expect(s.offset, lessThan(0.8));
    });

    test('left and bottom edges resolve', () {
      expect(
          snapDock(const Rect.fromLTWH(20, 300, 300, 224), app, card)
              .edge,
          DockEdge.left);
      expect(
          snapDock(const Rect.fromLTWH(500, 480, 300, 224), app, card)
              .edge,
          DockEdge.bottom);
    });

    test('snap is the inverse of dockRect (round trip)', () {
      for (final spot in [
        const DockSpot(DockEdge.right, 0.0),
        const DockSpot(DockEdge.right, 0.37),
        const DockSpot(DockEdge.left, 0.71),
        const DockSpot(DockEdge.top, 0.2),
        const DockSpot(DockEdge.bottom, 0.9),
      ]) {
        final back = snapDock(dockRect(spot, app, card), app, card);
        expect(back.edge, spot.edge);
        expect(back.offset, closeTo(spot.offset, 1e-9));
      }
    });
  });

  group('clampCardPos', () {
    test('drag never leaves the usable area', () {
      expect(clampCardPos(const Offset(-50, -50), app, card),
          const Offset(14, 14));
      expect(clampCardPos(const Offset(5000, 5000), app, card),
          const Offset(1280 - 14 - 300, 720 - 14 - 224));
    });
  });
}
