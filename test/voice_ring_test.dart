import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:grchat_client/src/app/providers.dart';
import 'package:grchat_client/src/app/theme.dart';
import 'package:grchat_client/src/auth/auth_repository.dart';
import 'package:grchat_client/src/chat/models.dart';
import 'package:grchat_client/src/chat/widgets/context_sidebar.dart';
import 'package:grchat_client/src/voice/voice_state.dart';

class _FakeSession extends SessionState {
  @override
  Session? build() => Session(userId: 'u1', nick: 'Rafael', token: 't');
}

class _FakeRoster extends VoiceState {
  _FakeRoster(this.map);
  final Map<String, Set<String>> map;

  @override
  Map<String, Set<String>> build() => map;
}

class _FakeVoice extends VoiceSessionState {
  _FakeVoice(this._s);
  final VoiceSession? _s;

  @override
  VoiceSession? build() => _s;
}

VoiceSession _session(double level) => VoiceSession(
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
          self: false,
          audioLevel: level),
    ]);

Future<void> _pumpTile(WidgetTester t, double level) async {
  await t.pumpWidget(ProviderScope(
      overrides: [
        sessionProvider.overrideWith(_FakeSession.new),
        voiceStateProvider.overrideWith(() => _FakeRoster({
              'vc1': {'u1', 'u2'}
            })),
        voiceSessionProvider.overrideWith(() => _FakeVoice(_session(level))),
      ],
      child: MaterialApp(
          theme: grchatDark,
          home: Scaffold(
              body: SizedBox(
                  width: 300,
                  child: VoiceTile(
                      channel: Channel(
                          id: 'vc1', name: 'voice', type: 'voice'),
                      community: null,
                      members: [
                        Member(userId: 'u2', nick: 'Second', role: '')
                      ]))))));
  await t.pump();
}

Color? _ringOf(WidgetTester t) {
  // Self sorts first and is silent here: take the most visible ring.
  Color? best;
  for (final c in t.widgetList<AnimatedContainer>(
      find.byType(AnimatedContainer))) {
    final d = c.decoration;
    if (d is BoxDecoration && d.shape == BoxShape.circle) {
      final col = d.border?.top.color;
      if (col != null && (best == null || col.a > best.a)) best = col;
    }
  }
  return best;
}

void main() {
  testWidgets('loud peer gets a solid green ring', (t) async {
    await _pumpTile(t, 0.8);
    final ring = _ringOf(t);
    expect(ring, isNotNull);
    // Discord green, mostly opaque at 0.8 loudness (0.3 + 0.7*0.8).
    expect(ring!.r, greaterThan(0.2));
    expect(ring.g, greaterThan(0.7));
    expect(ring.a, greaterThan(0.8));
  });

  testWidgets('quiet peer ring fades', (t) async {
    await _pumpTile(t, 0.2);
    final ring = _ringOf(t)!;
    // 0.3 + 0.7*0.2 = 0.44: visible but clearly translucent.
    expect(ring.a, greaterThan(0.3));
    expect(ring.a, lessThan(0.6));
  });

  testWidgets('silent peer has no ring', (t) async {
    await _pumpTile(t, 0.0);
    final ring = _ringOf(t)!;
    expect(ring.a, 0.0);
  });
}
