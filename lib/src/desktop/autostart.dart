import 'dart:io';

import 'package:launch_at_startup/launch_at_startup.dart';
/// OS autostart (Windows/macOS; Linux distros differ — tray only there).
abstract final class Autostart {
  static bool get supported =>
      Platform.isWindows || Platform.isMacOS;

  static void setup() {
    if (!supported) return;
    try {
      LaunchAtStartup.instance.setup(
          appName: 'GRChat', appPath: Platform.resolvedExecutable);
    } catch (_) {}
  }

  static Future<bool> isOn() async {
    if (!supported) return false;
    try {
      return await LaunchAtStartup.instance.isEnabled();
    } catch (_) {
      return false;
    }
  }

  static Future<void> toggle() async {
    if (!supported) return;
    try {
      if (await LaunchAtStartup.instance.isEnabled()) {
        await LaunchAtStartup.instance.disable();
      } else {
        await LaunchAtStartup.instance.enable();
      }
    } catch (_) {}
  }
}
