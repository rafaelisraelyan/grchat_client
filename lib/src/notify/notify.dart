import 'dart:async';
import 'dart:io';

import 'package:local_notifier/local_notifier.dart';
import 'package:riverpod/riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../desktop/desktop_log.dart';

/// Per-platform system notifications.
///
/// Windows/macOS: native toasts via local_notifier (it also owns the
/// Start Menu shortcut Windows needs to deliver toasts at all).
/// Calls carry [Открыть]/[Отклонить] buttons, messages a click-through.
/// Linux: `notify-send` (fire-and-forget, no click routing).
/// Android/iOS: stub — background push there means FCM/APNs, a separate
/// project (client is desktop-first).
typedef NotifyTap = void Function();

abstract class NotifyBackend {
  bool get supported;
  String get status;
  Future<void> init();
  Future<bool> enabled();
  Future<void> setEnabled(bool on);
  void showMessage(
      {required String tag,
      required String title,
      required String body,
      NotifyTap? onTap});
  void showCall(
      {required String tag,
      required String title,
      required String body,
      NotifyTap? onOpen,
      NotifyTap? onDecline});
  void cancel(String tag);
}

NotifyBackend createNotifyBackend() {
  if (Platform.isWindows || Platform.isMacOS) {
    return _LocalNotifierBackend();
  }
  if (Platform.isLinux) return _LinuxNotify();
  return _StubNotify();
}

final notifyBackendProvider = Provider<NotifyBackend>((ref) {
  return createNotifyBackend();
});

class _LocalNotifierBackend implements NotifyBackend {
  final _taps = <String, NotifyTap>{};
  final _declines = <String, NotifyTap>{};
  final _live = <String, LocalNotification>{};
  var _status = 'не готов';

  @override
  bool get supported =>
      Platform.isWindows || Platform.isMacOS;

  @override
  String get status => _status;

  @override
  Future<void> init() async {
    if (!supported) {
      _status = 'платформа без тостов';
      return;
    }
    try {
      await localNotifier.setup(
        appName: 'GRChat',
        shortcutPolicy: ShortcutPolicy.requireCreate,
      );
      _status = 'ок';
    } catch (e) {
      _status = 'ошибка: $e';
    }
  }

  @override
  Future<bool> enabled() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getBool('notifications_enabled') ?? true;
    } catch (_) {
      return true;
    }
  }

  @override
  Future<void> setEnabled(bool on) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool('notifications_enabled', on);
    } catch (_) {}
  }

  @override
  void showMessage(
      {required String tag,
      required String title,
      required String body,
      NotifyTap? onTap}) {
    () async {
      try {
        if (!await enabled()) return;
        await cancel(tag);
        final n = LocalNotification(
          identifier: tag,
          title: title,
          body: body,
          silent: false,
        );
        if (onTap != null) {
          _taps[tag] = onTap;
          n.onClick = () {
            DesktopLog.write('notify: message tapped $tag');
            final tap = _taps.remove(tag);
            if (tap != null) Future.microtask(tap);
          };
        }
        n.onClose = (_) {
          _taps.remove(tag);
          _live.remove(tag);
        };
        _live[tag] = n;
        await n.show();
      } catch (_) {}
    }();
  }

  @override
  void showCall(
      {required String tag,
      required String title,
      required String body,
      NotifyTap? onOpen,
      NotifyTap? onDecline}) {
    () async {
      try {
        if (!await enabled()) return;
        await cancel(tag);
        final n = LocalNotification(
          identifier: tag,
          title: title,
          body: body,
          silent: false,
          actions: [
            LocalNotificationAction(text: 'Открыть'),
            LocalNotificationAction(text: 'Отклонить'),
          ],
        );
        if (onOpen != null) {
          _taps[tag] = onOpen;
          n.onClick = () {
            DesktopLog.write('notify: call opened $tag');
            final tap = _taps.remove(tag);
            if (tap != null) Future.microtask(tap);
          };
        }
        if (onDecline != null) {
          _declines[tag] = onDecline;
          n.onClickAction = (i) {
            if (i == 1) {
              DesktopLog.write('notify: call declined $tag');
              final d = _declines.remove(tag);
              _taps.remove(tag);
              if (d != null) Future.microtask(d);
            } else {
              DesktopLog.write('notify: call opened $tag');
              final tap = _taps.remove(tag);
              if (tap != null) Future.microtask(tap);
            }
          };
        }
        n.onClose = (_) {
          _taps.remove(tag);
          _declines.remove(tag);
          _live.remove(tag);
        };
        _live[tag] = n;
        await n.show();
      } catch (_) {}
    }();
  }

  @override
  Future<void> cancel(String tag) async {
    _taps.remove(tag);
    _declines.remove(tag);
    final n = _live.remove(tag);
    if (n == null) return;
    try {
      await n.close();
    } catch (_) {}
  }
}

class _LinuxNotify implements NotifyBackend {
  @override
  bool get supported => Platform.isLinux;

  @override
  String get status => 'notify-send';

  @override
  Future<void> init() async {}

  @override
  Future<bool> enabled() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getBool('notifications_enabled') ?? true;
    } catch (_) {
      return true;
    }
  }

  @override
  Future<void> setEnabled(bool on) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool('notifications_enabled', on);
    } catch (_) {}
  }

  @override
  void showMessage(
      {required String tag,
      required String title,
      required String body,
      NotifyTap? onTap}) {
    () async {
      if (!await enabled()) return;
      _send(title, body);
    }();
  }

  @override
  void showCall(
      {required String tag,
      required String title,
      required String body,
      NotifyTap? onOpen,
      NotifyTap? onDecline}) {
    () async {
      if (!await enabled()) return;
      _send(title, body);
    }();
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
  Future<void> cancel(String tag) async {}
}

class _StubNotify implements NotifyBackend {
  @override
  bool get supported => false;

  @override
  String get status => 'FCM/APNs — отдельный проект';

  @override
  Future<void> init() async {}

  @override
  Future<bool> enabled() async => false;

  @override
  Future<void> setEnabled(bool on) async {}

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
      NotifyTap? onOpen,
      NotifyTap? onDecline}) {}

  @override
  Future<void> cancel(String tag) async {}
}
