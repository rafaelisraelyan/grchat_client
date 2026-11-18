import '../auth/auth_repository.dart';
import '../transport/grchat_connection.dart';

/// Authoritative state of one call, as returned by the server's `call_resume`
/// (Stage 2A). Purely a value: it carries no media and no credentials.
///
/// `acceptedAtMs` is what keeps the conversation timer honest across recovery -
/// it is the server's start time and must never be replaced by "now".
class CallSnapshot {
  const CallSnapshot({
    required this.callId,
    required this.phase,
    required this.video,
    required this.members,
    required this.serverTimeMs,
    required this.recoveryEpoch,
    required this.acceptedAtMs,
    required this.recovering,
  });

  factory CallSnapshot.fromJson(Map<String, dynamic> r) => CallSnapshot(
        callId: r['call_id']?.toString() ?? '',
        phase: r['phase']?.toString() ?? 'unknown',
        video: r['video'] == true,
        members: (r['members'] as num?)?.toInt() ?? 0,
        serverTimeMs: (r['server_time_ms'] as num?)?.toInt() ?? 0,
        recoveryEpoch: (r['recovery_epoch'] as num?)?.toInt() ?? 0,
        acceptedAtMs: (r['accepted_at_ms'] as num?)?.toInt(),
        recovering: r['recovering'] == true,
      );

  final String callId;
  final String phase;
  final bool video;
  final int members;
  final int serverTimeMs;

  /// Monotonic per-call recovery counter from the server. Used to tell a
  /// snapshot that is older than what we already applied from a newer one.
  final int recoveryEpoch;
  final int? acceptedAtMs;
  final bool recovering;

  bool get isActive => phase == 'active';
}

/// What to do with a resume answer. Pure decision, no side effects, so the
/// "never resurrect" rules are testable without a live call.
enum ResumeOutcome {
  /// Nothing to reconcile (no local call).
  noCall,

  /// Snapshot accepted; the local call continues with the same callId.
  keep,

  /// The local call is gone for good - do NOT resurrect it.
  refuse,
}

class ResumeReconciler {
  const ResumeReconciler();

  /// Decides whether [snapshot] may be applied to the local call.
  ///
  /// The rules that matter (Stage 2E):
  ///  * an explicit hangup is final - a late resume must never revive it;
  ///  * a snapshot for a DIFFERENT callId belongs to a call we are not in;
  ///  * a snapshot that carries no callId is not trustworthy;
  ///  * an older recovery epoch is stale and must not overwrite newer local
  ///    state (ordering is not guaranteed across a reconnect).
  ResumeOutcome decide({
    required String? localCallId,
    required bool localEnded,
    required int localRecoveryEpoch,
    required CallSnapshot? snapshot,
  }) {
    if (localCallId == null) return ResumeOutcome.noCall;
    if (snapshot == null) return ResumeOutcome.keep;
    // Explicit teardown wins over anything the server sends afterwards.
    if (localEnded) return ResumeOutcome.refuse;
    if (snapshot.callId.isEmpty || snapshot.callId != localCallId) {
      return ResumeOutcome.refuse;
    }
    if (snapshot.recoveryEpoch < localRecoveryEpoch) return ResumeOutcome.refuse;
    return ResumeOutcome.keep;
  }
}

/// Server call signaling (our protocol) + TURN credentials.
/// Media itself is WebRTC P2P (TURN fallback) — see CallState.
class CallApi {
  CallApi(this._conn, this._session);
  final GrchatConnection _conn;
  final Session _session;

  Map<String, String> get _auth => {'session_token': _session.token};

  void _throwIfError(Map<String, dynamic> r) {
    if (r['type'] == 'error') {
      throw GrchatException(r['code']?.toString() ?? 'UNKNOWN', r);
    }
  }

  Future<String> offer({String? peerNick, String? dmId, required String sdp}) async {
    final r = await _conn.request('call_offer', fields: {
      ..._auth,
      if (peerNick case final pn) 'peer_nick': pn,
      if (dmId case final d) 'dm_id': d,
      'sdp': sdp,
    });
    _throwIfError(r);
    return r['call_id'] as String;
  }

  Future<void> answer(
      {required String callId, required bool accept, String? sdp}) async {
    final r = await _conn.request('call_answer', fields: {
      ..._auth,
      'call_id': callId,
      'accept': accept,
      if (sdp case final s) 'sdp': s,
    });
    _throwIfError(r);
  }

  Future<void> ice(
      {required String callId,
      required String candidate,
      String? sdpMid,
      String? sdpMLineIndex}) async {
    final r = await _conn.request('ice', fields: {
      ..._auth,
      'call_id': callId,
      'candidate': candidate,
      if (sdpMid case final sm) 'sdp_mid': sm,
      if (sdpMLineIndex case final sl) 'sdp_mline_index': sl,
    });
    _throwIfError(r);
  }

  /// Mid-call renegotiation (late camera enable, P2P): a fresh offer rides
  /// this verb to the peer, the peer's answer comes back as the same push
  /// with `answer:true` (see CallState._onRenegotiate). Group calls
  /// negotiate through the SFU and never use this.
  Future<void> renegotiate(
      {required String callId, required String sdp, bool answer = false}) async {
    final r = await _conn.request('call_renegotiate', fields: {
      ..._auth,
      'call_id': callId,
      'sdp': sdp,
      'answer': answer,
    });
    _throwIfError(r);
  }

  Future<void> hangup(String callId) async {
    final r = await _conn.request('call_hangup',
        fields: {..._auth, 'call_id': callId});
    _throwIfError(r);
  }

  /// Stage 2B: ask the server for the authoritative state of [callId] after
  /// the signaling socket was rebuilt.
  ///
  /// Returns null when the server refuses: the call ended meanwhile, or this
  /// session no longer owns it (`NOT_CALL_OWNER`). The caller must NOT retry in
  /// a loop - a refusal is a decision, and an unauthorized one must stay refused.
  Future<CallSnapshot?> resume(String callId) async {
    final r = await _conn.request('call_resume',
        fields: {..._auth, 'call_id': callId});
    if (r['type'] == 'error') return null;
    return CallSnapshot.fromJson(r);
  }

  /// TURN credentials for coturn REST, or null when disabled server-side.
  Future<Map<String, dynamic>?> turnCredentials() async {
    final r = await _conn.request('turn_credentials', fields: _auth);
    if (r['type'] == 'error') return null;
    return r;
  }

  /// LiveKit SFU join token for a group DM I belong to. The room URL must
  /// be wss:// — media sessions over plaintext ws:// are refused in one
  /// place here, so groups and voice share the same gate.
  Future<({String url, String token, String room})> livekitToken(
      String dmId) async {
    final r = await _conn.request('livekit_token',
        fields: {..._auth, 'dm_id': dmId});
    _throwIfError(r);
    final url = r['url'] as String;
    if (!url.startsWith('wss://')) {
      throw GrchatException('INSECURE_ROOM_URL', r);
    }
    return (
      url: url,
      token: r['token'] as String,
      room: r['room'] as String
    );
  }

  /// LiveKit SFU join token for a voice channel I may enter (audio-only).
  /// Same wss:// gate as [livekitToken].
  Future<({String url, String token, String room})> voiceToken(
      String channelId) async {
    final r = await _conn.request('voice_token',
        fields: {..._auth, 'channel_id': channelId});
    _throwIfError(r);
    final url = r['url'] as String;
    if (!url.startsWith('wss://')) {
      throw GrchatException('INSECURE_ROOM_URL', r);
    }
    return (
      url: url,
      token: r['token'] as String,
      room: r['room'] as String
    );
  }
}
