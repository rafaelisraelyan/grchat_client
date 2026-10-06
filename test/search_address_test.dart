import 'package:flutter_test/flutter_test.dart';
import 'package:grchat_client/src/search/search_address.dart';

void main() {
  group('parseSearchAddress', () {
    test('parses all four types', () {
      expect(parseSearchAddress('channel/7F2K9A')?.type,
          SearchTargetType.channel);
      expect(parseSearchAddress('server/GRAUDIO')?.query, 'GRAUDIO');
      expect(parseSearchAddress('bot/MUSIC01')?.type, SearchTargetType.bot);
      expect(parseSearchAddress('user/rafael')?.query, 'rafael');
    });

    test('prefix is case-insensitive, query is not', () {
      final p = parseSearchAddress('SERVER/GRAUDIO');
      expect(p?.type, SearchTargetType.server);
      expect(p?.query, 'GRAUDIO');
      expect(
          parseSearchAddress('user/Rafael')?.query, 'Rafael');
    });

    test('rejects empty query, unknown prefix, extra slashes', () {
      expect(parseSearchAddress('channel/'), isNull);
      expect(parseSearchAddress('channel/  '), isNull);
      expect(parseSearchAddress('group/ABC'), isNull);
      expect(parseSearchAddress('server/A/B'), isNull);
      expect(parseSearchAddress('noSlashHere'), isNull);
      expect(parseSearchAddress(''), isNull);
    });
  });

  group('alias rules', () {
    test('accepts valid aliases', () {
      expect(isValidAlias('GRAUDIO'), isTrue);
      expect(isValidAlias('news_24'), isTrue);
      expect(isValidAlias('AB1'), isTrue);
    });

    test('rejects bad format', () {
      expect(isValidAlias('AB'), isFalse);
      expect(isValidAlias('a' * 25), isFalse);
      expect(isValidAlias('has space'), isFalse);
      expect(isValidAlias('has-dash'), isFalse);
      expect(isValidAlias('uniçode'), isFalse);
    });

    test('rejects reserved words case-insensitively', () {
      expect(isAllowedAlias('admin'), isFalse);
      expect(isAllowedAlias('ADMIN'), isFalse);
      expect(isAllowedAlias('Server'), isFalse);
      expect(isAllowedAlias('GRAUDIO'), isTrue);
    });
  });

  group('addressOf', () {
    test('builds full human-readable form', () {
      expect(addressOf(SearchTargetType.channel, '7F2K9A'),
          'channel/7F2K9A');
      expect(addressOf(SearchTargetType.user, 'rafael'), 'user/rafael');
    });
  });
}
