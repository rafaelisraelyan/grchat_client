import '../notify/notify.dart';
import 'tray_backend.dart';

/// Handles to desktop integrations for diagnostics (Settings → Система).
abstract final class DesktopKit {
  static TrayBackend? tray;
  static NotifyBackend? notify;
}
