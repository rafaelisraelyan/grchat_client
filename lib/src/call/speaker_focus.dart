/// Stabilized active-speaker presentation (§38–§40, §11–§15).
///
/// Raw SFU speaking state flaps with every syllable, cough and "угу".
/// This turns it into a calm `displayedId` that changes rarely:
/// a candidate must dominate continuously for [dominance] while the current
/// display has been held for at least [hold]. Silence never clears the
/// display (§21) — the last speaker stays put.
///
/// Pure logic, no widgets: engines feed it levels, the pill reads
/// [displayedId]. Clock is injected for tests.
///
/// Callers pre-filter: only REMOTE peers go in (§19–§20); the local user
/// never becomes the pill preview even mid-sentence.
class SpeakerStabilizer {
  SpeakerStabilizer({
    this.dominance = const Duration(milliseconds: 700),
    this.hold = const Duration(milliseconds: 1000),
    this.minLevel = 0.05,
  });

  /// A candidate must speak this long without interruption.
  final Duration dominance;

  /// Minimum time between display switches (anti-flicker).
  final Duration hold;

  /// Levels below this do not count as speaking, even with the flag set.
  final double minLevel;

  String? _displayed;
  String? _candidate;
  DateTime? _candidateSince;
  DateTime? _displayedSince;

  String? get displayedId => _displayed;

  void reset() {
    _displayed = null;
    _candidate = null;
    _candidateSince = null;
    _displayedSince = null;
  }

  /// Feed one sample. [levels] maps peer id → 0..1 loudness, [speaking]
  /// the SFU speaking flags. [knownIds] are the remote peers currently in
  /// the room: a displayed speaker who left clears immediately (the facade
  /// falls back to the first remaining remote, §22). Only ids present in
  /// [levels] are eligible. Returns the (possibly unchanged) [displayedId].
  String? update({
    required Map<String, double> levels,
    required Set<String> speaking,
    required Set<String> knownIds,
    required DateTime now,
  }) {
    if (_displayed != null && !knownIds.contains(_displayed)) {
      _displayed = null;
      _displayedSince = null;
      _candidate = null;
      _candidateSince = null;
    }
    String? loudest;
    var top = 0.0;
    for (final e in levels.entries) {
      if (!speaking.contains(e.key)) continue;
      if (e.value < minLevel) continue;
      if (e.value > top) {
        top = e.value;
        loudest = e.key;
      }
    }
    if (loudest == null) {
      // Silence or noise below threshold: hold the last display (§21).
      // A dead candidate (went quiet) stops accumulating.
      _candidate = null;
      _candidateSince = null;
      return _displayed;
    }
    if (loudest == _displayed) {
      _candidate = null;
      _candidateSince = null;
      return _displayed;
    }
    if (loudest != _candidate) {
      _candidate = loudest;
      _candidateSince = now;
      return _displayed;
    }
    final stableFor = now.difference(_candidateSince ?? now);
    final heldFor = now.difference(_displayedSince ?? now);
    // The first display has nothing to hold onto: dominance alone decides.
    // Later switches additionally respect the hold (anti-flutter, §14).
    final heldOk = _displayed == null || heldFor >= hold;
    if (stableFor >= dominance && heldOk) {
      _displayed = loudest;
      _displayedSince = now;
      _candidate = null;
      _candidateSince = null;
    }
    return _displayed;
  }
}
