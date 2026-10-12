import 'dart:async';

import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// User-selectable capture devices. The choice persists and the camera/
/// microphone open path feeds it into getUserMedia constraints.
///
/// OBS Virtual Camera is the universal fix for the DirectShow 15 fps
/// ceiling: OBS itself uses a well-driven MJPG pipeline, so its virtual
/// camera typically delivers a true 30 fps we can carry. It is marked in
/// the device list and auto-preferred when the user has no explicit
/// choice; installing OBS itself is the user's one-time setup (an
/// application cannot install a system-wide camera filter silently).
abstract final class MediaPrefs {
  static const cameraKey = 'media.cameraDeviceId';
  static const micKey = 'media.micDeviceId';

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

  static Future<List<MediaDeviceInfo>> cameras() async => (await _devices())
      .where((d) => d.kind == 'videoinput')
      .toList();

  static Future<List<MediaDeviceInfo>> mics() async => (await _devices())
      .where((d) => d.kind == 'audioinput')
      .toList();

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

  /// The OBS virtual camera device when present (its label carries OBS).
  static Future<String?> obsVirtualCamera() async {
    for (final d in await cameras()) {
      if (d.label.toLowerCase().contains('obs')) return d.deviceId;
    }
    return null;
  }

  /// Best-effort default: the user's explicit pick wins, then OBS virtual
  /// camera, then whatever the platform gives.
  static Future<String?> preferredCameraId() async {
    final explicit = await cameraDeviceId();
    if (explicit != null && explicit.isNotEmpty) return explicit;
    return obsVirtualCamera();
  }

  static Future<String?> preferredMicId() async {
    final explicit = await micDeviceId();
    if (explicit != null && explicit.isNotEmpty) return explicit;
    return null;
  }

  /// Devices with this substring get marked as the universal fallback in
  /// the settings UI.
  static const obsMarker = 'obs';

  static bool looksLikeObs(String label) =>
      label.toLowerCase().contains(obsMarker);
}
