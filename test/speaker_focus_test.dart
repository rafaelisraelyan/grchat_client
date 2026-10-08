import 'package:flutter_test/flutter_test.dart';
import 'package:grchat_client/src/call/speaker_focus.dart';

/// Presentation stability (§56–§57): short bursts and thrash never flip
/// the pill preview; stable speech does.
void main() {
  DateTime t(int ms) =>
      DateTime.fromMillisecondsSinceEpoch(ms);

  SpeakerStabilizer stab() => SpeakerStabilizer();

  Map<String, double> lv(Map<String, double> m) => m;
  Set<String> sp(List<String> ids) => ids.toSet();

  group('SpeakerStabilizer', () {
    test('stable speech over threshold becomes displayed', () {
      final s = stab();
      // Masha speaks alone: nothing until 700ms of dominance.
      expect(
          s.update(
              levels: lv({'m': 0.6}),
              speaking: sp(['m']),
              knownIds: const {'m'},
              now: t(0)),
          isNull);
      expect(
          s.update(
              levels: lv({'m': 0.6}),
              speaking: sp(['m']),
              knownIds: const {'m'},
              now: t(699)),
          isNull);
      expect(
          s.update(
              levels: lv({'m': 0.6}),
              speaking: sp(['m']),
              knownIds: const {'m'},
              now: t(700)),
          'm');
    });

    test('150ms burst never switches (§13, §39)', () {
      final s = stab();
      s.update(
          levels: lv({'m': 0.6}),
          speaking: sp(['m']),
          knownIds: const {'m', 'a'},
          now: t(0));
      s.update(
          levels: lv({'m': 0.6}),
          speaking: sp(['m']),
          knownIds: const {'m', 'a'},
          now: t(700));
      expect(s.displayedId, 'm');
      // Alex "да" for 200ms: Masha stays.
      s.update(
          levels: lv({'m': 0.1, 'a': 0.8}),
          speaking: sp(['m', 'a']),
          knownIds: const {'m', 'a'},
          now: t(800));
      s.update(
          levels: lv({'m': 0.1, 'a': 0.8}),
          speaking: sp(['m', 'a']),
          knownIds: const {'m', 'a'},
          now: t(1000));
      expect(s.displayedId, 'm');
    });

    test('sustained new speaker takes over after dominance + hold', () {
      final s = stab();
      s.update(
          levels: lv({'m': 0.6}),
          speaking: sp(['m']),
          knownIds: const {'m', 'a'},
          now: t(0));
      s.update(
          levels: lv({'m': 0.6}),
          speaking: sp(['m']),
          knownIds: const {'m', 'a'},
          now: t(700));
      expect(s.displayedId, 'm');
      // Alex starts a sentence at t=2000, dominant since.
      s.update(
          levels: lv({'m': 0.1, 'a': 0.7}),
          speaking: sp(['m', 'a']),
          knownIds: const {'m', 'a'},
          now: t(2000));
      // 600ms in: not yet (needs 700).
      s.update(
          levels: lv({'m': 0.1, 'a': 0.7}),
          speaking: sp(['m', 'a']),
          knownIds: const {'m', 'a'},
          now: t(2600));
      expect(s.displayedId, 'm');
      // 700ms dominant, hold (since t=700 → 2000ms) satisfied.
      s.update(
          levels: lv({'m': 0.1, 'a': 0.7}),
          speaking: sp(['m', 'a']),
          knownIds: const {'m', 'a'},
          now: t(2700));
      expect(s.displayedId, 'a');
    });

    test('hold blocks instant flip-flop (§14)', () {
      final s = stab();
      s.update(
          levels: lv({'m': 0.6}),
          speaking: sp(['m']),
          knownIds: const {'m', 'a'},
          now: t(0));
      s.update(
          levels: lv({'m': 0.6}),
          speaking: sp(['m']),
          knownIds: const {'m', 'a'},
          now: t(700));
      // Alex dominant a full 700ms but only 100ms after the last switch.
      s.update(
          levels: lv({'a': 0.9}),
          speaking: sp(['a']),
          knownIds: const {'m', 'a'},
          now: t(800));
      s.update(
          levels: lv({'a': 0.9}),
          speaking: sp(['a']),
          knownIds: const {'m', 'a'},
          now: t(1500));
      expect(s.displayedId, 'm',
          reason: '700ms dominance but hold (1000ms since switch) not met');
      s.update(
          levels: lv({'a': 0.9}),
          speaking: sp(['a']),
          knownIds: const {'m', 'a'},
          now: t(1700));
      expect(s.displayedId, 'a');
    });

    test('silence keeps the last speaker (§21)', () {
      final s = stab();
      s.update(
          levels: lv({'m': 0.6}),
          speaking: sp(['m']),
          knownIds: const {'m', 'a'},
          now: t(0));
      s.update(
          levels: lv({'m': 0.6}),
          speaking: sp(['m']),
          knownIds: const {'m', 'a'},
          now: t(700));
      expect(
          s.update(
              levels: const {},
              speaking: const {},
              knownIds: const {'m', 'a'},
              now: t(5000)),
          'm');
      // Quiet frames below threshold do not clear either.
      expect(
          s.update(
              levels: lv({'m': 0.01}),
              speaking: sp(['m']),
              knownIds: const {'m', 'a'},
              now: t(6000)),
          'm');
    });

    test('thrash A/B never flaps the display (§57)', () {
      final s = stab();
      s.update(
          levels: lv({'m': 0.6}),
          speaking: sp(['m']),
          knownIds: const {'m', 'a'},
          now: t(0));
      s.update(
          levels: lv({'m': 0.6}),
          speaking: sp(['m']),
          knownIds: const {'m', 'a'},
          now: t(700));
      // 100–200ms alternating bursts for 3 seconds.
      var now = 1000;
      var turn = false;
      final seen = <String?>{};
      while (now < 4000) {
        turn = !turn;
        final id = turn ? 'a' : 'm';
        s.update(
            levels: lv({id: 0.8}),
            speaking: sp([id]),
            knownIds: const {'m', 'a'},
            now: t(now));
        seen.add(s.displayedId);
        now += turn ? 100 : 200;
      }
      expect(seen, {'m'},
          reason: 'no burst survives 700ms, display must not flap');
    });

    test('loud but not speaking never wins (§15 threshold)', () {
      final s = stab();
      s.update(
          levels: lv({'m': 0.9}),
          speaking: const {},
          knownIds: const {'m'},
          now: t(0));
      s.update(
          levels: lv({'m': 0.9}),
          speaking: const {},
          knownIds: const {'m'},
          now: t(5000));
      expect(s.displayedId, isNull);
    });

    test('speaker who left clears immediately', () {
      final s = stab();
      s.update(
          levels: lv({'m': 0.6}),
          speaking: sp(['m']),
          knownIds: const {'m', 'a'},
          now: t(0));
      s.update(
          levels: lv({'m': 0.6}),
          speaking: sp(['m']),
          knownIds: const {'m', 'a'},
          now: t(700));
      expect(s.displayedId, 'm');
      expect(
          s.update(
              levels: lv({'a': 0.2}),
              speaking: const {},
              knownIds: const {'a'},
              now: t(800)),
          isNull);
    });
  });
}
