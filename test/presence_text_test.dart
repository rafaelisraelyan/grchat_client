import 'package:flutter_test/flutter_test.dart';
import 'package:grchat_client/src/chat/models.dart';
import 'package:grchat_client/src/chat/presence_text.dart';

void main() {
  // Fixed "now": 2026-10-10 (Saturday) 15:00 local.
  final now = DateTime(2026, 10, 10, 15, 0);

  PeerPresence p({bool online = false, DateTime? seen}) => PeerPresence(
      userId: 'u2', online: online, lastSeen: seen);

  group('formatPresence', () {
    test('unknown renders as nothing, never a fake status', () {
      expect(formatPresence(null, now), '');
      expect(formatPresence(p(), now), '');
    });

    test('online', () {
      expect(formatPresence(p(online: true), now), 'в сети');
    });

    test('minutes and hours with Russian plurals', () {
      expect(formatPresence(p(seen: now.subtract(
          const Duration(seconds: 30))), now), 'был(а) недавно');
      expect(formatPresence(p(seen: now.subtract(
          const Duration(minutes: 1))), now), 'был(а) 1 минуту назад');
      expect(formatPresence(p(seen: now.subtract(
          const Duration(minutes: 5))), now), 'был(а) 5 минут назад');
      expect(formatPresence(p(seen: now.subtract(
          const Duration(minutes: 21))), now), 'был(а) 21 минуту назад');
      expect(formatPresence(p(seen: now.subtract(
          const Duration(hours: 1))), now), 'был(а) 1 час назад');
      expect(formatPresence(p(seen: now.subtract(
          const Duration(hours: 3))), now), 'был(а) 3 часа назад');
      expect(formatPresence(p(seen: now.subtract(
          const Duration(hours: 5))), now), 'был(а) 5 часов назад');
    });

    test('yesterday, days, dates', () {
      expect(
          formatPresence(
              p(seen: DateTime(2026, 10, 9, 22, 7)), now),
          'был(а) вчера в 22:07');
      expect(
          formatPresence(
              p(seen: now.subtract(const Duration(days: 3))), now),
          'был(а) 3 дня назад');
      expect(
          formatPresence(
              p(seen: DateTime(2026, 10, 1, 9, 0)), now),
          'был(а) 1 окт');
      expect(
          formatPresence(
              p(seen: DateTime(2025, 12, 31, 23, 59)), now),
          'был(а) 31 дек 2025');
    });

    test('fromJson tolerates missing and broken stamps', () {
      final a = PeerPresence.fromJson(
          {'user_id': 'u2', 'online': true});
      expect(a.online, isTrue);
      expect(a.lastSeen, isNull);
      final b = PeerPresence.fromJson(
          {'user_id': 'u2', 'online': false, 'last_seen': 'garbage'});
      expect(b.online, isFalse);
      expect(b.lastSeen, isNull);
      final c = PeerPresence.fromJson({
        'user_id': 'u2',
        'online': false,
        'last_seen': '2026-10-09T22:07:00Z'
      });
      expect(c.lastSeen, isNotNull);
    });
  });
}
