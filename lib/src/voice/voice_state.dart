import 'dart:async';

import 'package:livekit_client/livekit_client.dart';
import 'package:riverpod/riverpod.dart';

import '../app/providers.dart';
import '../auth/auth_repository.dart';
import '../call/call_api.dart';
import '../call/call_diagnostics.dart';
import '../call/room_options.dart';
import '../call/speaker_focus.dart';

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
      required this.self,
      this.serverMuted = false,
      this.localMuted = false,
      this.videoTrack,
      this.audioLevel = 0.0});
  final String id;
  final String nick;
  final bool speaking;

  /// Effective mute (icon): self mic, remote track, server, local or deafen.
  final bool muted;
  final bool self;

  /// Muted by a moderator (lock + label), vs muted locally by me.
  final bool serverMuted;
  final bool localMuted;

  /// Live remote/local video track for the tile. Null = avatar mode.
  final VideoTrack? videoTrack;

  /// Mic loudness 0..1, quantized to 0.1 steps. Drives the speaking ring
  /// opacity: louder = more solid. Always 0 when effectively muted.
  final double audioLevel;
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
  Map<String, VideoTrack?> videos = const {},
  Map<String, double> levels = const {},
  required String myId,
  required String myNick,
  required bool selfMuted,
  required bool selfSpeaking,
  Set<String> mutedPeers = const {},
  Set<String> serverMuted = const {},
  bool deafened = false,
}) {
  final peers = <VoicePeer>[];
  final ids = {...signalingIds};
  if (!ids.contains(myId)) ids.add(myId);
  for (final id in ids) {
    final self = id == myId;
    final r = room[id];
    final fallback = id.length > 8 ? id.substring(0, 8) : id;
    final sm = !self && serverMuted.contains(id);
    final lm = !self && (mutedPeers.contains(id) || deafened);
    final effectiveMuted =
        self ? selfMuted : (r?.muted ?? true) || sm || lm;
    final rname = r?.name;
    final rspeaking = r?.speaking ?? false;
    final speakingNow =
        (self ? selfSpeaking : rspeaking) && !effectiveMuted;
    // Raw SFU levels are jittery; 0.1 steps keep the ring calm and let the
    // engine skip no-op rebuilds. Silent or muted = no ring at all.
    final raw = (levels[id] ?? 0.0).clamp(0.0, 1.0);
    final level =
        speakingNow ? (raw * 10).roundToDouble() / 10 : 0.0;
    peers.add(VoicePeer(
        id: id,
        nick: self ? myNick : (nicks[id] ?? rname ?? fallback),
        speaking: speakingNow,
        muted: effectiveMuted,
        self: self,
        serverMuted: sm,
        localMuted: lm,
        videoTrack: videos[id],
        audioLevel: level));
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
  const VoiceSession(
      {required this.channelId,
      required this.title,
      required this.room,
      this.peers = const [],
      this.muted = false,
      this.deafened = false,
      this.serverMutedMe = false,
      this.userLimit = 0,
      this.minimized = false,
      this.cameraOff = true,
      this.displayedSpeakerId});

  final String channelId;
  final String title;
  final String room;
  final List<VoicePeer> peers;
  final bool muted;

  /// Deaf: mic off + every remote publication unsubscribed (self-only).
  final bool deafened;

  /// A moderator muted me: my mic stays locked until they unmute.
  final bool serverMutedMe;

  /// Channel cap from voice_members, 0 = unlimited.
  final int userLimit;

  /// Presentation only: Call Window vs top-right pill (§12–§14).
  final bool minimized;

  /// Camera is opt-in (Discord voice default): nothing published until set.
  final bool cameraOff;

  /// Stabilized pill preview (§38): remote peer id, or null for the
  /// first-remote fallback. Never self (§19).
  final String? displayedSpeakerId;

  VoiceSession copyWith(
          {List<VoicePeer>? peers,
          bool? muted,
          bool? deafened,
          bool? serverMutedMe,
          int? userLimit,
          bool? minimized,
          bool? cameraOff,
          String? Function()? displayedSpeakerId}) =>
      VoiceSession(
          channelId: channelId,
          title: title,
          room: room,
          peers: peers ?? this.peers,
          muted: muted ?? this.muted,
          deafened: deafened ?? this.deafened,
          serverMutedMe: serverMutedMe ?? this.serverMutedMe,
          userLimit: userLimit ?? this.userLimit,
          minimized: minimized ?? this.minimized,
          cameraOff: cameraOff ?? this.cameraOff,
          displayedSpeakerId: displayedSpeakerId != null
              ? displayedSpeakerId()
              : this.displayedSpeakerId);
}

final voiceSessionApiProvider = Provider<CallApi>((ref) {
  final s = ref.watch(sessionProvider);
  if (s == null) throw StateError('no session');
  return CallApi(ref.watch(connectionProvider), s);
});

class VoiceSessionState extends Notifier<VoiceSession?> {
  Room? _room;
  EventsListener<RoomEvent>? _roomEvents;
  StreamSubscription<Map<String, dynamic>>? _pushSub;

  /// Mic-level sampler: LiveKit only emits speaking transitions, so levels
  /// for the ring opacity are polled. 16 Hz + 0.1 quantization + no-op guard
  /// below keep rebuilds to real changes only. Appearance itself is
  /// event-driven (ActiveSpeakersChangedEvent → _syncPeers); the poll only
  /// refines loudness between events.
  Timer? _levelTimer;

  /// Pill preview focus (§38): debounced over the polled SFU levels.
  /// Reset on every join/leave so a new room starts unbiased.
  final SpeakerStabilizer _speakerFocus = SpeakerStabilizer();

  /// Local-only mutes (deafen one person for myself). Never leaves the device.
  final Set<String> mutedPeers = {};

  /// Moderator mutes for my channel (signaling). Enforced on every sync.
  final Set<String> serverMuted = {};

  /// Last applied remote subscription per user: resubscribe only on change,
  /// never spam the SFU on every speaker event.
  final Map<String, bool> _appliedSubs = {};

  @override
  VoiceSession? build() {
    // Signaling roster moves (join/leave pushes): re-resolve nicks, then
    // re-merge the display list.
    ref.listen(voiceStateProvider, (_, _) {
      final cur = state;
      if (cur == null) return;
      _refreshRoster(cur.channelId).then((_) => _syncPeers());
    });
    _pushSub ??=
        ref.read(connectionProvider).pushes.listen(_onPush);
    ref.onDispose(() => _pushSub?.cancel());
    return null;
  }

  void ensureListening() {
    _pushSub ??=
        ref.read(connectionProvider).pushes.listen(_onPush);
  }

  void _onPush(Map<String, dynamic> ev) {
    final type = ev['type']?.toString();
    if (type != 'voice_muted' && type != 'voice_unmuted') return;
    final cur = state;
    if (cur == null || ev['channel_id'] != cur.channelId) return;
    final uid = (ev['user_id'] ?? '').toString();
    if (uid.isEmpty) return;
    if (type == 'voice_muted') {
      serverMuted.add(uid);
    } else {
      serverMuted.remove(uid);
    }
    final myId = ref.read(sessionProvider)?.userId ?? '';
    if (uid == myId) {
      if (type == 'voice_muted') {
        // Locked immediately, even mid-sentence.
        _lockMic();
      }
      state = state?.copyWith(serverMutedMe: type == 'voice_muted');
    }
    _syncPeers();
  }

  /// Moderator locked my mic: force it off now, keep it locked.
  Future<void> _lockMic() async {
    try {
      await _room?.localParticipant?.setMicrophoneEnabled(false);
    } catch (_) {}
    final live = state;
    if (live != null) state = live.copyWith(muted: true);
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
    final room = newRoom();
    try {
      _attach(room);
      await room.connect(creds.url, creds.token);
      await room.localParticipant?.setMicrophoneEnabled(true);
      dlog('voice joined room=${creds.room}');
      state = VoiceSession(
          channelId: channelId, title: title, room: creds.room);
      _speakerFocus.reset();
      _levelTimer?.cancel();
      _levelTimer =
          Timer.periodic(const Duration(milliseconds: 60), (_) {
        if (state == null || _room == null) return;
        _syncPeers();
      });
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
    mutedPeers.clear();
    serverMuted.clear();
    _appliedSubs.clear();
    _speakerFocus.reset();
    try {
      await ref.read(voiceStateProvider.notifier).leave();
    } catch (_) {}
  }

  void setMinimized(bool minimized) {
    final cur = state;
    if (cur == null || cur.minimized == minimized) return;
    state = cur.copyWith(minimized: minimized);
  }

  /// Camera opt-in: first enable publishes, disable unpublishes.
  Future<void> toggleCamera() async {
    final cur = state;
    if (cur == null) return;
    final off = !cur.cameraOff;
    try {
      await _room?.localParticipant?.setCameraEnabled(!off);
    } catch (_) {}
    final live = state;
    if (live == null || live.channelId != cur.channelId) return;
    state = live.copyWith(cameraOff: off);
    _syncPeers();
  }

  VideoTrack? get localVideoTrack {
    final pubs = _room?.localParticipant?.videoTrackPublications;
    if (pubs == null) return null;
    for (final p in pubs) {
      final t = p.track;
      if (t is VideoTrack && !p.muted) return t;
    }
    return null;
  }

  Future<void> toggleMute() async {
    final cur = state;
    if (cur == null) return;
    final muted = !cur.muted;
    if (!muted && cur.serverMutedMe) {
      // Locked by a moderator: unmute is refused, not silently dropped.
      throw GrchatException('MUTED_BY_SERVER');
    }
    try {
      await _room?.localParticipant?.setMicrophoneEnabled(!muted);
    } catch (_) {}
    final live = state;
    if (live == null || live.channelId != cur.channelId) return;
    state = live.copyWith(muted: muted);
    _syncPeers();
  }

  /// Deafen: mic off + stop hearing everyone (self-only). Undeafen restores
  /// hearing; the mic stays off until unmuted separately (Discord behaviour).
  Future<void> toggleDeafen() async {
    final cur = state;
    if (cur == null) return;
    final deaf = !cur.deafened;
    try {
      if (deaf) {
        await _room?.localParticipant?.setMicrophoneEnabled(false);
      }
    } catch (_) {}
    final live = state;
    if (live == null || live.channelId != cur.channelId) return;
    state = live.copyWith(deafened: deaf, muted: deaf ? true : live.muted);
    await _enforceSubscriptions();
    _syncPeers();
  }

  /// Mute one person for myself only (no slider in SDK 2.13: binary on/off).
  Future<void> setPeerMuted(String userId, bool muted) async {
    final cur = state;
    if (cur == null || userId.isEmpty) return;
    if (muted) {
      mutedPeers.add(userId);
    } else {
      mutedPeers.remove(userId);
    }
    await _enforceSubscriptions();
    _syncPeers();
  }

  /// Moderator mute in a channel. Works without joining it; when it targets
  /// my own channel the lock applies immediately, otherwise the roster
  /// refresh picks it up. Returns a confirmation line for the toast.
  Future<String?> serverMute(
      {required String channelId,
      required String userId,
      required bool muted}) async {
    final s = ref.read(sessionProvider);
    if (s == null || userId.isEmpty) return null;
    final r = await ref.read(connectionProvider).request('voice_mute',
        fields: {
          'session_token': s.token,
          'channel_id': channelId,
          'user_id': userId,
          'muted': muted,
        });
    if (r['type'] == 'error') {
      throw GrchatException(r['code']?.toString() ?? 'UNKNOWN');
    }
    final nick = _nicks[channelId]?[userId] ?? 'Участник';
    if (state?.channelId == channelId) {
      if (muted) {
        serverMuted.add(userId);
      } else {
        serverMuted.remove(userId);
      }
      final myId = s.userId;
      if (userId == myId) {
        if (muted) {
          _lockMic();
          state = state?.copyWith(serverMutedMe: true);
        } else {
          state = state?.copyWith(serverMutedMe: false);
        }
      }
      _syncPeers();
    }
    return muted ? '$nick замучен' : '$nick размучен';
  }

  /// Owner/admin: cap occupants (0 = unlimited). Channel-scoped, works
  /// without joining: management is not presence. Applies to future joins.
  Future<void> setLimit(
      {required String channelId, required int limit}) async {
    final s = ref.read(sessionProvider);
    if (s == null || channelId.isEmpty) return;
    final r = await ref.read(connectionProvider).request('voice_limit',
        fields: {
          'session_token': s.token,
          'channel_id': channelId,
          'user_limit': limit
        });
    if (r['type'] == 'error') {
      throw GrchatException(r['code']?.toString() ?? 'UNKNOWN');
    }
    final v = (r['user_limit'] as num?)?.toInt() ?? limit;
    limits[channelId] = v;
    final cur = state;
    if (cur != null && cur.channelId == channelId) {
      state = cur.copyWith(userLimit: v);
    }
  }

  /// Resolve nicks/mutes/limit for a channel without joining (limit display).
  Future<void> refreshChannel(String channelId) async {
    await _refreshRoster(channelId);
    final cur = state;
    if (cur != null) _syncPeers();
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
    final vids = <String, VideoTrack?>{};
    final lvls = <String, double>{};
    if (room != null) {
      for (final p in room.remoteParticipants.values) {
        var muted = true;
        VideoTrack? video;
        for (final pub in p.audioTrackPublications) {
          if (pub.subscribed && !pub.muted) muted = false;
        }
        for (final pub in p.videoTrackPublications) {
          if (pub.kind == TrackType.VIDEO &&
              !pub.isScreenShare &&
              pub.subscribed &&
              !pub.muted) {
            final t = pub.track;
            if (t is VideoTrack) video = t;
          }
        }
        r[p.identity] = (
          name: p.name.isNotEmpty ? p.name : p.identity,
          speaking: p.isSpeaking,
          muted: muted,
        );
        vids[p.identity] = video;
        lvls[p.identity] = p.audioLevel;
      }
      final local = room.localParticipant;
      if (local != null) {
        final s2 = ref.read(sessionProvider);
        r[local.identity] = (
          name: s2?.nick ?? '?',
          speaking: local.isSpeaking,
          muted: cur.muted,
        );
        vids[local.identity] = localVideoTrack;
        lvls[local.identity] = local.audioLevel;
      }
    }
    final s = ref.read(sessionProvider);
    final myId = s?.userId ?? '';
    final next = mergeVoicePeers(
        signalingIds: ids,
        nicks: nicks[cur.channelId] ?? {},
        room: r,
        videos: vids,
        levels: lvls,
        myId: myId,
        myNick: s?.nick ?? '?',
        selfMuted: cur.muted,
        selfSpeaking: room?.localParticipant?.isSpeaking ?? false,
        mutedPeers: mutedPeers,
        serverMuted: serverMuted,
        deafened: cur.deafened);
    // Stabilized pill preview (§38): remotes only, never self. Silence
    // holds the last display; a speaker who left clears (facade falls back
    // to the first remaining remote, §22).
    final remoteIds = {
      for (final p in next) if (!p.self) p.id,
    };
    final displayed = _speakerFocus.update(
        levels: {for (final id in remoteIds) id: lvls[id] ?? 0.0},
        speaking: {
          for (final p in next)
            if (!p.self && p.speaking) p.id,
        },
        knownIds: remoteIds,
        now: DateTime.now());
    // The level ticker fires 16×/s: publish only on visible change,
    // otherwise the whole sidebar + call grid would rebuild for nothing.
    if (!_samePeers(cur.peers, next) ||
        cur.displayedSpeakerId != displayed) {
      state = cur.copyWith(
          peers: next, displayedSpeakerId: () => displayed);
      dlog('voice levels: ${[
        for (final p in next)
          '${p.nick}=${p.speaking ? 's' : '-'}${p.audioLevel.toStringAsFixed(1)}${p.muted ? 'm' : ''}'
      ].join(' ')}');
    }
    _enforceSubscriptions();
  }

  /// Visible peer equality: ids, nicks, flags, quantized level and the live
  /// track identity. Anything else is not worth a rebuild.
  bool _samePeers(List<VoicePeer> a, List<VoicePeer> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      final x = a[i];
      final y = b[i];
      if (x.id != y.id ||
          x.nick != y.nick ||
          x.speaking != y.speaking ||
          x.muted != y.muted ||
          x.self != y.self ||
          x.serverMuted != y.serverMuted ||
          x.localMuted != y.localMuted ||
          x.audioLevel != y.audioLevel ||
          !identical(x.videoTrack, y.videoTrack)) {
        return false;
      }
    }
    return true;
  }

  /// Enforce who I actually hear: server mutes, my local mutes and deafen
  /// win over the published state. Unsubscribing (not just local gain)
  /// also stops the media flow. Resubscribes only on change.
  Future<void> _enforceSubscriptions() async {
    final cur = state;
    final room = _room;
    if (cur == null || room == null) return;
    for (final p in room.remoteParticipants.values) {
      final hear = !serverMuted.contains(p.identity) &&
          !mutedPeers.contains(p.identity) &&
          !cur.deafened;
      if (_appliedSubs[p.identity] == hear) continue;
      _appliedSubs[p.identity] = hear;
      for (final pub in p.audioTrackPublications) {
        try {
          if (hear) {
            await pub.subscribe();
          } else {
            await pub.unsubscribe();
          }
        } catch (_) {}
      }
    }
  }

  /// userId → nick per channel, from voice_members (room names back it up).
  final Map<String, Map<String, String>> _nicks = {};

  /// Channel caps from voice_members, 0 = unlimited.
  final Map<String, int> limits = {};

  Future<void> _refreshNicks(String channelId) async {
    await _refreshRoster(channelId);
  }

  /// Roster truth from signaling: nicks, moderator mutes and the user limit.
  Future<void> _refreshRoster(String channelId) async {
    final s = ref.read(sessionProvider);
    if (s == null) return;
    try {
      final r = await ref.read(connectionProvider).request('voice_members',
          fields: {'session_token': s.token, 'channel_id': channelId});
      if (r['type'] == 'error') return;
      final m = <String, String>{};
      final sm = <String>{};
      for (final e in ((r['members'] as List?) ?? const [])) {
        final mm = e as Map;
        final id = (mm['user_id'] ?? '').toString();
        final nick = (mm['nick'] ?? '').toString();
        if (id.isNotEmpty && nick.isNotEmpty) m[id] = nick;
        if (id.isNotEmpty && (mm['muted'] as bool? ?? false)) sm.add(id);
      }
      _nicks[channelId] = m;
      // Server mutes only ever apply to the channel I'm actually in:
      // resolving another channel's roster (limit display) must not
      // inherit its locks.
      if (state?.channelId == channelId) {
        serverMuted
          ..clear()
          ..addAll(sm);
      }
      limits[channelId] = (r['user_limit'] as num?)?.toInt() ?? 0;
    } catch (_) {}
  }

  Future<void> _leaveRoom() async {
    _levelTimer?.cancel();
    _levelTimer = null;
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
      'CHANNEL_FULL' => 'Канал полон',
      'NO_PERMISSION' => 'Нет прав',
      'MUTED_BY_SERVER' => 'Тебя замутили — микрофон заблокирован',
      _ => 'Не вышло зайти в войс',
    };
  }
  return 'Не вышло зайти в войс';
}
