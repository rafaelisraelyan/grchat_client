import 'dart:async';
import 'dart:ui' show lerpDouble;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

import '../widgets/avatar.dart';
import '../widgets/toast.dart';
import 'call_session.dart';
import 'call_state.dart';
import 'dock_state.dart';
import 'media_session.dart';

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
    with TickerProviderStateMixin {
  Timer? _ticker;
  int _secs = 0;
  String? _timedCall;

  /// Minimize/expand morph: 0 = expanded window, 1 = mini pill.
  /// The engine flag flips instantly; this animates the surface behind it.
  /// One normalized progress drives everything (§28): rect, radius,
  /// elevation and content staging. 380ms, emphasized but snappy (§26).
  late final AnimationController _morph = AnimationController(
      vsync: this, duration: const Duration(milliseconds: 380));

  /// Session the morph belongs to + last settled minimized value.
  /// A new session snaps instead of animating from a stale position.
  String? _morphCall;
  bool? _settled;

  /// Frozen pill-preview participant for the flight (§60): the surface
  /// shrinks AS one object, so the rider is snapshotted at takeoff.
  /// Settled states always use the live spotlight instead.
  CallParticipant? _rider;

  /// Last settled window size, reported post-layout (§33-safe: never read
  /// during build). The flight takes off pixel-exact from it, even for
  /// intrinsic-height windows.
  Size? _fromSize;
  final GlobalKey _measureKey = GlobalKey();

  /// Mini-card dock, per session (§39–§40, §44): edge + offset, never bare
  /// x/y, so resizes adapt (§42–§43). Survives minimize/restore cycles and
  /// navigation; a new session starts top-right again.
  DockSpot _dock = DockSpot.initial;

  /// Live drag position (card top-left), null when docked (§29–§32).
  Offset? _dragPos;

  /// Snap flight after release: rect interpolation + its own clock (§37).
  Rect? _snapFrom;
  Rect? _snapTo;
  late final AnimationController _snap = AnimationController(
      vsync: this, duration: const Duration(milliseconds: 220));

  /// Preview collapse clock (§23–§24, 220ms). The curved view drives the
  /// card height, the SizeTransition and the fade together.
  late final AnimationController _previewT = AnimationController(
      vsync: this, duration: const Duration(milliseconds: 220));
  late final Animation<double> _previewEase = CurvedAnimation(
      parent: _previewT, curve: Curves.easeInOutCubic);

  /// Last seen app size for gesture handlers (no context there).
  Size _lastScreen = Size.zero;

  @override
  void dispose() {
    _ticker?.cancel();
    _morph.dispose();
    _snap.dispose();
    _previewT.dispose();
    super.dispose();
  }

  /// Preview show/hide from the bar button (§6): presentation only, media
  /// untouched (§28). Event context: provider writes are safe here.
  void _onTogglePreview() {
    final next = !ref.read(miniPreviewVisibleProvider);
    ref.read(miniPreviewVisibleProvider.notifier).set(next);
    ref.read(lastMiniPreviewProvider.notifier).set(next);
  }

  /// Card rect right now: dragging follows the cursor 1:1 (§30), a
  /// finished snap interpolates to the dock, otherwise the dock rules.
  /// Height follows the collapse progress; dockRect anchors it per edge
  /// (§35): top stays for top/left/right docks, bottom-anchored docks
  /// fold upward so controls never jump.
  /// Card outer height right now: bar + ring + visible preview slice.
  double _cardHeight() =>
      kBarHeight + 2 * kCardBorder + kPreviewHeight * _previewEase.value;

  Rect _cardRect(Size screen) {
    final card = Size(kCardWidth, _cardHeight());
    if (_dragPos != null) {
      return Rect.fromLTWH(
          _dragPos!.dx, _dragPos!.dy, card.width, card.height);
    }
    if (_snapFrom != null && _snapTo != null && _snap.isAnimating) {
      return Rect.lerp(_snapFrom!, _snapTo!,
          Curves.easeOutCubic.transform(_snap.value))!;
    }
    return dockRect(_dock, screen, card);
  }

  void _onDragStart(DragStartDetails _) {
    // Only the settled card drags: mid-morph the surface owns the pointer.
    if (_morph.value != 1.0) return;
    _snap.stop();
    _snapFrom = null;
    _snapTo = null;
    _dragPos = _cardRect(_lastScreen).topLeft;
    setState(() {});
  }

  void _onDragUpdate(DragUpdateDetails d) {
    if (_dragPos == null) return;
    final card = Size(kCardWidth, _cardHeight());
    setState(() {
      _dragPos =
          clampCardPos(_dragPos! + d.delta, _lastScreen, card);
    });
  }

  void _onDragEnd(DragEndDetails _) {
    if (_dragPos == null) return;
    final card = Size(kCardWidth, _cardHeight());
    final rect = Rect.fromLTWH(
        _dragPos!.dx, _dragPos!.dy, card.width, card.height);
    _dock = snapDock(rect, _lastScreen, card);
    _snapFrom = rect;
    _snapTo = dockRect(_dock, _lastScreen, card);
    _dragPos = null;
    _snap.forward(from: 0);
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
                // A redial never kills a live session silently: free starts,
                // anything else gets a toast, never a confirm dialog from
                // a snackbar action.
                final coord =
                    ref.read(mediaCoordinatorProvider.notifier);
                switch (coord.requestSlot('redial')) {
                  case SessionRequest.free:
                    try {
                      final st =
                          ref.read(callStateProvider.notifier);
                      await st.startCall(
                          peerNick: redial.peerNick,
                          dmId: redial.dmId,
                          video: redial.video);
                    } catch (e) {
                      if (context.mounted) {
                        Toast.show(context, friendlyCallError(e));
                      }
                    }
                  case SessionRequest.confirm:
                    if (context.mounted) {
                      Toast.show(
                          context, 'Завершите текущий звонок');
                    }
                  case SessionRequest.busy:
                    if (context.mounted) {
                      Toast.show(
                          context, 'Дождитесь переключения звонка');
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
    _lastScreen = MediaQuery.sizeOf(context);
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
    final previewNow = ref.watch(miniPreviewVisibleProvider);
    if (_morphCall != call.sessionId) {
      final first = _morphCall == null && _settled == null;
      final target = mini ? 1.0 : 0.0;
      _morphCall = call.sessionId;
      _settled = mini;
      // A new session invalidates any stored takeoff size, drag, snap and
      // dock: it starts top-right again (§39). Preview starts shown (§54).
      _fromSize = null;
      _dock = DockSpot.initial;
      _dragPos = null;
      _snapFrom = null;
      _snapTo = null;
      if (first) {
        // No listeners yet: snap synchronously.
        _morph.value = target;
        _previewT.value = mini ? 1.0 : 0.0;
      } else {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          ref.read(miniPreviewVisibleProvider.notifier).set(true);
          ref.read(lastMiniPreviewProvider.notifier).set(true);
          _previewT.value = mini ? 1.0 : 0.0;
          if (_morph.value != target) _morph.value = target;
        });
      }
    } else if (_settled != mini) {
      _settled = mini;
      // Freeze the rider at takeoff: the flight carries one participant.
      _rider = call.spotlight;
      if (mini) {
        _morph.forward();
      } else {
        _morph.reverse();
      }
      // Provider writes wait a frame (listeners are attached); the morph
      // itself is already flying. Minimize restores the remembered mode
      // (§31–§32), expand records it.
      final savePreview = previewNow;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        if (mini) {
          ref.read(miniPreviewVisibleProvider.notifier).set(
              ref.read(lastMiniPreviewProvider));
          _previewT.value =
              ref.read(lastMiniPreviewProvider) ? 1.0 : 0.0;
        } else {
          ref.read(lastMiniPreviewProvider.notifier).set(savePreview);
        }
      });
    }
    // Collapse progress follows the mode (§23–§24): toggles animate it,
    // flights leave it frozen. forward()/reverse() only schedule frames,
    // so build-driven is safe (same pattern as the morph itself).
    final wantPreview =
        call.presentation == CallPresentationMode.miniWithPreview
            ? 1.0
            : 0.0;
    if (!_previewT.isAnimating && _previewT.value != wantPreview) {
      if (wantPreview > 0) {
        _previewT.forward();
      } else {
        _previewT.reverse();
      }
    }
    final ringing = call.kind == CallKind.direct &&
        call.phase == CallPhase.ringing;
    final body = AnimatedBuilder(
      animation: Listenable.merge([_morph, _snap, _previewT]),
      builder: (ctx, _) {
        final t = _morph.value;
        // Settled states render exact structures (Center + window, or the
        // docked card): zero pixel churn, goldens untouched. Only
        // mid-flight uses the morph wrappers.
        if (t >= 1.0) {
          return Stack(children: [
            Positioned.fromRect(
              rect: _cardRect(MediaQuery.sizeOf(ctx)),
              child: MiniCallOverlay(
                  call: call,
                  secs: _secs,
                  preview: _previewEase,
                  onTogglePreview: _onTogglePreview,
                  onDragStart: _onDragStart,
                  onDragUpdate: _onDragUpdate,
                  onDragEnd: _onDragEnd),
            ),
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
                  child: NotificationListener<SizeChangedLayoutNotification>(
                    onNotification: (_) {
                      // Post-layout report (never build): the next flight
                      // takes off from exactly this box.
                      _fromSize = _measureKey.currentContext?.size;
                      return true;
                    },
                    child: SizeChangedLayoutNotifier(
                      child: CallWindow(
                          key: _measureKey,
                          call: call,
                          secs: _secs,
                          media: _mediaFor(call)),
                    ),
                  ),
                ),
              ),
            ),
          ]);
        }
        // Single-object morph (§17–§18, §64): one container flies
        // expanded-center → current dock while its box, radius and
        // elevation interpolate. The rider video (same keyed element as
        // the grid and the card) rides full-bleed; only chrome crossfades
        // in stages (§28): title out early, card bar in late. Symmetric
        // on reverse, starting exactly from the dock (§41).
        final screen = MediaQuery.sizeOf(ctx);
        final box = callWindowSize(call, screen);
        // Prefer the measured settled box (exact, resize-live); computed
        // width with a fallback height otherwise.
        final fromSize =
            _fromSize ?? Size(box.width, box.height ?? 360.0);
        final fromRect = Rect.fromCenter(
            center: screen.center(Offset.zero),
            width: fromSize.width,
            height: fromSize.height);
        final dockRectNow = _cardRect(screen);
        final e = Curves.easeInOutCubic.transform(t); // §27
        final rect = Rect.lerp(fromRect, dockRectNow, e)!;
        final radius = lerpDouble(18, kCardRadius, e)!;
        final elev = lerpDouble(12, 8, e)!;
        // Staging: title fades 0–0.3, pill bar fades in 0.55–1.
        final titleOut = (1.0 - t / 0.3).clamp(0.0, 1.0);
        final barIn = ((t - 0.55) / 0.45).clamp(0.0, 1.0);
        final rider = _rider;
        return Stack(key: const ValueKey('morph-surface'), children: [
          // Slight dim while ringing only; active calls never block chat.
          // Kept under the flying surface until it mostly left.
          if (ringing && t < 0.5)
            const IgnorePointer(
              child: ModalBarrier(color: Colors.black38),
            ),
          Positioned.fromRect(
            rect: rect,
            child: Material(
              color:
                  Theme.of(ctx).colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(radius),
              elevation: elev,
              shadowColor: Colors.black.withValues(alpha: 0.5),
              child: Container(
                decoration: BoxDecoration(
                  border: Border.all(
                      color: Theme.of(ctx)
                          .dividerColor
                          .withValues(alpha: 0.5)),
                  borderRadius: BorderRadius.circular(radius),
                ),
                clipBehavior: Clip.antiAlias,
                child: Stack(children: [
                  // Rider fades with the collapse progress: minimizing
                  // into a collapsed card flies the bar, not the video.
                  Positioned.fill(
                    child: Opacity(
                      opacity: _previewEase.value,
                      child: _riderFace(rider, call.title,
                          _isWaiting(call) && rider == null),
                    ),
                  ),
                  if (titleOut > 0)
                    Positioned(
                      top: 14,
                      left: 18,
                      right: 18,
                      child: Opacity(
                        opacity: titleOut,
                        child: Text(call.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.w700)),
                      ),
                    ),
                  if (barIn > 0)
                    Positioned(
                      left: 0,
                      right: 0,
                      bottom: 0,
                      child: Opacity(
                        opacity: barIn,
                        child: Container(
                          padding: const EdgeInsets.fromLTRB(
                              12, 16, 12, 8),
                          decoration: const BoxDecoration(
                            gradient: LinearGradient(
                              begin: Alignment.topCenter,
                              end: Alignment.bottomCenter,
                              colors: [
                                Colors.transparent,
                                Colors.black87,
                              ],
                            ),
                          ),
                          child: _pillMeta(
                              name: rider?.nick ?? call.title,
                              muted: rider?.muted ?? false,
                              status: _pillStatus(call, _secs)),
                        ),
                      ),
                    ),
                ]),
              ),
            ),
          ),
        ]);
      },
    );
    // Session switch in progress (§57): veil with a spinner, no fake
    // "connected" state, media buttons untouchable until the new session
    // is live. Also serializes double-Accept: the buttons sit under this.
    if (!ref.watch(mediaCoordinatorProvider)) return body;
    return Stack(children: [
      body,
      const ModalBarrier(color: Colors.black54),
      Center(
        child: Card(
          child: Padding(
            padding:
                EdgeInsets.symmetric(horizontal: 20, vertical: 16),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2)),
              SizedBox(width: 12),
              Text('Переключаем звонок…'),
            ]),
          ),
        ),
      ),
    ]);
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
            // Same GlobalObjectKey as the pill/morph rider builder (§4):
            // minimizing re-homes this element instead of rebinding the
            // texture, so the frame never drops to black mid-flight.
            ? KeyedSubtree(
                key: GlobalObjectKey(remote!),
                child: RTCVideoView(remote,
                    objectFit: RTCVideoViewObjectFit
                        .RTCVideoViewObjectFitContain))
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

/// Compact card geometry (§4, §42): fixed 300px width in both mini
/// modes (no horizontal jump, §14), bar 52, preview 172 when shown.
/// Outer heights include the 1.5px speaking ring on both sides.
const double kCardWidth = 300;
const double kBarHeight = 52;
const double kPreviewHeight = 172;
const double kCardBorder = 1.5;
const double kCardCollapsedHeight = kBarHeight + 2 * kCardBorder;
const double kCardFullHeight = kBarHeight + kPreviewHeight + 2 * kCardBorder;
const double kCardRadius = 16;

/// Expanded window box for a call on [screen]. Shared by [CallWindow] and
/// the morph start rect so the flight takes off pixel-exact. Height stays
/// null for intrinsic (audio/identity) windows — the morph measures those
/// from the live window at takeoff instead.
({double width, double? height}) callWindowSize(
    UnifiedCall call, Size screen) {
  final wideVideo = call.video && call.phase == CallPhase.active;
  if (wideVideo) {
    return (
      width: (screen.width - 96).clamp(320.0, 880.0),
      height: (screen.height - 96).clamp(320.0, 640.0),
    );
  } else if (call.video || call.phase == CallPhase.active) {
    return (width: (screen.width - 64).clamp(320.0, 480.0), height: null);
  } else {
    return (width: (screen.width - 64).clamp(300.0, 440.0), height: null);
  }
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
    final box = callWindowSize(call, size);
    final width = box.width;
    final height = box.height;
    final wideVideo = height != null;
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
      Future<void> accept() async {
        try {
          await call.onAccept!();
        } catch (e) {
          if (context.mounted) {
            Toast.show(context, call.friendlyError(e));
          }
        }
      }

      Future<void> decline() async {
        try {
          await call.onDecline!();
        } catch (e) {
          if (context.mounted) {
            Toast.show(context, call.friendlyError(e));
          }
        }
      }

      // Call waiting (§30): the warning names the live session, and accept
      // says what it does — ends it — instead of silently tearing down.
      final detail = call.switchDetail;
      if (detail != null) {
        return Column(mainAxisSize: MainAxisSize.min, children: [
          const Text('Вы уже участвуете в другом разговоре.',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 12, color: Colors.grey)),
          Text(detail,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 12, color: Colors.grey)),
          const SizedBox(height: 10),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              _roundBtn(
                  Colors.red, Icons.call_end, 'Отклонить', decline),
              const SizedBox(width: 12),
              Tooltip(
                message: 'Завершить текущий и принять',
                child: FilledButton.tonalIcon(
                  onPressed: accept,
                  icon: const Icon(Icons.call, size: 18),
                  label: const Text('Завершить и принять'),
                ),
              ),
            ],
          ),
        ]);
      }
      return Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          _roundBtn(
              Colors.red, Icons.call_end, 'Отклонить', decline),
          const SizedBox(width: 28),
          _roundBtn(Colors.green, Icons.call, 'Принять', accept),
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

/// Minimized live card, docked in the app area (§1–§2): one floating
/// surface = top control bar (§3) + live remote preview. Positioning is
/// owned by the host (dock model); this widget is pure content.
/// P2P always shows the remote peer (§7–§8); group/voice show the
/// stabilized active remote speaker (§9). Never hangs up by itself;
/// hangup ends the session for real.
class MiniCallOverlay extends StatelessWidget {
  const MiniCallOverlay(
      {super.key,
      required this.call,
      required this.secs,
      required this.preview,
      required this.onTogglePreview,
      required this.onDragStart,
      required this.onDragUpdate,
      required this.onDragEnd});

  final UnifiedCall call;
  final int secs;

  /// Collapse progress from the host (§23–§24).
  final Animation<double> preview;
  final VoidCallback onTogglePreview;
  final GestureDragStartCallback onDragStart;
  final GestureDragUpdateCallback onDragUpdate;
  final GestureDragEndCallback onDragEnd;

  @override
  Widget build(BuildContext context) {
    return MiniCallCard(
        call: call,
        secs: secs,
        preview: preview,
        onTogglePreview: onTogglePreview,
        onDragStart: onDragStart,
        onDragUpdate: onDragUpdate,
        onDragEnd: onDragEnd);
  }
}

/// Speaking green, shared with the sidebar roster ring language.
const _pillSpeakGreen = Color(0xFF57F287);

/// Avatar face for camera-off preview (pill, morph, audio-only, §23/§47).
Widget _avatarFace(String nick, {double radius = 26}) => Container(
      color: Colors.black,
      child: Center(child: Avatar(nick, radius: radius)),
    );

/// Waiting state (§26): successfully inside a Server Voice Channel (or an
/// alone-able group LiveKit room) with zero remote peers. Exactly one
/// meaning — never error, silence, or reconnecting. P2P never qualifies:
/// its spotlight is always the remote peer.
bool _isWaiting(UnifiedCall call) =>
    call.phase == CallPhase.active &&
    (call.kind == CallKind.serverVoice || call.kind == CallKind.group) &&
    call.spotlight == null;

/// Rider face for the morph flight: waiting GIF when alone, live video
/// when the frozen rider has it, avatar otherwise. The video/GIF is the
/// same keyed element as the grid and the card (§4): nothing re-binds
/// mid-flight. The asset GIF is image-cache backed, so drag keeps it
/// playing with no re-decode (§20–§21).
Widget _riderFace(
    CallParticipant? rider, String fallbackNick, bool waiting) {
  if (waiting) return _waitingFace();
  final v = rider?.video;
  if (v != null) {
    return Container(color: Colors.black, child: Builder(builder: v));
  }
  return _avatarFace(rider?.nick ?? fallbackNick);
}

/// The waiting visual itself: a finished design, shown as-is with no
/// extra text on top (§8), cover-cropped without deforming (§6), clipped
/// by whatever rounded parent hosts it (§7).
Widget _waitingFace() => Container(
      color: Colors.black,
      child: Image.asset(
        'assets/grchat_waiting_from_reference_photo.gif',
        fit: BoxFit.cover,
      ),
    );

/// Bottom meta line shared by the morph flight and the settled pill:
/// name, mute state, duration. Never interactive itself.
Widget _pillMeta(
    {required String name, required bool muted, required String status}) {
  return Row(mainAxisSize: MainAxisSize.min, children: [
    Flexible(
      child: Text(name,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w700,
              color: Colors.white)),
    ),
    if (muted) ...[
      const SizedBox(width: 4),
      const Icon(Icons.mic_off, size: 11, color: Colors.white70),
    ],
    const SizedBox(width: 6),
    Text(status,
        style: const TextStyle(fontSize: 11, color: Colors.white70)),
  ]);
}

String _pillStatus(UnifiedCall call, int secs) =>
    call.phase == CallPhase.active
        ? formatCallDuration(secs)
        : 'Вызов…';

/// Settled card content: waiting GIF when alone, otherwise the live
/// spotlight with a short crossfade on speaker change (§9, §15). The card
/// box never moves or resizes; only this content fades, ~180ms.
Widget _pillPreview(UnifiedCall call) {
  final waiting = _isWaiting(call);
  final sp = waiting ? null : call.spotlight;
  final hasVideo = sp?.video != null;
  return AnimatedSwitcher(
    duration: const Duration(milliseconds: 180),
    transitionBuilder: (child, animation) =>
        FadeTransition(opacity: animation, child: child),
    layoutBuilder: (current, previous) => Stack(children: [
      if (current != null) Positioned.fill(child: current),
      for (final p in previous) Positioned.fill(child: p),
    ]),
    // Identity follows content: waiting is its own state; a camera toggle
    // on the same speaker swaps avatar ↔ video without changing who.
    // The speaker name rides along as a small chip (the bar carries the
    // call identity instead).
    child: KeyedSubtree(
      key: ValueKey(waiting
          ? 'spot-waiting'
          : 'spot-${sp?.id ?? 'none'}-${hasVideo ? 'v' : 'a'}'),
      child: waiting
          ? _waitingFace()
          : Stack(children: [
              Positioned.fill(
                child: hasVideo
                    ? Container(
                        color: Colors.black,
                        child: Builder(builder: sp!.video!))
                    : _avatarFace(sp?.nick ?? call.title),
              ),
              Positioned(
                left: 8,
                bottom: 6,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.55),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text(sp?.nick ?? call.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          fontSize: 11, color: Colors.white)),
                ),
              ),
            ]),
    ),
  );
}

/// The compact call window: control bar + preview, one clipped surface.
/// The free bar area is the drag handle (§30); the mic/expand/hangup
/// buttons live outside it, so a tap never starts a drag (§31).
/// Preview tap expands (§53); the tap slop tells click from drag apart.
class MiniCallCard extends StatelessWidget {
  const MiniCallCard(
      {super.key,
      required this.call,
      required this.secs,
      required this.preview,
      required this.onTogglePreview,
      required this.onDragStart,
      required this.onDragUpdate,
      required this.onDragEnd});

  final UnifiedCall call;
  final int secs;

  /// Collapse progress (§23–§24): 1 = preview fully shown, 0 = bar only.
  /// Owned by the host; the card only renders it.
  final Animation<double> preview;
  final VoidCallback onTogglePreview;
  final GestureDragStartCallback onDragStart;
  final GestureDragUpdateCallback onDragUpdate;
  final GestureDragEndCallback onDragEnd;

  @override
  Widget build(BuildContext context) {
    final sp = call.spotlight;
    final speaking = sp?.speaking ?? false;
    return SizedBox(
      width: kCardWidth,
      child: Container(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(kCardRadius),
          border: Border.all(
              color: speaking ? _pillSpeakGreen : Colors.transparent,
              width: 1.5),
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(kCardRadius - 1.5),
          child: Material(
            color:
                Theme.of(context).colorScheme.surfaceContainerHighest,
            elevation: 8,
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              MiniCallControlBar(
                  call: call,
                  secs: secs,
                  previewVisible: preview.value > 0.5,
                  onTogglePreview: onTogglePreview,
                  onDragStart: onDragStart,
                  onDragUpdate: onDragUpdate,
                  onDragEnd: onDragEnd),
              // Collapsible preview (§23): height + opacity ride the same
              // progress; the box never resizes for anything else.
              // The element stays mounted throughout (§29): no rebind,
              // no black flash on show.
              SizeTransition(
                sizeFactor: preview,
                axis: Axis.vertical,
                alignment: Alignment.topCenter,
                child: FadeTransition(
                  opacity: preview,
                  child: SizedBox(
                    width: kCardWidth,
                    height: kPreviewHeight,
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: () => call.onSetMinimized(false),
                      child: _pillPreview(call),
                    ),
                  ),
                ),
              ),
            ]),
          ),
        ),
      ),
    );
  }
}

/// One reusable control bar for every transport (§39): leading icon +
/// name/status, then Preview → Mic → Camera → End → Full, always (§5).
/// Layout never shifts: unavailable actions disable in place (§9, §13).
class MiniCallControlBar extends StatelessWidget {
  const MiniCallControlBar(
      {super.key,
      required this.call,
      required this.secs,
      required this.previewVisible,
      required this.onTogglePreview,
      required this.onDragStart,
      required this.onDragUpdate,
      required this.onDragEnd});

  final UnifiedCall call;
  final int secs;
  final bool previewVisible;
  final VoidCallback onTogglePreview;
  final GestureDragStartCallback onDragStart;
  final GestureDragUpdateCallback onDragUpdate;
  final GestureDragEndCallback onDragEnd;

  /// Camera is a real toggle where the engine supports it; where the call
  /// is audio-only the slot stays put, disabled (§9).
  bool get _cameraAvailable =>
      call.kind == CallKind.serverVoice || call.video;

  String get _endTooltip => switch (call.kind) {
        CallKind.direct => 'Завершить звонок',
        CallKind.group => 'Покинуть звонок',
        CallKind.serverVoice => 'Выйти из голосового канала',
      };

  Widget _btn(
      {required String tooltip,
      required IconData icon,
      required VoidCallback? onPressed,
      Color? color}) {
    return Tooltip(
      message: tooltip,
      child: InkWell(
        onTap: onPressed,
        borderRadius: BorderRadius.circular(8),
        child: Container(
          width: 36,
          height: 36,
          alignment: Alignment.center,
          child: Icon(icon,
              size: 20, color: color ?? Colors.white),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: kBarHeight,
      child: Row(children: [
        if (call.kind == CallKind.direct)
          Padding(
            padding: const EdgeInsets.only(left: 10),
            child: Avatar(call.title, radius: 12),
          )
        else
          const Padding(
            padding: EdgeInsets.only(left: 12),
            child: Icon(Icons.volume_up, size: 20),
          ),
        Expanded(
          child: GestureDetector(
            key: const ValueKey('mini-drag-handle'),
            behavior: HitTestBehavior.opaque,
            onPanStart: onDragStart,
            onPanUpdate: onDragUpdate,
            onPanEnd: onDragEnd,
            child: Padding(
              padding:
                  const EdgeInsets.symmetric(horizontal: 8),
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(call.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            fontWeight: FontWeight.w700)),
                    Text(_pillStatus(call, secs),
                        style: const TextStyle(
                            fontSize: 11, color: Colors.grey)),
                  ]),
            ),
          ),
        ),
        // 1. Preview show/hide: presentation only, never media (§6).
        _btn(
            tooltip: previewVisible
                ? 'Скрыть предпросмотр'
                : 'Показать предпросмотр',
            icon: previewVisible
                ? Icons.unfold_less
                : Icons.unfold_more,
            onPressed: onTogglePreview),
        // 2. Local microphone only (§7).
        _btn(
            tooltip: call.muted
                ? 'Включить микрофон'
                : 'Выключить микрофон',
            icon: call.muted ? Icons.mic_off : Icons.mic,
            onPressed: () => call.onToggleMute()),
        // 3. Local camera only (§8); hide-preview and camera-off are
        // different actions and stay different buttons.
        _btn(
            tooltip: !_cameraAvailable
                ? 'Камера недоступна'
                : (call.cameraOff
                    ? 'Включить камеру'
                    : 'Выключить камеру'),
            icon: call.cameraOff
                ? Icons.videocam_off
                : Icons.videocam,
            onPressed: _cameraAvailable
                ? () => call.onToggleCamera()
                : null),
        // 4. Destructive leave, always the same slot (§10, §44).
        _btn(
            tooltip: _endTooltip,
            icon: Icons.call_end,
            color: Colors.red,
            onPressed: () => call.onHangup()),
        // 5. Full expand, always last (§11).
        _btn(
            tooltip: 'Развернуть звонок',
            icon: Icons.open_in_full,
            onPressed: () => call.onSetMinimized(false)),
        const SizedBox(width: 4),
      ]),
    );
  }
}
