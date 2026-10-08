import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../voice/voice_state.dart';
import '../widgets/toast.dart';
import 'call_diagnostics.dart';
import 'call_state.dart';
import 'group_call.dart';

/// Media session kinds behind the single-realtime-session invariant.
enum MediaSessionKind { direct, group, voice }

/// One live media occupancy: an active transport or an unaccepted incoming
/// (which holds no media but blocks a second pending, §16).
class MediaSession {
  const MediaSession(
      {required this.id,
      required this.kind,
      required this.label,
      required this.video,
      required this.outgoing,
      this.pending = false});
  final String id;
  final MediaSessionKind kind;

  /// Human label for confirmations: peer nick, group title or «channel».
  final String label;
  final bool video;
  final bool outgoing;

  /// Unaccepted incoming: no media yet (dry ring), but a slot is reserved.
  final bool pending;
}

/// What asking for a new session yields (§43: every entry point gates here).
enum SessionRequest {
  /// Nothing live: start right away.
  free,

  /// Something live: confirm with the user, then [MediaCoordinator.switchStart].
  confirm,

  /// A switch is already running: reject, never queue (§15).
  busy,
}

enum SwitchResult { switched, busy, aborted, failed }

/// Global media session coordinator: the single source of truth behind
/// ACTIVE_MEDIA_SESSIONS <= 1 (§1, §4, §40).
///
/// The transport controllers (P2P flutter_webrtc, LiveKit group/voice)
/// keep owning their connections; the coordinator alone decides whether a
/// transport may start, and performs atomic session switches: end the old
/// session (with a timeout fallback, §24) before the new one starts (§3).
/// UI works primarily against this, not the engines directly.
class MediaCoordinator extends Notifier<bool> {
  /// Graceful old-session end before forcing the new one (§24).
  /// Mutable so tests can shrink it; production keeps 5s.
  Duration endTimeout = const Duration(seconds: 5);

  @override
  bool build() => false;

  bool get switching => state;

  /// Live media right now (pending incomings excluded: dry ring holds no
  /// microphone/camera). Null = free.
  MediaSession? activeMedia() {
    var count = 0;
    MediaSession? first;
    void consider(MediaSession? s) {
      if (s == null || s.pending) return;
      count++;
      first ??= s;
    }

    consider(_directSession());
    consider(_groupSession());
    consider(_voiceSession());
    assert(count <= 1, 'two live media sessions');
    if (count > 1) {
      dlog('MEDIA INVARIANT VIOLATED: $count live sessions, keeping first');
    }
    return first;
  }

  /// Unaccepted incomings (dry: no media, but one is enough — §16).
  List<MediaSession> pendings() {
    final out = <MediaSession>[];
    final d = _directSession();
    if (d != null && d.pending) out.add(d);
    final g = _groupSession();
    if (g != null && g.pending) out.add(g);
    return out;
  }

  bool hasPendingIncoming() => pendings().isNotEmpty;

  /// Gate every media start here (§43).
  SessionRequest requestSlot(String what) {
    dlog('MEDIA SESSION REQUEST $what');
    if (switching) {
      dlog('MEDIA CONFLICT $what: switch already running');
      return SessionRequest.busy;
    }
    final cur = activeMedia();
    if (cur != null) {
      dlog('MEDIA ACTIVE SESSION ${cur.kind} ${cur.id}');
      return SessionRequest.confirm;
    }
    if (hasPendingIncoming()) {
      dlog('MEDIA PENDING INCOMING blocks $what');
      return SessionRequest.confirm;
    }
    return SessionRequest.free;
  }

  /// Human line about what is live now, for confirm dialogs (§30–§34).
  String describeCurrent() {
    final a = activeMedia();
    if (a != null) {
      return switch (a.kind) {
        MediaSessionKind.voice => 'голосовой канал ${a.label}',
        MediaSessionKind.direct =>
          a.outgoing ? 'звонок: ${a.label}' : 'разговор с ${a.label}',
        MediaSessionKind.group => 'групповой звонок ${a.label}',
      };
    }
    if (hasPendingIncoming()) return 'входящий звонок';
    return 'другой разговор';
  }

  /// Warning detail for an incoming window over a live session (§31–§33).
  /// Null = nothing else live, plain accept.
  String? switchWarningFor(MediaSessionKind incomingKind) {
    // The incoming kind itself never counts: its engine holds at most the
    // ringing pending, and a second pending is declined at the door (§16).
    final a = activeMedia();
    if (a == null) return null;
    return switch (a.kind) {
      MediaSessionKind.voice =>
        'Вы сейчас в голосовом канале ${a.label}.',
      MediaSessionKind.direct => 'Вы разговариваете с ${a.label}.',
      MediaSessionKind.group =>
        'Вы участвуете в групповом звонке ${a.label}.',
    };
  }

  /// Accept an incoming call as one atomic switch (§3): end everything
  /// else first, then accept. Never two actives, never auto-resurrect (§35).
  Future<SwitchResult> acceptIncoming(
      {required MediaSessionKind kind, required String pendingId}) async {
    dlog('MEDIA SWITCH REQUEST accept $kind $pendingId');
    if (switching) {
      dlog('MEDIA CONFLICT accept $kind: switch already running');
      return SwitchResult.busy;
    }
    state = true;
    try {
      await endOthers(exceptKind: kind, exceptId: pendingId);
      // §37: the caller may have hung up while we were ending the old one.
      final stillThere = kind == MediaSessionKind.direct
          ? _directPending(pendingId)
          : _groupPending(pendingId);
      if (!stillThere) {
        dlog('MEDIA SWITCH ABORTED $pendingId: caller hung up');
        ref.read(callNoticeProvider.notifier).show(
            'Звонок завершён вызывающим');
        return SwitchResult.aborted;
      }
      dlog('MEDIA NEW SESSION START $kind $pendingId');
      if (kind == MediaSessionKind.direct) {
        await ref.read(callStateProvider.notifier).acceptIncoming();
      } else {
        await ref.read(groupCallProvider.notifier).acceptIncoming();
      }
      dlog('MEDIA NEW SESSION ACTIVE $kind $pendingId');
      return SwitchResult.switched;
    } catch (e) {
      dlog('MEDIA SWITCH FAILED $kind $pendingId: $e');
      ref.read(callNoticeProvider.notifier).show(kind ==
              MediaSessionKind.direct
          ? friendlyCallError(e)
          : friendlyGroupError(e));
      return SwitchResult.failed;
    } finally {
      state = false;
    }
  }

  /// Start an outgoing/join flow after the user confirmed (§10, §13, §17).
  /// When nothing is live this just runs the start (no veil, no switch).
  Future<SwitchResult> switchStart(
      Future<void> Function() start, String label) async {
    dlog('MEDIA SWITCH REQUEST start $label');
    if (switching) {
      dlog('MEDIA CONFLICT start $label: switch already running');
      return SwitchResult.busy;
    }
    if (activeMedia() == null && !hasPendingIncoming()) {
      try {
        await start();
        dlog('MEDIA NEW SESSION ACTIVE (free) $label');
        return SwitchResult.switched;
      } catch (e) {
        dlog('MEDIA START FAILED (free) $label: $e');
        rethrow;
      }
    }
    state = true;
    try {
      await endOthers();
      dlog('MEDIA NEW SESSION START $label');
      await start();
      dlog('MEDIA NEW SESSION ACTIVE $label');
      return SwitchResult.switched;
    } catch (e) {
      // The old session is gone and stays gone (§35): report, no undead.
      dlog('MEDIA SWITCH FAILED $label: $e');
      rethrow;
    } finally {
      state = false;
    }
  }

  /// End everything except the accepted pending (see [endAll] on the
  /// engines). Idempotent (§38), each engine timeout-guarded (§24).
  Future<void> endOthers(
      {MediaSessionKind? exceptKind, String? exceptId}) async {
    Future<void> guarded(Future<void> end, String who) async {
      try {
        await end.timeout(endTimeout);
        dlog('MEDIA OLD SESSION ENDED $who');
      } on TimeoutException {
        dlog('MEDIA OLD SESSION END TIMEOUT $who: forced proceed');
      } catch (e) {
        dlog('MEDIA OLD SESSION END ERROR $who: $e');
      }
    }

    dlog('MEDIA OLD SESSION END START'
        '${exceptId == null ? '' : ' except $exceptId'}');
    await guarded(
        ref.read(callStateProvider.notifier).endAll(
            exceptPendingId: exceptKind == MediaSessionKind.direct
                ? exceptId
                : null),
        'direct');
    await guarded(
        ref.read(groupCallProvider.notifier).endAll(
            exceptPendingId:
                exceptKind == MediaSessionKind.group ? exceptId : null),
        'group');
    await guarded(
        ref.read(voiceSessionProvider.notifier).leave(), 'voice');
  }

  MediaSession? _directSession() {
    final c = ref.read(callStateProvider);
    if (c == null) return null;
    final pending = !c.outgoing && c.phase == CallPhase.ringing;
    return MediaSession(
        id: c.callId,
        kind: MediaSessionKind.direct,
        label: c.peerNick,
        video: c.video,
        outgoing: c.outgoing,
        pending: pending);
  }

  MediaSession? _groupSession() {
    final c = ref.read(groupCallProvider);
    if (c == null) return null;
    final pending = !c.outgoing && c.phase == GroupPhase.ringing;
    return MediaSession(
        id: c.callId ?? 'group:${c.dmId}',
        kind: MediaSessionKind.group,
        label: '«${c.title}»',
        video: c.video,
        outgoing: c.outgoing,
        pending: pending);
  }

  MediaSession? _voiceSession() {
    final v = ref.read(voiceSessionProvider);
    if (v == null) return null;
    return MediaSession(
        id: 'voice:${v.channelId}',
        kind: MediaSessionKind.voice,
        label: '«${v.title}»',
        video: false,
        outgoing: false);
  }

  bool _directPending(String id) {
    final c = ref.read(callStateProvider);
    return c != null &&
        !c.outgoing &&
        c.phase == CallPhase.ringing &&
        c.callId == id;
  }

  bool _groupPending(String id) {
    final c = ref.read(groupCallProvider);
    return c != null &&
        !c.outgoing &&
        c.phase == GroupPhase.ringing &&
        c.callId == id;
  }
}

final mediaCoordinatorProvider =
    NotifierProvider<MediaCoordinator, bool>(MediaCoordinator.new);

/// Gate a user-initiated media start (§43): free → true; switching → toast
/// + false; live session → confirm dialog → true only when the user accepts
/// ending it. The caller then runs `coordinator.switchStart(start, label)`
/// inside its own try/catch (engine-specific error copy stays at the site).
Future<bool> ensureMediaSlot(BuildContext context, WidgetRef ref,
    {required String title, required String action}) async {
  final coord = ref.read(mediaCoordinatorProvider.notifier);
  switch (coord.requestSlot(title)) {
    case SessionRequest.free:
      return true;
    case SessionRequest.busy:
      if (context.mounted) {
        Toast.show(context, 'Дождитесь переключения звонка');
      }
      return false;
    case SessionRequest.confirm:
      if (!context.mounted) return false;
      final go = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
                title: Text(title,
                    maxLines: 2, overflow: TextOverflow.ellipsis),
                content: Text(
                    'Текущий ${coord.describeCurrent()} будет завершён.'),
                actions: [
                  TextButton(
                      onPressed: () => Navigator.pop(ctx, false),
                      child: const Text('Отмена')),
                  FilledButton(
                      onPressed: () => Navigator.pop(ctx, true),
                      child: Text('Завершить и $action')),
                ],
              ));
      return go ?? false;
  }
}

/// One-line media start for UI entry points (§43): gates through
/// [ensureMediaSlot], runs [MediaCoordinator.switchStart], toasts busy and
/// maps engine errors. Returns true when the start actually ran.
Future<bool> runMediaStart(BuildContext context, WidgetRef ref,
    {required String title,
    required String action,
    required Future<void> Function() start,
    required String label,
    required String Function(Object) friendlyError}) async {
  try {
    final ok = await ensureMediaSlot(context, ref,
        title: title, action: action);
    if (!ok) return false;
    final r = await ref
        .read(mediaCoordinatorProvider.notifier)
        .switchStart(start, label);
    if (r == SwitchResult.busy && context.mounted) {
      Toast.show(context, 'Дождитесь переключения звонка');
      return false;
    }
    return true;
  } catch (e) {
    if (context.mounted) Toast.show(context, friendlyError(e));
    return false;
  }
}
