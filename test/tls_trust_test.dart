import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:grchat_client/src/auth/auth_repository.dart';
import 'package:grchat_client/src/auth/auth_screen.dart';
import 'package:grchat_client/src/call/call_api.dart';
import 'package:grchat_client/src/transport/grchat_connection.dart';

/// Connection stub: every request answers with the canned reply.
class _FakeConn extends GrchatConnection {
  _FakeConn(this.reply);
  final Map<String, dynamic> reply;
  String? lastType;

  @override
  Future<Map<String, dynamic>> request(String type,
      {String? reqId, Map<String, dynamic> fields = const {}}) async {
    lastType = type;
    return reply;
  }
}

void main() {
  group('dev CA trust (debug only)', () {
    test('trusted only when debug and a path is set', () {
      expect(shouldTrustDevCa(isDebug: true, caPath: 'C:/x.pem'), isTrue);
      expect(shouldTrustDevCa(isDebug: true, caPath: ''), isFalse);
    });

    test('release build never trusts the dev CA, even with a path', () {
      expect(shouldTrustDevCa(isDebug: false, caPath: 'C:/x.pem'), isFalse);
      // No file is read in release: a missing path must not throw.
      expect(
          devTrustContext(isDebug: false, caPath: 'C:/does/not/exist.pem'),
          isNull);
    });

    test('no path gives no extra trust, even in debug', () {
      expect(devTrustContext(isDebug: true, caPath: ''), isNull);
    });
  });

  group('connection error text', () {
    test('untrusted certificate is reported as such', () {
      expect(
          connectErrorText(HandshakeException(
              'Handshake error (CERTIFICATE_VERIFY_FAILED)')),
          'Сертификат сервера не доверенный');
      expect(
          connectErrorText(HandshakeException(
              'unable to get local issuer certificate')),
          'Сертификат сервера не доверенный');
    });

    test('other handshake failure means no TLS on the server', () {
      expect(
          connectErrorText(HandshakeException('wrong version number')),
          'Сервер не поддерживает защищённое соединение');
    });

    test('anything else is a plain connection failure', () {
      expect(connectErrorText(const SocketException('refused')),
          'Нет соединения с сервером');
    });
  });

  group('LiveKit room URL must be wss://', () {
    final session = Session(userId: 'u1', nick: 'Rafael', token: 't');

    test('ws:// from livekit_token is refused', () async {
      final api = CallApi(
          _FakeConn({
            'type': 'livekit_token',
            'url': 'ws://localhost:7880',
            'token': 'x',
            'room': 'r',
          }),
          session);
      await expectLater(
          api.livekitToken('d1'),
          throwsA(isA<GrchatException>()
              .having((e) => e.code, 'code', 'INSECURE_ROOM_URL')));
    });

    test('ws:// from voice_token is refused', () async {
      final api = CallApi(
          _FakeConn({
            'type': 'voice_token',
            'url': 'ws://localhost:7880',
            'token': 'x',
            'room': 'r',
          }),
          session);
      await expectLater(
          api.voiceToken('c1'),
          throwsA(isA<GrchatException>()
              .having((e) => e.code, 'code', 'INSECURE_ROOM_URL')));
    });

    test('wss:// is accepted', () async {
      final api = CallApi(
          _FakeConn({
            'type': 'livekit_token',
            'url': 'wss://lk.example.test',
            'token': 'x',
            'room': 'r',
          }),
          session);
      final r = await api.livekitToken('d1');
      expect(r.url, 'wss://lk.example.test');
    });
  });
}
