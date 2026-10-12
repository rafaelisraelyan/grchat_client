import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:livekit_client/livekit_client.dart';

import '../app/providers.dart';
import '../chat/home_state.dart';
import '../voice/voice_state.dart';
import 'call_state.dart';
import 'group_call.dart';
import 'media_session.dart';

/// Call engine behind the universal window.
enum CallKind { direct, group, serverVoice }

/// One surface, three presentations (§2): never a pile of booleans that
/// can combine into impossible states.
enum CallPresentationMode { expanded, miniWithPreview, miniCollapsed }

/// Preview visibility inside mini, per session. Reset on session change;
/// drives the collapse animation, never the media (§4–§5).
///
/// Plain bool holder (Riverpod 3 has no StateProvider).
class _PreviewFlag extends Notifier<bool> {
  _PreviewFlag(this._initial);
  final bool _initial;

  @override
  bool build() => _initial;

  /// External writes go through here: raw `.state` sets are
  /// test/engine-only by framework rules.
  void set(bool value) {
    if (state != value) state = value;
  }
}

final miniPreviewVisibleProvider =
    NotifierProvider<_PreviewFlag, bool>(() => _PreviewFlag(true));

/// Remembered mini mode for expand→minimize round trips (§31): the mode
/// that was showing when the user last expanded.
final lastMiniPreviewProvider =
    NotifierProvider<_PreviewFlag, bool>(() => _PreviewFlag(true));

/// Engine-agnostic participant for the ParticipantGrid.
///
/// Video is engine-specific (flutter_webrtc vs LiveKit), so a tile carries a
/// ready widget builder instead of a track handle. Null video = avatar mode.
/// The grid itself never branches on [CallKind]: it renders participants.
class CallParticipant {
  CallParticipant(
      {required this.id,
      required this.nick,
      required this.self,
      required this.speaking,
      required this.muted,
      this.video,
      this.videoKey});
  final String id;
  final String nick;
  final bool self;
  final bool speaking;
  final bool muted;
  final WidgetBuilder? video;

  /// Stable identity for the media behind [video] (track/renderer object).
  /// Render sites wrap the video in `KeyedSubtree(GlobalObjectKey(videoKey))`
  /// so the SAME element — and its texture binding — survives layout moves
  /// (grid ↔ morph ↔ pill) with no black frame (§4, §53). Null = avatar.
  final Object? videoKey;
}

/// One value the universal Call Window renders, whichever engine owns media.
///
/// Media lifetime belongs to the engines (CallSession in the prompt's terms);
/// this is the view contract: header, participants, controls, window state.
/// Minimizing/closing the window never touches media — only explicit leave
/// actions stop the owning engine.
class UnifiedCall {
  UnifiedCall(
      {required this.kind,
      required this.sessionId,
      required this.title,
      required this.subtitle,
      required this.video,
      required this.outgoing,
      required this.phase,
      required this.muted,
      required this.cameraOff,
      required this.sharingScreen,
      required this.linkDown,
      required this.minimized,
      required this.participants,
      required this.onAccept,
      required this.onDecline,
      this.onAcceptAsGroup,
      required this.onHangup,
      required this.onToggleMute,
      required this.onToggleCamera,
      required this.onToggleShare,
      required this.onSetMinimized,
      required this.friendlyError,
      this.switchDetail,
      this.spotlight,
      this.remoteVideo = false,
      required this.presentation});
  final CallKind kind;
  final String sessionId;
  final String title;
  final String subtitle;
  final bool video;
  final bool outgoing;
  final CallPhase phase;
  final bool muted;
  final bool cameraOff;
  final bool sharingScreen;
  final bool linkDown;
  final bool minimized;
  final List<CallParticipant> participants;
  final Future<void> Function()? onAccept;
  final Future<void> Function()? onDecline;

  /// Escalate-into-group for a direct incoming over a live direct call:
  /// end the peer, decline the ring, continue together in a room.
  /// Null everywhere else (members unknown or nothing live).
  final Future<SwitchResult> Function()? onAcceptAsGroup;
  final Future<void> Function() onHangup;
  final void Function() onToggleMute;
  final void Function() onToggleCamera;
  final Future<void> Function() onToggleShare;
  final void Function(bool) onSetMinimized;

  /// Maps engine errors to Russian UI copy. Direct and voice share the P2P
  /// table; group calls have their own (NOT_MEMBER et al).
  final String Function(Object) friendlyError;

  /// Call-waiting context for the incoming window (§31–§33), e.g.
  /// 'Вы сейчас в голосовом канале «Studio».' Null = free, plain accept.
  final String? switchDetail;

  /// A remote video track arrived (late peer camera in a voice-started
  /// call): opens the wide hero view even when this side never sent video.
  final bool remoteVideo;

  /// Live pill preview (§61): the remote peer to watch while minimized.
  /// P2P = the peer, always (§18). Group/voice = stabilized active remote
  /// speaker with first-remote fallback (§9, §22). Null = no remote peers:
  /// the pill shows the call avatar instead.
  final CallParticipant? spotlight;

  /// Which of the three presentations to render (§2).
  final CallPresentationMode presentation;
}

/// Picks the live engine: direct P2P first, group SFU second, server voice
/// third. The busy guards in the engines prevent two live sessions at
/// once, so the order only decides which stale state wins on a race.
final unifiedCallProvider = Provider<UnifiedCall?>((ref) {
  final direct = ref.watch(callStateProvider);
  if (direct != null) return _fromDirect(ref, direct);
  final group = ref.watch(groupCallProvider);
  if (group != null) return _fromGroup(ref, group);
  final voice = ref.watch(voiceSessionProvider);
  if (voice != null) return _fromVoice(ref, voice);
  return null;
});

/// Minimize whichever call is live. Called on text-channel navigation (§33):
/// the window folds, media keeps running.
void minimizeLiveCall(Ref ref) {
  final direct = ref.read(callStateProvider);
  if (direct != null && !direct.minimized) {
    ref.read(callStateProvider.notifier).setMinimized(true);
  }
  final voice = ref.read(voiceSessionProvider);
  if (voice != null && !voice.minimized) {
    ref.read(voiceSessionProvider.notifier).setMinimized(true);
  }
  final group = ref.read(groupCallProvider);
  if (group != null && !group.minimized) {
    ref.read(groupCallProvider.notifier).setMinimized(true);
  }
}

/// Engine minimized flag + session preview visibility → the one
/// presentation mode (§2). Engines keep their bool untouched; the mapping
/// lives here, in one place.
CallPresentationMode _presentationOf(Ref ref, bool minimized) {
  if (!minimized) return CallPresentationMode.expanded;
  return ref.watch(miniPreviewVisibleProvider)
      ? CallPresentationMode.miniWithPreview
      : CallPresentationMode.miniCollapsed;
}

UnifiedCall _fromDirect(Ref ref, ActiveCall call) {
  final st = ref.read(callStateProvider.notifier);
  final coord = ref.read(mediaCoordinatorProvider.notifier);
  final incoming =
      !call.outgoing && call.phase == CallPhase.ringing;
  // P2P pill preview (§8, §18): always the remote peer, never self-view.
  // Speaking/mute of the remote side are unknown to the P2P engine, so the
  // tile stays neutral. The renderer object keys the shared video: the same
  // track binding rides grid ↔ morph ↔ pill with no re-create (§4, §53).
  final remoteRenderer = st.remoteRenderer;
  final hasRemoteVideo =
      call.video && call.remoteVideo && remoteRenderer != null;
  final remote = CallParticipant(
      id: 'peer',
      nick: call.peerNick,
      self: false,
      speaking: false,
      muted: false,
      video: hasRemoteVideo
          ? ((ctx) => KeyedSubtree(
              key: GlobalObjectKey(remoteRenderer),
              child: RTCVideoView(remoteRenderer,
                  objectFit: RTCVideoViewObjectFit
                      .RTCVideoViewObjectFitCover)))
          : null,
      videoKey: hasRemoteVideo ? remoteRenderer : null);
  return UnifiedCall(
    kind: CallKind.direct,
    sessionId: call.callId,
    title: call.peerNick,
    subtitle: incoming
        ? (call.video ? 'Входящий видеозвонок' : 'Входящий аудиозвонок')
        : (call.phase == CallPhase.ringing ? 'Вызов…' : 'Подключено'),
    video: call.video,
    outgoing: call.outgoing,
    phase: call.phase,
    muted: call.muted,
    cameraOff: call.cameraOff,
    sharingScreen: call.sharingScreen,
    linkDown: call.linkDown,
    minimized: call.minimized,
    participants: [remote],
    presentation: _presentationOf(ref, call.minimized),
    // Accept is an atomic coordinator switch (§3): the live session (if
    // any) ends first, the new media starts only after. Decline keeps the
    // current session untouched.
    onAccept: incoming
        ? () => coord.acceptIncoming(
            kind: MediaSessionKind.direct, pendingId: call.callId)
        : null,
    onDecline: incoming ? () => st.decline() : null,
    // Escalate: live direct peer + ringing caller continue in a room.
    // Only when both nicks are known (direct over direct).
    onAcceptAsGroup: incoming
        ? () {
            final active = coord.activeMedia();
            if (active == null ||
                active.kind != MediaSessionKind.direct) {
              ref
                  .read(callNoticeProvider.notifier)
                  .show('Звонок уже завершён');
              return Future.value(SwitchResult.aborted);
            }
            return coord.escalateToGroup(
                nicks: [active.label, call.peerNick], video: call.video);
          }
        : null,
    // User-pressed hangup: audible end first, then the engine ends.
    // Coordinator switches use endAll directly and stay silent.
    onHangup: () {
      st.toneForLocalEnd();
      return st.hangup();
    },
    onToggleMute: () => st.toggleMute(),
    onToggleCamera: () => st.toggleCamera(),
    onToggleShare: () => st.toggleScreenShare(),
    onSetMinimized: (m) => st.setMinimized(m),
    friendlyError: friendlyCallError,
    switchDetail:
        incoming ? coord.switchWarningFor(MediaSessionKind.direct) : null,
    // P2P spotlight is always the remote peer (§18), even mid-sentence.
    spotlight: remote,
    remoteVideo: call.remoteVideo,
  );
}

String _plural(int n, String one, String few, String many) {
  if (n % 10 == 1 && n % 100 != 11) return one;
  if (n % 10 >= 2 && n % 10 <= 4 && (n % 100 < 12 || n % 100 > 14)) {
    return few;
  }
  return many;
}

/// Pill preview pick (§9, §18–§22): stabilized display wins, otherwise the
/// first remote. Self never qualifies; empty remotes → null (avatar mode).
CallParticipant? spotlightPeer(
    {required List<CallParticipant> parts, String? displayedId}) {
  CallParticipant? first;
  for (final p in parts) {
    if (p.self) continue;
    first ??= p;
    if (displayedId != null && p.id == displayedId) return p;
  }
  return first;
}

/// Leave the server voice session; when its channel is still selected,
/// return to the last text scope (§24). Shared by the window, the pill
/// and the sidebar leave affordances.
Future<void> leaveVoice(VoiceSessionState voice, HomeState home,
    Scope? scope, String channelId) async {
  await voice.leave();
  if (scope is ChannelScope && scope.channel.id == channelId) {
    await home.reselectLastText();
  }
}

UnifiedCall _fromVoice(Ref ref, VoiceSession session) {
  final st = ref.read(voiceSessionProvider.notifier);
  final parts = <CallParticipant>[];
  for (final p in session.peers) {
    final track = p.videoTrack;
    parts.add(CallParticipant(
        id: p.id,
        nick: p.self ? '${p.nick} · Вы' : p.nick,
        self: p.self,
        speaking: p.speaking,
        muted: p.muted,
        video: track != null
            ? ((ctx) => KeyedSubtree(
                key: GlobalObjectKey(track),
                child: VideoTrackRenderer(track)))
            : null,
        videoKey: track));
  }
  final others = parts.where((p) => !p.self).length;
  return UnifiedCall(
    kind: CallKind.serverVoice,
    sessionId: session.channelId,
    title: '🔊 ${session.title}',
    subtitle:
        '$others ${_plural(others, 'участник', 'участника', 'участников')}',
    video: true,
    outgoing: false,
    phase: CallPhase.active,
    muted: session.muted,
    cameraOff: session.cameraOff,
    sharingScreen: false,
    linkDown: false,
    minimized: session.minimized,
    participants: parts,
    presentation: _presentationOf(ref, session.minimized),
    onAccept: null,
    onDecline: null,
    // Leave ends media, then returns to the last text scope when the voice
    // channel is still selected (§24). Direct leave keeps its scope.
    onHangup: () => leaveVoice(
        ref.read(voiceSessionProvider.notifier),
        ref.read(homeStateProvider.notifier),
        ref.read(homeStateProvider).scope,
        session.channelId),
    onToggleMute: () => st.toggleMute(),
    onToggleCamera: () => st.toggleCamera(),
    onToggleShare: () async {},
    onSetMinimized: (m) => st.setMinimized(m),
    friendlyError: friendlyCallError,
    // Stabilized remote speaker, first-remote fallback (§9, §22).
    spotlight: spotlightPeer(
        parts: parts, displayedId: session.displayedSpeakerId),
  );
}

UnifiedCall _fromGroup(Ref ref, GroupCall call) {
  final st = ref.read(groupCallProvider.notifier);
  final coord = ref.read(mediaCoordinatorProvider.notifier);
  final incoming =
      !call.outgoing && call.phase == GroupPhase.ringing;
  final parts = <CallParticipant>[];
  for (final p in call.peers) {
    final track = p.videoTrack;
    parts.add(CallParticipant(
        id: p.identity,
        nick: p.name,
        self: false,
        speaking: p.speaking,
        muted: p.audioMuted,
        video: track != null
            ? ((ctx) => KeyedSubtree(
                key: GlobalObjectKey(track),
                child: VideoTrackRenderer(track)))
            : null,
        videoKey: track));
  }
  // Self tile last, like the old group grid.
  final myNick = ref.read(sessionProvider)?.nick ?? '?';
  final selfTrack = st.localVideoTrack;
  parts.add(CallParticipant(
      id: 'self',
      nick: '$myNick · Вы',
      self: true,
      speaking: false,
      muted: call.muted,
      video: call.video && !call.cameraOff && selfTrack != null
          ? ((ctx) => KeyedSubtree(
              key: GlobalObjectKey(selfTrack),
              child: VideoTrackRenderer(selfTrack)))
          : null,
      videoKey: call.video && !call.cameraOff ? selfTrack : null));
  final n = call.peers.length;
  return UnifiedCall(
    kind: CallKind.group,
    sessionId: call.callId ?? 'group:${call.dmId}',
    title: call.title,
    subtitle: call.phase == GroupPhase.ringing
        ? (incoming
            ? (call.video
                ? 'Входящий групповой видеозвонок'
                : 'Входящий групповой звонок')
            : 'Вызов…')
        : '$n ${_plural(n, 'участник', 'участника', 'участников')}',
    video: call.video,
    outgoing: call.outgoing,
    phase: call.phase == GroupPhase.ringing
        ? CallPhase.ringing
        : CallPhase.active,
    muted: call.muted,
    cameraOff: call.cameraOff,
    sharingScreen: false,
    linkDown: false,
    minimized: call.minimized,
    participants: parts,
    presentation: _presentationOf(ref, call.minimized),
    onAccept: incoming
        ? () => coord.acceptIncoming(
            kind: MediaSessionKind.group, pendingId: call.callId!)
        : null,
    onDecline: incoming ? () => st.decline() : null,
    // User-pressed hangup: audible end first, then the engine ends.
    // Coordinator switches use endAll directly and stay silent.
    onHangup: () {
      st.toneForLocalEnd();
      return st.hangup();
    },
    onToggleMute: () => st.toggleMute(),
    onToggleCamera: () => st.toggleCamera(),
    onToggleShare: () async {},
    onSetMinimized: (m) => st.setMinimized(m),
    friendlyError: friendlyGroupError,
    switchDetail:
        incoming ? coord.switchWarningFor(MediaSessionKind.group) : null,
    // Stabilized remote speaker, first-remote fallback (§9, §22).
    spotlight: spotlightPeer(
        parts: parts, displayedId: call.displayedSpeakerId),
  );
}
