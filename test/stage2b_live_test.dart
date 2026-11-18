import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:grchat_client/src/auth/auth_repository.dart';
import 'package:grchat_client/src/call/call_api.dart';
import 'package:grchat_client/src/transport/grchat_connection.dart';

/// Stage 2B PART F - LIVE integration against the real Stage 2A server.
///
/// NOT debug state toggles: a real TCP proxy sits between the client and the
/// real TLS server, and [Proxy.cut] destroys both socket halves - a genuine
/// network break. The client must notice on its own and reconnect INSIDE the
/// server's 10s recovery grace. TCP/TLS and PostgreSQL run end to end. The
/// fixture uses synthetic SDP and an unsigned TLS server.
const _serverPort = int.fromEnvironment(
  'GRCHAT_STAGE2B_PORT',
  defaultValue: 18443,
);
const _caPath = String.fromEnvironment('GRCHAT_STAGE2B_CA');
const _mailFixture = String.fromEnvironment('GRCHAT_STAGE2B_MAIL_FIXTURE');
const _required = bool.fromEnvironment('GRCHAT_REQUIRE_STAGE2B');
const _sdp = 'v=0\r\nm=audio 9 UDP/TLS/RTP/SAVPF 111\r\na=sendrecv\r\n';

/// Fresh identities per run: F6 changes a password, so a re-run must not
/// collide with the accounts (or the changed password) of a previous run.
final _run = DateTime.now().microsecondsSinceEpoch.remainder(1000000);
String _n(String base) => '${base}_$_run';
String _e(String base) => '${base}_$_run@t.test';

/// Byte-forwarding proxy; TLS is end-to-end and never terminated here.
class Proxy {
  Proxy._(this._server);
  final ServerSocket _server;
  Socket? _clientSide;
  Socket? _serverSide;
  DateTime? _blockUntil;

  int get port => _server.port;

  static Future<Proxy> start(int targetPort) async {
    final srv = await ServerSocket.bind('127.0.0.1', 0);
    final p = Proxy._(srv);
    srv.listen((client) async {
      if (p._blockUntil?.isAfter(DateTime.now()) ?? false) {
        client.destroy();
        return;
      }
      p._clientSide = client;
      try {
        final up = await Socket.connect('127.0.0.1', targetPort);
        if (!identical(p._clientSide, client)) {
          up.destroy();
          client.destroy();
          return;
        }
        p._serverSide = up;
        client.listen(up.add, onDone: up.destroy, onError: (_) {});
        up.listen(client.add, onDone: client.destroy, onError: (_) {});
      } catch (_) {
        client.destroy();
      }
    });
    return p;
  }

  /// Hard break, like pulling the cable.
  void cut({Duration duration = Duration.zero}) {
    _blockUntil = DateTime.now().add(duration);
    for (final s in [_clientSide, _serverSide]) {
      try {
        s?.destroy();
      } catch (_) {}
    }
    _clientSide = null;
    _serverSide = null;
  }

  Future<void> close() async {
    cut();
    await _server.close();
  }
}

GrchatConnection tlsClient(int port) => GrchatConnection(
  connector: (h, p) => SecureSocket.connect(
    h,
    p,
    context: devTrustContext(isDebug: true, caPath: _caPath),
    // Fail closed, exactly like the production connector.
    onBadCertificate: (_) => false,
  ),
);

/// The fixture stores test mail in a private file, outside server diagnostics.
Future<String> mailCode(String email, {int attempts = 80}) async {
  final f = File(_mailFixture);
  final re = RegExp('${RegExp.escape(email)}\\t(\\d{6})');
  for (var i = 0; i < attempts; i++) {
    if (f.existsSync()) {
      final all = re.allMatches(f.readAsStringSync()).toList();
      if (all.isNotEmpty) return all.last.group(1)!;
    }
    await Future.delayed(const Duration(milliseconds: 100));
  }
  throw StateError('no mail code for $email');
}

final _fixtureSessions = Expando<Session>();

Future<Map<String, dynamic>> resumeWithFixtureSession(
  GrchatConnection connection,
  String callId,
) => connection.request(
  'call_resume',
  fields: {
    'call_id': callId,
    'session_token': _fixtureSessions[connection]!.token,
  },
);

/// Registers, verifies using captured fixture mail, and logs in.
Future<(CallApi, GrchatConnection, String)> account(
  int port,
  String base, {
  GrchatConnection? reuse,
}) async {
  final c = reuse ?? tlsClient(port);
  if (reuse == null) await c.connect('127.0.0.1', port);
  final nick = _n(base);
  final email = _e(base);
  await c.request(
    'register',
    fields: {'nick': nick, 'email': email, 'password': 'password123'},
  );
  await c.request(
    'verify_email',
    fields: {'email': email, 'code': await mailCode(email)},
  );
  final l = await c.request(
    'login',
    fields: {'login': nick, 'password': 'password123'},
  );
  expect(l['type'], 'login_ok');
  final session = Session(
    userId: l['user_id'] as String,
    nick: nick,
    token: l['session_token'] as String,
  );
  _fixtureSessions[c] = session;
  return (CallApi(c, session), c, nick);
}

void main() {
  var serverUp = false;

  setUpAll(() async {
    try {
      if (_caPath.isEmpty || _mailFixture.isEmpty) {
        throw StateError('Stage 2B requires CA and mail fixture paths');
      }
      if (_required) {
        await expectLater(
          SecureSocket.connect(
            '127.0.0.1',
            _serverPort,
            timeout: const Duration(seconds: 3),
          ),
          throwsA(isA<HandshakeException>()),
        );
      }
      final s = await SecureSocket.connect(
        '127.0.0.1',
        _serverPort,
        context: devTrustContext(isDebug: true, caPath: _caPath),
        timeout: const Duration(seconds: 3),
      );
      s.destroy();
      serverUp = true;
    } catch (error) {
      if (_required) {
        throw StateError(
          'Required Stage 2B fixture unavailable: ${error.runtimeType}',
        );
      }
      serverUp = false;
    }
  });

  /// Called first in every test: without the live server there is nothing to
  /// prove, and a hard-coded skip in setUp does not abort the body.
  bool requireServer() {
    if (serverUp) return true;
    markTestSkipped('Stage 2A server is not listening on $_serverPort');
    return false;
  }

  // F1 + F2: 2s and 5s signaling loss, resumed automatically.
  for (final outage in [2, 5]) {
    test('F${outage == 2 ? '1' : '2'} ${outage}s signaling loss keeps the '
        'same callId and resumes inside the grace', () async {
      if (!requireServer()) return;
      final proxy = await Proxy.start(_serverPort);
      final a = tlsClient(proxy.port);
      await a.connect('127.0.0.1', proxy.port);
      final (apiA, _, _) = await account(proxy.port, 'pf_a$outage', reuse: a);
      final (apiB, b, nickB) = await account(_serverPort, 'pf_b$outage');

      final callId = await apiA.offer(peerNick: nickB, sdp: _sdp);
      await apiB.answer(callId: callId, accept: true, sdp: _sdp);

      final t0 = DateTime.now();
      proxy.cut(duration: Duration(seconds: outage));

      CallSnapshot? snap;
      while (DateTime.now().difference(t0) < const Duration(seconds: 9)) {
        await Future.delayed(const Duration(milliseconds: 150));
        if (!a.isOpen) continue;
        try {
          snap = await apiA.resume(callId);
        } catch (_) {
          continue;
        }
        if (snap != null) break;
      }
      final took = DateTime.now().difference(t0);

      expect(
        snap,
        isNotNull,
        reason:
            'the client must reconnect and resume by itself '
            '(waited ${took.inMilliseconds}ms)',
      );
      expect(snap!.callId, callId, reason: 'callId must not change');
      expect(
        snap.acceptedAtMs,
        isNotNull,
        reason: 'the conversation start must survive recovery',
      );
      expect(
        took.inSeconds,
        lessThan(10),
        reason: 'resume must beat the server grace deadline',
      );

      expect(took.inMilliseconds, greaterThanOrEqualTo(outage * 1000));
      // ignore: avoid_print
      print(
        'Stage 2B recovery call=$callId socket=${a.socketGeneration} elapsed=${took.inMilliseconds}ms',
      );
      // Media signalling still flows on the same call.
      await apiB.ice(
        callId: callId,
        candidate: 'candidate:1 1 udp 1 1.2.3.4 5 typ host',
      );
      await apiA.hangup(callId);
      await a.dispose();
      await b.dispose();
      await proxy.close();
    });
  }

  // F3: longer than the grace -> the server ends the call.
  test('F3 a loss beyond the grace ends the call', () async {
    if (!requireServer()) return;
    final proxy = await Proxy.start(_serverPort);
    final a = tlsClient(proxy.port);
    await a.connect('127.0.0.1', proxy.port);
    final (apiA, _, _) = await account(proxy.port, 'pf_c', reuse: a);
    final (apiB, b, nickD) = await account(_serverPort, 'pf_d');

    final callId = await apiA.offer(peerNick: nickD, sdp: _sdp);
    await apiB.answer(callId: callId, accept: true, sdp: _sdp);
    final ended = b.pushes.firstWhere(
      (push) => push['type'] == 'call_ended' && push['call_id'] == callId,
    );
    proxy.cut(duration: const Duration(seconds: 11));
    await ended.timeout(const Duration(seconds: 14));
    await Future<void>.delayed(const Duration(seconds: 2));
    await a.retryNow();
    final r = await resumeWithFixtureSession(a, callId);
    expect(r['type'], 'error');
    expect(r['code'], 'NOT_IN_CALL');
    await a.dispose();
    await b.dispose();
    await proxy.close();
  });

  // F4: the SAME account on two connections - closing one must not end the
  // call that the other owns.
  test(
    'F4 a second connection of the same user closing does not end the call',
    () async {
      if (!requireServer()) return;
      final proxy = await Proxy.start(_serverPort);
      final device1 = tlsClient(proxy.port);
      await device1.connect('127.0.0.1', proxy.port);
      final (api1, c1, _) = await account(proxy.port, 'pf_e', reuse: device1);
      final (apiPeer, peer, nickF) = await account(_serverPort, 'pf_f');

      final callId = await api1.offer(peerNick: nickF, sdp: _sdp);
      await apiPeer.answer(callId: callId, accept: true, sdp: _sdp);

      // Same account, second connection, same session token, never in the call.
      final device2 = tlsClient(_serverPort);
      await device2.connect('127.0.0.1', _serverPort);
      final session = (await device2.request(
        'login',
        fields: {'login': _n('pf_e'), 'password': 'password123'},
      ));
      expect(session['type'], 'login_ok');
      await device2.dispose();
      await Future.delayed(const Duration(seconds: 12));

      final snap = await api1.resume(callId);
      expect(
        snap,
        isNotNull,
        reason: 'the idle second connection must not end this call',
      );
      expect(snap!.callId, callId);

      await api1.hangup(callId);
      await c1.dispose();
      await peer.dispose();
      await proxy.close();
    },
  );

  // F5: a resume that arrives after the call is gone must not revive it.
  test(
    'F5 a late resume after the grace ended does not revive the call',
    () async {
      if (!requireServer()) return;
      final proxy = await Proxy.start(_serverPort);
      final a = tlsClient(proxy.port);
      await a.connect('127.0.0.1', proxy.port);
      final (apiA, _, _) = await account(proxy.port, 'pf_g', reuse: a);
      final (apiB, b, nickH) = await account(_serverPort, 'pf_h');

      final callId = await apiA.offer(peerNick: nickH, sdp: _sdp);
      await apiB.answer(callId: callId, accept: true, sdp: _sdp);
      proxy.cut();
      await Future.delayed(const Duration(seconds: 11));

      expect(
        await apiA.resume(callId),
        isNull,
        reason: 'a resume for an ended call must be refused, not resurrected',
      );
      await a.dispose();
      await b.dispose();
      await proxy.close();
    },
  );

  // F6: a password reset revokes the session; the old one cannot resume.
  test(
    'F6 a password reset blocks the resume of the revoked session',
    () async {
      if (!requireServer()) return;
      final proxy = await Proxy.start(_serverPort);
      final a = tlsClient(proxy.port);
      await a.connect('127.0.0.1', proxy.port);
      final (apiA, _, _) = await account(proxy.port, 'pf_i', reuse: a);
      final (apiB, b, nickJ) = await account(_serverPort, 'pf_j');

      final callId = await apiA.offer(peerNick: nickJ, sdp: _sdp);
      await apiB.answer(callId: callId, accept: true, sdp: _sdp);

      final reset = tlsClient(_serverPort);
      await reset.connect('127.0.0.1', _serverPort);
      await reset.request('password_forgot', fields: {'email': _e('pf_i')});
      final code = await mailCode(_e('pf_i'));
      final rst = await reset.request(
        'password_reset',
        fields: {
          'email': _e('pf_i'),
          'code': code,
          'new_password': 'newpassword123',
        },
      );
      expect(rst['type'], 'password_reset_ok', reason: '$rst');

      proxy.cut();
      await Future.delayed(const Duration(seconds: 4));

      // The revoked token cannot authenticate, let alone resume.
      final r = await resumeWithFixtureSession(a, callId);
      expect(r['type'], 'error', reason: '$r');
      expect(r['code'], 'NOT_AUTHENTICATED');

      await reset.dispose();
      await a.dispose();
      await b.dispose();
      await proxy.close();
    },
  );

  // F7: a stale socket event must not disturb the live connection.
  test('F7 a stale socket event does not disturb the new connection', () async {
    if (!requireServer()) return;
    final c = tlsClient(_serverPort);
    await c.connect('127.0.0.1', _serverPort);
    expect((await c.request('ping'))['type'], 'pong');
    final gen = c.socketGeneration;

    await c.connect('127.0.0.1', _serverPort);
    await Future.delayed(const Duration(milliseconds: 300));
    expect(c.socketGeneration, greaterThan(gen));
    expect(
      (await c.request('ping'))['type'],
      'pong',
      reason: 'the live socket must still work',
    );
    await c.dispose();
  });
}
