import '../transport/grchat_connection.dart';
import 'call_api.dart';

/// Outcome of one signaling-recovery attempt.
enum SignalRecoveryOutcome {
  /// Nothing happened (status did not change, or no work was due).
  none,

  /// There is no local call to resume.
  noCall,

  /// The server confirmed the call: keep it exactly as it is.
  resumed,

  /// The server does not hand this call back (ended, or not ours).
  refused,

  /// Recovery itself could not be performed (transport error).
  failed,
}

/// Stage 2B: reconciles the signaling transport with a live P2P call.
///
/// Deliberately a separate, small, fully injectable unit instead of more state
/// inside CallState: the rules that matter ("never retry in a loop", "never
/// resurrect an ended call", "one attempt per outage") are pure decisions and
/// must be testable without a PeerConnection.
///
/// IMPORTANT policy: a refusal NEVER ends the call. The server can refuse a
/// resume for reasons that have nothing to do with media (the call was
/// declined elsewhere, the snapshot raced an end). Media ownership stays with
/// the ICE machine in [CallState], which knows whether audio/video actually
/// stopped. Killing a call here would reintroduce exactly the bug Stage 2A
/// removed on the other side of the wire.
class SignalRecovery {
  SignalRecovery({
    required this.resume,
    this.reconciler = const ResumeReconciler(),
    this.maxAttemptsPerOutage = 3,
  });

  /// Injected transport call. Returns the authoritative snapshot, or null when
  /// the server refused.
  final Future<CallSnapshot?> Function(String callId) resume;
  final ResumeReconciler reconciler;

  /// Hard bound: an outage may never turn into a retry storm.
  final int maxAttemptsPerOutage;

  bool _down = false;
  int _attempts = 0;
  bool _busy = false;

  /// True while the signaling transport is considered down.
  bool get signalingDown => _down;

  /// Attempts spent on the current outage (diagnostics + loop guard).
  int get attempts => _attempts;

  /// Call lifecycle boundary: a new call must not inherit the previous
  /// outage's "was down" flag, or it would try to resume immediately.
  void reset() {
    _down = false;
    _attempts = 0;
  }

  /// Feeds one transport status. [callId] is the CURRENT local call, or null
  /// when there is none; [localEnded] is true once that call has been torn
  /// down; [localRecoveryEpoch] is the newest epoch already applied locally.
  Future<SignalRecoveryOutcome> onStatus(
    ConnStatus status, {
    required String? callId,
    required bool localEnded,
    required int localRecoveryEpoch,
  }) async {
    if (status != ConnStatus.connected) {
      // connecting/offline opens (or keeps open) an outage window.
      _down = true;
      return SignalRecoveryOutcome.none;
    }

    if (!_down) return SignalRecoveryOutcome.none; // was already up
    _down = false;

    if (callId == null) return SignalRecoveryOutcome.noCall;
    // Already torn down locally: never even offer it to the server. A resume
    // for a finished call is at best wasted and at worst looks like a session
    // reaching for a call it no longer has.
    if (localEnded) return SignalRecoveryOutcome.refused;
    if (_busy) return SignalRecoveryOutcome.none; // never two attempts at once
    if (_attempts >= maxAttemptsPerOutage) {
      _attempts++;
      return SignalRecoveryOutcome.failed;
    }
    _attempts++;
    _busy = true;
    CallSnapshot? snapshot;
    try {
      snapshot = await resume(callId);
    } catch (_) {
      // Transport hiccup during recovery: leave the call to the ICE machine.
      return SignalRecoveryOutcome.failed;
    } finally {
      _busy = false;
    }

    // No snapshot means the server did not hand this call back. That is a
    // refusal (ended meanwhile, or not ours) - reported, never retried, and
    // never treated as a reason to end media that may still be flowing.
    if (snapshot == null) return SignalRecoveryOutcome.refused;

    final verdict = reconciler.decide(
      localCallId: callId,
      localEnded: localEnded,
      localRecoveryEpoch: localRecoveryEpoch,
      snapshot: snapshot,
    );
    switch (verdict) {
      case ResumeOutcome.noCall:
        return SignalRecoveryOutcome.noCall;
      case ResumeOutcome.keep:
        return SignalRecoveryOutcome.resumed;
      case ResumeOutcome.refuse:
        return SignalRecoveryOutcome.refused;
    }
  }
}
