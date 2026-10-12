// Server signing key management (Ed25519) for GRCHAT_SIGN_SEED.
//
//   dart run tool/server_sign.dart keygen <seed-file>
//       Generates a fresh 32-byte seed, writes its 64 hex chars to
//       <seed-file> and prints ONLY the public key (64 hex) to stdout.
//       Put the printed key into lib/src/transport/server_sign.dart
//       (serverSignPublicKeyHex) and the seed file path into the server's
//       GRCHAT_SIGN_SEED. The seed never touches stdout.
//
//   dart run tool/server_sign.dart print-pub <seed-file>
//       Prints the public key derived from an existing seed file.
//
// Pure Dart, no Flutter imports: runs with plain `dart run`.
import 'dart:io';

import 'package:cryptography/cryptography.dart';

String _hex(List<int> b) =>
    b.map((e) => e.toRadixString(16).padLeft(2, '0')).join();

List<int> _unhex(String s) => [
  for (var i = 0; i < s.length; i += 2)
    int.parse(s.substring(i, i + 2), radix: 16),
];

Future<void> main(List<String> args) async {
  if (args.length != 2) {
    stderr.writeln('usage: keygen <seed-file> | print-pub <seed-file>');
    exit(64);
  }
  final algo = Ed25519();
  final String seedHex;
  if (args[0] == 'keygen') {
    final kp = await algo.newKeyPair();
    seedHex = _hex(await kp.extractPrivateKeyBytes());
    File(args[1]).writeAsStringSync('$seedHex\n');
  } else if (args[0] == 'print-pub') {
    seedHex = File(args[1]).readAsStringSync().trim();
    if (!RegExp(r'^[0-9a-fA-F]{64}$').hasMatch(seedHex)) {
      stderr.writeln('seed file must contain 64 hex chars');
      exit(65);
    }
  } else {
    stderr.writeln('usage: keygen <seed-file> | print-pub <seed-file>');
    exit(64);
  }
  final kp = await algo.newKeyPairFromSeed(_unhex(seedHex));
  final pub = await kp.extractPublicKey();
  stdout.writeln(_hex(pub.bytes));
}
