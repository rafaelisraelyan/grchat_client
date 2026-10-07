import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:grchat_client/src/call/call_session.dart';
import 'package:grchat_client/src/call/call_state.dart';
import 'package:grchat_client/src/call/call_surface.dart';
import 'package:grchat_client/src/chat/home_state.dart';
import 'package:grchat_client/src/chat/models.dart';
import 'package:grchat_client/src/voice/voice_state.dart';

class _FakeCall extends CallState {
  _FakeCall(this._c);
  final ActiveCall? _c;

  @override
  ActiveCall? build() => _c;
}

class _FakeVoice extends VoiceSessionState {
  _FakeVoice(this._s);
  final VoiceSession? _s;

  bool leaveCalled = false;
  bool minimizedTo = false;
  bool minimizeSeen = false;

  @override
  VoiceSession? build() => _s;

  @override
  Future<void> leave() async {
    leaveCalled = true;
  }

  @override
  void setMinimized(bool m) {
    minimizeSeen = true;
    minimizedTo = m;
  }
}

ActiveCall _direct(
        {bool outgoing = true,
        bool video = true,
        CallPhase phase = CallPhase.active,
        bool minimized = false}) =>
    ActiveCall(
        callId: 'c1',
        peerNick: 'Masha',
        video: video,
        outgoing: outgoing,
        phase: phase,
        minimized: minimized);

VoiceSession _voice({bool minimized = false}) => VoiceSession(
    channelId: 'vc1',
    title: 'voice',
    room: 'grchat_vc_vc1',
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
          self: false),
    ],
    minimized: minimized);

UnifiedCall _u(ProviderContainer c) => c.read(unifiedCallProvider)!;

void main() {
  group('unifiedCallProvider', () {
    test('direct wins over voice when both present', () {
      final c = ProviderContainer(overrides: [
        callStateProvider.overrideWith(() => _FakeCall(_direct())),
        voiceSessionProvider.overrideWith(() => _FakeVoice(_voice())),
      ]);
      addTearDown(c.dispose);
      final u = _u(c);
      expect(u.kind, CallKind.direct);
      expect(u.title, 'Masha');
    });

    test('voice maps title, count, flags', () {
      final c = ProviderContainer(overrides: [
        callStateProvider.overrideWith(() => _FakeCall(null)),
        voiceSessionProvider.overrideWith(() => _FakeVoice(_voice())),
      ]);
      addTearDown(c.dispose);
      final u = _u(c);
      expect(u.kind, CallKind.serverVoice);
      expect(u.title, '🔊 voice');
      expect(u.subtitle, '1 участник');
      expect(u.phase, CallPhase.active);
      expect(u.participants, hasLength(2));
      expect(u.participants.first.self, isTrue);
      expect(u.onAccept, isNull);
    });

    test('nothing live yields null', () {
      final c = ProviderContainer(overrides: [
        callStateProvider.overrideWith(() => _FakeCall(null)),
        voiceSessionProvider.overrideWith(() => _FakeVoice(null)),
      ]);
      addTearDown(c.dispose);
      expect(c.read(unifiedCallProvider), isNull);
    });

    test('minimizeLiveCall folds the live engine only', () {
      final fc = _FakeCall(_direct());
      final fv = _FakeVoice(_voice());
      final c = ProviderContainer(overrides: [
        callStateProvider.overrideWith(() => fc),
        voiceSessionProvider.overrideWith(() => fv),
      ]);
      addTearDown(c.dispose);
      final probe = c.read(Provider((ref) => ref));
      minimizeLiveCall(probe);
      // Direct is live: its real setMinimized flips state (Riverpod object).
      expect(c.read(callStateProvider)?.minimized, isTrue);
      expect(fv.minimizeSeen, isTrue);
      expect(fv.minimizedTo, isTrue);
    });
  });

  group('voice scope navigation', () {
    test('selectVoiceScope sets scope without loading', () {
      final c = ProviderContainer();
      addTearDown(c.dispose);
      final n = c.read(homeStateProvider.notifier);
      final ch = Channel(id: 'vc1', name: 'voice', type: 'voice');
      n.selectVoiceScope(null, ch);
      final scope = c.read(homeStateProvider).scope;
      expect(scope, isA<ChannelScope>());
      expect((scope as ChannelScope).channel.id, 'vc1');
      expect(c.read(homeStateProvider).loading, isFalse);
    });

    test('reselectLastText no-ops when target vanished', () async {
      final c = ProviderContainer();
      addTearDown(c.dispose);
      final n = c.read(homeStateProvider.notifier);
      final ch = Channel(id: 'gone', name: 'gone', type: 'text');
      n.lastTextScope = ChannelScope(null, ch);
      await n.reselectLastText();
      // Nothing resolvable: scope untouched, no crash, no network.
      expect(c.read(homeStateProvider).scope, isNull);
    });
  });

  group('CallWindow from facade', () {
    Future<void> pump(WidgetTester t, UnifiedCall u) async {
      await t.pumpWidget(ProviderScope(
          child: MaterialApp(
              home: Scaffold(
                  body: CallWindow(
                      call: u,
                      secs: 20,
                      media: u.kind == CallKind.serverVoice
                          ? ParticipantGrid(
                              participants: u.participants)
                          : const SizedBox.shrink())))));
      await t.pump();
    }

    UnifiedCall voiceValue() => UnifiedCall(
        kind: CallKind.serverVoice,
        sessionId: 'vc1',
        title: '🔊 voice',
        subtitle: '1 участник',
        video: true,
        outgoing: false,
        phase: CallPhase.active,
        muted: false,
        cameraOff: true,
        sharingScreen: false,
        linkDown: false,
        minimized: false,
        participants: [
          CallParticipant(
              id: 'u1',
              nick: 'Rafael · Вы',
              self: true,
              speaking: false,
              muted: false),
          CallParticipant(
              id: 'u2',
              nick: 'Second',
              self: false,
              speaking: true,
              muted: false),
        ],
        onAccept: null,
        onDecline: null,
        onHangup: () async {},
        onToggleMute: () {},
        onToggleCamera: () {},
        onToggleShare: () async {},
        onSetMinimized: (_) {});

    testWidgets('voice grid shows both tiles with ring', (t) async {
      await pump(t, voiceValue());
      expect(find.text('🔊 voice'), findsOneWidget);
      expect(find.text('Rafael · Вы'), findsOneWidget);
      expect(find.text('Second'), findsOneWidget);
      // Camera (off) + mic + hangup, no screen share for voice.
      expect(find.byTooltip('Включить камеру'), findsOneWidget);
      expect(find.byTooltip('Выключить микрофон'), findsOneWidget);
      expect(find.byTooltip('Завершить'), findsOneWidget);
      expect(find.byTooltip('Демонстрация экрана'), findsNothing);
    });

    testWidgets('leave and minimize callbacks fire', (t) async {
      var left = false;
      var min = false;
      final u = voiceValue();
      await t.pumpWidget(ProviderScope(
          child: MaterialApp(
              home: Scaffold(
                  body: CallWindow(
                      call: UnifiedCall(
                          kind: u.kind,
                          sessionId: u.sessionId,
                          title: u.title,
                          subtitle: u.subtitle,
                          video: u.video,
                          outgoing: u.outgoing,
                          phase: u.phase,
                          muted: u.muted,
                          cameraOff: u.cameraOff,
                          sharingScreen: u.sharingScreen,
                          linkDown: u.linkDown,
                          minimized: u.minimized,
                          participants: u.participants,
                          onAccept: u.onAccept,
                          onDecline: u.onDecline,
                          onHangup: () async {
                            left = true;
                          },
                          onToggleMute: u.onToggleMute,
                          onToggleCamera: u.onToggleCamera,
                          onToggleShare: u.onToggleShare,
                          onSetMinimized: (_) {
                            min = true;
                          }),
                      secs: 0,
                      media: ParticipantGrid(
                          participants: u.participants))))));
      await t.pump();
      await t.tap(find.byTooltip('Завершить'));
      expect(left, isTrue);
      await t.tap(find.byTooltip('Свернуть'));
      expect(min, isTrue);
    });

    testWidgets('single tile centers, five tiles grid', (t) async {
      List<CallParticipant> parts(int n) => [
            for (var i = 0; i < n; i++)
              CallParticipant(
                  id: 'u$i',
                  nick: 'N$i',
                  self: i == 0,
                  speaking: false,
                  muted: true),
          ];
      await t.pumpWidget(const ProviderScope(
          child: MaterialApp(
              home: Scaffold(
                  body: ParticipantGrid(participants: [])))));
      await t.pump();
      expect(find.text('Подключение…'), findsOneWidget);
      await t.pumpWidget(ProviderScope(
          child: MaterialApp(
              home: Scaffold(
                  body: ParticipantGrid(
                      participants: parts(5))))));
      await t.pump();
      expect(find.byType(ParticipantTile), findsNWidgets(5));
      expect(find.byType(GridView), findsOneWidget);
    });
  });
}
