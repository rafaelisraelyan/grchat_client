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
    stderr.writeln('usage: keygen | sign <file>');
    exit(64);
  }
  switch (args[0]) {
    case 'keygen':
      final kp = await algo.newKeyPair();
      final seed = await kp.extractPrivateKeyBytes();
      final pub = (await kp.extractPublicKey()).bytes;
      stdout.writeln('PUBLIC  (put in app): ${_hex(pub)}');
      stdout.writeln('PRIVATE (keep secret): ${_hex(seed)}');
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
