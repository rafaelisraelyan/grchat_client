import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// macOS App Sandbox entitlements gate WebRTC, and the failure is invisible:
/// ICE still exchanges candidates and onTrack still fires, but the sandbox
/// drops inbound UDP so connectivity checks never answer and the peer
/// connection goes straight to Failed ("Selected ICE: unknown").
///
/// The bug shipped because Debug/Profile had `network.server` and Release did
/// not - and Codemagic only ever builds Release. These tests keep both files
/// in lockstep so that drift cannot come back.
void main() {
  // Keys WebRTC needs to form a candidate pair inside the sandbox.
  const webrtcKeys = [
    'com.apple.security.app-sandbox',
    'com.apple.security.network.client',
    // Inbound UDP: connectivity checks are sent from an unconnected socket.
    'com.apple.security.network.server',
    // macOS hides LAN addresses behind <uuid>.local; only multicast resolves them.
    'com.apple.security.network.multicast',
  ];

  Map<String, String> parseEntitlements(String path) {
    final body = File(path).readAsStringSync();
    // Minimal plist reader: <key>k</key> followed by <true/> or <string>..</string>.
    final out = <String, String>{};
    final entry = RegExp(
      r'<key>([^<]+)</key>\s*<(true|false)\s*/>|<key>([^<]+)</key>\s*<string>([^<]*)</string>',
    );
    for (final m in entry.allMatches(body)) {
      if (m.group(1) != null) {
        out[m.group(1)!] = m.group(2)!;
      } else {
        out[m.group(3)!] = m.group(4)!;
      }
    }
    return out;
  }

  final release = parseEntitlements('macos/Runner/Release.entitlements');
  final debugProfile =
      parseEntitlements('macos/Runner/DebugProfile.entitlements');

  group('macOS sandbox entitlements', () {
    test('Release carries every key WebRTC needs', () {
      for (final key in webrtcKeys) {
        expect(release.containsKey(key), isTrue,
            reason: 'Release.entitlements is missing $key - ICE will fail '
                'with "Selected ICE: unknown" and no media');
        expect(release[key], 'true', reason: '$key must be enabled');
      }
    });

    test('DebugProfile carries every key WebRTC needs', () {
      for (final key in webrtcKeys) {
        expect(debugProfile.containsKey(key), isTrue,
            reason: 'DebugProfile.entitlements is missing $key');
        expect(debugProfile[key], 'true', reason: '$key must be enabled');
      }
    });

    test('Release and DebugProfile agree on network keys', () {
      // The whole class of bug: one file gained a key, the other did not,
      // and only the Release build ever shipped.
      final networkKeys = {
        for (final e in release.keys)
          if (e.startsWith('com.apple.security.network')) e
      };
      for (final key in networkKeys) {
        expect(debugProfile.containsKey(key), isTrue,
            reason: '$key is in Release but not DebugProfile - debug and '
                'release builds would behave differently');
        expect(debugProfile[key], release[key]);
      }
      expect(networkKeys, isNotEmpty);
    });

    test('media permissions stay in place', () {
      for (final map in [release, debugProfile]) {
        expect(map['com.apple.security.device.audio-input'], 'true');
        expect(map['com.apple.security.device.camera'], 'true');
      }
    });

    test('Info.plist explains local network use', () {
      // macOS 15+ gates local network access; without this key the app cannot
      // prompt and LAN peers are unreachable.
      final plist = File('macos/Runner/Info.plist').readAsStringSync();
      expect(plist, contains('NSLocalNetworkUsageDescription'));
      expect(plist, contains('NSMicrophoneUsageDescription'));
      expect(plist, contains('NSCameraUsageDescription'));
    });
  });
}
