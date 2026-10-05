import 'dart:io';

import 'package:flutter/services.dart';
import 'package:nativeapi/nativeapi.dart';
import 'package:path_provider/path_provider.dart';

import 'desktop_log.dart';

/// Windows/macOS/Linux tray icon: show on click, menu with autostart
/// toggle and quit. Mobile: no-op stub.
class TrayBackend {
  TrayBackend(
      {required this.onShow,
      required this.onToggleAutostart,
      required this.onQuit,
      required this.isAutostartOn,
      required this.onToggleNotifications,
      required this.isNotificationsOn,
      this.autostartSupported = true});

  final void Function() onShow;
  final Future<void> Function() onToggleAutostart;
  final Future<bool> Function() isAutostartOn;
  final Future<void> Function() onToggleNotifications;
  final Future<bool> Function() isNotificationsOn;
  final void Function() onQuit;
  final bool autostartSupported;

  String status = 'не готов';

  TrayIcon? _tray;
  // Retain every native-backed wrapper: GC runs their finalizers and
  // frees the handles, which silently kills clicks on a visible menu.
  // ignore: unused_field
  Menu? _menu;
  final _items = <MenuItem>[];
  // ignore: unused_field
  Image? _iconImage;

  bool get supported =>
      Platform.isWindows || Platform.isMacOS || Platform.isLinux;

  Future<void> init() async {
    if (!supported) {
      status = 'платформа без трея';
      return;
    }
    try {
      final icon = TrayIcon.create();
      if (icon == null) {
        status = 'не создан (native)';
        return;
      }
      final img = await _loadIcon();
      if (img == null) {
        status = 'иконка не загрузилась';
        return;
      }
      _iconImage = img;
      icon.icon = img;
      icon.setTooltip('GRChat');
      icon.setContextMenuTrigger(ContextMenuTrigger.rightClicked);
      icon.addListener((ev) {
        // Left click shows the window; right click opens the menu natively.
        if (ev is TrayIconClickedEvent) {
          DesktopLog.write('tray: icon clicked');
          onShow();
        }
      });
      _tray = icon;
      await _rebuildMenu();
      if (!icon.setVisible(true)) {
        status = 'не показался';
        return;
      }
      status = 'ок';
    } catch (e) {
      status = 'ошибка: $e';
    }
  }

  Future<void> refreshMenu() async {
    if (_tray == null) return;
    try {
      await _rebuildMenu();
    } catch (_) {}
  }

  /// Remove the icon before process exit. Otherwise Windows keeps
  /// a ghost icon until the cursor hovers over it.
  Future<void> disposeTray() async {
    try {
      _tray?.setVisible(false);
    } catch (_) {}
    try {
      _tray?.dispose();
    } catch (_) {}
    _tray = null;
  }

  Future<Image?> _loadIcon() async {
    for (final name in ['assets/tray.png', 'assets/tray.ico']) {
      try {
        final data = await rootBundle.load(name);
        final dir = await getTemporaryDirectory();
        final ext = name.endsWith('.png') ? 'png' : 'ico';
        final f = File('${dir.path}/grchat_tray.$ext');
        await f.writeAsBytes(data.buffer.asUint8List(), flush: true);
        final img = Image.fromFile(f.path);
        if (img != null) return img;
      } catch (_) {}
    }
    return null;
  }

  Future<void> _rebuildMenu() async {
    final tray = _tray;
    if (tray == null) return;
    final menu = Menu.create();
    if (menu == null) return;
    // Retain: see fields.
    _menu = menu;
    _items.clear();
    // Per-item listeners (the documented mechanism): each item emits its
    // own MenuItemClickedEvent. The menu itself only emits opened/closed.
    final open =
        MenuItem.createWithLabelAndType('Открыть', MenuItemType.normal);
    if (open != null) {
      open.addListener((ev) {
        if (ev is MenuItemClickedEvent) {
          DesktopLog.write('tray: open clicked');
          onShow();
        }
      });
      menu.addItem(open);
      _items.add(open);
    }
    final nto = MenuItem.createWithLabelAndType(
        'Уведомления', MenuItemType.checkbox);
    if (nto != null) {
      try {
        nto.state = await isNotificationsOn()
            ? MenuItemState.checked
            : MenuItemState.unchecked;
      } catch (_) {}
      nto.addListener((ev) {
        if (ev is MenuItemClickedEvent) {
          DesktopLog.write('tray: notifications clicked');
          () async {
            try {
              await onToggleNotifications();
              nto.state = await isNotificationsOn()
                  ? MenuItemState.checked
                  : MenuItemState.unchecked;
            } catch (_) {}
          }();
        }
      });
      menu.addItem(nto);
      _items.add(nto);
    }
    if (autostartSupported) {
      final auto = MenuItem.createWithLabelAndType(
          'Запускать вместе с системой', MenuItemType.checkbox);
      if (auto != null) {
        try {
          auto.state = await isAutostartOn()
              ? MenuItemState.checked
              : MenuItemState.unchecked;
        } catch (_) {}
        auto.addListener((ev) {
          if (ev is MenuItemClickedEvent) {
            DesktopLog.write('tray: autostart clicked');
            () async {
              try {
                await onToggleAutostart();
                auto.state = await isAutostartOn()
                    ? MenuItemState.checked
                    : MenuItemState.unchecked;
              } catch (_) {}
            }();
          }
        });
        menu.addItem(auto);
        _items.add(auto);
      }
    }
    menu.addSeparator();
    final quit =
        MenuItem.createWithLabelAndType('Выйти', MenuItemType.normal);
    if (quit != null) {
      quit.addListener((ev) {
        if (ev is MenuItemClickedEvent) {
          DesktopLog.write('tray: quit clicked');
          onQuit();
        }
      });
      menu.addItem(quit);
      _items.add(quit);
    }
    tray.setContextMenu(menu);
  }
}
