import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:grchat_client/src/call/call_state.dart';
import 'package:grchat_client/src/call/call_surface.dart';

class _FakeCall extends CallState {
  _FakeCall(this._c);
  final ActiveCall? _c;

  String? lastPeer;
  String? lastDm;
  bool? lastVideo;

  @override
  ActiveCall? build() => _c;

  @override
  Future<void> startCall(
      {String? peerNick, String? dmId, required bool video}) async {
    lastPeer = peerNick;
    lastDm = dmId;
    lastVideo = video;
  }
}

void main() {
  group('callRedialProvider', () {
    test('starts empty, offer sets, clear resets', () {
      final c = ProviderContainer();
      addTearDown(c.dispose);
      expect(c.read(callRedialProvider), isNull);
      c.read(callRedialProvider.notifier).offer(const CallRedial(
          reason: 'Нет ответа',
          peerNick: 'Second',
          dmId: null,
          video: true));
      final r = c.read(callRedialProvider);
      expect(r, isNotNull);
      expect(r!.reason, 'Нет ответа');
      expect(r.peerNick, 'Second');
      expect(r.video, isTrue);
      c.read(callRedialProvider.notifier).clear();
      expect(c.read(callRedialProvider), isNull);
    });

    test('group redial carries dmId, not a nick', () {
      final c = ProviderContainer();
      addTearDown(c.dispose);
      c.read(callRedialProvider.notifier).offer(const CallRedial(
          reason: 'Нет ответа', peerNick: null, dmId: 'd9', video: false));
      final r = c.read(callRedialProvider)!;
      expect(r.peerNick, isNull);
      expect(r.dmId, 'd9');
    });
  });

  group('ActiveCall dmId', () {
    test('copyWith preserves dmId it did not name', () {
      final s = ActiveCall(
          callId: 'c1',
          peerNick: 'Группа',
          video: false,
          outgoing: true,
          dmId: 'd9',
          phase: CallPhase.ringing);
      final next = s.copyWith(phase: CallPhase.active);
      expect(next.dmId, 'd9');
      expect(next.phase, CallPhase.active);
    });
  });

  group('redial SnackBar', () {
    Future<ProviderContainer> pumpHost(WidgetTester t) async {
      final c = ProviderContainer(overrides: [
        callStateProvider.overrideWith(() => _FakeCall(null)),
      ]);
      addTearDown(c.dispose);
      await t.pumpWidget(UncontrolledProviderScope(
          container: c,
          child: const MaterialApp(
              home: Scaffold(body: Stack(children: [
            Placeholder(),
            CallOverlayHost(),
          ])))));
      await t.pump();
      return c;
    }

    testWidgets('shows reason with a redial action', (t) async {
      final c = await pumpHost(t);
      expect(find.text('Нет ответа'), findsNothing);
      c.read(callRedialProvider.notifier).offer(const CallRedial(
          reason: 'Нет ответа',
          peerNick: 'Second',
          dmId: null,
          video: true));
      await t.pump();
      expect(find.text('Нет ответа'), findsOneWidget);
      expect(find.text('Позвонить снова'), findsOneWidget);
    });

    testWidgets('action redials with stored args and clears', (t) async {
      final c = await pumpHost(t);
      c.read(callRedialProvider.notifier).offer(const CallRedial(
          reason: 'Second отклонил звонок',
          peerNick: 'Second',
          dmId: null,
          video: false));
      await t.pump();
      await t.pump(const Duration(milliseconds: 500));
      await t.tap(find.text('Позвонить снова'));
      await t.pump();
      await t.pump(const Duration(milliseconds: 500));
      final fake =
          c.read(callStateProvider.notifier) as _FakeCall;
      expect(fake.lastPeer, 'Second');
      expect(fake.lastDm, isNull);
      expect(fake.lastVideo, isFalse);
      expect(c.read(callRedialProvider), isNull);
    });
  });
}
