// STAGE 2C.4a - ETAP B: the test-only relay switch must be inert unless it is
// BOTH requested at compile time AND running in a debug build.
//
// The dangerous failure is a release build silently forcing relay, so all four
// combinations are asserted rather than reasoned about.

import 'package:flutter_test/flutter_test.dart';
import 'package:grchat_client/src/call/call_state.dart';

void main() {
  group('testRelayPolicyOverride (§2C.4a)', () {
    test('no flag -> normal ICE policy, in debug and in release', () {
      expect(testRelayPolicyOverride(flag: false, debug: true), isNull);
      expect(testRelayPolicyOverride(flag: false, debug: false), isNull);
    });

    test('flag in a DEBUG build -> relay', () {
      expect(testRelayPolicyOverride(flag: true, debug: true), 'relay');
    });

    test('flag in a RELEASE build -> must be ignored', () {
      expect(testRelayPolicyOverride(flag: true, debug: false), isNull,
          reason: 'a release build must never change ICE policy');
    });

    test('the compiled-in flag defaults to false', () {
      // Reading the actual compile-time constant used by _rtcConfig().
      expect(const bool.fromEnvironment('GRCHAT_TEST_FORCE_RELAY'), isFalse,
          reason: 'the default build must not request relay');
    });
  });
}