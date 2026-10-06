import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

import '../widgets/avatar.dart';
import '../widgets/toast.dart';
import 'call_state.dart';

/// Global call surface (§30–§51): centered CallWindow + mini overlay.
/// Lives in the home Stack, above every workspace, never inside ChatView.
/// Presentation only — state in CallState, WebRTC in CallState/pc.
class CallOverlayHost extends ConsumerStatefulWidget {
  const CallOverlayHost({super.key});

  @override
  ConsumerState<CallOverlayHost> createState() => _CallOverlayHostState();
}

class _CallOverlayHostState extends ConsumerState<CallOverlayHost> {
  Timer? _ticker;
  int _secs = 0;
  String? _timedCall;

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  void _track(ActiveCall? call) {
    final key = call != null && call.phase == CallPhase.active
        ? call.callId
        : null;
    if (key == _timedCall) return;
    _ticker?.cancel();
    _timedCall = key;
    if (key == null) return;
    _secs = 0;
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() => _secs++);
    });
  }

  @override
  Widget build(BuildContext context) {
    final call = ref.watch(callStateProvider);
    final st = ref.read(callStateProvider.notifier);
    ref.listen<String?>(callNoticeProvider, (prev, next) {
      if (next != null && next.isNotEmpty) {
        Toast.show(context, next);
        ref.read(callNoticeProvider.notifier).clear();
      }
    });
    _track(call);
    if (call == null) return const SizedBox.shrink();
    if (call.minimized) {
      return MiniCallOverlay(call: call, secs: _secs);
    }
    return Stack(children: [
      // Slight dim while ringing only; active calls never block the chat.
      if (call.phase == CallPhase.ringing)
        const IgnorePointer(
          child: ModalBarrier(color: Colors.black38),
        ),
      Center(
        child: CallbackShortcuts(
          bindings: {
            // Esc minimizes, never hangs up (§48).
            const SingleActivator(LogicalKeyboardKey.escape): () =>
                st.setMinimized(true),
          },
          child: Focus(
            autofocus: true,
            child: CallWindow(call: call, secs: _secs),
          ),
        ),
      ),
    ]);
  }
}

String formatCallDuration(int s) {
  final h = s ~/ 3600;
  final m = (s % 3600) ~/ 60;
  final sec = s % 60;
  final mm = m.toString().padLeft(2, '0');
  final ss = sec.toString().padLeft(2, '0');
  return h > 0 ? '$h:$mm:$ss' : '$mm:$ss';
}

/// Centered, elevated, visually separate from the chat (§33–§34).
class CallWindow extends ConsumerWidget {
  const CallWindow({super.key, required this.call, required this.secs});

  final ActiveCall call;
  final int secs;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final st = ref.read(callStateProvider.notifier);
    final incoming =
        !call.outgoing && call.phase == CallPhase.ringing;
    final size = MediaQuery.sizeOf(context);
    final double width;
    final double? height;
    if (call.video && call.phase == CallPhase.active) {
      width = (size.width - 96).clamp(320.0, 880.0);
      height = (size.height - 96).clamp(320.0, 640.0);
    } else if (call.video || call.phase == CallPhase.active) {
      width = (size.width - 64).clamp(320.0, 480.0);
      height = null;
    } else {
      width = (size.width - 64).clamp(300.0, 440.0);
      height = null;
    }
    return Material(
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      borderRadius: BorderRadius.circular(18),
      elevation: 12,
      shadowColor: Colors.black.withValues(alpha: 0.5),
      child: Container(
        width: width,
        height: height,
        padding: const EdgeInsets.all(18),
        decoration: BoxDecoration(
          border: Border.all(
              color:
                  Theme.of(context).dividerColor.withValues(alpha: 0.5)),
          borderRadius: BorderRadius.circular(18),
        ),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          _header(context, st),
          const SizedBox(height: 10),
          if (call.video && call.phase == CallPhase.active)
            Expanded(child: _videoArea(context, st))
          else
            _identity(context),
          if (call.linkDown &&
              call.phase == CallPhase.active) ...[
            const SizedBox(height: 8),
            const Text('Восстанавливаем соединение…',
                style: TextStyle(fontSize: 12, color: Colors.orange)),
          ],
          const SizedBox(height: 14),
          _controls(context, st, incoming),
        ]),
      ),
    );
  }

  Widget _header(BuildContext context, CallState st) {
    return Row(children: [
      const Expanded(child: SizedBox.shrink()),
      IconButton(
          tooltip: 'Свернуть',
          icon: const Icon(Icons.remove, size: 20),
          onPressed: () => st.setMinimized(true)),
    ]);
  }

  Widget _identity(BuildContext context) {
    final incoming =
        !call.outgoing && call.phase == CallPhase.ringing;
    return Column(mainAxisSize: MainAxisSize.min, children: [
      Avatar(call.peerNick, radius: 34),
      const SizedBox(height: 10),
      Text(call.peerNick,
          style: const TextStyle(
              fontSize: 18, fontWeight: FontWeight.w700)),
      const SizedBox(height: 2),
      Text(
          incoming
              ? (call.video
                  ? 'Входящий видеозвонок'
                  : 'Входящий аудиозвонок')
              : call.phase == CallPhase.ringing
                  ? 'Вызов…'
                  : call.sharingScreen
                      ? 'Демонстрация экрана · ${formatCallDuration(secs)}'
                      : 'Подключено · ${formatCallDuration(secs)}',
          style: const TextStyle(fontSize: 13, color: Colors.grey)),
    ]);
  }

  /// Active video: remote is the hero (§39); avatar until the track
  /// arrives (§41); local self-view is a small corner PiP (§40).
  Widget _videoArea(BuildContext context, CallState st) {
    final remote = st.remoteRenderer;
    final local = st.localRenderer;
    final hasRemote = call.remoteVideo && remote != null;
    return Stack(children: [
      Container(
        decoration: BoxDecoration(
            color: Colors.black,
            borderRadius: BorderRadius.circular(12)),
        clipBehavior: Clip.antiAlias,
        child: hasRemote
            ? RTCVideoView(remote,
                objectFit: RTCVideoViewObjectFit
                    .RTCVideoViewObjectFitContain)
            : Center(
                child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Avatar(call.peerNick, radius: 30),
                      const SizedBox(height: 8),
                      const Text('Подключение видео…',
                          style: TextStyle(
                              fontSize: 12, color: Colors.grey)),
                    ]),
              ),
      ),
      if (call.video && local != null)
        Positioned(
          right: 10,
          bottom: 10,
          width: 144,
          height: 192,
          child: Container(
            decoration: BoxDecoration(
                color: Colors.black,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: Colors.grey.shade700)),
            clipBehavior: Clip.antiAlias,
            child: call.cameraOff
                ? const Center(
                    child: Icon(Icons.videocam_off,
                        color: Colors.grey))
                : RTCVideoView(local,
                    mirror: true,
                    objectFit: RTCVideoViewObjectFit
                        .RTCVideoViewObjectFitCover),
          ),
        ),
    ]);
  }

  Widget _controls(
      BuildContext context, CallState st, bool incoming) {
    if (incoming) {
      return Row(mainAxisAlignment: MainAxisAlignment.center, children: [
        _roundBtn(Colors.red, Icons.call_end, 'Отклонить',
            () => st.decline()),
        const SizedBox(width: 28),
        _roundBtn(Colors.green, Icons.call, 'Принять',
            () => st.acceptIncoming()),
      ]);
    }
    return Row(mainAxisAlignment: MainAxisAlignment.center, children: [
      _roundBtn(
          call.muted ? Colors.red : null,
          call.muted ? Icons.mic_off : Icons.mic,
          call.muted ? 'Включить микрофон' : 'Выключить микрофон',
          () => st.toggleMute()),
      const SizedBox(width: 12),
      if (call.video)
        _roundBtn(
            call.cameraOff ? Colors.red : null,
            call.cameraOff ? Icons.videocam_off : Icons.videocam,
            call.cameraOff ? 'Включить камеру' : 'Выключить камеру',
            () => st.toggleCamera()),
      if (call.video) const SizedBox(width: 12),
      if (call.video && call.phase == CallPhase.active)
        _roundBtn(
            call.sharingScreen ? Colors.blue : null,
            call.sharingScreen
                ? Icons.stop_screen_share
                : Icons.screen_share,
            'Демонстрация экрана',
            () => st.toggleScreenShare()),
      if (call.video && call.phase == CallPhase.active)
        const SizedBox(width: 12),
      _roundBtn(Colors.red, Icons.call_end, 'Завершить',
          () => st.hangup()),
    ]);
  }

  Widget _roundBtn(
      Color? bg, IconData icon, String tip, VoidCallback onTap) {
    return Tooltip(
      message: tip,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(27),
        child: Container(
          width: 54,
          height: 54,
          decoration: BoxDecoration(
              color: bg ?? Colors.grey.withValues(alpha: 0.25),
              shape: BoxShape.circle),
          child: Icon(icon, color: Colors.white),
        ),
      ),
    );
  }
}

/// Minimized call pill (§46): timer, mic, restore, hangup. Never hangs
/// up by itself; restore recreates nothing (§47).
class MiniCallOverlay extends ConsumerWidget {
  const MiniCallOverlay(
      {super.key, required this.call, required this.secs});

  final ActiveCall call;
  final int secs;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final st = ref.read(callStateProvider.notifier);
    return Positioned(
      right: 12,
      top: 12,
      child: Material(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(14),
        elevation: 8,
        child: Container(
          padding:
              const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            border: Border.all(
                color: Theme.of(context)
                    .dividerColor
                    .withValues(alpha: 0.5)),
            borderRadius: BorderRadius.circular(14),
          ),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Avatar(call.peerNick, radius: 14),
            const SizedBox(width: 8),
            Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(call.peerNick,
                      style: const TextStyle(
                          fontWeight: FontWeight.w700)),
                  Text(
                      call.phase == CallPhase.active
                          ? formatCallDuration(secs)
                          : 'Вызов…',
                      style: const TextStyle(
                          fontSize: 11, color: Colors.grey)),
                ]),
            const SizedBox(width: 8),
            IconButton(
                tooltip:
                    call.muted ? 'Включить микрофон' : 'Выключить',
                icon: Icon(
                    call.muted ? Icons.mic_off : Icons.mic,
                    size: 20),
                onPressed: () => st.toggleMute()),
            IconButton(
                tooltip: 'Вернуть звонок',
                icon: const Icon(Icons.open_in_full, size: 20),
                onPressed: () => st.setMinimized(false)),
            IconButton(
                tooltip: 'Завершить',
                icon: const Icon(Icons.call_end,
                    size: 20, color: Colors.red),
                onPressed: () => st.hangup()),
          ]),
        ),
      ),
    );
  }
}
