// Release signing for the auto-updater (Ed25519).
//
//   dart run tool/sign_release.dart keygen
//       Prints a new key pair. Paste the PUBLIC key into
//       UpdateCenter.updatePublicKeyHex (lib/src/update/update_service.dart).
//       Store the PRIVATE seed OUTSIDE GitHub (password manager / local
//       file / CI secret with restricted access). Never commit it.
//
//   GRCHAT_SIGN_SEED=<64 hex> dart run tool/sign_release.dart sign grchat_client-windows.zip
//       Writes grchat_client-windows.zip.sig (128 hex chars). Upload the
//       .sig next to the zip in the GitHub release.
//
//   dart run tool/sign_release.dart verify <file> <64-hex-public-key> [<file>.sig]
//       Verifies a detached signature (defaults to <file>.sig) against the
//       given public key. Same algorithm UpdateCenter uses to gate installs.
//
// Pure Dart, no Flutter imports: runs with plain `dart run`.
import 'dart:io';

import 'package:cryptography/cryptography.dart';

String _hex(List<int> b) =>
    b.map((e) => e.toRadixString(16).padLeft(2, '0')).join();

List<int> _unhex(String s) => [
      for (var i = 0; i < s.length; i += 2)
        int.parse(s.substring(i, i + 2), radix: 16)
    ];

Future<void> main(List<String> args) async {
  final algo = Ed25519();
  if (args.isEmpty) {
    stderr.writeln('usage: keygen | sign <file> | verify <file> <pub> [sig]');
    exit(64);
  }
  switch (args[0]) {
    case 'keygen':
      final kp = await algo.newKeyPair();
      final seed = await kp.extractPrivateKeyBytes();
      final pub = (await kp.extractPublicKey()).bytes;
      stdout.writeln('PUBLIC  (put in app): ${_hex(pub)}');
      stdout.writeln('PRIVATE (keep secret): ${_hex(seed)}');
    case 'verify':
      if (args.length < 3) {
        stderr.writeln('usage: verify <file> <64-hex-public-key> [<file>.sig]');
        exit(64);
      }
      final dataPath = args[1];
      final pubHex = args[2];
      final sigPath = args.length > 3 ? args[3] : '$dataPath.sig';
      if (!RegExp(r'^[0-9a-fA-F]{64}$').hasMatch(pubHex)) {
        stderr.writeln('public key must be 64 hex chars');
        exit(64);
      }
      final sigRaw =
          (await File(sigPath).readAsString()).trim().replaceAll('\n', '');
      if (!RegExp(r'^[0-9a-fA-F]{128}$').hasMatch(sigRaw)) {
        stderr.writeln('signature must be 128 hex chars');
        exit(64);
      }
      final pub = SimplePublicKey(_unhex(pubHex), type: KeyPairType.ed25519);
      final ok = await algo.verify(
        await File(dataPath).readAsBytes(),
        signature: Signature(_unhex(sigRaw), publicKey: pub),
      );
      stdout.writeln(ok ? 'SIGNATURE OK' : 'SIGNATURE MISMATCH');
      exit(ok ? 0 : 65);
    case 'sign':
      if (args.length < 2) {
        stderr.writeln('usage: sign <file>');
        exit(64);
      }
      final seedHex = Platform.environment['GRCHAT_SIGN_SEED']?.trim() ?? '';
      if (!RegExp(r'^[0-9a-fA-F]{64}$').hasMatch(seedHex)) {
        stderr.writeln('set GRCHAT_SIGN_SEED to the 64-hex private seed');
        exit(64);
      }
      final kp = await algo.newKeyPairFromSeed(_unhex(seedHex));
      final data = await File(args[1]).readAsBytes();
      final sig = await algo.sign(data, keyPair: kp);
      await File('${args[1]}.sig').writeAsString('${_hex(sig.bytes)}\n');
      stdout.writeln('wrote ${args[1]}.sig');
    default:
      stderr.writeln('unknown command ${args[0]}');
      exit(64);
  }
}
