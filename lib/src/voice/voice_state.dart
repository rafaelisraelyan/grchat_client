import 'dart:async';

import 'package:livekit_client/livekit_client.dart';
import 'package:riverpod/riverpod.dart';

import '../app/providers.dart';
import '../auth/auth_repository.dart';
import '../call/call_api.dart';
import '../call/call_diagnostics.dart';

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
    if (r['type'] == 'error') {
      throw GrchatException(r['code']?.toString() ?? 'UNKNOWN');
    }
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

/// One voice-channel participant as shown under the channel: signaling gives
/// membership + nicks, the SFU room gives speaking + mute.
class VoicePeer {
  VoicePeer(
      {required this.id,
      required this.nick,
      required this.speaking,
      required this.muted,
      required this.self});
  final String id;
  final String nick;
  final bool speaking;
  final bool muted;
  final bool self;
}

/// Merge signaling roster (authoritative membership + nicks) with room
/// participants (authoritative speaking/mute). Pure: unit-tested.
///
/// Signaling wins membership: someone between voice_join and room connect
/// still shows (silent avatar), never a ghost from a stale room.
List<VoicePeer> mergeVoicePeers({
  required Set<String> signalingIds,
  required Map<String, String> nicks,
  required Map<String, ({String name, bool speaking, bool muted})> room,
  required String myId,
  required String myNick,
  required bool selfMuted,
  required bool selfSpeaking,
}) {
  final peers = <VoicePeer>[];
  final ids = {...signalingIds};
  if (!ids.contains(myId)) ids.add(myId);
  for (final id in ids) {
    final self = id == myId;
    final r = room[id];
    final fallback = id.length > 8 ? id.substring(0, 8) : id;
    peers.add(VoicePeer(
        id: id,
        nick: self
            ? myNick
            : (nicks[id] ?? r?.name ?? fallback),
        speaking: self ? selfSpeaking : (r?.speaking ?? false),
        muted: self ? selfMuted : (r?.muted ?? true),
        self: self));
  }
  peers.sort((a, b) {
    if (a.self != b.self) return a.self ? -1 : 1;
    return a.nick.toLowerCase().compareTo(b.nick.toLowerCase());
  });
  return peers;
}

/// A joined voice channel: persistent SFU room, audio-only, no ringing.
/// Separate from the signaling roster (VoiceState): this is the media session.
class VoiceSession {
  VoiceSession(
      {required this.channelId,
      required this.title,
      required this.room,
      this.peers = const [],
      this.muted = false});

  final String channelId;
  final String title;
  final String room;
  final List<VoicePeer> peers;
  final bool muted;

  VoiceSession copyWith({List<VoicePeer>? peers, bool? muted}) => VoiceSession(
      channelId: channelId,
      title: title,
      room: room,
      peers: peers ?? this.peers,
      muted: muted ?? this.muted);
}

final voiceSessionApiProvider = Provider<CallApi>((ref) {
  final s = ref.watch(sessionProvider);
  if (s == null) throw StateError('no session');
  return CallApi(ref.watch(connectionProvider), s);
});

class VoiceSessionState extends Notifier<VoiceSession?> {
  Room? _room;
  EventsListener<RoomEvent>? _roomEvents;

  @override
  VoiceSession? build() {
    // Signaling roster moves (join/leave pushes): re-resolve nicks, then
    // re-merge the display list.
    ref.listen(voiceStateProvider, (_, _) {
      final cur = state;
      if (cur == null) return;
      _refreshNicks(cur.channelId).then((_) => _syncPeers());
    });
    return null;
  }

  /// Click a voice channel: signaling presence first, then the SFU room with
  /// microphone only. Already here → no-op; elsewhere → move.
  Future<void> join({required String channelId, required String title}) async {
    if (state?.channelId == channelId) return;
    if (state != null) await leave();
    final s = ref.read(sessionProvider);
    if (s == null) return;
    final voice = ref.read(voiceStateProvider.notifier);
    final api = ref.read(voiceSessionApiProvider);
    await voice.join(channelId);
    await _refreshNicks(channelId);
    // Token or room failure after the signaling join: back the roster out,
    // otherwise we linger as a ghost member with no audio.
    late ({String url, String token, String room}) creds;
    try {
      creds = await api.voiceToken(channelId);
    } catch (e) {
      dlog('voice token failed: $e');
      try {
        await voice.leave();
      } catch (_) {}
      rethrow;
    }
    final room = Room();
    try {
      _attach(room);
      await room.connect(creds.url, creds.token);
      await room.localParticipant?.setMicrophoneEnabled(true);
      dlog('voice joined room=${creds.room}');
      state = VoiceSession(
          channelId: channelId, title: title, room: creds.room);
      _syncPeers();
    } catch (e) {
      dlog('voice join failed: $e');
      await _leaveRoom();
      try {
        await voice.leave();
      } catch (_) {}
      rethrow;
    }
  }

  Future<void> leave() async {
    if (state == null) return;
    dlog('voice left');
    await _leaveRoom();
    state = null;
    try {
      await ref.read(voiceStateProvider.notifier).leave();
    } catch (_) {}
  }

  Future<void> toggleMute() async {
    final cur = state;
    if (cur == null) return;
    final muted = !cur.muted;
    try {
      await _room?.localParticipant?.setMicrophoneEnabled(!muted);
    } catch (_) {}
    final live = state;
    if (live == null || live.channelId != cur.channelId) return;
    state = live.copyWith(muted: muted);
    _syncPeers();
  }

  void _attach(Room room) {
    _room = room;
    _roomEvents?.dispose();
    _roomEvents = room.createListener();
    _roomEvents!
      ..on<ParticipantConnectedEvent>((_) => _syncPeers())
      ..on<ParticipantDisconnectedEvent>((_) => _syncPeers())
      ..on<TrackSubscribedEvent>((_) => _syncPeers())
      ..on<TrackUnsubscribedEvent>((_) => _syncPeers())
      ..on<TrackMutedEvent>((_) => _syncPeers())
      ..on<TrackUnmutedEvent>((_) => _syncPeers())
      ..on<ActiveSpeakersChangedEvent>((_) => _syncPeers());
  }

  void _syncPeers() {
    final cur = state;
    final room = _room;
    if (cur == null) return;
    final ids = ref.read(voiceStateProvider)[cur.channelId] ?? {};
    final nicks = _nicks;
    final r = <String, ({String name, bool speaking, bool muted})>{};
    if (room != null) {
      for (final p in room.remoteParticipants.values) {
        var muted = true;
        for (final pub in p.audioTrackPublications) {
          if (pub.subscribed && !pub.muted) muted = false;
        }
        r[p.identity] = (
          name: p.name.isNotEmpty ? p.name : p.identity,
          speaking: p.isSpeaking,
          muted: muted,
        );
      }
    }
    final s = ref.read(sessionProvider);
    final myId = s?.userId ?? '';
    state = cur.copyWith(
        peers: mergeVoicePeers(
            signalingIds: ids,
            nicks: nicks[cur.channelId] ?? {},
            room: r,
            myId: myId,
            myNick: s?.nick ?? '?',
            selfMuted: cur.muted,
            selfSpeaking:
                room?.localParticipant?.isSpeaking ?? false));
  }

  /// userId → nick per channel, from voice_members (room names back it up).
  final Map<String, Map<String, String>> _nicks = {};

  Future<void> _refreshNicks(String channelId) async {
    final s = ref.read(sessionProvider);
    if (s == null) return;
    try {
      final r = await ref.read(connectionProvider).request('voice_members',
          fields: {'session_token': s.token, 'channel_id': channelId});
      if (r['type'] == 'error') return;
      final m = <String, String>{};
      for (final e in ((r['members'] as List?) ?? const [])) {
        final mm = e as Map;
        final id = (mm['user_id'] ?? '').toString();
        final nick = (mm['nick'] ?? '').toString();
        if (id.isNotEmpty && nick.isNotEmpty) m[id] = nick;
      }
      _nicks[channelId] = m;
    } catch (_) {}
  }

  Future<void> _leaveRoom() async {
    try {
      _roomEvents?.dispose();
    } catch (_) {}
    _roomEvents = null;
    try {
      await _room?.disconnect();
    } catch (_) {}
    try {
      await _room?.dispose();
    } catch (_) {}
    _room = null;
  }
}

final voiceSessionProvider =
    NotifierProvider<VoiceSessionState, VoiceSession?>(VoiceSessionState.new);

/// Raw server codes must never reach the UI.
String friendlyVoiceError(Object e) {
  if (e is GrchatException) {
    return switch (e.code) {
      'NOT_MEMBER' => 'Нет доступа к войсу',
      'NOT_IN_VOICE' => 'Ты не в войсе',
      'BAD_TYPE' => 'Это не голосовой канал',
      'NOT_FOUND' => 'Канал не найден',
      _ => 'Не вышло зайти в войс',
    };
  }
  return 'Не вышло зайти в войс';
}
