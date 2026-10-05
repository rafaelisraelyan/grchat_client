import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:grchat_client/src/transport/grchat_connection.dart';

/// Signaling protocol against the local dev server (needs it running).
///
/// Self-sufficient fixtures: the test owns `sigfix_a`/`sigfix_b` end to end
/// and never depends on hand-made dev accounts (no more BAD_CREDENTIALS
/// when someone changes Rafael's password).
///
/// First run needs the verification codes, which the server prints to its
/// own stdout (`MAIL ... to=<email> code=<6 digits>`). Point the test at
/// that output once in IDEA: Run | Edit Configurations | Logs |
/// "Save console output to file". Then either pass it explicitly:
///
///   flutter test test/call_signaling_test.dart \
///     --dart-define=GRCHAT_SERVER_LOG=C:/path/to/grchat-server.log
///
/// or accept the default below. After the one-time verify the fixtures
/// persist and later runs just log in; a wiped dev DB self-heals the
/// same way (register + auto-verify + login).
const _fixPassword = 'signaling123';
const _fixA = (nick: 'sigfix_a', email: 'sigfix_a@mail.test');
const _fixB = (nick: 'sigfix_b', email: 'sigfix_b@mail.test');

// Where the dev server's console output lands (IDEA run config).
const _serverLog = String.fromEnvironment('GRCHAT_SERVER_LOG',
    defaultValue:
        r'C:\Users\GR\Projects\grchat-server\grchat-server.log');

Future<Map<String, dynamic>> _req(
    GrchatConnection c, String type, Map<String, dynamic> fields) {
  return c.request(type, fields: fields);
}

/// Newest `MAIL ... code=` for [email] appended to the server log after
/// [fromOffset] (byte offset captured before triggering the send).
Future<String> _waitForMailCode(String email, int fromOffset) async {
  final f = File(_serverLog);
  if (!await f.exists()) {
    throw StateError(
        'fixture $email needs verification but the server log is missing '
        'at $_serverLog. Enable console-to-file in the IDEA run config and '
        'rerun with --dart-define=GRCHAT_SERVER_LOG=<path>.');
  }
  final re = RegExp('to=${RegExp.escape(email)} code=(\\d{6})');
  final deadline = DateTime.now().add(const Duration(seconds: 30));
  while (DateTime.now().isBefore(deadline)) {
    final bytes = await f.readAsBytes();
    final tail = String.fromCharCodes(bytes.sublist(
        fromOffset.clamp(0, bytes.length)));
    String? last;
    for (final m in re.allMatches(tail)) {
      last = m.group(1);
    }
    if (last != null) return last;
    await Future.delayed(const Duration(milliseconds: 500));
  }
  throw StateError(
      'no verification code for $email in $_serverLog within 30s');
}

Future<int> _logSize() async {
  try {
    return await File(_serverLog).length();
  } catch (_) {
    return 0;
  }
}

Future<void> _verifyFromServerLog(
    GrchatConnection c, String email, int fromOffset) async {
  var code = await _waitForMailCode(email, fromOffset);
  var v = await _req(c, 'verify_email', {'email': email, 'code': code});
  if (v['type'] == 'error' && v['code'] == 'CODE_EXPIRED') {
    final mark = await _logSize();
    await _req(c, 'resend_code', {'email': email});
    code = await _waitForMailCode(email, mark);
    v = await _req(c, 'verify_email', {'email': email, 'code': code});
  }
  if (v['type'] == 'error') {
    throw StateError('fixture verify $email failed: ${v['code']}');
  }
}

/// Login, registering + auto-verifying the dedicated fixture on demand.
Future<String> _loginFixture(
    GrchatConnection c, String nick, String email) async {
  Future<String> login() async {
    final r = await _req(
        c, 'login', {'login': nick, 'password': _fixPassword});
    if (r['type'] == 'error') {
      throw _LoginFailed(r['code']?.toString() ?? 'UNKNOWN');
    }
    return r['session_token'] as String;
  }

  try {
    return await login();
  } on _LoginFailed catch (e) {
    if (e.code != 'BAD_CREDENTIALS' && e.code != 'EMAIL_NOT_VERIFIED') {
      throw StateError(
          'fixture login $nick failed: ${e.code} (is the dev server running?)');
    }
    if (e.code == 'EMAIL_NOT_VERIFIED') {
      // Registered before but never verified: fresh code, then in.
      final mark = await _logSize();
      final rs = await _req(c, 'resend_code', {'email': email});
      if (rs['type'] == 'error' && rs['code'] != 'RESEND_COOLDOWN') {
        throw StateError('fixture resend $email failed: ${rs['code']}');
      }
      await _verifyFromServerLog(c, email, mark);
      return login();
    }
    // Unknown user (or, improbably, a hijacked nick): claim it.
    final mark = await _logSize();
    final reg = await _req(c, 'register',
        {'nick': nick, 'email': email, 'password': _fixPassword});
    if (reg['type'] == 'error') {
      throw StateError(
          'fixture nick $nick is taken by someone else; free it and rerun '
          '(register said ${reg['code']})');
    }
    await _verifyFromServerLog(c, email, mark);
    return login();
  }
}

class _LoginFailed implements Exception {
  _LoginFailed(this.code);
  final String code;
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
      final tokA = await _loginFixture(a, _fixA.nick, _fixA.email);
      final tokB = await _loginFixture(b, _fixB.nick, _fixB.email);

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
        'peer_nick': _fixB.nick,
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
      expect(incoming!['from_nick'], _fixA.nick);

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
