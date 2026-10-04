import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

import 'call_state.dart';

/// Floating call panel: incoming (accept/decline) + active (video, controls).
class CallOverlay extends ConsumerStatefulWidget {
  const CallOverlay({super.key});

  @override
  ConsumerState<CallOverlay> createState() => _CallOverlayState();
}

class _CallOverlayState extends ConsumerState<CallOverlay> {
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
    _track(call);
    if (call == null) return const SizedBox.shrink();
    final incoming =
        !call.outgoing && call.phase == CallPhase.ringing;
    return Positioned(
      right: 12,
      top: 12,
      bottom: 12,
      width: 330,
      child: Material(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(14),
        elevation: 8,
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(children: [
            Text(call.peerNick,
                style: const TextStyle(
                    fontSize: 17, fontWeight: FontWeight.w700)),
            const SizedBox(height: 2),
            Text(
                incoming
                    ? (call.video ? 'Входящий видеозвонок…' : 'Входящий звонок…')
                    : call.phase == CallPhase.ringing
                        ? 'Вызов…'
                        : _fmt(_secs),
                style:
                    const TextStyle(fontSize: 12, color: Colors.grey)),
            const SizedBox(height: 10),
            Expanded(child: _videos(context, st, call)),
            const SizedBox(height: 12),
            if (incoming)
              Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                _roundBtn(Colors.red, Icons.call_end, () => st.decline()),
                const SizedBox(width: 28),
                _roundBtn(Colors.green, Icons.call,
                    () => st.acceptIncoming()),
              ])
            else
              Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                _roundBtn(
                    call.muted ? Colors.red : null,
                    call.muted ? Icons.mic_off : Icons.mic,
                    () => st.toggleMute()),
                const SizedBox(width: 12),
                if (call.video)
                  _roundBtn(
                      call.cameraOff ? Colors.red : null,
                      call.cameraOff
                          ? Icons.videocam_off
                          : Icons.videocam,
                      () => st.toggleCamera()),
                if (call.video) const SizedBox(width: 12),
                _roundBtn(Colors.red, Icons.call_end, () => st.hangup()),
              ]),
          ]),
        ),
      ),
    );
  }

  Widget _roundBtn(Color? bg, IconData icon, VoidCallback onTap) {
    return InkWell(
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
    );
  }

  Widget _videos(
      BuildContext context, CallState st, ActiveCall call) {
    final remote = st.remoteRenderer;
    final local = st.localRenderer;
    return Stack(children: [
      Container(
        decoration: BoxDecoration(
            color: Colors.black,
            borderRadius: BorderRadius.circular(10)),
        clipBehavior: Clip.antiAlias,
        child: remote != null
            ? RTCVideoView(remote, objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover)
            : const Center(
                child: Icon(Icons.person,
                    size: 56, color: Colors.grey)),
      ),
      if (call.video && local != null)
        Positioned(
          right: 8,
          bottom: 8,
          width: 84,
          height: 112,
          child: Container(
            decoration: BoxDecoration(
                color: Colors.black,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: Colors.grey.shade700)),
            clipBehavior: Clip.antiAlias,
            child: RTCVideoView(local,
                mirror: true,
                objectFit:
                    RTCVideoViewObjectFit.RTCVideoViewObjectFitCover),
          ),
        ),
    ]);
  }

  String _fmt(int s) =>
      '${(s ~/ 60).toString().padLeft(2, '0')}:${(s % 60).toString().padLeft(2, '0')}';
}
