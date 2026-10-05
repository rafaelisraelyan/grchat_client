import 'package:flutter_test/flutter_test.dart';
import 'package:grchat_client/src/transport/grchat_connection.dart';

/// Signaling protocol against the local dev server (needs it running,
/// like connection_test): offer/answer/hangup pushes + error codes.
Future<Map<String, dynamic>> _req(
    GrchatConnection c, String type, Map<String, dynamic> fields) {
  return c.request(type, fields: fields);
}

Future<String> _login(GrchatConnection c, String login, String pw) async {
  final r = await _req(c, 'login', {'login': login, 'password': pw});
  if (r['type'] == 'error') throw StateError('login $login: ${r['code']}');
  return r['session_token'] as String;
}

Future<Map<String, dynamic>?> _waitFor(
    List<Map<String, dynamic>> seen,
    bool Function(Map<String, dynamic>) match,
    {Duration wait = const Duration(seconds: 5)}) async {
  final deadline = DateTime.now().add(wait);
  while (DateTime.now().isBefore(deadline)) {
    for (final e in seen) {
      if (match(e)) return e;
    }
    await Future.delayed(const Duration(milliseconds: 100));
  }
  for (final e in seen) {
    if (match(e)) return e;
  }
  return null;
}

void main() {
  test('call signaling: errors + decline reason', () async {
    final a = GrchatConnection();
    final b = GrchatConnection();
    // Capture pushes from the start: broadcast streams drop events
    // that arrive with no listener attached.
    final aPushes = <Map<String, dynamic>>[];
    final bPushes = <Map<String, dynamic>>[];
    final subA = a.pushes.listen(aPushes.add);
    final subB = b.pushes.listen(bPushes.add);
    try {
      await a.connect('127.0.0.1', 8181);
      await b.connect('127.0.0.1', 8181);
      final tokA = await _login(a, 'Rafael', 'newsecret123');
      final tokB = await _login(b, 'TestPilot', 'pilot12345');

      // Unknown nick -> NOT_FOUND, no side effects.
      final nf = await _req(a, 'call_offer', {
        'session_token': tokA,
        'peer_nick': 'no_such_nick_xyz',
        'sdp': 'v=0 dummy',
      });
      expect(nf['code'], 'NOT_FOUND');

      // Random call id -> NOT_IN_CALL.
      final nic = await _req(a, 'call_hangup', {
        'session_token': tokA,
        'call_id': '0' * 32,
      });
      expect(nic['code'], 'NOT_IN_CALL');

      // Real offer: either peer offline (assert code) or full decline flow.
      final offer = await _req(a, 'call_offer', {
        'session_token': tokA,
        'peer_nick': 'TestPilot',
        'sdp': 'v=0 dummy',
      });
      if (offer['type'] == 'error') {
        expect(offer['code'], 'USER_OFFLINE');
        return;
      }
      final callId = offer['call_id'] as String;

      final incoming = await _waitFor(
          bPushes,
          (e) =>
              e['type'] == 'call_incoming' && e['call_id'] == callId);
      expect(incoming, isNotNull, reason: 'callee never rang');
      expect(incoming!['from_nick'], 'Rafael');

      final declined = await _req(b, 'call_answer', {
        'session_token': tokB,
        'call_id': callId,
        'accept': false,
      });
      expect(declined['type'], isNot('error'));

      final ended = await _waitFor(
          aPushes,
          (e) =>
              e['type'] == 'call_ended' && e['call_id'] == callId);
      expect(ended, isNotNull, reason: 'caller never told');
      expect(ended!['reason'], 'declined');
    } finally {
      await subA.cancel();
      await subB.cancel();
      await a.dispose();
      await b.dispose();
    }  });
}
