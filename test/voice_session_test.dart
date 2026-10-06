import 'package:flutter_test/flutter_test.dart';
import 'package:grchat_client/src/auth/auth_repository.dart';
import 'package:grchat_client/src/voice/voice_state.dart';

/// Headless-safe voice paths (no LiveKit room): roster merge, error copy,
/// model. join()/leave() need a room + server and stay in the manual matrix.
void main() {
  group('mergeVoicePeers', () {
    List<VoicePeer> merge({
      Set<String> signaling = const {'u1', 'u2'},
      Map<String, String> nicks = const {'u1': 'Rafael', 'u2': 'Second'},
      Map<String, ({String name, bool speaking, bool muted})> room = const {
        'u2': (name: 'Second', speaking: true, muted: false),
      },
      String myId = 'u1',
      bool selfMuted = false,
      bool selfSpeaking = false,
    }) =>
        mergeVoicePeers(
            signalingIds: signaling,
            nicks: nicks,
            room: room,
            myId: myId,
            myNick: 'Rafael',
            selfMuted: selfMuted,
            selfSpeaking: selfSpeaking);

    test('signaling roster shows, room gives speaking', () {
      final peers = merge();
      expect(peers.map((p) => p.id), containsAll(['u1', 'u2']));
      final second = peers.firstWhere((p) => p.id == 'u2');
      expect(second.nick, 'Second');
      expect(second.speaking, isTrue);
      expect(second.muted, isFalse);
      expect(second.self, isFalse);
    });

    test('self comes first with own flags', () {
      final peers =
          merge(selfMuted: true, selfSpeaking: true);
      expect(peers.first.id, 'u1');
      expect(peers.first.self, isTrue);
      expect(peers.first.muted, isTrue);
      expect(peers.first.speaking, isTrue);
    });

    test('between join and room connect shows silent, not ghost', () {
      // u3 in signaling but not in the room yet: present, silent, avatar.
      final peers = merge(
          signaling: {'u1', 'u3'},
          nicks: {'u1': 'Rafael', 'u3': 'Third'},
          room: const {});
      final third = peers.firstWhere((p) => p.id == 'u3');
      expect(third.nick, 'Third');
      expect(third.speaking, isFalse);
    });

    test('stale room entries never leak in', () {
      // u9 left signaling but lingers in the room map: must not show.
      final peers = merge(room: const {
        'u2': (name: 'Second', speaking: false, muted: true),
        'u9': (name: 'Ghost', speaking: true, muted: false),
      });
      expect(peers.map((p) => p.id), containsAll(['u1', 'u2']));
      expect(peers.any((p) => p.id == 'u9'), isFalse);
    });

    test('unknown nick falls back to room name, then id prefix', () {
      final peers = merge(
          signaling: {'u1', 'u7'},
          nicks: const {'u1': 'Rafael'},
          room: const {
            'u7': (name: 'RoomName', speaking: false, muted: true),
          });
      expect(peers.firstWhere((p) => p.id == 'u7').nick, 'RoomName');
      final bare = merge(
          signaling: {'u1', 'u8'}, nicks: const {'u1': 'Rafael'}, room: const {});
      expect(bare.firstWhere((p) => p.id == 'u8').nick, 'u8');
    });

    test('self without signaling membership still shows', () {
      final peers = merge(signaling: {'u2'});
      expect(peers.first.id, 'u1');
    });
  });

  group('friendlyVoiceError', () {
    test('maps codes to Russian copy', () {
      expect(friendlyVoiceError(GrchatException('NOT_MEMBER')),
          'Нет доступа к войсу');
      expect(friendlyVoiceError(GrchatException('NOT_IN_VOICE')),
          'Ты не в войсе');
      expect(friendlyVoiceError(GrchatException('BAD_TYPE')),
          'Это не голосовой канал');
      expect(friendlyVoiceError(GrchatException('NOT_FOUND')),
          'Канал не найден');
      expect(friendlyVoiceError(GrchatException('NOPE')),
          'Не вышло зайти в войс');
      expect(friendlyVoiceError(StateError('x')), 'Не вышло зайти в войс');
    });
  });
}
