import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

import '../widgets/avatar.dart';
import '../widgets/toast.dart';
import 'call_session.dart';
import 'call_state.dart';

/// Global call surface: centered CallWindow + top-right mini pill.
/// Renders [UnifiedCall], whichever engine owns media (direct P2P today,
/// server voice; group migrates next). Media lifetime belongs to the engines:
/// minimizing/closing this UI never stops them — only leave actions do.
class CallOverlayHost extends ConsumerStatefulWidget {
  const CallOverlayHost({super.key});

  @override
  ConsumerState<CallOverlayHost> createState() => _CallOverlayHostState();
}

class _CallOverlayHostState extends ConsumerState<CallOverlayHost>
    with SingleTickerProviderStateMixin {
  Timer? _ticker;
  int _secs = 0;
  String? _timedCall;

  /// Minimize/expand morph: 0 = expanded window, 1 = mini pill.
  /// The engine flag flips instantly; this animates the surface behind it.
  late final AnimationController _morph = AnimationController(
      vsync: this, duration: const Duration(milliseconds: 280));

  /// Session the morph belongs to + last settled minimized value.
  /// A new session snaps instead of animating from a stale position.
  String? _morphCall;
  bool? _settled;

  @override
  void dispose() {
    _ticker?.cancel();
    _morph.dispose();
    super.dispose();
  }

  void _track(UnifiedCall? call) {
    final key = call != null && call.phase == CallPhase.active
        ? call.sessionId
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
    final call = ref.watch(unifiedCallProvider);
    ref.listen<String?>(callNoticeProvider, (prev, next) {
      if (next != null && next.isNotEmpty) {
        Toast.show(context, next);
        ref.read(callNoticeProvider.notifier).clear();
      }
    });
    ref.listen<CallRedial?>(callRedialProvider, (prev, next) {
      if (next == null) return;
      final redial = next;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(
            content: Text(redial.reason),
            action: SnackBarAction(
              label: 'Позвонить снова',
              onPressed: () async {
                ref.read(callRedialProvider.notifier).clear();
                try {
                  final st = ref.read(callStateProvider.notifier);
                  await st.startCall(
                      peerNick: redial.peerNick,
                      dmId: redial.dmId,
                      video: redial.video);
                } catch (e) {
                  if (context.mounted) {
                    Toast.show(context, friendlyCallError(e));
                  }
                }
              },
            ),
          ))
          .closed
          .then((_) {
        ref.read(callRedialProvider.notifier).clear();
      });
    });
    _track(call);
    if (call == null) {
      _morphCall = null;
      _settled = null;
      return const SizedBox.shrink();
    }
    // New session: snap the morph, never animate from a stale position.
    // Minimized flag flip: animate towards it (forward/reverse schedule
    // frames but never build synchronously, so build-driven is safe).
    // Direct value assignment notifies listeners, so on a live session swap
    // it must wait a frame; on the very first build there are no listeners
    // yet and the morph must start settled.
    //
    // An incoming call (accept/decline showing) demands attention: it stays
    // expanded even when minimized is set, for every engine. Otherwise the
    // pill would strand the call with no way to accept it.
    final mini = call.minimized && call.onAccept == null;
    if (_morphCall != call.sessionId) {
      final first = _morphCall == null && _settled == null;
      final target = mini ? 1.0 : 0.0;
      _morphCall = call.sessionId;
      _settled = mini;
      if (first) {
        _morph.value = target;
      } else if (_morph.value != target) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _morph.value = target;
        });
      }
    } else if (_settled != mini) {
      _settled = mini;
      if (mini) {
        _morph.forward();
      } else {
        _morph.reverse();
      }
    }
    final ringing = call.kind == CallKind.direct &&
        call.phase == CallPhase.ringing;
    return AnimatedBuilder(
      animation: _morph,
      builder: (ctx, _) {
        final t = _morph.value;
        // Settled states render the exact pre-morph structure (Center +
        // window, or the bare pill): zero pixel churn, goldens untouched.
        // Only mid-flight uses the morph wrappers.
        if (t >= 1.0) {
          return Stack(children: [
            MiniCallOverlay(call: call, secs: _secs),
          ]);
        }
        if (t <= 0.0) {
          return Stack(children: [
            // Slight dim while ringing only; active calls never block chat.
            if (ringing)
              const IgnorePointer(
                child: ModalBarrier(color: Colors.black38),
              ),
            Center(
              child: CallbackShortcuts(
                bindings: {
                  // Esc minimizes, never hangs up (§48).
                  const SingleActivator(LogicalKeyboardKey.escape):
                      () => call.onSetMinimized(true),
                },
                child: Focus(
                  autofocus: true,
                  child: CallWindow(
                      call: call,
                      secs: _secs,
                      media: _mediaFor(call)),
                ),
              ),
            ),
          ]);
        }
        // Mid-flight both surfaces exist: the window flies into the corner
        // while the pill fades in (and symmetrically back on expand).
        final showWindow = t < 1.0;
        final showPill = t > 0.0;
        // Flight path: center → top-right corner, shrinking; the last third
        // is mostly a crossfade so the handoff point never pops.
        final fly =
            Curves.easeInOutCubic.transform((t / 0.7).clamp(0.0, 1.0));
        final fade =
            Curves.easeOut.transform(((t - 0.55) / 0.45).clamp(0.0, 1.0));
        return Stack(children: [
          // Slight dim while ringing only; active calls never block chat.
          // Kept under the flying window until it mostly left.
          if (ringing && t < 0.5)
            const IgnorePointer(
              child: ModalBarrier(color: Colors.black38),
            ),
          if (showWindow)
            Positioned.fill(
              child: Align(
                alignment:
                    Alignment.lerp(Alignment.center, Alignment.topRight, fly)!,
                child: Opacity(
                  opacity: 1.0 - fade,
                  child: Transform.scale(
                    scale: 1.0 - 0.78 * fly,
                    child: CallbackShortcuts(
                      bindings: {
                        // Esc minimizes, never hangs up (§48).
                        const SingleActivator(LogicalKeyboardKey.escape):
                            () => call.onSetMinimized(true),
                      },
                      child: Focus(
                        autofocus: true,
                        child: CallWindow(
                            call: call,
                            secs: _secs,
                            media: _mediaFor(call)),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          if (showPill)
            Positioned(
              right: 12,
              top: 12,
              child: Opacity(
                opacity: fade,
                child: Transform.scale(
                  scale: 0.8 + 0.2 * fade,
                  alignment: Alignment.topRight,
                  child: MiniPillBody(call: call, secs: _secs),
                ),
              ),
            ),
        ]);
      },
    );
  }

  /// Central area: direct keeps its hero/PiP/identity layout verbatim (§29);
  /// server voice and group calls render the ParticipantGrid.
  Widget _mediaFor(UnifiedCall call) {
    if (call.kind == CallKind.serverVoice) {
      return ParticipantGrid(participants: call.participants);
    }
    if (call.kind == CallKind.group) {
      if (call.video && call.phase == CallPhase.active) {
        return ParticipantGrid(participants: call.participants);
      }
      return _identity(call);
    }
    final direct = ref.read(callStateProvider);
    final st = ref.read(callStateProvider.notifier);
    final remote = st.remoteRenderer;
    final local = st.localRenderer;
    final hasRemote =
        (direct?.remoteVideo ?? false) && remote != null;
    if (call.video && call.phase == CallPhase.active) {
      return _videoArea(context, call, remote, local, hasRemote);
    }
    return _identity(call);
  }

  /// Active video: remote is the hero (§39); avatar until the track
  /// arrives (§41); local self-view is a small corner PiP (§40).
  Widget _videoArea(BuildContext context, UnifiedCall call,
      RTCVideoRenderer? remote, RTCVideoRenderer? local, bool hasRemote) {
    return Stack(children: [
      Container(
        decoration: BoxDecoration(
            color: Colors.black,
            borderRadius: BorderRadius.circular(12)),
        clipBehavior: Clip.antiAlias,
        child: hasRemote
            ? RTCVideoView(remote!,
                objectFit: RTCVideoViewObjectFit
                    .RTCVideoViewObjectFitContain)
            : Center(
                child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Avatar(call.title, radius: 30),
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

  Widget _identity(UnifiedCall call) {
    final incoming = call.onAccept != null;
    // Room-based calls (voice/group) already carry the context line in the
    // window header: the identity shows avatar + name only, otherwise the
    // status text would appear twice. Direct keeps the full block since its
    // top bar is bare.
    final roomBased = call.kind != CallKind.direct;
    return Column(mainAxisSize: MainAxisSize.min, children: [
      Avatar(call.title, radius: 34),
      const SizedBox(height: 10),
      Text(call.title,
          style: const TextStyle(
              fontSize: 18, fontWeight: FontWeight.w700)),
      if (!roomBased) ...[
        const SizedBox(height: 2),
        Text(
            incoming
                ? call.subtitle
                : call.phase == CallPhase.ringing
                    ? 'Вызов…'
                    : 'Подключено · ${formatCallDuration(_secs)}',
            style:
                const TextStyle(fontSize: 13, color: Colors.grey)),
      ],
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
class CallWindow extends StatelessWidget {
  const CallWindow(
      {super.key,
      required this.call,
      required this.secs,
      required this.media});

  final UnifiedCall call;
  final int secs;
  final Widget media;

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    final wideVideo = call.video && call.phase == CallPhase.active;
    final double width;
    final double? height;
    if (wideVideo) {
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
          _header(context),
          const SizedBox(height: 10),
          if (wideVideo)
            Expanded(child: media)
          else
            media,
          if (call.linkDown &&
              call.phase == CallPhase.active) ...[
            const SizedBox(height: 8),
            const Text('Восстанавливаем соединение…',
                style: TextStyle(fontSize: 12, color: Colors.orange)),
          ],
          const SizedBox(height: 14),
          _controls(context),
        ]),
      ),
    );
  }

  Widget _header(BuildContext context) {
    // Direct keeps its old bare top bar; the context title (§27) is for
    // room-based calls (voice/group), where the peer-name identity below
    // does not exist.
    if (call.kind == CallKind.direct) {
      return Row(children: [
        const Expanded(child: SizedBox.shrink()),
        IconButton(
            tooltip: 'Свернуть',
            icon: const Icon(Icons.remove, size: 20),
            onPressed: () => call.onSetMinimized(true)),
      ]);
    }
    return Row(children: [
      Expanded(
        child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(call.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      fontSize: 16, fontWeight: FontWeight.w700)),
              Text(
                  call.phase == CallPhase.active
                      ? '${call.subtitle} · ${formatCallDuration(secs)}'
                      : call.subtitle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style:
                      const TextStyle(fontSize: 13, color: Colors.grey)),
            ]),
      ),
      IconButton(
          tooltip: 'Свернуть',
          icon: const Icon(Icons.remove, size: 20),
          onPressed: () => call.onSetMinimized(true)),
    ]);
  }

  Widget _controls(BuildContext context) {
    if (call.onAccept != null) {
      return Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          _roundBtn(Colors.red, Icons.call_end, 'Отклонить',
              () async {
            try {
              await call.onDecline!();
            } catch (e) {
              if (context.mounted) {
                Toast.show(context, call.friendlyError(e));
              }
            }
          }),
          const SizedBox(width: 28),
          _roundBtn(Colors.green, Icons.call, 'Принять', () async {
            try {
              await call.onAccept!();
            } catch (e) {
              if (context.mounted) {
                Toast.show(context, call.friendlyError(e));
              }
            }
          }),
        ],
      );
    }
    return Row(mainAxisAlignment: MainAxisAlignment.center, children: [
      _roundBtn(
          call.muted ? Colors.red : null,
          call.muted ? Icons.mic_off : Icons.mic,
          call.muted ? 'Включить микрофон' : 'Выключить микрофон',
          () => call.onToggleMute()),
      const SizedBox(width: 12),
      if (call.video)
        _roundBtn(
            call.cameraOff ? Colors.red : null,
            call.cameraOff ? Icons.videocam_off : Icons.videocam,
            call.cameraOff ? 'Включить камеру' : 'Выключить камеру',
            () => call.onToggleCamera()),
      if (call.video) const SizedBox(width: 12),
      if (call.kind == CallKind.direct &&
          call.video &&
          call.phase == CallPhase.active)
        _roundBtn(
            call.sharingScreen ? Colors.blue : null,
            call.sharingScreen
                ? Icons.stop_screen_share
                : Icons.screen_share,
            'Демонстрация экрана',
            () => call.onToggleShare()),
      if (call.kind == CallKind.direct &&
          call.video &&
          call.phase == CallPhase.active)
        const SizedBox(width: 12),
      _roundBtn(Colors.red, Icons.call_end, 'Завершить', () {
        call.onHangup();
      }),
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

/// Participant grid (§5): 1 centered, 2 side by side, 3–4 as 2×2,
/// 5+ responsive. Size never shifts on speaking (§10). Tiles always fit the
/// available area: the cell aspect is derived from the constraints so no row
/// is ever clipped by the control bar.
class ParticipantGrid extends StatelessWidget {
  const ParticipantGrid({super.key, required this.participants});

  final List<CallParticipant> participants;

  @override
  Widget build(BuildContext context) {
    if (participants.isEmpty) {
      return const Center(
          child: Text('Подключение…',
              style: TextStyle(fontSize: 12, color: Colors.grey)));
    }
    if (participants.length == 1) {
      return Center(
        child: ConstrainedBox(
          constraints:
              const BoxConstraints(maxWidth: 420, maxHeight: 320),
          child: AspectRatio(
              aspectRatio: 4 / 3,
              child: ParticipantTile(participant: participants.first)),
        ),
      );
    }
    final cols = participants.length <= 2
        ? participants.length
        : participants.length <= 4
            ? 2
            : 3;
    final rows =
        (participants.length + cols - 1) ~/ cols;
    return LayoutBuilder(builder: (ctx, cons) {
      var aspect = 4 / 3;
      if (cons.maxWidth.isFinite &&
          cons.maxHeight.isFinite &&
          cons.maxWidth > 0 &&
          cons.maxHeight > 0) {
        aspect = (cons.maxWidth * rows) / (cons.maxHeight * cols);
      }
      return GridView.count(
        crossAxisCount: cols,
        crossAxisSpacing: 8,
        mainAxisSpacing: 8,
        childAspectRatio: aspect,
        physics: const NeverScrollableScrollPhysics(),
        children: [
          for (final p in participants) ParticipantTile(participant: p),
        ],
      );
    });
  }
}

/// One participant tile (§6–§8): avatar mode or filling video,
/// name overlay always readable, accent ring while speaking (§10).
class ParticipantTile extends StatelessWidget {
  const ParticipantTile({super.key, required this.participant});

  final CallParticipant participant;

  @override
  Widget build(BuildContext context) {
    final p = participant;
    final video = p.video;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 200),
      decoration: BoxDecoration(
        color: Colors.black,
        borderRadius: BorderRadius.circular(12),
        border: p.speaking
            ? Border.all(
                color: Theme.of(context).colorScheme.primary, width: 2)
            : Border.all(color: Colors.transparent, width: 2),
      ),
      clipBehavior: Clip.antiAlias,
      child: Stack(children: [
        if (video != null)
          Positioned.fill(child: Builder(builder: video))
        else
          Center(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Avatar(p.nick, radius: 30),
              const SizedBox(height: 8),
              if (p.muted)
                const Icon(Icons.mic_off,
                    size: 14, color: Colors.grey),
            ]),
          ),
        Positioned(
          left: 8,
          right: 8,
          bottom: 6,
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Flexible(
              child: Container(
                padding: const EdgeInsets.symmetric(
                    horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.55),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text(p.nick,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        fontSize: 11, color: Colors.white)),
              ),
            ),
            if (p.muted) ...[
              const SizedBox(width: 4),
              Container(
                padding: const EdgeInsets.all(2),
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.55),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: const Icon(Icons.mic_off,
                    size: 11, color: Colors.white70),
              ),
            ],
          ]),
        ),
      ]),
    );
  }
}

/// Minimized call pill, top right (§13/§46): title, status, mic, expand,
/// leave. Never hangs up by itself.
class MiniCallOverlay extends StatelessWidget {
  const MiniCallOverlay(
      {super.key, required this.call, required this.secs});

  final UnifiedCall call;
  final int secs;

  @override
  Widget build(BuildContext context) {
    return Positioned(
      right: 12,
      top: 12,
      child: MiniPillBody(call: call, secs: secs),
    );
  }
}

/// The pill itself, position-free so the minimize morph can fade/scale it
/// inside its own Positioned. Same pixels as [MiniCallOverlay].
class MiniPillBody extends StatelessWidget {
  const MiniPillBody(
      {super.key, required this.call, required this.secs});

  final UnifiedCall call;
  final int secs;

  @override
  Widget build(BuildContext context) {
    final status = call.phase == CallPhase.active
        ? (call.kind == CallKind.direct
            ? formatCallDuration(secs)
            : '${call.subtitle} · ${formatCallDuration(secs)}')
        : (call.phase == CallPhase.ringing ? 'Вызов…' : call.subtitle);
    return Material(
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
            if (call.kind == CallKind.direct)
              Avatar(call.title, radius: 14)
            else
              const Icon(Icons.volume_up, size: 20),
            const SizedBox(width: 8),
            Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(call.title,
                      style: const TextStyle(
                          fontWeight: FontWeight.w700)),
                  Text(status,
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
                onPressed: () => call.onToggleMute()),
            IconButton(
                tooltip: 'Вернуть звонок',
                icon: const Icon(Icons.open_in_full, size: 20),
                onPressed: () => call.onSetMinimized(false)),
            IconButton(
                tooltip: 'Завершить',
                icon: const Icon(Icons.call_end,
                    size: 20, color: Colors.red),
                onPressed: () => call.onHangup()),
          ]),
        ),
    );
  }
}
