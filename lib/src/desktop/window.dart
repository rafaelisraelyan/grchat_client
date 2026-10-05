import 'dart:io';

import 'package:window_manager/window_manager.dart';

bool get isDesktop =>
    Platform.isWindows || Platform.isMacOS || Platform.isLinux;

/// Bring the window forward (tray click, notification tap, incoming call).
Future<void> focusWindow() async {
  if (!isDesktop) return;
  try {
    if (await windowManager.isMinimized()) {
      await windowManager.restore();
    }
    await windowManager.show();
    await windowManager.focus();
  } catch (_) {}
}

/// True when the user is looking at the app right now.
Future<bool> windowEngaged() async {
  if (!isDesktop) return true;
  try {
    return await windowManager.isFocused();
  } catch (_) {
    return true;
  }
}

Future<void> hideWindow() async {
  if (!isDesktop) return;
  try {
    await windowManager.hide();
  } catch (_) {}
}

Future<void> destroyWindow() async {
  if (!isDesktop) return;
  try {
    await windowManager.destroy();
  } catch (_) {}
}
