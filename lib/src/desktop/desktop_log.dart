import 'dart:io';

/// Append-only debug log for desktop integrations (tray clicks,
/// notification taps). Lives in the temp dir; Settings shows the path.
abstract final class DesktopLog {
  static File? _file;

  static String get path {
    final dir = Directory.systemTemp.path;
    return '$dir\\grchat_desktop.log';
  }

  static void write(String line) {
    try {
      _file ??= File(path);
      _file!.writeAsStringSync(
          '${DateTime.now().toIso8601String()} $line\n',
          mode: FileMode.append,
          flush: true);
    } catch (_) {}
  }
}
