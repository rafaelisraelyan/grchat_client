import 'dart:async';
import 'dart:io';

import 'package:nativeapi/nativeapi.dart';
import 'package:riverpod/riverpod.dart';

/// Per-platform system notifications.
///
/// Windows/macOS: native toasts via nativeapi (tag = replace key, one
/// "Открыть" button, click routes back through [onTap]).
/// Linux: `notify-send` (fire-and-forget, no click routing).
/// Android/iOS: stub — background push there means FCM/APNs, a separate
/// project (client is desktop-first).
typedef NotifyTap = void Function();

abstract class NotifyBackend {
  bool get supported;
  Future<void> init();
  void showMessage(
      {required String tag,
      required String title,
      required String body,
      NotifyTap? onTap});
  void showCall(
      {required String tag,
      required String title,
      required String body,
      NotifyTap? onTap});
  void cancel(String tag);
}

NotifyBackend createNotifyBackend() {
  if (Platform.isWindows || Platform.isMacOS) {
    return _NativeNotify();
  }
  if (Platform.isLinux) return _LinuxNotify();
  return _StubNotify();
}

final notifyBackendProvider = Provider<NotifyBackend>((ref) {
  return createNotifyBackend();
});

class _NativeNotify implements NotifyBackend {
  final _taps = <String, NotifyTap>{};
  var _ready = false;

  @override
  bool get supported =>
      Platform.isWindows || Platform.isMacOS;

  @override
  Future<void> init() async {
    if (!supported) return;
    try {
      if (!NotificationManager.instance.isSupported()) return;
      NotificationManager.instance.initialize();
      NotificationManager.instance.addListener((ev) {
        if (ev is NotificationActivatedEvent && ev.argument != null) {
          final tap = _taps.remove(ev.argument);
          if (tap != null) Future.microtask(tap);
        }
      });
      _ready = true;
    } catch (_) {}
  }

  @override
  void showMessage(
      {required String tag,
      required String title,
      required String body,
      NotifyTap? onTap}) {
    _show(tag: tag, title: title, body: body, onTap: onTap);
  }

  @override
  void showCall(
      {required String tag,
      required String title,
      required String body,
      NotifyTap? onTap}) {
    _show(tag: tag, title: title, body: body, onTap: onTap);
  }

  void _show(
      {required String tag,
      required String title,
      required String body,
      NotifyTap? onTap}) {
    if (!_ready) return;
    try {
      if (onTap != null) {
        _taps[tag] = onTap;
      } else {
        _taps.remove(tag);
      }
      NotificationManager.instance.show(title, body, tag, 'Открыть');
    } catch (_) {}
  }

  @override
  void cancel(String tag) {
    _taps.remove(tag);
    if (!_ready) return;
    try {
      NotificationManager.instance.remove(tag);
    } catch (_) {}
  }
}

class _LinuxNotify implements NotifyBackend {
  @override
  bool get supported => Platform.isLinux;

  @override
  Future<void> init() async {}

  @override
  void showMessage(
      {required String tag,
      required String title,
      required String body,
      NotifyTap? onTap}) {
    _send(title, body);
  }

  @override
  void showCall(
      {required String tag,
      required String title,
      required String body,
      NotifyTap? onTap}) {
    _send(title, body);
  }

  void _send(String title, String body) {
    // No click routing here; tray icon click opens the app.
    () async {
      try {
        await Process.run('notify-send', [title, body]);
      } catch (_) {}
    }();
  }

  @override
  void cancel(String tag) {}
}

class _StubNotify implements NotifyBackend {
  @override
  bool get supported => false;

  @override
  Future<void> init() async {}

  @override
  void showMessage(
      {required String tag,
      required String title,
      required String body,
      NotifyTap? onTap}) {}

  @override
  void showCall(
      {required String tag,
      required String title,
      required String body,
      NotifyTap? onTap}) {}

  @override
  void cancel(String tag) {}
}
