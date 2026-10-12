import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' show lerpDouble;

import 'package:flutter/gestures.dart' show kPrimaryMouseButton;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'call_diagnostics.dart' show dlog;

import 'package:flutter_webrtc/flutter_webrtc.dart';

import '../widgets/avatar.dart';
import '../widgets/toast.dart';
import 'call_session.dart';
import 'call_state.dart';
import 'dock_state.dart';
import 'group_call.dart' show friendlyGroupError;
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
    vsync: this,
    duration: const Duration(milliseconds: 380),
  );

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

  /// Self-preview interaction (final architecture): the media viewport
  /// carries ONE Listener whose localPosition IS the media coordinate —
  /// stable parent space, no moving-child feedback, no global/local
  /// conversions. During a gesture the single source of truth is the
  /// LIVE rect (media-local); dock state is touched only at pointer-up
  /// (§11–§12 of the positioning spec, §23).
  Rect? _pipLiveRect;
  bool _pipGestureIsResize = false;
  SelfPipZone _pipGestureZone = SelfPipZone.center;
  Rect _pipGestureStart = Rect.zero;
  Offset _pipGesturePointer0 = Offset.zero;

  /// Hover zone for the cursor feedback (§20): null = pointer outside
  /// the preview (plain cursor over the remote video).
  SelfPipZone? _pipHoverZone;

  /// Interaction mode (§22): one enum, never a bool soup.
  _PipMode get _pipMode {
    if (_pipLiveRect != null) {
      if (!_pipGestureIsResize) return _PipMode.dragging;
      return switch (_pipGestureZone) {
        SelfPipZone.topLeft => _PipMode.resizingTopLeft,
        SelfPipZone.topRight => _PipMode.resizingTopRight,
        SelfPipZone.bottomLeft => _PipMode.resizingBottomLeft,
        SelfPipZone.bottomRight => _PipMode.resizingBottomRight,
        SelfPipZone.center => _PipMode.idle,
      };
    }
    return _PipMode.idle;
  }

  /// Geometry of the self-preview: the LIVE rect during a gesture (§15:
  /// layout never re-derives it from dock mid-gesture), the snap flight
  /// after release, otherwise the docked spot from fresh constraints.
  Rect _pipRect(Size mediaArea, Size pipSize) {
    if (_pipLiveRect != null) return _pipLiveRect!;
    if (_pipSnapFrom != null && _pipSnapTo != null && !_pipSnap.isCompleted) {
      return Rect.lerp(_pipSnapFrom!, _pipSnapTo!, _pipEase.value)!;
    }
    return dockRect(_pipDock, mediaArea, pipSize);
  }

  /// Pointer DOWN on the media viewport (§7–§8): starts a drag (anywhere
  /// on the preview, corners included) or a corner resize. Nothing starts
  /// when the camera is off or the pointer is outside the preview.
  void _pipOnPointerDown(
    PointerDownEvent e,
    bool showSelf,
    Size mediaArea,
    Size pipSize,
  ) {
    if (!showSelf) return;
    // Primary button only (§8): secondary buttons stay idle.
    if (e.buttons != kPrimaryMouseButton) return;
    final p = e.localPosition; // media-local: stable parent space (§3)
    final rect = _pipRect(mediaArea, pipSize);
    if (!rect.contains(p)) return;
    final zone = selfPipZoneFor(p - rect.topLeft, pipSize);
    _pipSnap.stop();
    _pipSnapFrom = null;
    _pipSnapTo = null;
    _pipGestureIsResize = zone != SelfPipZone.center;
    _pipGestureZone = zone;
    _pipGestureStart = rect;
    _pipGesturePointer0 = p;
    _pipLiveRect = rect; // §24: start never moves the preview
    dlog(
      'SELF_PREVIEW_${_pipGestureIsResize ? 'RESIZE' : 'DRAG'}_START '
      'zone=$zone rect=${rect.width.toStringAsFixed(0)}x${rect.height.toStringAsFixed(0)}',
    );
    _pipTick.value++;
  }

  /// Pointer MOVE (§8/§10, §16): candidate always from startRect + TOTAL
  /// delta; one clamp into the safe viewport rect; doubles everywhere.
  void _pipOnPointerMove(PointerMoveEvent e, Size mediaArea, Size pipSize) {
    if (_pipLiveRect == null) return;
    final delta = e.localPosition - _pipGesturePointer0;
    if (_pipGestureIsResize) {
      _pipLiveRect = selfPipResizedRect(
        start: _pipGestureStart,
        pointerDelta: delta,
        zone: _pipGestureZone,
        dock: _pipDock.edge,
        media: mediaArea,
      );
    } else {
      final safe = selfPipSafeRect(mediaArea);
      final candidate = _pipGestureStart.shift(delta);
      final left = candidate.left
          .clamp(safe.left, math.max(safe.left, safe.right - pipSize.width))
          .toDouble();
      final top = candidate.top
          .clamp(safe.top, math.max(safe.top, safe.bottom - pipSize.height))
          .toDouble();
      _pipLiveRect = Rect.fromLTWH(
          left, top, _pipGestureStart.width, _pipGestureStart.height);
    }
    _pipTick.value++;
  }

  /// Pointer UP / CANCEL (§19, §12 of positioning, §23): persist dock +
  /// size ONCE; animate ONLY a real snap/correction gap (§25).
  void _pipOnPointerEnd(PointerEvent e, Size mediaArea) {
    final rect = _pipLiveRect;
    if (rect == null) return;
    final wasResize = _pipGestureIsResize;
    _pipLiveRect = null;
    _pipGestureZone = SelfPipZone.center;
    final safe = selfPipSafeRect(mediaArea);
    final pipNow = Size(
      rect.width,
      selfPipHeightFor(rect.width),
    );
    // Belt & braces: the persisted spot is computed from a rect that is
    // already inside the safe area (clamp handles any residue).
    final settledRect = Rect.fromLTWH(
      rect.left.clamp(safe.left, math.max(safe.left, safe.right - pipNow.width)),
      rect.top.clamp(safe.top, math.max(safe.top, safe.bottom - pipNow.height)),
      pipNow.width,
      pipNow.height,
    );
    if (wasResize) {
      // Keep the dock EDGE, recompute the offset along it (§60 model).
      _pipUserW = settledRect.width;
      _pipDock = _pipDockSpotFor(settledRect, mediaArea, pipNow);
    } else {
      _pipDock = snapDock(settledRect, mediaArea, pipNow);
    }
    final target = dockRect(_pipDock, mediaArea, pipNow);
    if (target.topLeft != settledRect.topLeft) {
      // Only a real gap animates (§25/§27): 160ms, part of the release.
      _pipSnapFrom = settledRect;
      _pipSnapTo = target;
      _pipSnap.forward(from: 0);
    }
    dlog(
      'SELF_PREVIEW_${wasResize ? 'RESIZE' : 'DRAG'}_END '
      'w=${settledRect.width.toStringAsFixed(0)} dock=$_pipDock',
    );
    _pipTick.value++;
  }

  /// Dock spot for a settled rect: SAME edge, offset re-derived (§13 of
  /// positioning spec) — used after resizes to keep the flush edge.
  DockSpot _pipDockSpotFor(Rect rect, Size mediaArea, Size pipSize) {
    final maxX = math.max(kDockMargin, mediaArea.width - kDockMargin - pipSize.width);
    final maxY = math.max(kDockMargin, mediaArea.height - kDockMargin - pipSize.height);
    double off;
    switch (_pipDock.edge) {
      case DockEdge.left || DockEdge.right:
        off = (maxY <= kDockMargin)
            ? 0.5
            : ((rect.top - kDockMargin) / (maxY - kDockMargin)).clamp(0.0, 1.0);
      case DockEdge.top || DockEdge.bottom:
        off = (maxX <= kDockMargin)
            ? 0.5
            : ((rect.left - kDockMargin) / (maxX - kDockMargin)).clamp(0.0, 1.0);
    }
    return DockSpot(_pipDock.edge, off);
  }

  /// Live drag position (card top-left), null when docked (§29–§32).
  Offset? _dragPos;

  /// Snap flight after release: rect interpolation + its own clock (§37).
  Rect? _snapFrom;
  Rect? _snapTo;
  late final AnimationController _snap = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 220),
  );

  /// Self-preview dock INSIDE the expanded video area. Same model as the
  /// mini card (edge + normalized offset, never bare x/y) but a separate
  /// entity — self never shares state with the mini remote preview (§21).
  /// Defaults to RIGHT (§25), survives camera off/on within the session
  /// (§40), resets when a new session starts (§41).
  DockSpot _pipDock = const DockSpot(DockEdge.right, 0.4);
  Rect? _pipSnapFrom;
  Rect? _pipSnapTo;

  /// User-chosen self-preview WIDTH (§33–§43): height follows the fixed
  /// 16:9 aspect. Survives drags, resizes, camera off/on and window
  /// resizes for the whole session (§40–§42); resets with a new session.
  double _pipUserW = kSelfPipDefaultW;

  /// Localized rebuild clock for the overlay subtree: pointer updates
  /// bump this instead of [setState], so a 60Hz mouse move never rebuilds
  /// the whole call window (§23–§24). The manager rebuilds the frame
  /// driven by [TickerProviderStateMixin].
  final ValueNotifier<int> _pipTick = ValueNotifier(0);

  late final AnimationController _pipSnap = AnimationController(
    vsync: this,
    // §27: snap after release feels like part of the release itself.
    duration: const Duration(milliseconds: 160),
  );
  late final Animation<double> _pipEase = CurvedAnimation(
    parent: _pipSnap,
    curve: Curves.easeOutCubic,
  );

  /// Preview collapse clock (§23–§24, 220ms). The curved view drives the
  /// card height, the SizeTransition and the fade together.
  late final AnimationController _previewT = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 220),
  );
  late final Animation<double> _previewEase = CurvedAnimation(
    parent: _previewT,
    curve: Curves.easeInOutCubic,
  );

  /// Last seen app size for gesture handlers (no context there).
  Size _lastScreen = Size.zero;

  @override
  void dispose() {
    _ticker?.cancel();
    _morph.dispose();
    _snap.dispose();
    _pipSnap.dispose();
    _pipTick.dispose();
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
      return Rect.fromLTWH(_dragPos!.dx, _dragPos!.dy, card.width, card.height);
    }
    if (_snapFrom != null && _snapTo != null && _snap.isAnimating) {
      return Rect.lerp(
        _snapFrom!,
        _snapTo!,
        Curves.easeOutCubic.transform(_snap.value),
      )!;
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
      _dragPos = clampCardPos(_dragPos! + d.delta, _lastScreen, card);
    });
  }

  void _onDragEnd(DragEndDetails _) {
    if (_dragPos == null) return;
    final card = Size(kCardWidth, _cardHeight());
    final rect = Rect.fromLTWH(
      _dragPos!.dx,
      _dragPos!.dy,
      card.width,
      card.height,
    );
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
          .showSnackBar(
            SnackBar(
              content: Text(redial.reason),
              action: SnackBarAction(
                label: 'Позвонить снова',
                onPressed: () async {
                  ref.read(callRedialProvider.notifier).clear();
                  // A redial never kills a live session silently: free starts,
                  // anything else gets a toast, never a confirm dialog from
                  // a snackbar action.
                  final coord = ref.read(mediaCoordinatorProvider.notifier);
                  switch (coord.requestSlot('redial')) {
                    case SessionRequest.free:
                      try {
                        final st = ref.read(callStateProvider.notifier);
                        await st.startCall(
                          peerNick: redial.peerNick,
                          dmId: redial.dmId,
                          video: redial.video,
                        );
                      } catch (e) {
                        if (context.mounted) {
                          Toast.show(context, friendlyCallError(e));
                        }
                      }
                    case SessionRequest.confirm:
                      if (context.mounted) {
                        Toast.show(context, 'Завершите текущий звонок');
                      }
                    case SessionRequest.busy:
                      if (context.mounted) {
                        Toast.show(context, 'Дождитесь переключения звонка');
                      }
                  }
                },
              ),
            ),
          )
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
      // Self-preview resets with the session: right side, middle-ish (§41),
      // default width (§43).
      _pipDock = const DockSpot(DockEdge.right, 0.4);
      _pipUserW = kSelfPipDefaultW;
      _pipLiveRect = null;
      _pipGestureIsResize = false;
      _pipGestureZone = SelfPipZone.center;
      _pipHoverZone = null;
      _pipSnapFrom = null;
      _pipSnapTo = null;
      _pipSnap.reset();
      _pipTick.value++;
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
          ref
              .read(miniPreviewVisibleProvider.notifier)
              .set(ref.read(lastMiniPreviewProvider));
          _previewT.value = ref.read(lastMiniPreviewProvider) ? 1.0 : 0.0;
        } else {
          ref.read(lastMiniPreviewProvider.notifier).set(savePreview);
        }
      });
    }
    // Collapse progress follows the mode (§23–§24): toggles animate it,
    // flights leave it frozen. forward()/reverse() only schedule frames,
    // so build-driven is safe (same pattern as the morph itself).
    final wantPreview =
        call.presentation == CallPresentationMode.miniWithPreview ? 1.0 : 0.0;
    if (!_previewT.isAnimating && _previewT.value != wantPreview) {
      if (wantPreview > 0) {
        _previewT.forward();
      } else {
        _previewT.reverse();
      }
    }
    final ringing =
        call.kind == CallKind.direct && call.phase == CallPhase.ringing;
    final body = AnimatedBuilder(
      animation: Listenable.merge([_morph, _snap, _previewT]),
      builder: (ctx, _) {
        final t = _morph.value;
        // Settled states render exact structures (Center + window, or the
        // docked card): zero pixel churn, goldens untouched. Only
        // mid-flight uses the morph wrappers.
        if (t >= 1.0) {
          return Stack(
            children: [
              Positioned.fromRect(
                rect: _cardRect(MediaQuery.sizeOf(ctx)),
                child: MiniCallOverlay(
                  call: call,
                  secs: _secs,
                  preview: _previewEase,
                  onTogglePreview: _onTogglePreview,
                  onDragStart: _onDragStart,
                  onDragUpdate: _onDragUpdate,
                  onDragEnd: _onDragEnd,
                ),
              ),
            ],
          );
        }
        if (t <= 0.0) {
          return Stack(
            children: [
              // Slight dim while ringing only; active calls never block chat.
              if (ringing)
                const IgnorePointer(child: ModalBarrier(color: Colors.black38)),
              Center(
                child: CallbackShortcuts(
                  bindings: {
                    // Esc minimizes, never hangs up (§48).
                    const SingleActivator(LogicalKeyboardKey.escape): () =>
                        call.onSetMinimized(true),
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
                          media: _mediaFor(call),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          );
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
        final fromSize = _fromSize ?? Size(box.width, box.height ?? 360.0);
        final fromRect = Rect.fromCenter(
          center: screen.center(Offset.zero),
          width: fromSize.width,
          height: fromSize.height,
        );
        final dockRectNow = _cardRect(screen);
        final e = Curves.easeInOutCubic.transform(t); // §27
        final rect = Rect.lerp(fromRect, dockRectNow, e)!;
        final radius = lerpDouble(18, kCardRadius, e)!;
        final elev = lerpDouble(12, 8, e)!;
        // Staging: title fades 0–0.3, pill bar fades in 0.55–1.
        final titleOut = (1.0 - t / 0.3).clamp(0.0, 1.0);
        final barIn = ((t - 0.55) / 0.45).clamp(0.0, 1.0);
        final rider = _rider;
        return Stack(
          key: const ValueKey('morph-surface'),
          children: [
            // Slight dim while ringing only; active calls never block chat.
            // Kept under the flying surface until it mostly left.
            if (ringing && t < 0.5)
              const IgnorePointer(child: ModalBarrier(color: Colors.black38)),
            Positioned.fromRect(
              rect: rect,
              child: Material(
                color: Theme.of(ctx).colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(radius),
                elevation: elev,
                shadowColor: Colors.black.withValues(alpha: 0.5),
                child: Container(
                  decoration: BoxDecoration(
                    border: Border.all(
                      color: Theme.of(ctx).dividerColor.withValues(alpha: 0.5),
                    ),
                    borderRadius: BorderRadius.circular(radius),
                  ),
                  clipBehavior: Clip.antiAlias,
                  child: Stack(
                    children: [
                      // Rider fades with the collapse progress: minimizing
                      // into a collapsed card flies the bar, not the video.
                      Positioned.fill(
                        child: Opacity(
                          opacity: _previewEase.value,
                          child: _riderFace(
                            rider,
                            call.title,
                            _isWaiting(call) && rider == null,
                          ),
                        ),
                      ),
                      if (titleOut > 0)
                        Positioned(
                          top: 14,
                          left: 18,
                          right: 18,
                          child: Opacity(
                            opacity: titleOut,
                            child: Text(
                              call.title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
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
                              padding: const EdgeInsets.fromLTRB(12, 16, 12, 8),
                              decoration: const BoxDecoration(
                                gradient: LinearGradient(
                                  begin: Alignment.topCenter,
                                  end: Alignment.bottomCenter,
                                  colors: [Colors.transparent, Colors.black87],
                                ),
                              ),
                              child: _pillMeta(
                                name: rider?.nick ?? call.title,
                                muted: rider?.muted ?? false,
                                status: _pillStatus(call, _secs),
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
    // Session switch in progress (§57): veil with a spinner, no fake
    // "connected" state, media buttons untouchable until the new session
    // is live. Also serializes double-Accept: the buttons sit under this.
    if (!ref.watch(mediaCoordinatorProvider)) return body;
    return Stack(
      children: [
        body,
        const ModalBarrier(color: Colors.black54),
        Center(
          child: Card(
            child: Padding(
              padding: EdgeInsets.symmetric(horizontal: 20, vertical: 16),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                  SizedBox(width: 12),
                  Text('Переключаем звонок…'),
                ],
              ),
            ),
          ),
        ),
      ],
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
    final hasRemote = (direct?.remoteVideo ?? false) && remote != null;
    // Remote video can arrive mid-call even when this side never sent
    // theirs (late peer camera): the hero view opens for that too.
    final videoNow = call.video || call.remoteVideo;
    if (videoNow && call.phase == CallPhase.active) {
      return _videoArea(context, call, remote, local, hasRemote);
    }
    return _identity(call);
  }

  /// Active video: remote is the hero (§39); avatar until the track
  /// arrives (§41); local self-view is a floating draggable overlay (§40).
  Widget _videoArea(
    BuildContext context,
    UnifiedCall call,
    RTCVideoRenderer? remote,
    RTCVideoRenderer? local,
    bool hasRemote,
  ) {
    // Self preview lives ONLY for a real local capture (§22–§24): camera
    // off or capture-less states render NOTHING here — no black tile, no
    // placeholder, no frozen frame. Floating overlay so the remote
    // surface never reflows (§29); 180ms fade/scale on state changes.
    final hasTracker = local != null;
    final showSelf = call.video && !call.cameraOff && hasTracker;
    // §13 visual safety net: the whole layer stack clips to itself — even
    // a geometry regression can't draw the preview over the controls region
    // or the window edges (clip ≠ clamp, but both are in place now).
    return Stack(
      key: const ValueKey('self-video-area-stack'),
      clipBehavior: Clip.hardEdge,
      children: [
        Container(
          decoration: BoxDecoration(
            color: Colors.black,
            borderRadius: BorderRadius.circular(12),
          ),
          clipBehavior: Clip.antiAlias,
          child: hasRemote
              // Same GlobalObjectKey as the pill/morph rider builder (§4):
              // minimizing re-homes this element instead of rebinding the
              // texture, so the frame never drops to black mid-flight.
              ? KeyedSubtree(
                  key: GlobalObjectKey(remote!),
                  child: RTCVideoView(
                    remote,
                    objectFit:
                        RTCVideoViewObjectFit.RTCVideoViewObjectFitContain,
                  ),
                )
              : Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Avatar(call.title, radius: 30),
                      const SizedBox(height: 8),
                      const Text(
                        'Подключение видео…',
                        style: TextStyle(fontSize: 12, color: Colors.grey),
                      ),
                    ],
                  ),
                ),
        ),
        // Camera fps floor (§capture-fps): when the capture delivers fewer
        // fps than the tier asks, say it out loud - higher tiers only
        // enlarge the picture, they cannot smooth the motion. Rendered
        // BELOW the pip layer, so a parked preview simply covers it.
        if (call.video && call.phase == CallPhase.active)
          Positioned(
            left: 0,
            right: 0,
            top: 10,
            child: Center(
              child: Consumer(
                builder: (context, ref, _) {
                  final cap = ref.watch(cameraFpsCapProvider);
                  if (cap <= 0) return const SizedBox.shrink();
                  return Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 10, vertical: 4),
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.55),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Text(
                      'Камера: $cap fps',
                      style: const TextStyle(
                          fontSize: 11, color: Colors.white70),
                    ),
                  );
                },
              ),
            ),
          ),
        // Floating self preview (§25–§40): clipped by the window's own
        // rounded rect; drag anywhere; snap to the nearest edge with
        // offset preserved (§35–§37); position lives ON THE HOST so
        // camera OFF→ON keeps the last spot (§40). Render NOTHING when
        // the camera is off — the slot itself disappears with a fade (§43).
        if (hasTracker) _pipOverlay(showSelf, local),
      ],
    );
  }

  /// Rounded, draggable, corner-resizable self preview. Physically a
  /// child of the media viewport stack (§1 of the positioning spec): its
  /// coordinates are LOCAL to the black video area, with a hard clip so
  /// nothing can ever paint over header/controls.
  ///
  /// INTERACTION: ONE Listener at the viewport level — its localPosition
  /// is the stable media coordinate, so neither the moving preview nor
  /// global/render-box conversions exist. Inner area + straight edges =
  /// move; the four rounded corners (12px, invisible, corner-follows-
  /// pointer) = resize. Cursors are the only affordance (§20, §32).
  Widget _pipOverlay(bool showSelf, RTCVideoRenderer? local) {
    return Positioned.fill(
      child: AnimatedScale(
        scale: showSelf ? 1.0 : 0.94,
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOutCubic,
        child: AnimatedOpacity(
          opacity: showSelf ? 1.0 : 0.0,
          duration: const Duration(milliseconds: 180),
          child: LayoutBuilder(
            builder: (ctx, cons) {
              final mediaArea = cons.biggest;
              // Window-resize clamp of the user width: mid-BUILD mutation
              // is forbidden — sync after the frame (§14/§42).
              final pendingW = selfPipWidthFor(mediaArea, _pipUserW);
              if (pendingW != _pipUserW) {
                WidgetsBinding.instance.addPostFrameCallback((_) {
                  if (!mounted) return;
                  final eff = selfPipWidthFor(mediaArea, _pipUserW);
                  if (eff != _pipUserW) {
                    _pipUserW = eff;
                    _pipTick.value++;
                  }
                });
              }
              // During a gesture the LIVE rect width IS the size; between
              // gestures the user width rules (§17/§23 of positioning).
              final liveW = _pipLiveRect?.width ?? selfPipWidthFor(mediaArea, _pipUserW);
              final pipSize = Size(liveW, selfPipHeightFor(liveW));
              final video = RepaintBoundary(
                child: Container(
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(color: Colors.black54, width: 1),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.35),
                        blurRadius: 18,
                        offset: const Offset(0, 8),
                      ),
                    ],
                  ),
                  clipBehavior: Clip.antiAlias,
                  child: RTCVideoView(
                    local!,
                    mirror: true,
                    objectFit:
                        RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
                  ),
                ),
              );
              MouseCursor pipCursor() {
                switch (_pipMode) {
                  case _PipMode.dragging:
                    return SystemMouseCursors.grabbing;
                  case _PipMode.resizingTopLeft ||
                      _PipMode.resizingBottomRight:
                    return SystemMouseCursors.resizeUpLeftDownRight;
                  case _PipMode.resizingTopRight ||
                      _PipMode.resizingBottomLeft:
                    return SystemMouseCursors.resizeUpRightDownLeft;
                  case _PipMode.idle:
                    final z = _pipHoverZone;
                    if (z == null) return SystemMouseCursors.basic;
                    return switch (z) {
                      SelfPipZone.topLeft || SelfPipZone.bottomRight =>
                        SystemMouseCursors.resizeUpLeftDownRight,
                      SelfPipZone.topRight || SelfPipZone.bottomLeft =>
                        SystemMouseCursors.resizeUpRightDownLeft,
                      SelfPipZone.center => SystemMouseCursors.grab,
                    };
                }
              }

              return MouseRegion(
                opaque: false,
                cursor: pipCursor(),
                onHover: (e) {
                  // Hover tracking in media space (§20); rebuild stays
                  // local to this overlay (§26). Skipped mid-gesture:
                  // the drag/resize cursor covers it and the zone work
                  // would only add per-move overhead during resize.
                  if (_pipMode != _PipMode.idle) return;
                  final rect = _pipRect(mediaArea, pipSize);
                  final SelfPipZone? z = rect.contains(e.localPosition)
                      ? selfPipZoneFor(e.localPosition - rect.topLeft, pipSize)
                      : null;
                  if (z != _pipHoverZone) {
                    _pipHoverZone = z;
                    _pipTick.value++;
                  }
                },
                child: Listener(
                  behavior: HitTestBehavior.translucent,
                  onPointerDown: (e) =>
                      _pipOnPointerDown(e, showSelf, mediaArea, pipSize),
                  onPointerMove: (e) => _pipOnPointerMove(e, mediaArea, pipSize),
                  onPointerUp: (e) => _pipOnPointerEnd(e, mediaArea),
                  onPointerCancel: (e) => _pipOnPointerEnd(e, mediaArea),
                  child: AnimatedBuilder(
                    animation: Listenable.merge([_pipEase, _pipTick]),
                    child: video,
                    builder: (b, v) => Stack(
                      clipBehavior: Clip.none,
                      fit: StackFit.expand,
                      children: [
                        Positioned.fromRect(
                          rect: _pipRect(mediaArea, pipSize),
                          child: v!,
                        ),
                      ],
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );
  }

  Widget _identity(UnifiedCall call) {
    final incoming = call.onAccept != null;
    // Room-based calls (voice/group) already carry the context line in the
    // window header: the identity shows avatar + name only, otherwise the
    // status text would appear twice. Direct keeps the full block since its
    // top bar is bare.
    final roomBased = call.kind != CallKind.direct;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Avatar(call.title, radius: 34),
        const SizedBox(height: 10),
        Text(
          call.title,
          style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
        ),
        if (!roomBased) ...[
          const SizedBox(height: 2),
          Text(
            incoming
                ? call.subtitle
                : call.phase == CallPhase.ringing
                ? 'Вызов…'
                : 'Подключено · ${formatCallDuration(_secs)}',
            style: const TextStyle(fontSize: 13, color: Colors.grey),
          ),
        ],
      ],
    );
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

/// Self-preview SIZE policy (§33–§43). The stored user width lives in
/// [kSelfPipMinW, hard cap]; the EFFECTIVE max is responsive: 35% of the
/// usable video-area width AND 40% of its height (through the fixed 3:4
/// aspect), never above the hard cap — computed live during resize and
/// window resizes (§36–§38). Reveals of video use the same aspect, so
/// nothing is distorted (§10).
const double kSelfPipMinW = 180;
const double kSelfPipHardMaxW = 420;
const double kSelfPipDefaultW = 220;

/// Height/width ratio of the preview: 16:9 per the final UX spec
/// (§34: 180×101 min; §39: 420×236 max, defaultWidth 220).
const double kSelfPipAspect = 9 / 16;

/// Effective max width for a video area of [media].
double selfPipMaxWidthFor(Size media) {
  final byWidth = media.width * 0.35;
  final byHeight = media.height * 0.4 / kSelfPipAspect; // w = h * 16/9
  final max = math.min(kSelfPipHardMaxW, math.min(byWidth, byHeight));
  // Never below the minimum even in a tiny area: position clamping
  // handles the leftovers instead of shrinking to a useless dot (§34).
  return max.clamp(kSelfPipMinW, kSelfPipHardMaxW);
}

/// Clamp a user-chosen width for the given area (min..responsive max).
double selfPipWidthFor(Size media, double userW) =>
    userW.clamp(kSelfPipMinW, selfPipMaxWidthFor(media));

double selfPipHeightFor(double w) => w * kSelfPipAspect;

/// Safe inset between the self-preview and the video viewport bounds
/// (§2/§3 of the bounds spec): ~12px on every side.
const double kSelfPipInset = 12;

/// The safe rect inside the media viewport: preview geometry must always
/// stay within this rect (§2–§3, §9). One coordinate space, computed from
/// the fresh layout constraints — never stale window values (§14–§15).
Rect selfPipSafeRect(Size media) {
  final minX = kSelfPipInset;
  final minY = kSelfPipInset;
  final maxX = math.max(minX, media.width - kSelfPipInset);
  final maxY = math.max(minY, media.height - kSelfPipInset);
  return Rect.fromLTRB(minX, minY, maxX, maxY);
}

/// Interaction zones over the self-preview (§3–§5, §28): corners WIN over
/// edges — are plain drag. The corner hit area hugs the visible rounded
/// corner (~12px): a bit deeper inside the pointer is already a plain
/// grab cursor (§4, §27, §32).
enum SelfPipZone { center, topLeft, topRight, bottomLeft, bottomRight }

SelfPipZone selfPipZoneFor(Offset local, Size size, {double corner = 12}) {
  final nearLeft = local.dx <= corner;
  final nearRight = local.dx >= size.width - corner;
  final nearTop = local.dy <= corner;
  final nearBottom = local.dy >= size.height - corner;
  if (nearLeft && nearTop) return SelfPipZone.topLeft;
  if (nearRight && nearTop) return SelfPipZone.topRight;
  if (nearLeft && nearBottom) return SelfPipZone.bottomLeft;
  if (nearRight && nearBottom) return SelfPipZone.bottomRight;
  return SelfPipZone.center;
}

/// Interaction mode of the self-preview (§22): a single enum instead of
/// competing booleans. Derived from the active gesture + zone. Corners
/// carry resize; straight edges are plain drag (§1–§5, §32).
enum _PipMode {
  idle,
  dragging,
  resizingTopLeft,
  resizingTopRight,
  resizingBottomLeft,
  resizingBottomRight,
}

/// Corner-only resize math (§8–§15, §19–§22). ONE continuous scalar per
/// gesture — no dominant-axis switching (§9); geometry stays in doubles
/// (§11–§12); limits clamp live without moving anchors (§19–§21); the
/// dock edge stays frozen during the gesture (§22).
///
/// FLUSH grabs (the grabbed corner lies ON the docked edge, §15): the
/// dock wins — the flush corner itself stays anchored and the preview
/// grows INWARD; the height follows the vertical pointer delta and the
/// width re-derives from the fixed 16:9 aspect (§12).
///
/// FREE grabs (corners away from the dock edge): the OPPOSITE corner is
/// fixed (§10) and the same diagonal-projection scalar drives the size.
Rect selfPipResizedRect({
  required Rect start,
  required Offset pointerDelta,
  required SelfPipZone zone,
  required DockEdge dock,
  required Size media,
  double minW = kSelfPipMinW,
}) {
  // --- FLUSH grabs: the grabbed side is docked; anchor it, grow inward.
  // Safe bounds first (§9/§12): the height cap is the span from the flush
  // side of the START rect to the safe edge — never a bulk 40% guess that
  // can shoot the rect past the top/bottom viewport lines.
  final safe = selfPipSafeRect(media);
  final flushOnRight =
      dock == DockEdge.right && zone == SelfPipZone.topRight ||
      dock == DockEdge.right && zone == SelfPipZone.bottomRight;
  final flushOnLeft =
      dock == DockEdge.left && zone == SelfPipZone.topLeft ||
      dock == DockEdge.left && zone == SelfPipZone.bottomLeft;
  final flushOnTop =
      dock == DockEdge.top && zone == SelfPipZone.topLeft ||
      dock == DockEdge.top && zone == SelfPipZone.topRight;
  final flushOnBottom =
      dock == DockEdge.bottom && zone == SelfPipZone.bottomLeft ||
      dock == DockEdge.bottom && zone == SelfPipZone.bottomRight;
  final minH = minW * kSelfPipAspect;
  final wCap = math.min(kSelfPipHardMaxW, media.width * 0.35);
  if (flushOnRight || flushOnLeft) {
    // Height-driven growth; the horizontal edge stays flush.
    final growsUp = flushOnRight
        ? zone == SelfPipZone.topRight
        : zone == SelfPipZone.topLeft;
    // Pulling UP (growsUp) extends the TOP edge: cap = start.bottom−safe.top.
    // Pulling DOWN extends the BOTTOM edge: cap = safe.bottom−start.top.
    final hCapSafe = growsUp
        ? math.max(minH, start.bottom - safe.top)
        : math.max(minH, safe.bottom - start.top);
    var h = (start.height + (growsUp ? -pointerDelta.dy : pointerDelta.dy))
        .clamp(minH, hCapSafe)
        .toDouble();
    var w = (h / kSelfPipAspect).clamp(minW, math.max(minW, wCap)).toDouble();
    h = w * kSelfPipAspect; // aspect stays EXACT at the floor (§12)
    if (flushOnRight) {
      return Rect.fromLTWH(
        start.right - w,
        growsUp ? start.bottom - h : start.top,
        w,
        h,
      );
    }
    return Rect.fromLTWH(
      start.left,
      growsUp ? start.bottom - h : start.top,
      w,
      h,
    );
  }
  if (flushOnTop || flushOnBottom) {
    // The flush edge is horizontal: vertical anchor fixed, horizontal may
    // extend toward the free side ( budgets from the SAFE edges — §9).
    final growsDown = flushOnTop;
    final hCapSafe = growsDown
        ? math.max(minH, safe.bottom - start.top)
        : math.max(minH, start.bottom - safe.top);
    var h = (start.height + (growsDown ? pointerDelta.dy : -pointerDelta.dy))
        .clamp(minH, hCapSafe)
        .toDouble();
    // Horizontal span toward the free side (zone-relative).
    final wSpanSafe = (zone == SelfPipZone.topLeft ||
            zone == SelfPipZone.bottomLeft)
        ? math.max(minW, start.right - safe.left)
        : math.max(minW, safe.right - start.left);
    var w = (h / kSelfPipAspect).clamp(minW, math.max(minW, math.min(wCap, wSpanSafe))).toDouble();
    h = w * kSelfPipAspect;
    final left = (zone == SelfPipZone.topLeft || zone == SelfPipZone.bottomLeft)
        ? start.right - w
        : start.left;
    final top = flushOnTop ? start.top : start.bottom - h;
    return Rect.fromLTWH(left, top, w, h);
  }

  // --- FREE grabs: opposite corner fixed (§10), one continuous scalar
  // (§9), every budget in a single clamp (§19–§21). The scalar lives in
  // WIDTH space: a pure horizontal pull maps 1:1 onto the width (the
  // cursor never "lags" the card edge), a vertical pull adds a smooth
  // 9/16 share. No normalization, no axis switching (§9).
  final aspect = kSelfPipAspect; // 9/16 (h/w)
  final (dxS, dyS) = switch (zone) {
    SelfPipZone.bottomRight => (1.0, 1.0),
    SelfPipZone.topLeft => (-1.0, -1.0),
    SelfPipZone.bottomLeft => (-1.0, 1.0),
    SelfPipZone.topRight => (1.0, -1.0),
    _ => (1.0, 1.0),
  };
  final projected =
      dxS * pointerDelta.dx + dyS * pointerDelta.dy * aspect;
  final fixed = switch (zone) {
    SelfPipZone.bottomRight => start.topLeft,
    SelfPipZone.topLeft => start.bottomRight,
    SelfPipZone.bottomLeft => start.topRight,
    SelfPipZone.topRight => start.bottomLeft,
    _ => start.topLeft,
  };
  final spanToRight = media.width - kDockMargin - fixed.dx;
  final spanToLeft = fixed.dx - kDockMargin;
  final spanToBottom = media.height - kDockMargin - fixed.dy;
  final spanToTop = fixed.dy - kDockMargin;
  final wSpan = (zone == SelfPipZone.bottomRight || zone == SelfPipZone.topRight)
      ? spanToRight
      : spanToLeft;
  final hSpan = (zone == SelfPipZone.topLeft || zone == SelfPipZone.topRight)
      ? spanToTop
      : spanToBottom;
  final w = (start.width + projected)
      .clamp(
        minW,
        math.max(
          minW,
          math.min(
            kSelfPipHardMaxW,
            math.min(
              media.width * 0.35,
              math.min(
                media.height * 0.4 / kSelfPipAspect,
                math.max(minW, math.min(wSpan, hSpan * 16 / 9)),
              ),
            ),
          ),
        ),
      )
      .toDouble();
  final h = selfPipHeightFor(w);
  // Anchor table (§10/§13): the FIXED corner is the OPPOSITE of the grab.
  // grab bottomRight → fixed topLeft     → left=fixed.dx,   top=fixed.dy
  // grab topRight    → fixed bottomLeft  → left=fixed.dx,   top=fixed.dy-h
  // grab topLeft     → fixed bottomRight → left=fixed.dx-w, top=fixed.dy-h
  // grab bottomLeft  → fixed topRight    → left=fixed.dx-w, top=fixed.dy
  final left =
      (zone == SelfPipZone.bottomRight || zone == SelfPipZone.topRight)
      ? fixed.dx
      : fixed.dx - w;
  final top = (zone == SelfPipZone.topLeft || zone == SelfPipZone.topRight)
      ? fixed.dy - h
      : fixed.dy;
  // Safe bounds in the SAME media space (§9/§11): the spans above already
  // carry the safe margins; the anchored corner never moves (§20).
  return Rect.fromLTWH(left, top, w, h);
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
({double width, double? height}) callWindowSize(UnifiedCall call, Size screen) {
  final wideVideo =
      (call.video || call.remoteVideo) && call.phase == CallPhase.active;
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
  const CallWindow({
    super.key,
    required this.call,
    required this.secs,
    required this.media,
  });

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
            color: Theme.of(context).dividerColor.withValues(alpha: 0.5),
          ),
          borderRadius: BorderRadius.circular(18),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _header(context),
            const SizedBox(height: 10),
            if (wideVideo) Expanded(child: media) else media,
            if (call.linkDown && call.phase == CallPhase.active) ...[
              const SizedBox(height: 8),
              const Text(
                'Восстанавливаем соединение…',
                style: TextStyle(fontSize: 12, color: Colors.orange),
              ),
            ],
            const SizedBox(height: 14),
            _controls(context),
          ],
        ),
      ),
    );
  }

  Widget _header(BuildContext context) {
    // Direct keeps its old bare top bar; the context title (§27) is for
    // room-based calls (voice/group), where the peer-name identity below
    // does not exist.
    if (call.kind == CallKind.direct) {
      return Row(
        children: [
          const Expanded(child: SizedBox.shrink()),
          IconButton(
            tooltip: 'Свернуть',
            icon: const Icon(Icons.remove, size: 20),
            onPressed: () => call.onSetMinimized(true),
          ),
        ],
      );
    }
    return Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                call.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                ),
              ),
              Text(
                call.phase == CallPhase.active
                    ? '${call.subtitle} · ${formatCallDuration(secs)}'
                    : call.subtitle,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 13, color: Colors.grey),
              ),
            ],
          ),
        ),
        IconButton(
          tooltip: 'Свернуть',
          icon: const Icon(Icons.remove, size: 20),
          onPressed: () => call.onSetMinimized(true),
        ),
      ],
    );
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
        Future<void> acceptAsGroup() async {
          if (call.onAcceptAsGroup == null) return;
          try {
            final r = await call.onAcceptAsGroup!();
            if (r == SwitchResult.busy && context.mounted) {
              Toast.show(context, 'Дождитесь переключения звонка');
            }
          } catch (e) {
            if (context.mounted) {
              Toast.show(context, friendlyGroupError(e));
            }
          }
        }

        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              'Вы уже участвуете в другом разговоре.',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 12, color: Colors.grey),
            ),
            Text(
              detail,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 12, color: Colors.grey),
            ),
            const SizedBox(height: 10),
            // Wrap, not Row: three actions must survive narrow windows
            // (and the test font, which runs wider than production).
            Wrap(
              alignment: WrapAlignment.center,
              spacing: 12,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                _roundBtn(Colors.red, Icons.call_end, 'Отклонить', decline),
                if (call.onAcceptAsGroup != null)
                  Tooltip(
                    message: 'Продолжить в групповом звонке',
                    child: FilledButton.tonalIcon(
                      onPressed: acceptAsGroup,
                      icon: const Icon(Icons.group_add, size: 18),
                      label: const Text('В группу'),
                    ),
                  ),
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
          ],
        );
      }
      return Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          _roundBtn(Colors.red, Icons.call_end, 'Отклонить', decline),
          const SizedBox(width: 28),
          // Answer-with-camera intent (direct video only): toggling never
          // captures the device and never accepts the call by itself.
          // ON = neutral graphite with a normal camera glyph; OFF = filled
          // red with a crossed camera — obvious at a glance (§7–§8), but
          // still distinct from Decline (call glyph) at half the radius.
          if (call.onToggleRingCamera != null) ...[
            _roundBtn(
              call.ringCameraOn ? null : Colors.red.shade600,
              call.ringCameraOn ? Icons.videocam : Icons.videocam_off_outlined,
              call.ringCameraOn ? 'Выключить камеру' : 'Включить камеру',
              () => call.onToggleRingCamera!(),
            ),
            const SizedBox(width: 28),
          ],
          _roundBtn(Colors.green, Icons.call, 'Принять', accept),
        ],
      );
    }
    // The camera is reachable in every direct call: a call that started
    // on voice only turns the device on here (renegotiation), so the
    // button shows even before the initial `video` flag exists.
    // Watching-only (peer video live, our camera off) renders the button
    // RED videocam_off — the honest "your camera is off" affordance.
    final cameraLive = call.video && !call.cameraOff;
    final watchingOnly = (call.video || call.remoteVideo) && !cameraLive;
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        _roundBtn(
          call.muted ? Colors.red : null,
          call.muted ? Icons.mic_off : Icons.mic,
          call.muted ? 'Включить микрофон' : 'Выключить микрофон',
          () => call.onToggleMute(),
        ),
        const SizedBox(width: 12),
        if (call.kind == CallKind.direct || call.video) ...[
          _roundBtn(
            watchingOnly ? Colors.red : null,
            watchingOnly ? Icons.videocam_off : Icons.videocam,
            cameraLive ? 'Выключить камеру' : 'Включить камеру',
            () => call.onToggleCamera(),
          ),
          const SizedBox(width: 12),
        ],
        if (call.kind == CallKind.direct &&
            call.video &&
            call.phase == CallPhase.active)
          _roundBtn(
            call.sharingScreen ? Colors.blue : null,
            call.sharingScreen ? Icons.stop_screen_share : Icons.screen_share,
            'Демонстрация экрана',
            () => call.onToggleShare(),
          ),
        if (call.kind == CallKind.direct &&
            call.video &&
            call.phase == CallPhase.active)
          const SizedBox(width: 12),
        _roundBtn(Colors.red, Icons.call_end, 'Завершить', () {
          call.onHangup();
        }),
      ],
    );
  }

  Widget _roundBtn(Color? bg, IconData icon, String tip, VoidCallback onTap) {
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
            shape: BoxShape.circle,
          ),
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
        child: Text(
          'Подключение…',
          style: TextStyle(fontSize: 12, color: Colors.grey),
        ),
      );
    }
    if (participants.length == 1) {
      return Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420, maxHeight: 320),
          child: AspectRatio(
            aspectRatio: 4 / 3,
            child: ParticipantTile(participant: participants.first),
          ),
        ),
      );
    }
    final cols = participants.length <= 2
        ? participants.length
        : participants.length <= 4
        ? 2
        : 3;
    final rows = (participants.length + cols - 1) ~/ cols;
    return LayoutBuilder(
      builder: (ctx, cons) {
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
      },
    );
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
            ? Border.all(color: Theme.of(context).colorScheme.primary, width: 2)
            : Border.all(color: Colors.transparent, width: 2),
      ),
      clipBehavior: Clip.antiAlias,
      child: Stack(
        children: [
          if (video != null)
            Positioned.fill(child: Builder(builder: video))
          else
            Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Avatar(p.nick, radius: 30),
                  const SizedBox(height: 8),
                  if (p.muted)
                    const Icon(Icons.mic_off, size: 14, color: Colors.grey),
                ],
              ),
            ),
          Positioned(
            left: 8,
            right: 8,
            bottom: 6,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Flexible(
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 6,
                      vertical: 2,
                    ),
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.55),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Text(
                      p.nick,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 11, color: Colors.white),
                    ),
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
                    child: const Icon(
                      Icons.mic_off,
                      size: 11,
                      color: Colors.white70,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
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
  const MiniCallOverlay({
    super.key,
    required this.call,
    required this.secs,
    required this.preview,
    required this.onTogglePreview,
    required this.onDragStart,
    required this.onDragUpdate,
    required this.onDragEnd,
  });

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
      onDragEnd: onDragEnd,
    );
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
Widget _riderFace(CallParticipant? rider, String fallbackNick, bool waiting) {
  if (waiting) return _waitingFace();
  final v = rider?.video;
  if (v != null) {
    return Container(
      color: Colors.black,
      child: Builder(builder: v),
    );
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
Widget _pillMeta({
  required String name,
  required bool muted,
  required String status,
}) {
  return Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Flexible(
        child: Text(
          name,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w700,
            color: Colors.white,
          ),
        ),
      ),
      if (muted) ...[
        const SizedBox(width: 4),
        const Icon(Icons.mic_off, size: 11, color: Colors.white70),
      ],
      const SizedBox(width: 6),
      Text(status, style: const TextStyle(fontSize: 11, color: Colors.white70)),
    ],
  );
}

String _pillStatus(UnifiedCall call, int secs) =>
    call.phase == CallPhase.active ? formatCallDuration(secs) : 'Вызов…';

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
    layoutBuilder: (current, previous) => Stack(
      children: [
        if (current != null) Positioned.fill(child: current),
        for (final p in previous) Positioned.fill(child: p),
      ],
    ),
    // Identity follows content: waiting is its own state; a camera toggle
    // on the same speaker swaps avatar ↔ video without changing who.
    // The speaker name rides along as a small chip (the bar carries the
    // call identity instead).
    child: KeyedSubtree(
      key: ValueKey(
        waiting
            ? 'spot-waiting'
            : 'spot-${sp?.id ?? 'none'}-${hasVideo ? 'v' : 'a'}',
      ),
      child: waiting
          ? _waitingFace()
          : Stack(
              children: [
                Positioned.fill(
                  child: hasVideo
                      ? Container(
                          color: Colors.black,
                          child: Builder(builder: sp!.video!),
                        )
                      : _avatarFace(sp?.nick ?? call.title),
                ),
                Positioned(
                  left: 8,
                  bottom: 6,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 6,
                      vertical: 2,
                    ),
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.55),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Text(
                      sp?.nick ?? call.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 11, color: Colors.white),
                    ),
                  ),
                ),
              ],
            ),
    ),
  );
}

/// The compact call window: control bar + preview, one clipped surface.
/// The free bar area is the drag handle (§30); the mic/expand/hangup
/// buttons live outside it, so a tap never starts a drag (§31).
/// Preview tap expands (§53); the tap slop tells click from drag apart.
class MiniCallCard extends StatelessWidget {
  const MiniCallCard({
    super.key,
    required this.call,
    required this.secs,
    required this.preview,
    required this.onTogglePreview,
    required this.onDragStart,
    required this.onDragUpdate,
    required this.onDragEnd,
  });

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
            width: 1.5,
          ),
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(kCardRadius - 1.5),
          child: Material(
            color: Theme.of(context).colorScheme.surfaceContainerHighest,
            elevation: 8,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                MiniCallControlBar(
                  call: call,
                  secs: secs,
                  previewVisible: preview.value > 0.5,
                  onTogglePreview: onTogglePreview,
                  onDragStart: onDragStart,
                  onDragUpdate: onDragUpdate,
                  onDragEnd: onDragEnd,
                ),
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
              ],
            ),
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
  const MiniCallControlBar({
    super.key,
    required this.call,
    required this.secs,
    required this.previewVisible,
    required this.onTogglePreview,
    required this.onDragStart,
    required this.onDragUpdate,
    required this.onDragEnd,
  });

  final UnifiedCall call;
  final int secs;
  final bool previewVisible;
  final VoidCallback onTogglePreview;
  final GestureDragStartCallback onDragStart;
  final GestureDragUpdateCallback onDragUpdate;
  final GestureDragEndCallback onDragEnd;

  /// Camera is a real toggle where the engine supports it; where the call
  /// is audio-only the slot stays put, disabled (§9). Direct is special:
  /// the late camera enable (renegotiation) makes the toggle reachable in
  /// a voice-only call — pressing it turns the device on.
  bool get _cameraAvailable =>
      call.kind == CallKind.serverVoice ||
      call.kind == CallKind.direct ||
      (call.kind == CallKind.group && call.video);

  String get _endTooltip => switch (call.kind) {
    CallKind.direct => 'Завершить звонок',
    CallKind.group => 'Покинуть звонок',
    CallKind.serverVoice => 'Выйти из голосового канала',
  };

  Widget _btn({
    required String tooltip,
    required IconData icon,
    required VoidCallback? onPressed,
    Color? color,
  }) {
    return Tooltip(
      message: tooltip,
      child: InkWell(
        onTap: onPressed,
        borderRadius: BorderRadius.circular(8),
        child: Container(
          width: 36,
          height: 36,
          alignment: Alignment.center,
          child: Icon(icon, size: 20, color: color ?? Colors.white),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    // Watching-only (peer video live, our camera off) — red videocam_off.
    final cameraLive = call.video && !call.cameraOff;
    final watchingOnly = (call.video || call.remoteVideo) && !cameraLive;
    return SizedBox(
      height: kBarHeight,
      child: Row(
        children: [
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
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(
                      call.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontWeight: FontWeight.w700),
                    ),
                    Text(
                      _pillStatus(call, secs),
                      style: const TextStyle(fontSize: 11, color: Colors.grey),
                    ),
                  ],
                ),
              ),
            ),
          ),
          // 1. Preview show/hide: presentation only, never media (§6).
          _btn(
            tooltip: previewVisible
                ? 'Скрыть предпросмотр'
                : 'Показать предпросмотр',
            icon: previewVisible ? Icons.unfold_less : Icons.unfold_more,
            onPressed: onTogglePreview,
          ),
          // 2. Local microphone only (§7).
          _btn(
            tooltip: call.muted ? 'Включить микрофон' : 'Выключить микрофон',
            icon: call.muted ? Icons.mic_off : Icons.mic,
            onPressed: () => call.onToggleMute(),
          ),
          // 3. Local camera only (§8); hide-preview and camera-off are
          // different actions and stay different buttons. Watching-only
          // (peer video live, ours off) — red videocam_off.
          _btn(
            tooltip: !_cameraAvailable
                ? 'Камера недоступна'
                : (cameraLive ? 'Выключить камеру' : 'Включить камеру'),
            icon: watchingOnly
                ? Icons.videocam_off
                : (call.cameraOff ? Icons.videocam_off : Icons.videocam),
            color: watchingOnly ? Colors.red : null,
            onPressed: _cameraAvailable ? () => call.onToggleCamera() : null,
          ),
          // 4. Destructive leave, always the same slot (§10, §44).
          _btn(
            tooltip: _endTooltip,
            icon: Icons.call_end,
            color: Colors.red,
            onPressed: () => call.onHangup(),
          ),
          // 5. Full expand, always last (§11).
          _btn(
            tooltip: 'Развернуть звонок',
            icon: Icons.open_in_full,
            onPressed: () => call.onSetMinimized(false),
          ),
          const SizedBox(width: 4),
        ],
      ),
    );
  }
}
