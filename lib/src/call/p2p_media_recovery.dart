/// Stage 2C.2 — P2P media recovery controller.
///
/// WHAT THIS IS: a deterministic decision machine for what to do with a live
/// P2P call when its media path wobbles. It owns no PeerConnection, performs no
/// async work and never touches a timer: the caller feeds events and executes
/// the returned decision. That is what makes every rule below unit-testable
/// without WebRTC.
///
/// WHY IT EXISTS ALONGSIDE [ReconnectWatch]: ReconnectWatch treats `failed` and
/// `closed` identically and ends the call immediately (reconnect_watch.dart:
/// `case LinkState.failed: case LinkState.closed: _clear(); return
/// LinkVerdict.endNow;`). WebRTC semantics do not justify that: `failed` means
/// ICE could not find a working candidate pair *for this generation* and is
/// routinely repaired by an ICE restart on the SAME PeerConnection, with media
/// identity intact. Only `closed` — and only after teardown — is final.
///
/// RELATION TO [SignalRecovery]: no logic is duplicated. SignalRecovery owns the
/// SIGNALLING transport (resume the call on the server). This controller owns
/// MEDIA. They answer different questions and neither may end a call on behalf
/// of the other: a signaling resume refusal must never kill media, and a media
/// wobble must never trigger a signaling resume.
///
/// RELATION TO [PerfectNegotiation]: this controller DECIDES that an ICE restart
/// is due. The negotiation policy DECIDES how to carry it out without glare.
/// The two are deliberately separate: a wrong restart policy must not be able to
/// tear a call down, and a wrong recovery policy must not corrupt SDP.
///
/// SCOPE: pure policy only. It is not wired into CallState at this stage.
library;

/// Transport state as the CONTROLLER sees it. The driver maps native ICE states
/// onto this; event-backed nullable plugin fields are never trusted directly.
enum MediaLinkState {
  /// Startup / ICE checking. Explicitly NOT a failure: every call passes
  /// through it, and treating it as a failure killed calls before they connected.
  checking,

  connected,
  completed,
  disconnected,
  failed,

  /// Transport closed. Definitive once teardown has actually started.
  closed,
}

/// Lifecycle of the controller for one call.
enum RecoveryPhase {
  /// No call, or a call that is healthy.
  idle,

  /// Media is down; a bounded grace period is running.
  recovering,

  /// The grace period is over and an ICE restart has been requested.
  restarting,

  /// The call is over. Terminal until a NEW call is registered.
  ended,
}

/// What the driver must do. Decisions, never direct WebRTC calls.
enum RecoveryAction {
  /// Do nothing.
  keep,

  /// Media is down: show the reconnecting banner and start the grace period.
  showReconnecting,

  /// Media is back: hide the banner, cancel every recovery step.
  recovered,

  /// Perform an ICE restart on the existing PeerConnection now.
  requestIceRestart,

  /// Signaling is down but media is up: keep the call and wait for signaling.
  awaitSignaling,

  /// The event belongs to a call this controller no longer owns: ignore it.
  stale,

  /// End the call. [RecoveryAction.endCall] is the only terminal decision.
  endCall,
}

/// One decision plus the context a log needs.
class RecoveryDecision {
  const RecoveryDecision(this.action, this.phase, this.reason, {this.restartNumber});

  final RecoveryAction action;
  final RecoveryPhase phase;
  final String reason;

  /// 1-based number of the ICE restart being requested (null when not a restart).
  final int? restartNumber;

  @override
  String toString() =>
      'RecoveryDecision(${action.name}, ${phase.name}, $reason'
      '${restartNumber == null ? '' : ', restart#$restartNumber'})';
}

/// Stage 2C.2 recovery controller for one call at a time.
class P2PMediaRecovery {
  P2PMediaRecovery({
    this.grace = const Duration(seconds: 10),
    this.maxIceRestarts = 2,
    this.recoveryBudget = const Duration(seconds: 45),
  })  : assert(maxIceRestarts >= 0),
        assert(grace > Duration.zero),
        assert(recoveryBudget > Duration.zero);

  /// How long a transient loss may last before the call is escalated.
  final Duration grace;

  /// Hard wall-clock bound for ONE recovery session, measured from the first
  /// moment media was lost.
  ///
  /// WHY THIS IS NEEDED: bounding restarts alone is not a time bound. Each new
  /// grace starts at `now + grace`, and a grace that expires merely buys
  /// another restart, so total time could reach (maxIceRestarts + 1) * grace.
  /// Worse, an event-driven loop could keep re-entering recovery if the clock
  /// source were rewound. A single budget measured from the FIRST loss makes the
  /// whole session finite no matter how the events interleave.
  final Duration recoveryBudget;

  /// Hard bound: an outage may never become a restart storm. Two is not
  /// arbitrary - R5.4 proved one restart restores media on this runtime, so the
  /// second covers a restart that itself hit a transient loss; a third would
  /// mean the path is gone, not that we got unlucky.
  final int maxIceRestarts;

  String? _callId;
  int? _epoch;
  RecoveryPhase _phase = RecoveryPhase.idle;
  DateTime? _deadline;

  /// Wall-clock end of the whole recovery session, null while media is healthy.
  DateTime? _budgetEnd;
  int _restartsUsed = 0;
  bool _signalingDown = false;
  bool _mediaWasDown = false;

  /// Current lifecycle phase.
  RecoveryPhase get phase => _phase;

  /// True while the user should see «Переподключение…».
  bool get recovering =>
      _phase == RecoveryPhase.recovering || _phase == RecoveryPhase.restarting;

  /// Deadline of the current grace period, null when not recovering.
  DateTime? get deadline => _deadline;

  /// Wall-clock end of the current recovery session, null while healthy.
  DateTime? get recoveryDeadline => _budgetEnd;

  /// True when the wall-clock budget for this outage is spent.
  bool get recoveryBudgetSpent =>
      _budgetEnd != null && !_lastNow!.isBefore(_budgetEnd!);

  DateTime? _lastNow;

  /// Feeds the clock so the caller can query budget status between events.
  void observe(DateTime now) => _lastNow = now;

  /// Binds the REAL callId to a session that was already registered.
  ///
  /// WHY THIS EXISTS (§2C.4b): an outgoing call creates its transport before the
  /// server assigns a callId, so the controller is registered as
  /// `onCallChanged(callId: '', epoch: n)`. When the real id arrives, every ICE
  /// event carries it and [_isStale] rejects each one — recovery is dead for the
  /// whole call while the epoch happens to match.
  ///
  /// Re-registering through [onCallChanged] would be wrong: it resets phase,
  /// deadlines and the restart budget of a live session, so an outage would
  /// silently get a fresh allowance. This only fills in an EMPTY identity and
  /// never overwrites a real one, so the stale guards stay exactly as strong as
  /// before: a later event from another call is still stale.
  void bindCallId(String callId) {
    if (callId.isEmpty) return;
    if (_callId != null && _callId!.isNotEmpty) return;
    _callId = callId;
  }

  /// ICE restarts spent on the current outage.
  int get iceRestartsUsed => _restartsUsed;

  /// Restarts still available before the call must end.
  int get iceRestartsLeft => maxIceRestarts - _restartsUsed;

  /// True when signaling is currently considered down.
  bool get signalingDown => _signalingDown;

  /// The call this controller currently owns, if any.
  String? get callId => _callId;

  /// Registers a new call. Any previous recovery is discarded: a new call must
  /// never inherit the previous one's grace deadline or restart budget.
  void onCallChanged({required String callId, required int epoch}) {
    _callId = callId;
    _epoch = epoch;
    _phase = RecoveryPhase.idle;
    _deadline = null;
    _budgetEnd = null;
    _restartsUsed = 0;
    _signalingDown = false;
    _mediaWasDown = false;
  }

  /// The call ended (user hangup or server end). Terminal: every later event
  /// for this call is [RecoveryAction.stale], and a new call must register
  /// again through [onCallChanged].
  RecoveryDecision onCallEnded({required String reason}) {
    _phase = RecoveryPhase.ended;
    _clear();
    return RecoveryDecision(RecoveryAction.endCall, RecoveryPhase.ended, reason);
  }

  /// User hangup: highest priority. It wins over any running recovery and over
  /// a pending grace deadline, because the user asked for it explicitly.
  RecoveryDecision onUserHangup() =>
      onCallEnded(reason: 'user hangup takes priority over recovery');

  /// Feeds one media/ICE transport state.
  ///
  /// INVARIANT: a signaling outage alone never causes an ICE restart. Media and
  /// signaling are separate paths, and restarting ICE while media is healthy
  /// would renegotiate a perfectly good call.
  RecoveryDecision onIceState({
    required MediaLinkState state,
    required String callId,
    required int epoch,
    required DateTime now,
  }) {
    final stale = _isStale(callId, epoch);
    if (stale != null) return stale;
    if (_phase == RecoveryPhase.ended) {
      return RecoveryDecision(RecoveryAction.stale, _phase,
          'call already ended; ${state.name} ignored');
    }

    switch (state) {
      case MediaLinkState.checking:
        // Startup path of every call. Never a failure.
        return RecoveryDecision(RecoveryAction.keep, _phase, 'ICE checking');

      case MediaLinkState.connected:
      case MediaLinkState.completed:
        _mediaWasDown = false;
        if (_phase == RecoveryPhase.idle) {
          return RecoveryDecision(RecoveryAction.keep, _phase, 'media healthy');
        }
        // Recovery worked, whether it was the grace period or a restart.
        // P0 FIX: the restart budget belongs to ONE outage. A call that
        // recovered and later drops again must get a fresh allowance, otherwise
        // a long call would lose its second attempt after an unrelated blip.
        final spent = _restartsUsed;
        _restartsUsed = 0;
        _phase = RecoveryPhase.idle;
        _clear();
        return RecoveryDecision(RecoveryAction.recovered, RecoveryPhase.idle,
            'media restored after $spent restart(s); restart budget refreshed');

      case MediaLinkState.disconnected:
        return _enterRecovery(callId, epoch, now, state);

      case MediaLinkState.failed:
        // Unlike `closed`, a failed ICE generation is repairable in place.
        return _enterRecovery(callId, epoch, now, state);

      case MediaLinkState.closed:
        // Definitive: the transport is gone, there is nothing left to restart.
        _phase = RecoveryPhase.ended;
        _clear();
        return RecoveryDecision(RecoveryAction.endCall, RecoveryPhase.ended,
            'ICE closed is final after teardown');
    }
  }

  RecoveryDecision _enterRecovery(
      String callId, int epoch, DateTime now, MediaLinkState cause) {
    _callId = callId;
    _epoch = epoch;
    _mediaWasDown = true;
    if (_phase == RecoveryPhase.recovering) {
      // A repeated disconnect while already recovering must NOT extend the
      // deadline: otherwise a flapping link could hold the call open forever.
      return RecoveryDecision(RecoveryAction.keep, _phase,
          'already recovering ($cause); deadline not extended');
    }
    if (_phase == RecoveryPhase.restarting) {
      // A restart is in flight and the media is already failing again. Give the
      // next escalation its own grace period instead of absorbing the event:
      // absorbing it would leave the call in `restarting` FOREVER whenever the
      // driver never reports the restart outcome, which is a hang, not a policy.
      _phase = RecoveryPhase.recovering;
      _deadline = now.add(grace);
      return RecoveryDecision(RecoveryAction.showReconnecting, _phase,
          'media failed again after restart #${_restartsUsed - 1}; '
          'new grace until ${_deadline!.toIso8601String()}');
    }
    _phase = RecoveryPhase.recovering;
    _deadline = now.add(grace);
    // The wall-clock budget starts at the FIRST loss of this outage and is
    // never restarted, so repeated failures cannot extend it.
    _budgetEnd ??= now.add(recoveryBudget);
    _lastNow = now;
    return RecoveryDecision(RecoveryAction.showReconnecting, _phase,
        'media down ($cause); grace until ${_deadline!.toIso8601String()}, '
        'session budget until ${_budgetEnd!.toIso8601String()}');
  }

  /// Grace-period tick. Ends the call only when the deadline really expired for
  /// the call this controller owns; anything else is a no-op.
  RecoveryDecision onTick({
    required String callId,
    required int epoch,
    required DateTime now,
  }) {
    final stale = _isStale(callId, epoch);
    if (stale != null) return stale;
    if (_phase == RecoveryPhase.ended) {
      return RecoveryDecision(RecoveryAction.stale, _phase,
          'call already ended; tick ignored');
    }
    // P0 FIX: the wall-clock budget is checked FIRST and INDEPENDENTLY of the
    // local grace deadline. `restarting` has no grace deadline at all, so
    // checking the deadline first used to return `keep` forever and let the
    // budget silently never fire - a live hang when restartIce() never
    // produced an ICE Connected event.
    final budgetEnd = _budgetEnd;
    if (budgetEnd != null && !now.isBefore(budgetEnd)) {
      final wasIn = _phase.name;
      _phase = RecoveryPhase.ended;
      _clear();
      return RecoveryDecision(RecoveryAction.endCall, RecoveryPhase.ended,
          'recovery session budget of $recoveryBudget s exhausted '
          '(was in $wasIn, restarts=$_restartsUsed)');
    }
    final deadline = _deadline;
    if (deadline == null) {
      return RecoveryDecision(RecoveryAction.keep, _phase,
          'no grace deadline in phase ${_phase.name}; budget still running');
    }
    if (now.isBefore(deadline)) {
      return RecoveryDecision(RecoveryAction.keep, RecoveryPhase.recovering,
          'grace period still running');
    }
    // Grace expired: escalate to an ICE restart if the budget allows.
    if (_restartsUsed < maxIceRestarts) {
      // P0 FIX: an ICE restart is only executable if the SDP can actually be
      // sent. With signaling down the restart would fail immediately and burn
      // an attempt, so we wait instead - bounded by the SAME budget, which is
      // not extended by waiting.
      if (_signalingDown) {
        return RecoveryDecision(RecoveryAction.awaitSignaling, _phase,
            'grace expired but signaling is down: waiting to restart '
            '#${_restartsUsed + 1} (budget ends ${budgetEnd?.toIso8601String()})');
      }
      _restartsUsed++;
      _phase = RecoveryPhase.restarting;
      _deadline = null;
      return RecoveryDecision(
          RecoveryAction.requestIceRestart,
          _phase,
          'grace expired; restart $_restartsUsed/$maxIceRestarts',
          restartNumber: _restartsUsed);
    }
    _phase = RecoveryPhase.ended;
    _clear();
    return RecoveryDecision(RecoveryAction.endCall, RecoveryPhase.ended,
        'recovery budget exhausted after $_restartsUsed restart(s)');
  }

  /// The driver reports that it performed the requested ICE restart.
  ///
  /// A restart that was never requested, or one requested for an older outage,
  /// is ignored: this is the stale-async guard that keeps a late restart from
  /// renegotiating a call that has already recovered.
  RecoveryDecision onIceRestartCompleted({
    required int restartNumber,
    required String callId,
    required int epoch,
    required bool succeeded,
  }) {
    final stale = _isStale(callId, epoch);
    if (stale != null) return stale;
    if (_phase != RecoveryPhase.restarting) {
      return RecoveryDecision(RecoveryAction.stale, _phase,
          'restart #$restartNumber is not expected (phase=${_phase.name})');
    }
    if (restartNumber != _restartsUsed) {
      return RecoveryDecision(RecoveryAction.stale, _phase,
          'restart #$restartNumber != outstanding #$_restartsUsed');
    }
    if (succeeded) {
      // Success is only believed once the transport says so; until then the
      // call stays in `restarting` and a later ICE event completes it.
      return RecoveryDecision(RecoveryAction.keep, _phase,
          'restart #$restartNumber applied; awaiting transport confirmation');
    }
    // Restart failed: end immediately rather than burning another restart in
    // the same outage - the driver has already proven the restart was useless.
    _phase = RecoveryPhase.ended;
    _clear();
    return RecoveryDecision(RecoveryAction.endCall, RecoveryPhase.ended,
        'ICE restart #$restartNumber failed');
  }

  /// Feeds signaling transport availability.
  RecoveryDecision onSignaling({
    required bool up,
    required String callId,
    required int epoch,
    required DateTime now,
  }) {
    final stale = _isStale(callId, epoch);
    if (stale != null) return stale;
    if (_phase == RecoveryPhase.ended) {
      return RecoveryDecision(RecoveryAction.stale, _phase,
          'call already ended; signaling ${up ? 'up' : 'down'} ignored');
    }
    _signalingDown = !up;
    if (up) {
      return const RecoveryDecision(RecoveryAction.keep, RecoveryPhase.idle,
          'signaling restored; media lifecycle is untouched');
    }
    // INVARIANT: signaling down while media is healthy must not restart ICE and
    // must not start a media grace period. SignalRecovery owns the resume.
    if (!_mediaWasDown && _phase == RecoveryPhase.idle) {
      return const RecoveryDecision(RecoveryAction.awaitSignaling,
          RecoveryPhase.idle,
          'signaling lost but media healthy: wait for resume, do not restart ICE');
    }
    return RecoveryDecision(RecoveryAction.keep, _phase,
        'signaling lost while media already recovering: handled by media recovery');
  }

  /// Returns a stale decision when the event belongs to another call/session.
  RecoveryDecision? _isStale(String callId, int epoch) {
    if (_callId == null) {
      // No call was ever registered. P1 FIX: do NOT adopt the callId from a
      // stray event - that would let any late callback (from a finished call,
      // or from a signal that never belonged to a live session) take ownership
      // of the controller and start a recovery for a call that does not exist.
      return RecoveryDecision(RecoveryAction.stale, _phase,
          'event for $callId/$epoch before any call was registered: ignored');
    }
    if (callId != _callId || epoch != _epoch) {
      return RecoveryDecision(RecoveryAction.stale, _phase,
          'event for $callId/$epoch, controller owns $_callId/$_epoch');
    }
    return null;
  }

  void _clear() {
    _deadline = null;
    _budgetEnd = null;
    _mediaWasDown = false;
  }
}