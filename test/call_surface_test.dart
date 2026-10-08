import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:grchat_client/src/call/call_state.dart';
import 'package:grchat_client/src/call/call_surface.dart';

class _FakeCall extends CallState {
  _FakeCall(this._c);
  ActiveCall? _c;

  @override
  ActiveCall? build() => _c;

  @override
  Future<void> hangup() async {
    _c = null;
    state = null;
  }

  @override
  Future<void> decline() async {
    _c = null;
    state = null;
  }
}

ActiveCall _call(
        {bool outgoing = false,
        bool video = false,
        CallPhase phase = CallPhase.ringing,
        bool remoteVideo = false,
        bool linkDown = false,
        bool minimized = false}) =>
    ActiveCall(
        callId: 'c1',
        peerNick: 'Masha',
        video: video,
        outgoing: outgoing,
        phase: phase,
        remoteVideo: remoteVideo,
        linkDown: linkDown,
        minimized: minimized);

Future<void> _pumpHost(
    WidgetTester t, ActiveCall? call) async {
  await t.pumpWidget(ProviderScope(
      overrides: [
        callStateProvider.overrideWith(() => _FakeCall(call)),
      ],
      child: const MaterialApp(
          home: Scaffold(
              body: Stack(children: [
        Placeholder(),
        CallOverlayHost(),
      ])))));
  await t.pump();
}

void main() {
  group('CallSurface', () {
    testWidgets('incoming audio is centered, chat stays behind',
        (t) async {
      await _pumpHost(t, _call(video: false));
      expect(find.text('Входящий аудиозвонок'), findsOneWidget);
      expect(
          find.ancestor(
              of: find.text('Входящий аудиозвонок'),
              matching: find.byType(Center)),
          findsWidgets);
      // Workspace still mounted behind the window.
      expect(find.byType(Placeholder), findsOneWidget);
    });

    testWidgets('incoming video label', (t) async {
      await _pumpHost(t, _call(video: true));
      expect(find.text('Входящий видеозвонок'), findsOneWidget);
    });

    testWidgets('outgoing shows calling state', (t) async {
      await _pumpHost(
          t, _call(outgoing: true, video: false));
      expect(find.text('Вызов…'), findsOneWidget);
    });

    testWidgets('active audio has mic+end, no camera upgrade',
        (t) async {
      await _pumpHost(
          t,
          _call(
              outgoing: true,
              video: false,
              phase: CallPhase.active));
      expect(find.text('Подключено · 00:00'), findsOneWidget);
      expect(find.byIcon(Icons.mic), findsOneWidget);
      expect(find.byIcon(Icons.call_end), findsOneWidget);
      expect(find.byIcon(Icons.videocam), findsNothing);
    });

    testWidgets('video without remote track shows avatar',
        (t) async {
      await _pumpHost(
          t,
          _call(
              outgoing: true,
              video: true,
              phase: CallPhase.active));
      expect(find.text('Подключение видео…'), findsOneWidget);
    });

    testWidgets('linkDown shows reconnect banner', (t) async {
      await _pumpHost(
          t,
          _call(
              outgoing: true,
              video: false,
              phase: CallPhase.active,
              linkDown: true));
      expect(
          find.text('Восстанавливаем соединение…'), findsOneWidget);
    });

    testWidgets('minimize keeps the call, restore brings it back',
        (t) async {
      await _pumpHost(
          t,
          _call(
              outgoing: true,
              video: false,
              phase: CallPhase.active));
      await t.tap(find.byTooltip('Свернуть'));
      // The morph flies the window into the pill: mid-flight both exist.
      // (Flush pump: the tap resolves a frame after the gesture.)
      await t.pump();
      await t.pump(const Duration(milliseconds: 150));
      expect(find.byType(CallWindow), findsOneWidget);
      expect(find.byType(MiniPillBody), findsOneWidget);
      await t.pump(const Duration(milliseconds: 300));
      // Mini pill visible, session alive (no hangup).
      expect(find.byTooltip('Вернуть звонок'), findsOneWidget);
      expect(find.text('Подключено · 00:00'), findsNothing);
      await t.tap(find.byTooltip('Вернуть звонок'));
      await t.pump();
      await t.pump(const Duration(milliseconds: 300));
      expect(find.text('Подключено · 00:00'), findsOneWidget);
    });

    testWidgets('Esc minimizes instead of hanging up', (t) async {
      await _pumpHost(
          t,
          _call(
              outgoing: true,
              video: true,
              phase: CallPhase.active));
      await t.sendKeyEvent(LogicalKeyboardKey.escape);
      await t.pump();
      await t.pump(const Duration(milliseconds: 300));
      expect(find.byTooltip('Вернуть звонок'), findsOneWidget);
      expect(find.byTooltip('Завершить'), findsOneWidget);
    });

    testWidgets('hangup ends the session', (t) async {
      await _pumpHost(
          t,
          _call(
              outgoing: true,
              video: false,
              phase: CallPhase.active));
      await t.tap(find.byTooltip('Завершить'));
      await t.pump();
      expect(find.byType(CallWindow), findsNothing);
      expect(find.byType(MiniCallOverlay), findsNothing);
    });

    testWidgets('decline ends incoming', (t) async {
      await _pumpHost(t, _call(video: false));
      await t.tap(find.byTooltip('Отклонить'));
      await t.pump();
      expect(find.byType(CallWindow), findsNothing);
    });
  });
}
