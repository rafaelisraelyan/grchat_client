// Link-loss state machine for a live call (§reconnect, 2026-10-14).
//
// WHY: a transient ICE `disconnected` used to be able to tear a call down
// within milliseconds (measured: 21 ms after the event the session was
// already being cleaned up), while nothing logged WHY. For a product this
// is unacceptable - a two-second network wobble must not kill a call.
//
// Semantics (owner-confirmed):
//   connected    -> cancel the grace period, back to active, SAME session
//                   (the call is never re-created, the call timer is never
//                   reset, media identity is preserved);
//   disconnected -> enter reconnecting, UI says «Переподключение…», grace
//                   period up to 10 s;
//   failed/closed-> definitive per WebRTC semantics: end right away, no
//                   artificial waiting;
//   grace expired-> end cleanly with a reason.
//
// The grace period is SCOPED to (epoch, callId): a timer that outlives its
// call can never finish a DIFFERENT call - that is the stale-callback class
// of bug this machine exists to prevent.
//
// Pure and clock-injected: no PeerConnection, no timers, fully testable.
enum LinkState {
  /// Transport is up.
  connected,

  /// Normal startup / ICE checking phase. NOT a failure: answering a call
  /// passes through Connecting before Connected, and treating it as one
  /// killed the call 14 ms before it connected (2026-10-14).
  connecting,

  /// Transient loss: grace period (§reconnect).
  disconnected,

  /// Definitive failure.
  failed,

  /// The transport is closed - definitive.
  closed,
}

/// What the caller must do after feeding the machine.
enum LinkVerdict {
  /// Nothing to do (state unchanged, or an event for a call that is gone).
  none,

  /// Transient loss: show reconnecting, start the grace timer.
  enterReconnecting,

  /// Connection is back: drop the banner, cancel the timer.
  recovered,

  /// Definitive end: the grace period expired or the link failed.
  endNow,

  /// The event belongs to a call/session that is no longer current - ignore
  /// it completely (never let a stale callback touch the live call).
  stale,
}

class ReconnectWatch {
  ReconnectWatch({this.grace = const Duration(seconds: 10)});

  /// How long a transient loss may last before the call is ended.
  final Duration grace;

  String? _callId;
  int? _epoch;
  DateTime? _deadline;

  /// True while the grace period is running (the UI banner).
  bool get reconnecting => _deadline != null;

  /// Deadline of the current grace period (null when healthy).
  DateTime? get deadline => _deadline;

  /// Feeds one transport state event.
  LinkVerdict onState({
    required LinkState state,
    required int epoch,
    required String callId,
    required DateTime now,
  }) {
    if (_epoch != null && (epoch != _epoch || callId != _callId)) {
      // A new call already replaced ours: never apply the old call's events.
      return LinkVerdict.stale;
    }
    switch (state) {
      case LinkState.connecting:
        // Startup / ICE checking: the normal path of every call. Never a
        // failure, never a grace period - answering produced Connecting
        // 14 ms before Connected and the call was torn down in between.
        return LinkVerdict.none;
      case LinkState.connected:
        final wasReconnecting = _deadline != null;
        _clear();
        return wasReconnecting ? LinkVerdict.recovered : LinkVerdict.none;
      case LinkState.disconnected:
        if (_deadline != null) return LinkVerdict.none;
        _epoch = epoch;
        _callId = callId;
        _deadline = now.add(grace);
        return LinkVerdict.enterReconnecting;
      case LinkState.failed:
      case LinkState.closed:
        _clear();
        return LinkVerdict.endNow;
    }
  }

  /// Timer tick: ends the call only when the grace period really expired for
  /// the CURRENT call. A tick from a finished call is reported as
  /// [LinkVerdict.stale] and changes NOTHING - not even the live call's
  /// deadline (clearing it would silently cancel the new call's protection).
  LinkVerdict onTick({
    required int epoch,
    required String callId,
    required DateTime now,
  }) {
    if (_deadline == null) return LinkVerdict.none;
    if (_epoch != null && (epoch != _epoch || callId != _callId)) {
      return LinkVerdict.stale;
    }
    if (now.isBefore(_deadline!)) return LinkVerdict.none;
    _clear();
    return LinkVerdict.endNow;
  }

  /// Call/session teardown: forget everything.
  void reset() => _clear();

  void _clear() {
    _deadline = null;
    _callId = null;
    _epoch = null;
  }
}