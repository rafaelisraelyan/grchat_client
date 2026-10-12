// Server envelope signature verification (Ed25519) - defense-in-depth on
// top of TLS.
//
// The server (EnvelopeSigner.java) appends `ts` plus a 128-zero `sig`
// placeholder to every outgoing envelope, serialises the line, signs those
// exact UTF-8 bytes with an Ed25519 seed (GRCHAT_SIGN_SEED) and splices the
// real hex over the zeros: the splice preserves every other byte and the
// line length. Verification therefore needs no JSON canonicalisation: zero
// out the single wire-level `"sig":"<128 hex>"` occurrence and verify the
// same bytes. Quotes inside JSON string values always travel escaped, so
// the plain substring match only ever hits the top-level field.
//
// Lines without a signature are accepted (a server runs unsigned when
// GRCHAT_SIGN_SEED is not configured; TLS remains the primary boundary).
// A present-but-invalid signature fails the whole line (fail-closed).
import 'dart:convert';

import 'package:cryptography/cryptography.dart';

/// Pinned server signing public key (64 hex). Build-time override for dev
/// key rotation: `--dart-define=GRCHAT_SERVER_PUBKEY=<hex>`.
///
/// Public key of GRCHAT_SIGN_SEED (tool/server_sign.dart keygen).
const serverSignPublicKeyHex = String.fromEnvironment(
  'GRCHAT_SERVER_PUBKEY',
  defaultValue:
      '3fc81b698a57cc7c6113d3c47d4a0dddc911554fa85f45c0ff6b928b897cbbf5',
);

final _hexPattern = RegExp(r'^[0-9a-f]{128}$');

List<int> _unhex(String s) => [
  for (var i = 0; i < s.length; i += 2)
    int.parse(s.substring(i, i + 2), radix: 16),
];

/// Result of the envelope signature check.
enum ServerSigCheck { ok, absent, bad }

/// Verifies the top-level `"sig"` of a server wire line against `pubKeyHex`.
///
/// Returns [ServerSigCheck.absent] when the line carries no signature,
/// [ServerSigCheck.ok] when it verifies, [ServerSigCheck.bad] otherwise
/// (malformed slot or verification failure - the caller must drop the line).
Future<ServerSigCheck> checkServerSig(
  String line,
  String pubKeyHex, {
  Ed25519? ed,
}) async {
  final ed25519 = ed ?? Ed25519();
  const marker = '"sig":"';
  final at = line.lastIndexOf(marker);
  if (at < 0) return ServerSigCheck.absent;
  final start = at + marker.length;
  final end = start + 128;
  if (end + 1 > line.length || line[end] != '"') {
    return ServerSigCheck.bad;
  }
  final sigHex = line.substring(start, end);
  if (!_hexPattern.hasMatch(sigHex) || pubKeyHex.length != 64) {
    return ServerSigCheck.bad;
  }
  final zeroed = line.substring(0, start) + '0' * 128 + line.substring(end);
  final pub = SimplePublicKey(_unhex(pubKeyHex), type: KeyPairType.ed25519);
  final ok = await ed25519.verify(
    utf8.encode(zeroed),
    signature: Signature(_unhex(sigHex), publicKey: pub),
  );
  return ok ? ServerSigCheck.ok : ServerSigCheck.bad;
}

/// Convenience for the transport: checks against the pinned key.
Future<ServerSigCheck> checkServerEnvelopeSig(String line, {Ed25519? ed}) =>
    checkServerSig(line, serverSignPublicKeyHex, ed: ed);
