import '../transport/grchat_connection.dart';

class GrchatException implements Exception {
  GrchatException(this.code, [this.raw]);
  final String code;
  final Map<String, dynamic>? raw;

  @override
  String toString() => 'GrchatException($code)';
}

class Session {
  Session({required this.userId, required this.nick, required this.token});
  final String userId;
  final String nick;
  final String token;
}

Map<String, dynamic> _ok(Map<String, dynamic> r) {
  if (r['type'] == 'error') throw GrchatException(r['code']?.toString() ?? 'UNKNOWN');
  return r;
}

/// Auth API over an open [GrchatConnection]. Stateless besides [session].
class AuthRepository {
  AuthRepository(this._conn);
  final GrchatConnection _conn;
  Session? session;

  Future<bool> register(
      {required String nick, required String email, required String password}) async {
    final r = _ok(await _conn.request('register',
        fields: {'nick': nick, 'email': email, 'password': password}));
    return (r['verify_required'] as bool?) ?? false;
  }

  Future<void> verifyEmail({required String email, required String code}) async {
    _ok(await _conn.request('verify_email', fields: {'email': email, 'code': code}));
  }

  Future<void> resendCode({required String email}) async {
    _ok(await _conn.request('resend_code', fields: {'email': email}));
  }

  Future<Session> login({required String login, required String password}) async {
    final r = _ok(await _conn.request('login',
        fields: {'login': login, 'password': password}));
    session = Session(
      userId: r['user_id'] as String,
      nick: r['nick'] as String,
      token: r['session_token'] as String,
    );
    return session!;
  }

  Future<void> forgot({required String email}) async {
    _ok(await _conn.request('password_forgot', fields: {'email': email}));
  }

  Future<void> reset(
      {required String email, required String code, required String newPassword}) async {
    _ok(await _conn.request('password_reset',
        fields: {'email': email, 'code': code, 'new_password': newPassword}));
  }
}
