import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:grchat_client/src/auth/auth_repository.dart';
import 'package:grchat_client/src/transport/grchat_connection.dart';

/// Live test against a running dev server on TLS 8443.
/// Skipped unless run with:
///   `flutter test test/tls_live_test.dart --dart-define=GRCHAT_DEV_CA=<path>`
///   (optional: `--dart-define=LIVE_LOGIN=<nick> --dart-define=LIVE_PASS=<pwd>`)
void main() {
  final caPath = const String.fromEnvironment('GRCHAT_DEV_CA');

  test('real login over TLS 8443 with the dev CA', () async {
    if (caPath.isEmpty) {
      // Intentionally skipped: live test needs the dev CA define.
      return;
    }
    final conn = GrchatConnection(devCaPath: caPath, isDebug: true);
    await conn.connect('127.0.0.1', 8443);
    expect(conn.isOpen, isTrue);
    final repo = AuthRepository(conn);
    final session = await repo.login(
      login: const String.fromEnvironment('LIVE_LOGIN', defaultValue: 'Masha'),
      password: const String.fromEnvironment('LIVE_PASS',
          defaultValue: 'mashaPass1'),
    );
    expect(session.userId, isNotEmpty);
    expect(session.token, isNotEmpty);
    await conn.dispose();
  }, timeout: const Timeout(Duration(seconds: 30)));

  test('isolated trust anchor: wrong/empty roots fail closed', () async {
    // The OS trust store now contains the dev CA, so an "empty context"
    // connect can legitimately succeed. The precise negative check: with
    // isolated roots (withTrustedRoots: false) the self-signed server MUST
    // be refused — onBadCertificate stays false, no engine-level bypass.
    if (caPath.isEmpty || !File('C:\\Users\\GR\\.grchat_dev\\badca.pem').existsSync()) {
      return;
    }
    Future<Socket> isoConnect(SecurityContext? ctx) =>
        SecureSocket.connect('127.0.0.1', 8443,
            context: ctx, onBadCertificate: (_) => false);

    final bad = SecurityContext(withTrustedRoots: false);
    bad.setTrustedCertificatesBytes(
        File('C:\\Users\\GR\\.grchat_dev\\badca.pem').readAsBytesSync());
    await expectLater(isoConnect(bad), throwsA(isA<HandshakeException>()));

    await expectLater(isoConnect(SecurityContext(withTrustedRoots: false)),
        throwsA(isA<HandshakeException>()));
  }, timeout: const Timeout(Duration(seconds: 30)));
}
