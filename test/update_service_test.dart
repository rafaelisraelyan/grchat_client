import 'dart:convert';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:grchat_client/src/update/update_service.dart';

/// The release gate: what counts as newer, and what a tag parses to.
/// A wrong answer here either hides a release or pushes a downgrade through
/// the auto-install path, so the table is explicit.
void main() {
  group('release tag parsing', () {
    test('stable and beta tags yield dotted versions', () {
      expect(UpdateCenter.numbersForTest('v1.1.1-beta.1'), '1.1.1');
      expect(UpdateCenter.numbersForTest('v1.1.0-beta.1'), '1.1.0');
      expect(UpdateCenter.numbersForTest('v2.0.0'), '2.0.0');
      expect(UpdateCenter.numbersForTest('garbage'), '0.0.0');
      expect(UpdateCenter.numbersForTest(''), '0.0.0');
    });
  });

  group('newer-than check', () {
    test('patch and minor bumps are newer', () {
      expect(UpdateCenter.isNewerForTest('1.1.1', '1.1.0'), isTrue);
      expect(UpdateCenter.isNewerForTest('1.2.0', '1.1.9'), isTrue);
      expect(UpdateCenter.isNewerForTest('2.0.0', '1.9.9'), isTrue);
    });

    test('same or older is not newer — never reinstall, never downgrade', () {
      expect(UpdateCenter.isNewerForTest('1.1.0', '1.1.0'), isFalse);
      expect(UpdateCenter.isNewerForTest('1.1.0', '1.1.1'), isFalse);
      expect(UpdateCenter.isNewerForTest('1.1.10', '1.1.9'), isTrue,
          reason: 'numeric, not lexicographic: 10 > 9');
      expect(UpdateCenter.isNewerForTest('1.1.9', '1.1.10'), isFalse);
    });
  });

  /// The trust gate: an update installs only with a valid Ed25519 signature
  /// from the baked-in key. Everything malformed must fail closed.
  group('update signature', () {
    final data = utf8.encode('fake zip bytes');

    Future<(List<int> pub, List<int> sig)> signed(List<int> payload) async {
      final algo = Ed25519();
      final kp = await algo.newKeyPair();
      final pub = (await kp.extractPublicKey()).bytes;
      final sig = await algo.sign(payload, keyPair: kp);
      return (pub, sig.bytes);
    }

    test('valid signature verifies', () async {
      final (pub, sig) = await signed(data);
      expect(
          await UpdateCenter.verifySignature(
              data: data, signature: sig, publicKey: pub),
          isTrue);
    });

    test('tampered data is rejected', () async {
      final (pub, sig) = await signed(data);
      expect(
          await UpdateCenter.verifySignature(
              data: utf8.encode('evil zip bytes'),
              signature: sig,
              publicKey: pub),
          isFalse);
    });

    test('signature from another key is rejected', () async {
      final (_, sig) = await signed(data);
      final (otherPub, _) = await signed(data);
      expect(
          await UpdateCenter.verifySignature(
              data: data, signature: sig, publicKey: otherPub),
          isFalse);
    });

    test('malformed lengths fail closed, never throw', () async {
      expect(
          await UpdateCenter.verifySignature(
              data: data, signature: [1, 2, 3], publicKey: List.filled(32, 0)),
          isFalse);
      expect(
          await UpdateCenter.verifySignature(
              data: data, signature: List.filled(64, 0), publicKey: [1]),
          isFalse);
    });

    test('hex parsing is strict', () {
      expect(UpdateCenter.parseHex('00ff', 2), [0, 255]);
      expect(UpdateCenter.parseHex('00ff\n', 2), [0, 255]);
      expect(UpdateCenter.parseHex('00ff', 3), isNull);
      expect(UpdateCenter.parseHex('zz', 1), isNull);
      expect(UpdateCenter.parseHex('', 32), isNull,
          reason: 'empty key constant = signing not configured');
    });
  });

  /// The apply script template: rendered paths in, no Dart-interpolation
  /// accidents, and the full resilient chain (sibling kill, logged
  /// expand, restart). A broken template means a dead client with no
  /// trace — exactly the silent 1.4.0 and 1.5.1 failures.
  group('apply script', () {
    String script() => UpdateCenter.buildApplyScript(
        pid: 1234,
        zipPath: r'C:\T\grchat_updX\update.zip',
        dir: r'C:\App\Release',
        exe: r'C:\App\Release\grchat_client.exe',
        log: r'C:\T\grchat_updX\apply.log');

    test('bakes in runtime values, keeps PowerShell vars literal', () {
      final s = script();
      expect(s, contains(r'$pid0 = 1234'));
      expect(s, contains(r'C:\T\grchat_updX\update.zip'));
      expect(s, contains(r'C:\App\Release\grchat_client.exe'));
      expect(s, contains(r'C:\T\grchat_updX\apply.log'));
      // No un-rendered Dart interpolation leftovers.
      expect(s.contains('\$zip'), isFalse);
      expect(s.contains('\$dir'), isFalse);
      expect(s.contains('\$exe'), isFalse);
      expect(s.contains('\$log'), isFalse);
    });

    test('waits, kills siblings, expands logged, restarts', () {
      final s = script();
      expect(s, contains('Wait-Process -Id \$pid0'));
      expect(s, contains('Get-Process grchat_client'));
      expect(s, contains('Stop-Process'));
      expect(s, contains('Expand-Archive'));
      expect(s, contains('-ErrorAction Stop'));
      expect(s, contains('Start-Process'));
      expect(s, contains('-WorkingDirectory'));
      expect(s, contains('apply.log'));
    });

    test('balanced braces', () {
      final s = script();
      int depth = 0;
      for (final c in s.split('')) {
        if (c == '{') depth++;
        if (c == '}') depth--;
        expect(depth, greaterThanOrEqualTo(0));
      }
      expect(depth, 0);
    });
  });

  /// The spawn chain: cmd/start daemonize (detached children never run
  /// here), and the script path goes through BARE — pre-quoting mangles
  /// it into `"""..."""` and the launch dies silently.
  group('updater argv', () {
    test('cmd start chain with a bare script path', () {
      final argv = UpdateCenter.updaterArgv(
          r'C:\T\grchat_updX\apply.ps1');
      expect(argv.first, '/c');
      expect(argv, contains('start'));
      expect(argv, contains('powershell.exe'));
      // The -File argument goes through bare (the empty "" is start's
      // window title and stays).
      expect(argv.last, r'C:\T\grchat_updX\apply.ps1');
      expect(argv.last.contains('"'), isFalse);
    });

    test('paths with spaces stay bare (Dart quotes them)', () {
      final argv = UpdateCenter.updaterArgv(
          r'C:\My Dir\apply.ps1');
      expect(argv.last, r'C:\My Dir\apply.ps1');
    });
  });
}
