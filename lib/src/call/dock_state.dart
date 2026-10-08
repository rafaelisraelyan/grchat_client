import 'dart:ui';

/// Docking model for the Mini Call Card (§33–§43).
///
/// A dock is an edge plus a normalized offset along it — never bare x/y —
/// so window resizes adapt instead of stranding the card (§42–§43).
/// Corners need no special case: right + offset 1.0 *is* bottom-right (§36).
class DockSpot {
  const DockSpot(this.edge, this.offset);

  /// First minimize of a session lands here (§39).
  static const DockSpot initial = DockSpot(DockEdge.right, 0.0);

  final DockEdge edge;

  /// 0..1 along the edge (top→bottom for sides, left→right for top/bottom).
  final double offset;

  DockSpot clamped() => DockSpot(edge, offset.clamp(0.0, 1.0));

  @override
  bool operator ==(Object other) =>
      other is DockSpot && other.edge == edge && other.offset == offset;

  @override
  int get hashCode => Object.hash(edge, offset);

  @override
  String toString() => 'DockSpot($edge, ${offset.toStringAsFixed(2)})';
}

enum DockEdge { left, right, top, bottom }

/// Usable-area margins: the card never docks pixel-to-pixel (§38) and
/// never slides under the native title controls (§48).
const double kDockMargin = 14;

/// Card rect for [spot] inside [app]. Always fully inside the usable area;
/// clamps when the window shrank past the old position (§43).
Rect dockRect(DockSpot spot, Size app, Size card) {
  final s = spot.clamped();
  final maxX = (app.width - kDockMargin - card.width)
      .clamp(kDockMargin, double.infinity);
  final maxY = (app.height - kDockMargin - card.height)
      .clamp(kDockMargin, double.infinity);
  switch (s.edge) {
    case DockEdge.left:
      return Rect.fromLTWH(
          kDockMargin, kDockMargin + s.offset * (maxY - kDockMargin), card.width, card.height);
    case DockEdge.right:
      return Rect.fromLTWH(maxX,
          kDockMargin + s.offset * (maxY - kDockMargin), card.width, card.height);
    case DockEdge.top:
      return Rect.fromLTWH(
          kDockMargin + s.offset * (maxX - kDockMargin), kDockMargin, card.width, card.height);
    case DockEdge.bottom:
      return Rect.fromLTWH(kDockMargin + s.offset * (maxX - kDockMargin),
          maxY, card.width, card.height);
  }
}

/// Magnetic snap for a release rect (§33–§37): nearest edge wins; near a
/// corner the offset pins to the exact end (§36). Returns edge + offset —
/// the card then animates there over ~220ms, it never stays floating.
DockSpot snapDock(Rect rect, Size app, Size card) {
  const cornerPull = 90.0;
  final dTop = rect.top;
  final dBottom = app.height - rect.bottom;
  final dLeft = rect.left;
  final dRight = app.width - rect.right;
  final maxX = app.width - kDockMargin - card.width;
  final maxY = app.height - kDockMargin - card.height;
  // Inverse of dockRect: release position back to a normalized offset.
  double offX() {
    final range = maxX - kDockMargin;
    if (range <= 0) return 0.5;
    return ((rect.left - kDockMargin) / range).clamp(0.0, 1.0);
  }

  double offY() {
    final range = maxY - kDockMargin;
    if (range <= 0) return 0.5;
    return ((rect.top - kDockMargin) / range).clamp(0.0, 1.0);
  }

  final nearTop = dTop < cornerPull;
  final nearBottom = dBottom < cornerPull;
  final nearLeft = dLeft < cornerPull;
  final nearRight = dRight < cornerPull;
  // Corner magnet: pin the exact corner through one edge + end offset.
  if ((nearTop || nearBottom) && (nearLeft || nearRight)) {
    if (dLeft <= dRight && dLeft <= dTop && dLeft <= dBottom) {
      return DockSpot(DockEdge.left, nearTop ? 0.0 : 1.0);
    }
    if (dRight <= dLeft && dRight <= dTop && dRight <= dBottom) {
      return DockSpot(DockEdge.right, nearTop ? 0.0 : 1.0);
    }
    if (dTop <= dBottom) {
      return DockSpot(DockEdge.top, nearLeft ? 0.0 : 1.0);
    }
    return DockSpot(DockEdge.bottom, nearLeft ? 0.0 : 1.0);
  }
  final m = [dTop, dBottom, dLeft, dRight]
      .reduce((a, b) => a < b ? a : b);
  if (m == dTop) return DockSpot(DockEdge.top, offX());
  if (m == dBottom) return DockSpot(DockEdge.bottom, offX());
  if (m == dLeft) return DockSpot(DockEdge.left, offY());
  return DockSpot(DockEdge.right, offY());
}

/// Clamp a dragged top-left so the card stays fully usable (§32).
Offset clampCardPos(Offset pos, Size app, Size card) {
  final maxX = app.width - kDockMargin - card.width;
  final maxY = app.height - kDockMargin - card.height;
  return Offset(
    pos.dx.clamp(kDockMargin, maxX < kDockMargin ? kDockMargin : maxX),
    pos.dy.clamp(kDockMargin, maxY < kDockMargin ? kDockMargin : maxY),
  );
}
