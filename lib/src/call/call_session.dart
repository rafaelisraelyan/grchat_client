import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:livekit_client/livekit_client.dart';

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
      required this.onSetMinimized});
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
}

/// Picks the live engine: direct P2P first, server voice second.
/// Group calls still own their window (migrates next); the busy guards in
/// the engines prevent two live sessions at once.
final unifiedCallProvider = Provider<UnifiedCall?>((ref) {
  final direct = ref.watch(callStateProvider);
  if (direct != null) return _fromDirect(ref, direct);
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
  );
}
