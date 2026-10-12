import '../auth/auth_repository.dart';
import '../transport/grchat_connection.dart';

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
