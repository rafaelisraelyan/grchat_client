import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:grchat_client/src/call/group_call.dart';
import 'package:grchat_client/src/call/group_call_window.dart';

/// Group surface: ringing window, minimize affordance, decline clears.
/// Join/accept need a LiveKit room and stay in the manual matrix.
Future<void> _pumpHost(WidgetTester t, ProviderContainer c) async {
  await t.pumpWidget(UncontrolledProviderScope(
      container: c,
      child: const MaterialApp(
          home: Scaffold(
              body: Stack(children: [
        Placeholder(),
        GroupCallHost(),
      ])))));
  await t.pump();
}

void main() {
  group('GroupCallHost', () {
    testWidgets('incoming group video rings with actions', (t) async {
      final c = ProviderContainer();
      addTearDown(c.dispose);
      c.read(groupCallProvider.notifier).incoming(
          callId: 'k1',
          dmId: 'd1',
          room: 'grchat_d1',
          video: true,
          fromNick: 'Second');
      await _pumpHost(t, c);
      expect(
          find.text('Входящий групповой видеозвонок'), findsOneWidget);
      expect(find.byTooltip('Принять'), findsOneWidget);
      expect(find.byTooltip('Отклонить'), findsOneWidget);
      // Chat stays mounted behind the window.
      expect(find.byType(Placeholder), findsOneWidget);
    });

    testWidgets('window offers minimize, ringing stays up', (t) async {
      final c = ProviderContainer();
      addTearDown(c.dispose);
      c.read(groupCallProvider.notifier).incoming(
          callId: 'k1',
          dmId: 'd1',
          room: 'grchat_d1',
          video: true,
          fromNick: 'Second');
      await _pumpHost(t, c);
      expect(find.byTooltip('Свернуть'), findsOneWidget);
      await t.tap(find.byTooltip('Свернуть'));
      await t.pump();
      // Ringing demands attention: the window stays, only the flag flips.
      expect(find.text('Входящий групповой видеозвонок'),
          findsOneWidget);
      expect(
          c.read(groupCallProvider)?.minimized, isTrue);
    });

    testWidgets('decline clears the surface', (t) async {
      final c = ProviderContainer();
      addTearDown(c.dispose);
      c.read(groupCallProvider.notifier).incoming(
          callId: 'k1',
          dmId: 'd1',
          room: 'grchat_d1',
          video: false,
          fromNick: 'Second');
      await _pumpHost(t, c);
      await t.tap(find.byTooltip('Отклонить'));
      await t.pump();
      expect(find.byType(GroupCallWindow), findsNothing);
      expect(find.byType(GroupMiniOverlay), findsNothing);
    });
  });
}
