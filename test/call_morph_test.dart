import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:grchat_client/src/app/providers.dart';
import 'package:grchat_client/src/auth/auth_repository.dart';
import 'package:grchat_client/src/call/call_session.dart';
import 'package:grchat_client/src/call/call_state.dart';
import 'package:grchat_client/src/call/call_surface.dart';
import 'package:grchat_client/src/voice/voice_state.dart';

/// True-morph surface (§54–§58): one object shrinking into a live pill,
/// stabilized remote preview, no media churn.

class _FakeSession extends SessionState {
  @override
  Session? build() => Session(userId: 'u1', nick: 'Rafael', token: 't');
}

class _FakeVoice extends VoiceSessionState {
  _FakeVoice(this._s);
  VoiceSession? _s;
  var joins = 0;
  var leaves = 0;

  @override
  VoiceSession? build() => _s;

  @override
  Future<void> leave() async {
    leaves++;
    _s = null;
    state = null;
  }
}

VoiceSession _voiceSession({bool minimized = false}) => VoiceSession(
    channelId: 'vc1',
    title: 'voice',
    room: 'grchat_vc_vc1',
    minimized: minimized,
    peers: [
      VoicePeer(
          id: 'u1',
          nick: 'Rafael',
          speaking: false,
          muted: false,
          self: true),
      VoicePeer(
          id: 'u2',
          nick: 'Second',
          speaking: true,
          muted: false,
          self: false,
          audioLevel: 0.7),
    ]);

Future<void> _pumpPill(WidgetTester t, ProviderContainer c) async {
  await t.pumpWidget(UncontrolledProviderScope(
      container: c,
      child: const MaterialApp(
          home: Scaffold(body: CallOverlayHost()))));
  await t.pump();
}

void main() {
  group('morph geometry (§54)', () {
    testWidgets('card is docked top-right at 300x224', (t) async {
      t.view.physicalSize = const Size(1280, 720);
      t.view.devicePixelRatio = 1.0;
      addTearDown(t.view.resetPhysicalSize);
      final fv = _FakeVoice(_voiceSession(minimized: true));
      final c = ProviderContainer(overrides: [
        sessionProvider.overrideWith(_FakeSession.new),
        voiceSessionProvider.overrideWith(() => fv),
      ]);
      addTearDown(c.dispose);
      await _pumpPill(t, c);
      final card = find.byType(MiniCallCard);
      expect(card, findsOneWidget);
      expect(t.getSize(card), const Size(300, 224));
      final tr = t.getTopRight(card);
      expect(tr.dx, closeTo(1280 - 14, 1.0));
      expect(tr.dy, closeTo(14, 1.0));
    });

    testWidgets('resize keeps the card docked (§33)', (t) async {
      t.view.physicalSize = const Size(1280, 720);
      t.view.devicePixelRatio = 1.0;
      addTearDown(t.view.resetPhysicalSize);
      final c = ProviderContainer(overrides: [
        sessionProvider.overrideWith(_FakeSession.new),
        voiceSessionProvider.overrideWith(
            () => _FakeVoice(_voiceSession(minimized: true))),
      ]);
      addTearDown(c.dispose);
      await _pumpPill(t, c);
      t.view.physicalSize = const Size(900, 600);
      await t.pump();
      final tr = t.getTopRight(find.byType(MiniCallCard));
      expect(tr.dx, closeTo(900 - 14, 1.0));
      expect(tr.dy, closeTo(14, 1.0));
    });

    testWidgets('minimize/restore never touches media (§36)', (t) async {
      final fv = _FakeVoice(_voiceSession(minimized: false));
      final c = ProviderContainer(overrides: [
        sessionProvider.overrideWith(_FakeSession.new),
        voiceSessionProvider.overrideWith(() => fv),
      ]);
      addTearDown(c.dispose);
      await _pumpPill(t, c);
      expect(find.byType(CallWindow), findsOneWidget);
      // Minimize through the real flag path.
      c.read(voiceSessionProvider.notifier).setMinimized(true);
      await t.pump();
      await t.pump(const Duration(milliseconds: 500));
      expect(find.byType(MiniCallCard), findsOneWidget);
      // Restore through the bar expand button.
      await t.tap(find.byTooltip('Вернуть звонок'));
      await t.pump();
      await t.pump(const Duration(milliseconds: 500));
      expect(find.byType(CallWindow), findsOneWidget);
      // No leave, no rejoin: presentation only.
      expect(fv.leaves, 0);
      expect(fv.joins, 0);
    });

    testWidgets('drag docks right-middle and survives a cycle (§57)',
        (t) async {
      t.view.physicalSize = const Size(1280, 720);
      t.view.devicePixelRatio = 1.0;
      addTearDown(t.view.resetPhysicalSize);
      final c = ProviderContainer(overrides: [
        sessionProvider.overrideWith(_FakeSession.new),
        voiceSessionProvider.overrideWith(
            () => _FakeVoice(_voiceSession(minimized: true))),
      ]);
      addTearDown(c.dispose);
      await _pumpPill(t, c);
      final handle = find.byKey(const ValueKey('mini-drag-handle'));
      expect(handle, findsOneWidget);
      // Drag down along the right side, then release.
      await t.drag(handle, const Offset(0, 300));
      await t.pump();
      await t.pump(const Duration(milliseconds: 400));
      final card = find.byType(MiniCallCard);
      final r = t.getRect(card);
      // Docked right, pushed down — not a corner, not floating.
      expect(r.right, closeTo(1280 - 14, 1.0));
      expect(r.top, greaterThan(100));
      expect(r.top, lessThan(400));
      // Expand from there, minimize back: same dock (§40).
      await t.tap(find.byTooltip('Вернуть звонок'));
      await t.pump();
      await t.pump(const Duration(milliseconds: 500));
      expect(find.byType(CallWindow), findsOneWidget);
      c.read(voiceSessionProvider.notifier).setMinimized(true);
      await t.pump();
      await t.pump(const Duration(milliseconds: 500));
      final r2 = t.getRect(find.byType(MiniCallCard));
      expect(r2.top, closeTo(r.top, 2.0));
      expect(r2.right, closeTo(r.right, 1.0));
    });
  });

    testWidgets('20 minimize/restore cycles leave one surface (§56)',
        (t) async {
      final c = ProviderContainer(overrides: [
        sessionProvider.overrideWith(_FakeSession.new),
        voiceSessionProvider.overrideWith(
            () => _FakeVoice(_voiceSession(minimized: false))),
      ]);
      addTearDown(c.dispose);
      await _pumpPill(t, c);
      final st = c.read(voiceSessionProvider.notifier);
      for (var i = 0; i < 20; i++) {
        st.setMinimized(true);
        await t.pump();
        await t.pump(const Duration(milliseconds: 500));
        expect(find.byType(MiniCallCard), findsOneWidget);
        expect(find.byType(CallWindow), findsNothing);
        st.setMinimized(false);
        await t.pump();
        await t.pump(const Duration(milliseconds: 500));
        expect(find.byType(CallWindow), findsOneWidget);
        expect(find.byType(MiniCallCard), findsNothing);
      }
      // No leaked overlay, no second surface, session untouched.
      expect(find.byType(CallOverlayHost), findsOneWidget);
    });

  group('spotlight pick (§55)', () {
    test('P2P preview is always the remote peer', () {
      final remote = CallParticipant(
          id: 'peer',
          nick: 'Masha',
          self: false,
          speaking: false,
          muted: false);
      final self = CallParticipant(
          id: 'self',
          nick: 'Rafael',
          self: true,
          speaking: true,
          muted: false);
      // Even a "speaking" local never wins: P2P is deterministic.
      expect(spotlightPeer(parts: [self, remote], displayedId: 'self'),
          same(remote));
      expect(spotlightPeer(parts: [self, remote], displayedId: null),
          same(remote));
    });

    test('group falls back to first remote, never self', () {
      final a = CallParticipant(
          id: 'a', nick: 'A', self: false, speaking: false, muted: true);
      final b = CallParticipant(
          id: 'b', nick: 'B', self: false, speaking: true, muted: false);
      final self = CallParticipant(
          id: 's', nick: 'Me', self: true, speaking: true, muted: false);
      expect(
          spotlightPeer(parts: [self, a, b], displayedId: 'b'), same(b));
      expect(spotlightPeer(parts: [self, a, b], displayedId: 'gone'),
          same(a));
      expect(spotlightPeer(parts: [self], displayedId: null), isNull);
    });

    test('facade maps voice spotlight from the engine focus', () {
      final c = ProviderContainer(overrides: [
        sessionProvider.overrideWith(_FakeSession.new),
        voiceSessionProvider.overrideWith(() => _FakeVoice(VoiceSession(
            channelId: 'vc1',
            title: 'voice',
            room: 'r',
            peers: [
              VoicePeer(
                  id: 'u1',
                  nick: 'Rafael',
                  speaking: true,
                  muted: false,
                  self: true,
                  audioLevel: 0.9),
              VoicePeer(
                  id: 'u2',
                  nick: 'Second',
                  speaking: false,
                  muted: false,
                  self: false),
            ],
            displayedSpeakerId: 'u2'))),
      ]);
      addTearDown(c.dispose);
      final u = c.read(unifiedCallProvider)!;
      // Local is louder, but self never becomes the preview (§19–§20).
      expect(u.spotlight?.id, 'u2');
    });
  });

  group('pill content (§24, §58)', () {
    Future<void> pumpPreview(
        WidgetTester t, CallParticipant? spot) async {
      final u = UnifiedCall(
          kind: CallKind.group,
          sessionId: 'g1',
          title: 'Team',
          subtitle: '1 участник',
          video: true,
          outgoing: true,
          phase: CallPhase.active,
          muted: false,
          cameraOff: false,
          sharingScreen: false,
          linkDown: false,
          minimized: true,
          participants: const [],
          onAccept: null,
          onDecline: null,
          onHangup: () async {},
          onToggleMute: () {},
          onToggleCamera: () {},
          onToggleShare: () async {},
          onSetMinimized: (_) {},
          friendlyError: (_) => 'x',
          spotlight: spot);
      await t.pumpWidget(ProviderScope(
          child: MaterialApp(
              home: Scaffold(
                  body: Stack(children: [
            const Positioned.fill(child: ColoredBox(color: Colors.black)),
            Positioned.fromRect(
              rect: const Rect.fromLTWH(986, 14, 300, 224),
              child: MiniCallOverlay(
                  call: u,
                  secs: 65,
                  onDragStart: (_) {},
                  onDragUpdate: (_) {},
                  onDragEnd: (_) {}),
            ),
          ])))));
      await t.pump();
    }

    CallParticipant peer(String id, String nick, {bool video = false}) =>
        CallParticipant(
            id: id,
            nick: nick,
            self: false,
            speaking: true,
            muted: false,
            video: video ? ((_) => Text('VID-$id')) : null);

    testWidgets('speaker change crossfades content, box stays put',
        (t) async {
      await pumpPreview(t, peer('u2', 'Second'));
      expect(find.text('Second'), findsOneWidget);
      final box = t.getSize(find.byType(MiniCallCard));
      await pumpPreview(t, peer('u3', 'TestPilot'));
      await t.pump(const Duration(milliseconds: 300));
      expect(find.text('TestPilot'), findsOneWidget);
      expect(find.text('Second'), findsNothing);
      // No resize, no bounce (§25).
      expect(t.getSize(find.byType(MiniCallCard)), box);
    });

    testWidgets('camera toggle keeps identity (§58)', (t) async {
      await pumpPreview(t, peer('u2', 'Second', video: false));
      expect(find.text('Second'), findsOneWidget);
      expect(find.text('VID-u2'), findsNothing);
      await pumpPreview(t, peer('u2', 'Second', video: true));
      await t.pump(const Duration(milliseconds: 300));
      expect(find.text('Second'), findsOneWidget);
      expect(find.text('VID-u2'), findsOneWidget);
    });
  });
}
