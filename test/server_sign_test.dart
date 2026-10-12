import 'dart:convert';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:grchat_client/src/transport/server_sign.dart';

List<int> _unhex(String s) => [
  for (var i = 0; i < s.length; i += 2)
    int.parse(s.substring(i, i + 2), radix: 16),
];

String _hex(List<int> b) =>
    b.map((e) => e.toRadixString(16).padLeft(2, '0')).join();

/// RFC 8032 §7.1 TEST 1 - the shared cross-implementation pin with
/// EnvelopeSignerTest.java (either side drifting is caught).
const rfc8032Seed =
    '9d61b19deffd5a60ba844af492ec2cc4'
    '4449c5697b326919703bac031cae7f60';
const rfc8032Pub =
    'd75a980182b10ab7d54bfed3c964073a'
    '0ee172f3daa62325af021a68f707511a';
const rfc8032EmptyMsgSig =
    'e5564300c360ac729086e2cc806e828a'
    '84877f1eb8e5d974d873e06522490155'
    '5fb8821590a33bacc61e39701cf9b46b'
    'd25bf5f0595bbe24655141438e7a100b';

/// Signs a zero-sig line deterministically over its exact UTF-8 bytes and
/// splices the real hex over the 128 zeros (mirrors EnvelopeSigner.java).
Future<String> signedLine(String zeroForm) async {
  final ed = Ed25519();
  final kp = await ed.newKeyPairFromSeed(_unhex(rfc8032Seed));
  final sig = await ed.sign(utf8.encode(zeroForm), keyPair: kp);
  return zeroForm.replaceRange(
    zeroForm.length - 2 - 128,
    zeroForm.length - 2,
    _hex(sig.bytes),
  );
}

void main() {
  test('RFC 8032 TEST 1 pin: produce the published signature', () async {
    final ed = Ed25519();
    final kp = await ed.newKeyPairFromSeed(_unhex(rfc8032Seed));
    final sig = await ed.sign(const [], keyPair: kp);
    expect(_hex(sig.bytes), rfc8032EmptyMsgSig);
  });

  test('ok: signed line verifies against the pinned-in-test key', () async {
    final line = await signedLine(
      '{"v":1,"type":"call_ring","ts":1730000000000,"sig":"${'0' * 128}"}',
    );
    expect(await checkServerSig(line, rfc8032Pub), ServerSigCheck.ok);
  });

  test('ok: escaped pseudo-"sig" inside a string value is ignored', () async {
    // Quotes inside JSON string values travel escaped, so the top-level
    // marker is the last `"sig":"` occurrence and the slot is still the
    // true one.
    final line = await signedLine(
      '{"v":1,"type":"msg","body":"\\"sig\\":\\"'
      '${'a' * 128}\\"","ts":1,"sig":"${'0' * 128}"}',
    );
    expect(await checkServerSig(line, rfc8032Pub), ServerSigCheck.ok);
  });

  test('bad: one flipped byte fails closed', () async {
    var line = await signedLine(
      '{"v":1,"type":"x","ts":1,"sig":"${'0' * 128}"}',
    );
    line = line.replaceFirst('"type":"x"', '"type":"y"');
    expect(await checkServerSig(line, rfc8032Pub), ServerSigCheck.bad);
  });

  test('bad: wrong key, malformed slot, truncated slot', () async {
    final line = await signedLine(
      '{"v":1,"type":"x","ts":1,"sig":"${'0' * 128}"}',
    );
    expect(await checkServerSig(line, rfc8032Seed), ServerSigCheck.bad);
    expect(await checkServerSig('{"sig":"zz}', rfc8032Pub), ServerSigCheck.bad);
    expect(
      await checkServerSig(
        '{"v":1,"type":"x","ts":1,"sig":"${'f' * 127}',
        rfc8032Pub,
      ),
      ServerSigCheck.bad,
    );
  });

  test('absent: unsigned lines pass through (TLS is the boundary)', () async {
    expect(
      await checkServerSig('{"v":1,"type":"ping"}', rfc8032Pub),
      ServerSigCheck.absent,
    );
    expect(
      await checkServerSig('{"v":1,"sig":null}', rfc8032Pub),
      ServerSigCheck.absent,
    );
  });

  test('reconstruction round-trip is byte-exact', () async {
    final zeroForm =
        '{"v":1,"type":"x","body":"q\\"uote","ts":7,'
        '"sig":"${'0' * 128}"}';
    final line = await signedLine(zeroForm);
    final at = line.indexOf('"sig":"') + 7;
    final rebuilt =
        line.substring(0, at) + '0' * 128 + line.substring(at + 128);
    expect(rebuilt, zeroForm);
  });
}
