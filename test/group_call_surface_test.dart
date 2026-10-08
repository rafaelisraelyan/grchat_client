import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:grchat_client/src/app/providers.dart';
import 'package:grchat_client/src/auth/auth_repository.dart';
import 'package:grchat_client/src/call/call_session.dart';
import 'package:grchat_client/src/call/call_state.dart';
import 'package:grchat_client/src/call/call_surface.dart';
import 'package:grchat_client/src/call/group_call.dart';

/// Group calls through the universal window: ringing, attention,
/// decline, and the active participant grid. Join/accept need a LiveKit
/// room and stay in the manual matrix.

class _FakeSession extends SessionState {
  @override
  Session? build() => Session(userId: 'u1', nick: 'Rafael', token: 't');
}

class _FakeGroup extends GroupCallState {
  _FakeGroup(this._c);
  final GroupCall? _c;

  @override
  GroupCall? build() => _c;
}

Future<void> _pumpHost(WidgetTester t, ProviderContainer c) async {
  await t.pumpWidget(UncontrolledProviderScope(
      container: c,
      child: const MaterialApp(
          home: Scaffold(
              body: Stack(children: [
        Placeholder(),
        CallOverlayHost(),
      ])))));
  await t.pump();
}

ProviderContainer _incomingContainer() {
  final c = ProviderContainer();
  addTearDown(c.dispose);
  c.read(groupCallProvider.notifier).incoming(
      callId: 'k1',
      dmId: 'd1',
      room: 'grchat_d1',
      video: true,
      fromNick: 'Second');
  return c;
}

void main() {
  group('GroupCall on universal window', () {
    testWidgets('incoming group video rings with actions', (t) async {
      await _pumpHost(t, _incomingContainer());
      expect(
          find.text('Входящий групповой видеозвонок'), findsOneWidget);
      expect(find.byTooltip('Принять'), findsOneWidget);
      expect(find.byTooltip('Отклонить'), findsOneWidget);
      // Chat stays mounted behind the window.
      expect(find.byType(Placeholder), findsOneWidget);
    });

    testWidgets('minimize keeps a ringing window up', (t) async {
      final c = _incomingContainer();
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
      final c = _incomingContainer();
      await _pumpHost(t, c);
      await t.tap(find.byTooltip('Отклонить'));
      await t.pump();
      expect(find.byType(CallWindow), findsNothing);
      expect(find.byType(MiniCallOverlay), findsNothing);
    });

    testWidgets('active group shows the participant grid', (t) async {
      final c = ProviderContainer(overrides: [
        sessionProvider.overrideWith(_FakeSession.new),
        groupCallProvider.overrideWith(() => _FakeGroup(GroupCall(
            dmId: 'd1',
            title: 'Команда',
            room: 'grchat_d1',
            video: true,
            outgoing: true,
            phase: GroupPhase.active,
            callId: 'k1',
            peers: [
              GroupPeer(
                  identity: 'u2',
                  name: 'Second',
                  videoTrack: null,
                  audioMuted: false),
            ]))),
      ]);
      addTearDown(c.dispose);
      await _pumpHost(t, c);
      expect(find.text('Команда'), findsOneWidget);
      expect(find.text('Second'), findsOneWidget);
      expect(find.text('Rafael · Вы'), findsOneWidget);
      expect(find.byType(ParticipantGrid), findsOneWidget);
      expect(find.byType(ParticipantTile), findsNWidgets(2));
    });

    test('facade maps group title, count and self tile', () {
      final c = ProviderContainer(overrides: [
        callStateProvider.overrideWith(() => _FakeDirectCall(null)),
        groupCallProvider.overrideWith(() => _FakeGroup(GroupCall(
            dmId: 'd1',
            title: 'Команда',
            room: 'grchat_d1',
            video: true,
            outgoing: false,
            phase: GroupPhase.ringing,
            callId: 'k1'))),
      ]);
      addTearDown(c.dispose);
      final u = c.read(unifiedCallProvider)!;
      expect(u.kind, CallKind.group);
      expect(u.title, 'Команда');
      expect(u.subtitle, 'Входящий групповой видеозвонок');
      expect(u.onAccept, isNotNull);
      expect(u.onDecline, isNotNull);
      // Self tile resolves against the session nick (headless: '?').
      expect(u.participants.last.self, isTrue);
    });
  });
}

class _FakeDirectCall extends CallState {
  _FakeDirectCall(this._c);
  final ActiveCall? _c;

  @override
  ActiveCall? build() => _c;
}
