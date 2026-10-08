import 'dart:async';

import 'package:livekit_client/livekit_client.dart';
import 'package:riverpod/riverpod.dart';

import '../app/providers.dart';
import '../auth/auth_repository.dart';
import '../chat/home_state.dart';
import 'call_api.dart';
import 'call_diagnostics.dart';
import 'call_state.dart' show callNoticeProvider, callStateProvider;
import 'media_session.dart';
import 'sfu_marker.dart';
import 'speaker_focus.dart';

enum GroupPhase { ringing, active }

/// One remote member of the SFU room. [videoTrack] is null until a
/// subscribed, unmuted video track exists — the UI shows an avatar then.
/// [speaking]/[audioLevel] feed the stabilized pill preview (§38).
class GroupPeer {
  GroupPeer({
    required this.identity,
    required this.name,
    required this.videoTrack,
    required this.audioMuted,
    this.speaking = false,
    this.audioLevel = 0.0,
  });
  final String identity;
  final String name;
  final VideoTrack? videoTrack;
  final bool audioMuted;
  final bool speaking;
  final double audioLevel;
}

/// A group call lives in a LiveKit room; our server only mints tokens
/// and fans out the invite. 1-1 calls stay on direct P2P (CallState).
class GroupCall {
  GroupCall({
    required this.dmId,
    required this.title,
    required this.room,
    required this.video,
    required this.outgoing,
    required this.phase,
    this.callId,
    this.peers = const [],
    this.muted = false,
    this.cameraOff = false,
    this.minimized = false,
    this.displayedSpeakerId,
  });

  final String dmId;
  final String title;
  final String room;
  final bool video;
  final bool outgoing;
  final GroupPhase phase;

  /// Signaling call id for hangup/decline correlation. Null until the
  /// outgoing offer returns, or until an incoming invite arrives.
  final String? callId;
  final List<GroupPeer> peers;
  final bool muted;
  final bool cameraOff;

  /// Presentation only: mini pill vs centered window, same as 1-1 (§46–§48).
  final bool minimized;

  /// Stabilized pill preview (§38): remote identity, or null for the
  /// first-remote fallback. Never self.
  final String? displayedSpeakerId;

  GroupCall copyWith({
    GroupPhase? phase,
    String? callId,
    List<GroupPeer>? peers,
    bool? muted,
    bool? cameraOff,
    bool? minimized,
    String? Function()? displayedSpeakerId,
  }) =>
      GroupCall(
        dmId: dmId,
        title: title,
        room: room,
        video: video,
        outgoing: outgoing,
        phase: phase ?? this.phase,
        callId: callId ?? this.callId,
        peers: peers ?? this.peers,
        muted: muted ?? this.muted,
        cameraOff: cameraOff ?? this.cameraOff,
        minimized: minimized ?? this.minimized,
        displayedSpeakerId: displayedSpeakerId != null
            ? displayedSpeakerId()
            : this.displayedSpeakerId,
      );
}

final groupCallApiProvider = Provider<CallApi>((ref) {
  final s = ref.watch(sessionProvider);
  if (s == null) throw StateError('no session');
  return CallApi(ref.watch(connectionProvider), s);
});

class GroupCallState extends Notifier<GroupCall?> {
  Room? _room;
  EventsListener<RoomEvent>? _roomEvents;
  StreamSubscription<Map<String, dynamic>>? _pushSub;

  /// Level sampler for the stabilized pill preview (§38): 8 Hz, guarded
  /// publishes only. Reset per session so a new room starts unbiased.
  Timer? _levelTimer;
  final SpeakerStabilizer _speakerFocus = SpeakerStabilizer();

  @override
  GroupCall? build() => null;

  void ensureListening() {
    _pushSub ??=
        ref.read(connectionProvider).pushes.listen(_onPush);
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

  /// Outgoing group call: join the SFU room first, then ring the members
  /// through the stock invite fan-out.
  Future<void> join(
      {required String dmId,
      required String title,
      required bool video}) async {
    if (state != null) return;
    if (ref.read(callStateProvider) != null) {
      ref.read(callNoticeProvider.notifier).show('Занято');
      return;
    }
    final api = ref.read(groupCallApiProvider);
    final creds = await api.livekitToken(dmId);
    final room = Room();
    try {
      _attach(room);
      await room.connect(creds.url, creds.token);
      await room.localParticipant
          ?.setMicrophoneEnabled(true);
      if (video) {
        try {
          await room.localParticipant?.setCameraEnabled(true);
        } catch (e) {
          dlog('group camera failed: $e');
        }
      }
      state = GroupCall(
          dmId: dmId,
          title: title,
          room: creds.room,
          video: video,
          outgoing: true,
          phase: GroupPhase.active);
      _startLevels();
      _syncPeers();
      try {
        final callId = await api.offer(
            dmId: dmId,
            sdp: buildSfuMarker(creds.room, video));
        state = state?.copyWith(callId: callId);
      } catch (e) {
        // Invite failed (e.g. everyone offline): stay in the room so a
        // late joiner still lands; the error is shown, not thrown.
        dlog('group invite failed: $e');
        ref
            .read(callNoticeProvider.notifier)
            .show(friendlyGroupError(e));
      }
    } catch (e) {
      await _leaveRoom();
      rethrow;
    }
  }

  /// Incoming SFU invite from the signaling fan-out.
  void incoming(
      {required String callId,
      required String dmId,
      required String room,
      required bool video,
      required String fromNick}) {
    // One pending at a time (§15, §16): switching or ringing elsewhere
    // means BUSY. A live session of any kind gets call waiting instead:
    // group ringing holds no media, accept is a coordinator switch.
    final coord = ref.read(mediaCoordinatorProvider.notifier);
    if (coord.switching || coord.hasPendingIncoming()) {
      try {
        ref
            .read(groupCallApiProvider)
            .answer(callId: callId, accept: false)
            .catchError((_) {});
      } catch (_) {}
      return;
    }
    if (state != null) {
      // Busy in another group call: decline quietly.
      try {
        ref
            .read(groupCallApiProvider)
            .answer(callId: callId, accept: false)
            .catchError((_) {});
      } catch (_) {}
      return;
    }
    dlog('group incoming room=$room from=$fromNick');
    state = GroupCall(
        dmId: dmId,
        title: _dmTitle(dmId),
        room: room,
        video: video,
        outgoing: false,
        phase: GroupPhase.ringing,
        callId: callId);
  }

  String _dmTitle(String dmId) {
    try {
      final data = ref.read(homeStateProvider);
      final myId = ref.read(sessionProvider)?.userId ?? '';
      final match = data.dms.where((d) => d.id == dmId);
      if (match.isNotEmpty) return match.first.title(myId);
    } catch (_) {}
    return 'Группа';
  }

  Future<void> acceptIncoming() async {
    final cur = state;
    if (cur == null || cur.outgoing || cur.phase != GroupPhase.ringing) {
      return;
    }
    final api = ref.read(groupCallApiProvider);
    final room = Room();
    try {
      _attach(room);
      final creds = await api.livekitToken(cur.dmId);
      await room.connect(creds.url, creds.token);
      await room.localParticipant?.setMicrophoneEnabled(true);
      if (cur.video) {
        try {
          await room.localParticipant?.setCameraEnabled(true);
        } catch (e) {
          dlog('group camera failed: $e');
        }
      }
      state = cur.copyWith(phase: GroupPhase.active);
      _startLevels();
      _syncPeers();
      // Acknowledge over signaling so the caller tracks + records.
      // The marker sdp is convention only; media lives in the room.
      await api.answer(
          callId: cur.callId!,
          accept: true,
          sdp: buildSfuMarker(cur.room, cur.video));
    } catch (e) {
      await decline();
      rethrow;
    }
  }

  Future<void> decline() async {
    final cur = state;
    if (cur == null) return;
    if (cur.callId != null) {
      try {
        await ref
            .read(groupCallApiProvider)
            .answer(callId: cur.callId!, accept: false);
      } catch (_) {}
    }
    await _leaveRoom();
    state = null;
  }

  Future<void> hangup() async {
    final cur = state;
    if (cur == null) return;
    if (cur.callId != null) {
      try {
        await ref
            .read(groupCallApiProvider)
            .hangup(cur.callId!);
      } catch (_) {}
    }
    await _leaveRoom();
    state = null;
  }

  /// Coordinator primitive: end everything this engine holds. A bare ring
  /// is declined, a live session hung up; the accepted pending
  /// ([exceptPendingId]) is left alone. Idempotent (§38).
  Future<void> endAll({String? exceptPendingId}) async {
    final cur = state;
    if (cur == null) return;
    if (!cur.outgoing &&
        cur.phase == GroupPhase.ringing &&
        cur.callId == exceptPendingId) {
      return;
    }
    if (!cur.outgoing && cur.phase == GroupPhase.ringing) {
      await decline();
    } else {
      await hangup();
    }
  }

  Future<void> toggleMute() async {
    final cur = state;
    if (cur == null) return;
    final muted = !cur.muted;
    try {
      await _room?.localParticipant?.setMicrophoneEnabled(!muted);
    } catch (_) {}
    _patchIfSame(cur, (live) => live.copyWith(muted: muted));
  }

  Future<void> toggleCamera() async {
    final cur = state;
    if (cur == null || !cur.video) return;
    final off = !cur.cameraOff;
    try {
      await _room?.localParticipant?.setCameraEnabled(!off);
    } catch (_) {}
    _patchIfSame(cur, (live) => live.copyWith(cameraOff: off));
  }

  void setMinimized(bool minimized) {
    final cur = state;
    if (cur == null || cur.minimized == minimized) return;
    state = cur.copyWith(minimized: minimized);
  }

  /// Patch the live state, never a snapshot captured before an await:
  /// room events (_syncPeers) and UI toggles interleave, and writing back a
  /// stale object wipes whatever the other side changed (same clobber class
  /// as the 1-1 remoteVideo bug). The dmId+room check keeps a patch from
  /// leaking onto a different call that started meanwhile.
  void _patchIfSame(
      GroupCall cur, GroupCall Function(GroupCall live) patch) {
    final live = state;
    if (live == null) return;
    if (live.dmId != cur.dmId || live.room != cur.room) return;
    state = patch(live);
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
      ..on<RoomDisconnectedEvent>((_) => _onRoomLost());
  }

  void _syncPeers() {
    final cur = state;
    final room = _room;
    if (cur == null || room == null) return;
    final peers = <GroupPeer>[];
    final levels = <String, double>{};
    final speaking = <String>{};
    for (final p in room.remoteParticipants.values) {
      VideoTrack? video;
      var audioMuted = true;
      for (final pub in p.audioTrackPublications) {
        if (pub.subscribed && !pub.muted) audioMuted = false;
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
      levels[p.identity] = p.audioLevel;
      if (p.isSpeaking && !audioMuted) speaking.add(p.identity);
      // Quantized like voice: raw SFU floats jitter every frame, and the
      // 8 Hz guard below must only fire on visible change.
      final level =
          (p.audioLevel.clamp(0.0, 1.0) * 10).roundToDouble() / 10;
      levels[p.identity] = level;
      peers.add(GroupPeer(
          identity: p.identity,
          name: p.name.isNotEmpty ? p.name : p.identity,
          videoTrack: video,
          audioMuted: audioMuted,
          speaking: p.isSpeaking && !audioMuted,
          audioLevel: level));
    }
    // Stabilized pill preview (§38): remotes only, silence holds last.
    final displayed = _speakerFocus.update(
        levels: levels,
        speaking: speaking,
        knownIds: levels.keys.toSet(),
        now: DateTime.now());
    if (_samePeers(cur.peers, peers) &&
        cur.displayedSpeakerId == displayed) {
      return;
    }
    dlog('group peers=${peers.length} focus=${displayed ?? '-'}');
    _patchIfSame(
        cur,
        (live) => live.copyWith(
            peers: peers, displayedSpeakerId: () => displayed));
  }

  /// Guard the 8 Hz sampler: publish only on visible change (§52).
  bool _samePeers(List<GroupPeer> a, List<GroupPeer> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      final x = a[i];
      final y = b[i];
      if (x.identity != y.identity ||
          x.name != y.name ||
          x.audioMuted != y.audioMuted ||
          x.speaking != y.speaking ||
          x.audioLevel != y.audioLevel ||
          !identical(x.videoTrack, y.videoTrack)) {
        return false;
      }
    }
    return true;
  }

  void _startLevels() {
    _speakerFocus.reset();
    _levelTimer?.cancel();
    _levelTimer = Timer.periodic(const Duration(milliseconds: 120), (_) {
      if (state == null || _room == null) return;
      _syncPeers();
    });
  }

  void _onRoomLost() {
    dlog('group room lost');
    // Never vanish silently: the window is gone, so the toast is the only
    // trace of why. The user redials by hand from the DM.
    ref.read(callNoticeProvider.notifier).show('Соединение с комнатой потеряно');
    _leaveRoom();
    state = null;
  }

  Future<void> _leaveRoom() async {
    _levelTimer?.cancel();
    _levelTimer = null;
    _speakerFocus.reset();
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

  void _onPush(Map<String, dynamic> ev) {
    switch (ev['type']?.toString()) {
      case 'call_ended':
        final cur = state;
        if (cur == null ||
            cur.callId == null ||
            ev['call_id'] != cur.callId) {
          return;
        }
        dlog('group ended by signaling');
        _leaveRoom();
        state = null;
    }
  }
}

final groupCallProvider =
    NotifierProvider<GroupCallState, GroupCall?>(GroupCallState.new);

/// Raw server codes must never reach the UI.
String friendlyGroupError(Object e) {
  if (e is GrchatException) {
    return switch (e.code) {
      'NOT_MEMBER' => 'Нет доступа к звонку',
      'NOT_FOUND' => 'Чат не найден',
      'ALREADY_IN_CALL' => 'Вы уже сейчас в звонке',
      _ => 'Не вышло позвонить',
    };
  }
  return 'Не вышло позвонить';
}
