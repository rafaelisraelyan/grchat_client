import 'dart:async';

import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// User-selectable capture devices. The choice persists and the camera/
/// microphone open path feeds it into getUserMedia constraints.
///
/// Device-selection grammar on the desktop plugin (§2026-10-13): BOTH the
/// camera and the recording device are matched ONLY through the legacy
/// `optional: [{sourceId: ...}]` values; a `deviceId` (any feather) only
/// selects the audio OUTPUT and `{exact: N}`-style maps are ignored for
/// inputs. Before the sourceId fix every pick was cosmetic: the capture
/// always opened device index 0.
///
/// Default device rule (§default-camera 2026-10-13): with no explicit
/// choice the FIRST PHYSICAL camera wins. Virtual cameras (OBS, NVIDIA
/// Broadcast, Snap Camera, …) are NOT the default any more — they were
/// promoted by the old "DirectShow 15 fps ceiling" assumption, which the
/// plugin path proved wrong (OBS VC delivers honest 1080p60 through our
/// DS stack once the device is selected properly).
abstract final class MediaPrefs {
  static const cameraKey = 'media.cameraDeviceId';
  static const micKey = 'media.micDeviceId';

  /// Substrings (lowercased) marking a VIRTUAL camera. One list for the
  /// default rule and the settings labeling.
  static const virtualMarkers = <String>[
    'obs',
    'virtual',
    'nvidia broadcast',
    'snap camera',
    'manycam',
    'xsplit',
    'droidcam',
    'camo',
    'privacy view',
  ];

  /// Virtual cameras that are a BLACK HOLE by design (privacy/shadow
  /// devices): while their host app shows nothing they deliver a synthetic
  /// black stream — measured 2026-10-14 as 1280x720 at ~465 fps, burning
  /// ~620 kbit/s so the peer sees a black screen that looks like a UI bug.
  /// They stay selectable by hand, but the dial-time walk must try every
  /// REAL camera before one of these (§dial-camera-walk).
  static const blackHoleMarkers = <String>[
    'privacy view',
    'dazzle',
  ];

  /// True when the label matches [blackHoleMarkers] (case-insensitive).
  static bool looksBlackHole(String label) {
    final low = label.toLowerCase();
    for (final m in blackHoleMarkers) {
      if (low.contains(m)) return true;
    }
    return false;
  }

  /// True when the label matches [virtualMarkers] (case-insensitive).
  static bool looksVirtual(String label) {
    final low = label.toLowerCase();
    for (final m in virtualMarkers) {
      if (low.contains(m)) return true;
    }
    return false;
  }

  /// Tests run without platform channels: a broken channel counts as «no
  /// persisted choice» and must never crash the settings screen.
  static Future<SharedPreferences?> _prefs() async {
    try {
      return await SharedPreferences.getInstance();
    } catch (_) {
      return null;
    }
  }

  static Future<List<MediaDeviceInfo>> _devices() async {
    try {
      return await navigator.mediaDevices.enumerateDevices();
    } catch (_) {
      return const [];
    }
  }

  static Future<List<MediaDeviceInfo>> cameras() async =>
      (await _devices()).where((d) => d.kind == 'videoinput').toList();

  static Future<List<MediaDeviceInfo>> mics() async =>
      (await _devices()).where((d) => d.kind == 'audioinput').toList();

  static Future<String?> cameraDeviceId() async {
    final p = await _prefs();
    return p?.getString(cameraKey);
  }

  static Future<void> setCameraDeviceId(String? id) async {
    final p = await _prefs();
    if (p == null) return;
    if (id == null) {
      await p.remove(cameraKey);
    } else {
      await p.setString(cameraKey, id);
    }
  }

  static Future<String?> micDeviceId() async {
    final p = await _prefs();
    return p?.getString(micKey);
  }

  static Future<void> setMicDeviceId(String? id) async {
    final p = await _prefs();
    if (p == null) return;
    if (id == null) {
      await p.remove(micKey);
    } else {
      await p.setString(micKey, id);
    }
  }

  /// The default pick from an already-captured device snapshot: the first
  /// PHYSICAL camera; when none exists, whatever is there. Pure so the
  /// rule is testable without platform channels.
  static String? defaultDeviceIdFrom(
    List<({String id, String label})> devices,
  ) {
    for (final d in devices) {
      if (!looksVirtual(d.label)) return d.id;
    }
    return devices.isEmpty ? null : devices.first.id;
  }

  static Future<String?> defaultCameraId() async {
    final cams = await cameras();
    return defaultDeviceIdFrom(
      cams.map((d) => (id: d.deviceId, label: d.label)).toList(),
    );
  }

  static Future<String?> defaultMicId() async {
    final all = await mics();
    return defaultDeviceIdFrom(
      all.map((d) => (id: d.deviceId, label: d.label)).toList(),
    );
  }

  /// Resolves the camera the capture opens: the explicit pick when it still
  /// exists (a stale pick is quietly reset to the default and the stored
  /// value cleared), else the default rule above.
  static Future<String?> resolveCameraId() async {
    final explicit = await cameraDeviceId();
    final devices = await cameras();
    final byId = {for (final d in devices) d.deviceId: d.label};
    if (explicit != null && explicit.isNotEmpty) {
      if (byId.containsKey(explicit)) return explicit;
      // The stored camera disappeared: quiet fallback + reset the pick.
      await setCameraDeviceId(null);
    }
    return defaultDeviceIdFrom(
      devices.map((d) => (id: d.deviceId, label: d.label)).toList(),
    );
  }

  /// Same contract as [resolveCameraId] for the microphone; the default
  /// rule applies too (first physical - virtual MICS are rare but
  /// Broadcast and OBS mic filters exist).
  static Future<String?> resolveMicId() async {
    final explicit = await micDeviceId();
    final devices = await mics();
    final byId = {for (final d in devices) d.deviceId: d.label};
    if (explicit != null && explicit.isNotEmpty) {
      if (byId.containsKey(explicit)) return explicit;
      await setMicDeviceId(null);
    }
    return defaultDeviceIdFrom(
      devices.map((d) => (id: d.deviceId, label: d.label)).toList(),
    );
  }

  /// The rescue order for a camera that delivered nothing at call start
  /// (§dial-camera-walk): every OTHER camera, ordered by how likely it is to
  /// be usable — physical first (the default rule), then ordinary virtual
  /// cameras (OBS / Broadcast outputs deliver real frames), and privacy /
  /// black-hole devices LAST: they hand out synthetic black video, so a call
  /// that "rescued" itself onto one looks broken (2026-10-14). Capped at
  /// [limit]: the walk rescues a dead default, it must not spend the dial
  /// time on a shelf of dead devices. Pure so the rule is testable without
  /// platform channels.
  static List<({String id, String label})> walkOrderFrom(
    List<({String id, String label})> devices,
    String? used, {
    int limit = 3,
  }) {
    final rest = devices.where((d) => d.id != used).toList()
      ..sort((a, b) => _walkRank(a.label).compareTo(_walkRank(b.label)));
    return rest.take(limit).toList();
  }

  /// 0 = real camera, 1 = virtual camera, 2 = privacy / black-hole device.
  static int _walkRank(String label) {
    if (looksBlackHole(label)) return 2;
    return looksVirtual(label) ? 1 : 0;
  }
}
