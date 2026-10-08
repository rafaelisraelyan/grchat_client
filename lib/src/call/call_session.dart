import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:livekit_client/livekit_client.dart';

import '../app/providers.dart';
import '../chat/home_state.dart';
import '../voice/voice_state.dart';
import 'call_state.dart';
import 'group_call.dart';

/// Call engine behind the universal window.
enum CallKind { direct, group, serverVoice }

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
      this.video});
  final String id;
  final String nick;
  final bool self;
  final bool speaking;
  final bool muted;
  final WidgetBuilder? video;
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
      required this.onHangup,
      required this.onToggleMute,
      required this.onToggleCamera,
      required this.onToggleShare,
      required this.onSetMinimized,
      required this.friendlyError});
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
  final Future<void> Function() onHangup;
  final void Function() onToggleMute;
  final void Function() onToggleCamera;
  final Future<void> Function() onToggleShare;
  final void Function(bool) onSetMinimized;

  /// Maps engine errors to Russian UI copy. Direct and voice share the P2P
  /// table; group calls have their own (NOT_MEMBER et al).
  final String Function(Object) friendlyError;
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

UnifiedCall _fromDirect(Ref ref, ActiveCall call) {
  final st = ref.read(callStateProvider.notifier);
  final incoming =
      !call.outgoing && call.phase == CallPhase.ringing;
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
    participants: const [],
    onAccept: incoming ? () => st.acceptIncoming() : null,
    onDecline: incoming ? () => st.decline() : null,
    onHangup: () => st.hangup(),
    onToggleMute: () => st.toggleMute(),
    onToggleCamera: () => st.toggleCamera(),
    onToggleShare: () => st.toggleScreenShare(),
    onSetMinimized: (m) => st.setMinimized(m),
    friendlyError: friendlyCallError,
  );
}

String _plural(int n, String one, String few, String many) {
  if (n % 10 == 1 && n % 100 != 11) return one;
  if (n % 10 >= 2 && n % 10 <= 4 && (n % 100 < 12 || n % 100 > 14)) {
    return few;
  }
  return many;
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
            ? ((ctx) => VideoTrackRenderer(track))
            : null));
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
  );
}

UnifiedCall _fromGroup(Ref ref, GroupCall call) {
  final st = ref.read(groupCallProvider.notifier);
  final incoming =
      !call.outgoing && call.phase == GroupPhase.ringing;
  final parts = <CallParticipant>[];
  for (final p in call.peers) {
    final track = p.videoTrack;
    parts.add(CallParticipant(
        id: p.identity,
        nick: p.name,
        self: false,
        // The group engine tracks membership, not loudness: no ring yet.
        // Same as the old group grid — presence without speaking state.
        speaking: false,
        muted: p.audioMuted,
        video: track != null
            ? ((ctx) => VideoTrackRenderer(track))
            : null));
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
          ? ((ctx) => VideoTrackRenderer(selfTrack))
          : null));
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
    onAccept: incoming ? () => st.acceptIncoming() : null,
    onDecline: incoming ? () => st.decline() : null,
    onHangup: () => st.hangup(),
    onToggleMute: () => st.toggleMute(),
    onToggleCamera: () => st.toggleCamera(),
    onToggleShare: () async {},
    onSetMinimized: (m) => st.setMinimized(m),
    friendlyError: friendlyGroupError,
  );
}
