/// Stage 2C / R5 - Perfect Negotiation policy.
///
/// WHAT THIS IS: a pure decision machine. It owns no PeerConnection, touches no
/// transport and performs no async work. The driver (CallState today, the
/// native harness tomorrow) asks "what should I do with this description or
/// candidate?" and then does exactly that. Everything that can be got wrong -
/// who yields, what is stale, what belongs to a rejected generation - is a
/// plain function of the inputs and therefore unit-testable without WebRTC.
///
/// WHY IT EXISTS: the current signaling path cannot survive an offer collision.
/// Both peers call createOffer + setLocalDescription and land in
/// `have-local-offer`; each then tries setRemoteDescription on the peer's offer
/// and the native stack refuses it with `Called in wrong state:
/// have-local-offer`. Today that refusal is swallowed by a try/catch, so BOTH
/// users see "не получилось включить камеру" and then sit out a 15 s answer
/// timeout. Perfect negotiation replaces that with a deterministic winner.
///
/// ROLE ASSIGNMENT (stable, complementary, no protocol change):
/// `polite = localEndpointKey > remoteEndpointKey` (lexicographic). Exactly one
/// side is polite, both sides compute the same answer independently, and the
/// assignment cannot flip during a call. The server already forwards
/// `from_id` on every `call_renegotiate` push, so the remote user id is
/// available today; pass a finer endpoint key if multi-device support is added
/// later - the policy does not care what the key contains.
///
/// Note on rollback: native rollback was verified functionally on this stack
/// (accepted in `have-local-offer`, rejected in `stable` as
/// `Called in wrong signalingState: stable`), so `rollbackThenAcceptOffer` is
/// a real operation here, not a theory.
library;

/// Signaling state, as seen by the POLICY. The driver reports the native
/// value; the policy never reads it from the PeerConnection itself.
enum PnSignalingState {
  stable,
  haveLocalOffer,
  haveRemoteOffer,
  haveLocalPranswer,
  haveRemotePranswer,
  closed,
}

/// The four description types that can travel on the wire.
enum PnDescriptionType { offer, answer, pranswer, rollback }

/// What the driver must do. Deliberately small: one enum, no side effects.
enum PnAction {
  /// Nothing to do.
  none,

  /// A conflicting offer was rejected. Its ICE candidates must be dropped too.
  ignoreCollidingOffer,

  /// Roll the local offer back, then apply the incoming one. Polite side only.
  rollbackThenAcceptOffer,

  /// Apply the incoming offer and answer it.
  acceptOffer,

  /// Apply the answer to our own outstanding offer.
  acceptAnswer,

  /// An answer for an offer we are not waiting for. Applying it would corrupt
  /// the current negotiation.
  ignoreStaleAnswer,

  /// A candidate belonging to a generation we rejected.
  ignoreStaleCandidate,
}

/// One policy decision plus the context a driver (and a log) needs.
class PnDecision {
  const PnDecision(this.action, this.generation, this.reason);

  final PnAction action;
  final int generation;
  final String reason;

  /// Convenience for the very common "nothing happened" case.
  static const PnDecision none =
      PnDecision(PnAction.none, -1, 'no action required');

  @override
  String toString() => 'PnDecision(${action.name}, gen=$generation, $reason)';
}

/// Extracts the first ICE ufrag from an SDP, or null when there is none.
/// Candidates are tagged with the ufrag of the description that produced them,
/// which is how a rejected generation's candidates are recognised.
String? iceUfragOf(String? sdp) {
  if (sdp == null) return null;
  final m = RegExp(r'a=ice-ufrag:(\S+)').firstMatch(sdp);
  return m?.group(1);
}

/// Stage 2C/R5 negotiation policy for one direction of one call.
class PerfectNegotiation {
  PerfectNegotiation({
    required String localEndpointKey,
    required String remoteEndpointKey,
  })  : assert(localEndpointKey != remoteEndpointKey,
            'a call cannot have one endpoint on both sides'),
        polite = localEndpointKey.compareTo(remoteEndpointKey) > 0;

  /// True for exactly one of the two peers; the polite peer yields.
  final bool polite;

  /// Set while createOffer + setLocalDescription + send is in flight.
  bool _makingOffer = false;

  /// Monotonic negotiation counter. Bumped when a local offer starts and when
  /// a remote offer is accepted. Diagnostics and stale-answer detection.
  int _generation = 0;

  /// Generation of the offer we sent and are waiting for an answer to, or null.
  int? _pendingLocalOffer;

  /// ufrags of descriptions we rejected. Candidates carrying them are dropped.
  final Set<String> _rejectedUfrags = <String>{};

  /// Latest ufrag we accepted FROM the peer, used to sanity-check answers.
  String? _acceptedRemoteUfrag;

  /// True while createOffer + setLocalDescription + send is in flight.
  bool get makingOffer => _makingOffer;

  /// Current negotiation generation.
  int get generation => _generation;

  /// Generation of the outstanding local offer, or null when none is awaited.
  int? get pendingLocalOffer => _pendingLocalOffer;

  /// Last ufrag we accepted FROM the peer. Diagnostic only: it must never decide
/// whether an answer is stale, because the peer restarts its ICE freely.
String? get lastAcceptedRemoteUfrag => _acceptedRemoteUfrag;

  /// Rejected-generation ufrags currently being filtered.
  Set<String> get rejectedUfrags => Set.unmodifiable(_rejectedUfrags);

  /// A new call must not inherit the previous negotiation's state, or a stale
  /// "awaiting answer" would reject the first real answer of the new call.
  void reset() {
    _makingOffer = false;
    _generation = 0;
    _pendingLocalOffer = null;
    _rejectedUfrags.clear();
    _acceptedRemoteUfrag = null;
  }

  /// The driver is about to create and send a local offer.
  ///
  /// Returns `ignoreRequest` semantics through [PnAction.none] with a reason
  /// when a negotiation is already in flight: this endpoint must not stack a
  /// second offer on top of an unanswered one, or it manufactures a collision
  /// of its own making.
  PnDecision beginLocalOffer() {
    if (_makingOffer) {
      return const PnDecision(PnAction.none, -1,
          'local offer already in flight');
    }
    if (_pendingLocalOffer != null) {
      return const PnDecision(PnAction.none, -1,
          'awaiting an answer to a previous local offer');
    }
    _makingOffer = true;
    _generation++;
    _pendingLocalOffer = _generation;
    return PnDecision(PnAction.none, _generation, 'local offer started');
  }

  /// The driver finished createOffer + setLocalDescription + send.
  void endLocalOffer() => _makingOffer = false;

  /// A remote description arrived.
  ///
  /// Implements the collision rules of perfect negotiation:
  ///   readyForOffer   = !makingOffer && signalingState == stable
  ///   offerCollision  = type == offer && !readyForOffer
  ///   ignoreOffer     = offerCollision && !polite
  /// polite collision -> rollback, then accept. impolite collision -> ignore,
  /// and remember the rejected ufrag so its candidates are dropped too.
  PnDecision onRemoteDescription({
    required PnDescriptionType type,
    required PnSignalingState signalingState,
    String? sdp,
  }) {
    if (signalingState == PnSignalingState.closed) {
      return const PnDecision(PnAction.none, -1,
          'signaling closed: no renegotiation is possible');
    }

    switch (type) {
      case PnDescriptionType.offer:
        return _onRemoteOffer(sdp, signalingState);
      case PnDescriptionType.answer:
        return _onRemoteAnswer(sdp);
      case PnDescriptionType.pranswer:
      case PnDescriptionType.rollback:
        // pranswer/rollback are never exchanged by GRChat signaling; treating
        // them as an error is safer than silently accepting a state change.
        return const PnDecision(PnAction.ignoreStaleAnswer, -1,
            'pranswer/rollback are not part of the GRChat signaling protocol');
    }
  }

  PnDecision _onRemoteOffer(String? sdp, PnSignalingState signalingState) {
    final readyForOffer =
        !_makingOffer && signalingState == PnSignalingState.stable;
    final collision = !readyForOffer;
    final ufrag = iceUfragOf(sdp);

    if (!collision) {
      _makingOffer = false;
      _pendingLocalOffer = null;
      _generation++;
      if (ufrag != null) _acceptedRemoteUfrag = ufrag;
      return PnDecision(PnAction.acceptOffer, _generation,
          'clean offer accepted (signalingState=$signalingState)');
    }

    // --- collision ---
    if (!polite) {
      // We win: our own offer stands. Remember the generation we refused so
      // its candidates are not fed into the negotiation we are keeping.
      _makingOffer = false;
      if (ufrag != null) _rejectedUfrags.add(ufrag);
      return PnDecision(PnAction.ignoreCollidingOffer, _generation,
          'impolite: refusing colliding offer (state=$signalingState'
          '${_makingOffer ? ', makingOffer' : ''})');
    }

    // Polite: yield. Our own outstanding offer is abandoned, so we must stop
    // waiting for an answer to it - otherwise a late answer would be applied to
    // the negotiation that replaced it.
    if (signalingState != PnSignalingState.haveLocalOffer &&
        signalingState != PnSignalingState.haveLocalPranswer) {
      // Collision without a local offer of ours: there is nothing to roll back,
      // so accepting directly is both safe and correct.
      _makingOffer = false;
      _pendingLocalOffer = null;
      _generation++;
      if (ufrag != null) _acceptedRemoteUfrag = ufrag;
      return PnDecision(PnAction.acceptOffer, _generation,
          'polite: no local offer to roll back, accepting');
    }
    _makingOffer = false;
    _pendingLocalOffer = null;
    _generation++;
    if (ufrag != null) _acceptedRemoteUfrag = ufrag;
    return PnDecision(PnAction.rollbackThenAcceptOffer, _generation,
        'polite: rolling back local offer for the peer\'s');
  }

  PnDecision _onRemoteAnswer(String? sdp) {
    if (_pendingLocalOffer == null) {
      // Either a duplicate delivery, or the answer to an offer we already
      // abandoned during a collision. Applying it would apply an answer to a
      // negotiation that no longer exists.
      return PnDecision(PnAction.ignoreStaleAnswer, _generation,
          'answer with no outstanding local offer');
    }
    final ufrag = iceUfragOf(sdp);
    // An answer's ICE ufrag belongs to the ANSWERER and legitimately changes
    // whenever the peer restarts its own ICE - which it may do at any time,
    // including in reply to our own restart. Rejecting an answer because its
    // ufrag differs from the last accepted offer is therefore UNSOUND and would
    // silently drop valid answers. Staleness is decided by the outstanding
    // offer above, not by ICE credentials.
    final gen = _pendingLocalOffer!;
    _pendingLocalOffer = null;
    _makingOffer = false;
    return PnDecision(PnAction.acceptAnswer, gen,
        'answer to our offer (peer ufrag=$ufrag, accepted regardless of ufrag)');
  }


  /// A remote ICE candidate arrived.
  ///
  /// A candidate is dropped ONLY when it belongs to a description we actually
  /// rejected. Candidates are never dropped merely because a glare happened at
  /// some point, and candidates with an unknown ufrag are accepted: the peer
  /// may legitimately send them before its description reaches us.
  PnDecision onRemoteCandidate({required String? ufrag}) {
    if (ufrag != null && _rejectedUfrags.contains(ufrag)) {
      return PnDecision(PnAction.ignoreStaleCandidate, _generation,
          'candidate belongs to rejected generation $ufrag');
    }
    return PnDecision(PnAction.none, _generation,
        ufrag == null ? 'candidate accepted (no ufrag in sdp)' : 'candidate accepted');
  }
}
