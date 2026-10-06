import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:grchat_client/src/chat/models.dart';
import 'package:grchat_client/src/chat/widgets/channel_feed.dart';

Message _post({String? editedAt}) => Message(
      id: 'p1',
      channelId: 'ch9',
      authorId: 'u2',
      authorNick: 'Editor',
      text: 'Release notes',
      createdAt: '2026-10-05T14:32:00Z',
      editedAt: editedAt,
      kind: 'post',
    );

Future<void> _pump(
    WidgetTester t, Message m, bool canModerate) async {
  await t.pumpWidget(MaterialApp(
      home: Scaffold(
          body: PostCard(message: m, canModerate: canModerate))));
  await t.pumpAndSettle();
}

/// Opens the hover menu; caller must remove the pointer at the end.
Future<TestGesture> _openMenu(WidgetTester t) async {
  final g =
      await t.createGesture(kind: ui.PointerDeviceKind.mouse);
  await g.addPointer();
  await g.moveTo(t.getCenter(find.byType(PostCard)));
  await t.pump();
  await t.tap(find.byIcon(Icons.more_horiz));
  await t.pumpAndSettle();
  return g;
}

void main() {
  group('PostCard', () {
    testWidgets('moderator gets edit and delete', (t) async {
      await _pump(t, _post(), true);
      final g = await _openMenu(t);
      expect(find.text('Редактировать'), findsOneWidget);
      expect(find.text('Удалить'), findsOneWidget);
      expect(find.text('Копировать текст'), findsOneWidget);
      await g.removePointer();
    });

    testWidgets('subscriber gets copy only', (t) async {
      await _pump(t, _post(), false);
      final g = await _openMenu(t);
      expect(find.text('Редактировать'), findsNothing);
      expect(find.text('Удалить'), findsNothing);
      expect(find.text('Копировать текст'), findsOneWidget);
      await g.removePointer();
    });

    testWidgets('edited post shows the label', (t) async {
      await _pump(t, _post(editedAt: '2026-10-05T15:00:00Z'), false);
      expect(find.text('изменено'), findsOneWidget);
    });

    testWidgets('clean post has no label', (t) async {
      await _pump(t, _post(), false);
      expect(find.text('изменено'), findsNothing);
    });
  });
}
