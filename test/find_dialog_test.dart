import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:grchat_client/src/auth/auth_repository.dart';
import 'package:grchat_client/src/search/find_dialog.dart';
import 'package:grchat_client/src/search/search_address.dart';
import 'package:grchat_client/src/search/search_results.dart';

class _FakeApi implements FindSearchApi {
  final calls = <String>[];
  GrchatException? throwNext;

  @override
  Future<ServerHit> findServer(String alias) async {
    calls.add('server:$alias');
    final e = throwNext;
    if (e != null) throw e;
    return ServerHit(
        communityId: 'c1',
        name: 'GR Audio',
        alias: alias,
        isPrivate: false,
        membersCount: 423,
        isMember: false);
  }

  @override
  Future<ChannelHit> findChannel(String alias) async {
    calls.add('channel:$alias');
    final e = throwNext;
    if (e != null) throw e;
    return ChannelHit(
        channelId: 'ch1',
        name: 'News',
        alias: alias,
        type: 'text',
        isPrivate: false,
        subscribersCount: 12,
        hasAccess: false);
  }

  @override
  Future<({String userId, String nick})> findUser(String nick) async {
    calls.add('user:$nick');
    final e = throwNext;
    if (e != null) throw e;
    return (userId: 'u9', nick: nick);
  }
}

Future<void> _pump(
    WidgetTester t, _FakeApi api, List<String> actions,
    {SearchTargetType initial = SearchTargetType.channel}) async {
  await t.pumpWidget(MaterialApp(
      home: Scaffold(
          body: FindDialog(
    initialType: initial,
    search: api,
    onOpenServer: (_) async => actions.add('open-server'),
    onOpenChannel: (_) async => actions.add('open-channel'),
    onWriteUser: (n) async => actions.add('write:$n'),
    onJoinServer: (_) async => actions.add('join-server'),
    onSubscribeChannel: (_) async => actions.add('subscribe-channel'),
  ))));
  await t.pumpAndSettle();
}

void main() {
  group('FindDialog', () {
    testWidgets('prefix follows the selected type', (t) async {
      final api = _FakeApi();
      await _pump(t, api, []);
      expect(find.text('channel/'), findsOneWidget);
      await t.tap(find.text('Сервер'));
      await t.pumpAndSettle();
      expect(find.text('server/'), findsOneWidget);
      await t.tap(find.text('Пользователь'));
      await t.pumpAndSettle();
      expect(find.text('user/'), findsOneWidget);
    });

    testWidgets('paste of a full address switches the type', (t) async {
      final api = _FakeApi();
      await _pump(t, api, []);
      await t.enterText(find.byType(TextField), 'server/GRAUDIO');
      await t.pumpAndSettle();
      expect(find.text('server/'), findsOneWidget);
      expect(find.text('GRAUDIO'), findsOneWidget);
    });

    testWidgets('switching type keeps the query', (t) async {
      final api = _FakeApi();
      await _pump(t, api, []);
      await t.enterText(find.byType(TextField), 'ABC123');
      await t.tap(find.text('Сервер'));
      await t.pumpAndSettle();
      expect(find.text('server/'), findsOneWidget);
      expect(find.text('ABC123'), findsOneWidget);
    });

    testWidgets('empty query sends no request', (t) async {
      final api = _FakeApi();
      await _pump(t, api, []);
      await t.tap(find.text('Найти'));
      await t.pumpAndSettle();
      expect(api.calls, isEmpty);
    });

    testWidgets('unknown prefix does not crash', (t) async {
      final api = _FakeApi();
      await _pump(t, api, []);
      await t.enterText(find.byType(TextField), 'group/ABC');
      await t.tap(find.text('Найти'));
      await t.pumpAndSettle();
      // Falls back to the selected type with the raw text.
      expect(api.calls, ['channel:group/ABC']);
    });

    testWidgets('bot type is present but inactive', (t) async {
      final api = _FakeApi();
      await _pump(t, api, [], initial: SearchTargetType.bot);
      expect(find.text('Боты появятся позже.'), findsOneWidget);
      expect(find.text('Найти'), findsNothing);
      expect(api.calls, isEmpty);
    });

    testWidgets('server result offers join, then runs it', (t) async {
      final api = _FakeApi();
      final actions = <String>[];
      await _pump(t, api, actions);
      await t.tap(find.text('Сервер'));
      await t.pumpAndSettle();
      await t.enterText(find.byType(TextField), 'GRAUDIO');
      await t.tap(find.text('Найти'));
      await t.pumpAndSettle();
      expect(find.text('GR Audio'), findsOneWidget);
      expect(find.text('Присоединиться'), findsOneWidget);
      await t.tap(find.text('Присоединиться'));
      await t.pumpAndSettle();
      expect(actions, ['join-server']);
      expect(find.byType(FindDialog), findsNothing);
    });

    testWidgets('not found shows Russian copy', (t) async {
      final api = _FakeApi()..throwNext = GrchatException('NOT_FOUND');
      await _pump(t, api, []);
      await t.tap(find.text('Сервер'));
      await t.pumpAndSettle();
      await t.enterText(find.byType(TextField), 'NOPE');
      await t.tap(find.text('Найти'));
      await t.pumpAndSettle();
      expect(
          find.text('Сервер с таким кодом не найден.'), findsOneWidget);
    });

    testWidgets('user result offers write', (t) async {
      final api = _FakeApi();
      final actions = <String>[];
      await _pump(t, api, actions, initial: SearchTargetType.user);
      await t.enterText(find.byType(TextField), 'rafael');
      await t.tap(find.text('Найти'));
      await t.pumpAndSettle();
      expect(find.text('Написать'), findsOneWidget);
      await t.tap(find.text('Написать'));
      await t.pumpAndSettle();
      expect(actions, ['write:rafael']);
    });
  });
}
