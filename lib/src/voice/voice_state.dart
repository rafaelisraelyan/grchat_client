import 'dart:async';

import 'package:riverpod/riverpod.dart';

import '../app/providers.dart';

/// Voice channel presence (signaling only for now; media comes with SFU).
class VoiceState extends Notifier<Map<String, Set<String>>> {
  StreamSubscription<Map<String, dynamic>>? _pushSub;

  @override
  Map<String, Set<String>> build() => {};

  void ensureListening() {
    _pushSub ??=
        ref.read(connectionProvider).pushes.listen(_onPush);
  }

  String? get joinedChannelId {
    final myId = ref.read(sessionProvider)?.userId;
    for (final e in state.entries) {
      if (e.value.contains(myId)) return e.key;
    }
    return null;
  }

  Future<void> join(String channelId) async {
    final s = ref.read(sessionProvider);
    if (s == null) return;
    final r = await ref.read(connectionProvider).request('voice_join',
        fields: {'session_token': s.token, 'channel_id': channelId});
    if (r['type'] == 'error') throw Exception(r['code']);
    await refresh(channelId);
  }

  Future<void> leave() async {
    final s = ref.read(sessionProvider);
    if (s == null) return;
    final cur = joinedChannelId;
    if (cur == null) return;
    await ref.read(connectionProvider).request('voice_leave',
        fields: {'session_token': s.token, 'channel_id': cur});
    final next = Map<String, Set<String>>.from(state);
    next[cur]?.remove(s.userId);
    state = next;
  }

  Future<void> refresh(String channelId) async {
    final s = ref.read(sessionProvider);
    if (s == null) return;
    final r = await ref.read(connectionProvider).request('voice_members',
        fields: {'session_token': s.token, 'channel_id': channelId});
    if (r['type'] == 'error') return;
    final ids = ((r['members'] as List?) ?? const [])
        .map((m) => ((m as Map)['user_id'] ?? '').toString())
        .where((id) => id.isNotEmpty)
        .toSet();
    state = {...state, channelId: ids};
  }

  void _onPush(Map<String, dynamic> ev) {
    final type = ev['type']?.toString();
    if (type != 'voice_joined' && type != 'voice_left') return;
    final ch = ev['channel_id']?.toString();
    final uid = ev['user_id']?.toString();
    if (ch == null || uid == null) return;
    final next = Map<String, Set<String>>.from(state);
    final set = Set<String>.from(next[ch] ?? {});
    if (type == 'voice_joined') {
      set.add(uid);
    } else {
      set.remove(uid);
    }
    next[ch] = set;
    state = next;
  }
}

final voiceStateProvider =
    NotifierProvider<VoiceState, Map<String, Set<String>>>(VoiceState.new);
