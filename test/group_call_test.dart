import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:grchat_client/src/auth/auth_repository.dart';
import 'package:grchat_client/src/call/group_call.dart';

/// Headless-safe paths only (no native WebRTC): join()/accept() need a
/// device and are covered by the manual matrix, not here.
void main() {
  group('GroupCallState', () {
    test('incoming rings when idle', () {
      final c = ProviderContainer();
      addTearDown(c.dispose);
      c
          .read(groupCallProvider.notifier)
          .incoming(
              callId: 'k1',
              dmId: 'd1',
              room: 'grchat_d1',
              video: true,
              fromNick: 'Second');
      final call = c.read(groupCallProvider);
      expect(call, isNotNull);
      expect(call!.phase, GroupPhase.ringing);
      expect(call.outgoing, isFalse);
      expect(call.video, isTrue);
      expect(call.callId, 'k1');
      expect(call.title, 'Группа');
    });

    test('incoming while busy keeps the first call', () async {
      final c = ProviderContainer();
      addTearDown(c.dispose);
      final n = c.read(groupCallProvider.notifier);
      n.incoming(
          callId: 'k1',
          dmId: 'd1',
          room: 'grchat_d1',
          video: false,
          fromNick: 'Second');
      // Busy decline must not throw headless (api errors are caught).
      n.incoming(
          callId: 'k2',
          dmId: 'd2',
          room: 'grchat_d2',
          video: false,
          fromNick: 'Third');
      await Future<void>.delayed(Duration.zero);
      expect(c.read(groupCallProvider)?.callId, 'k1');
    });

    test('decline clears without native room', () async {
      final c = ProviderContainer();
      addTearDown(c.dispose);
      final n = c.read(groupCallProvider.notifier);
      n.incoming(
          callId: 'k1',
          dmId: 'd1',
          room: 'grchat_d1',
          video: false,
          fromNick: 'Second');
      await n.decline();
      expect(c.read(groupCallProvider), isNull);
    });

    test('toggleMute flips locally', () async {
      final c = ProviderContainer();
      addTearDown(c.dispose);
      final n = c.read(groupCallProvider.notifier);
      n.incoming(
          callId: 'k1',
          dmId: 'd1',
          room: 'grchat_d1',
          video: false,
          fromNick: 'Second');
      await n.toggleMute();
      expect(c.read(groupCallProvider)?.muted, isTrue);
      await n.toggleMute();
      expect(c.read(groupCallProvider)?.muted, isFalse);
    });
  });

  group('friendlyGroupError', () {
    test('maps codes to Russian copy', () {
      expect(friendlyGroupError(GrchatException('NOT_MEMBER')),
          'Нет доступа к звонку');
      expect(friendlyGroupError(GrchatException('NOPE')),
          'Не вышло позвонить');
      expect(friendlyGroupError(StateError('x')), 'Не вышло позвонить');
    });
  });
}
