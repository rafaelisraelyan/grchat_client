import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:grchat_client/src/app/providers.dart';
import 'package:grchat_client/src/app/theme.dart';
import 'package:grchat_client/src/auth/auth_repository.dart';
import 'package:grchat_client/src/chat/home_screen.dart';
import 'package:grchat_client/src/chat/home_state.dart';
import 'package:grchat_client/src/chat/models.dart';

class _FakeSession extends SessionState {
  @override
  Session? build() =>
      Session(userId: 'u1', nick: 'Rafael', token: 't');
}

class _FakeHome extends HomeState {
  @override
  HomeData build() {
    final thread = DmThread(id: 'd1', isGroup: false, members: [
      DmMember(userId: 'u1', nick: 'Rafael'),
      DmMember(userId: 'u2', nick: 'Second'),
    ]);
    final comm = Community(
        id: 'c1', name: 'Club', role: 'owner', channels: [
      Channel(id: 'ch1', name: 'general', type: 'text'),
    ]);
    return HomeData(
      communities: [comm],
      dms: [thread],
      scope: DmScope(thread, 'u1'),
      messages: [
        Message(
            id: 'm1',
            dmId: 'd1',
            authorId: 'u2',
            authorNick: 'Second',
            text: 'Привет',
            createdAt: '2026-09-02T12:41:00Z'),
        Message(
            id: 'm2',
            dmId: 'd1',
            authorId: 'u1',
            authorNick: 'Rafael',
            text: 'Моё последнее',
            createdAt: '2026-09-02T12:42:00Z'),
      ],
      members: const [],
      loading: false,
    );
  }
}

Future<void> _pump(WidgetTester t) async {
  t.view.physicalSize = const Size(1280, 720);
  t.view.devicePixelRatio = 1.0;
  addTearDown(t.view.resetPhysicalSize);
  await t.pumpWidget(ProviderScope(
      overrides: [
        sessionProvider.overrideWith(_FakeSession.new),
        homeStateProvider.overrideWith(_FakeHome.new),
      ],
      child: MaterialApp(
          theme: grchatLight,
          darkTheme: grchatDark,
          themeMode: ThemeMode.dark,
          home: const HomeScreen())));
  await t.pumpAndSettle();
}

void main() {
  group('Keyboard', () {
    testWidgets('Up in empty composer edits my last message',
        (t) async {
      await _pump(t);
      expect(find.text('Редактирование'), findsNothing);
      // Focus the composer (empty) and press Up.
      await t.tap(find.byType(TextField).first);
      await t.pump();
      await t.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      await t.pumpAndSettle();
      expect(find.text('Редактирование'), findsOneWidget);
    });

    testWidgets('Ctrl+K opens the palette, filter narrows',
        (t) async {
      await _pump(t);
      await t.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await t.sendKeyEvent(LogicalKeyboardKey.keyK);
      await t.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await t.pumpAndSettle();
      if (find.text('Перейти').evaluate().isEmpty) {
        await t.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
        await t.sendKeyEvent(LogicalKeyboardKey.keyK);
        await t.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
        await t.pumpAndSettle();
      }
      expect(find.text('Перейти'), findsOneWidget);
      final inDialog = find.descendant(
          of: find.byType(AlertDialog), matching: find.text('Second'));
      expect(inDialog, findsOneWidget);
      expect(find.text('# general'), findsOneWidget);
      await t.enterText(
          find.byType(TextField).last, 'general');
      await t.pumpAndSettle();
      expect(
          find.descendant(
              of: find.byType(AlertDialog),
              matching: find.text('Second')),
          findsNothing);
      expect(find.text('# general'), findsOneWidget);
      // Esc closes.
      await t.sendKeyEvent(LogicalKeyboardKey.escape);
      await t.pumpAndSettle();
      expect(find.text('Перейти'), findsNothing);
    });
  });
}
