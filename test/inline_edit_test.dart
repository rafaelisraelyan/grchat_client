import 'dart:ui' as ui;

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
    return HomeData(
      communities: const [],
      dms: [thread],
      scope: DmScope(thread, 'u1'),
      messages: [
        Message(
            id: 'm1',
            dmId: 'd1',
            authorId: 'u1',
            authorNick: 'Rafael',
            text: 'Моё сообщение',
            createdAt: '2026-09-02T12:41:00Z'),
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

Future<void> _hoverEdit(WidgetTester t) async {
  final g =
      await t.createGesture(kind: ui.PointerDeviceKind.mouse);
  await g.addPointer();
  await g.moveTo(t.getCenter(find.text('Моё сообщение')));
  await t.pumpAndSettle();
  await t.tap(find.byIcon(Icons.edit));
  await t.pumpAndSettle();
  await g.removePointer();
}

void main() {
  group('Inline edit', () {
    testWidgets('toolbar opens the banner prefilled', (t) async {
      await _pump(t);
      expect(find.text('Редактирование'), findsNothing);
      await _hoverEdit(t);
      expect(find.text('Редактирование'), findsOneWidget);
      // Composer prefilled with the message text.
      final fields = find.byType(TextField);
      expect(fields, findsOneWidget);
      expect(
          (t.widget<TextField>(fields).controller?.text ?? ''),
          'Моё сообщение');
      // Checkmark action instead of the send plane.
      expect(find.byTooltip('Сохранить'), findsOneWidget);
    });

    testWidgets('Esc cancels editing', (t) async {
      await _pump(t);
      await _hoverEdit(t);
      expect(find.text('Редактирование'), findsOneWidget);
      await t.sendKeyEvent(LogicalKeyboardKey.escape);
      await t.pumpAndSettle();
      expect(find.text('Редактирование'), findsNothing);
    });

    testWidgets('failed save keeps the draft', (t) async {
      await _pump(t);
      await _hoverEdit(t);
      await t.enterText(find.byType(TextField), 'Новый текст');
      await t.tap(find.byTooltip('Сохранить'));
      // No dev server here: the 15s request timeout fires, save fails,
      // banner stays with the draft. No settle: reconnect timers pend.
      await t.pump();
      await t.pump(const Duration(seconds: 20));
      await t.pump();
      expect(find.text('Редактирование'), findsOneWidget);
    });
  });
}
