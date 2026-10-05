import 'dart:io';

import 'package:flutter/services.dart';
import 'package:nativeapi/nativeapi.dart';
import 'package:path_provider/path_provider.dart';

/// Windows/macOS/Linux tray icon: show on click, menu with autostart
/// toggle and quit. Mobile: no-op stub.
class TrayBackend {
  TrayBackend(
      {required this.onShow,
      required this.onToggleAutostart,
      required this.onQuit,
      required this.isAutostartOn,
      this.autostartSupported = true});

  final void Function() onShow;
  final Future<void> Function() onToggleAutostart;
  final Future<bool> Function() isAutostartOn;
  final void Function() onQuit;
  final bool autostartSupported;

  TrayIcon? _tray;

  bool get supported =>
      Platform.isWindows || Platform.isMacOS || Platform.isLinux;

  Future<void> init() async {
    if (!supported) return;
    try {
      final icon = TrayIcon.create();
      if (icon == null) return;
      final img = await _loadIcon();
      if (img != null) icon.icon = img;
      icon.setTooltip('GRChat');
      icon.setContextMenuTrigger(ContextMenuTrigger.rightClicked);
      icon.addListener((ev) {
        // Left click shows the window; right click opens the menu natively.
        if (ev is TrayIconClickedEvent) onShow();
      });
      await _rebuildMenu();
      icon.setVisible(true);
      _tray = icon;
    } catch (_) {}
  }

  Future<void> refreshMenu() async {
    if (_tray == null) return;
    try {
      await _rebuildMenu();
    } catch (_) {}
  }

  Future<Image?> _loadIcon() async {
    try {
      final data = await rootBundle.load('assets/tray.ico');
      final dir = await getTemporaryDirectory();
      final f = File('${dir.path}/grchat_tray.ico');
      await f.writeAsBytes(data.buffer.asUint8List(), flush: true);
      return Image.fromFile(f.path);
    } catch (_) {
      return null;
    }
  }

  Future<void> _rebuildMenu() async {
    final tray = _tray;
    if (tray == null) return;
    final menu = Menu.create();
    if (menu == null) return;
    final open =
        MenuItem.createWithLabelAndType('Открыть', MenuItemType.normal);
    open?.addListener((ev) {
      if (ev is MenuItemClickedEvent) onShow();
    });
    if (open != null) menu.addItem(open);
    if (autostartSupported) {
      final auto = MenuItem.createWithLabelAndType(
          'Запускать вместе с системой', MenuItemType.checkbox);
      if (auto != null) {
        try {
          auto.state = await isAutostartOn()
              ? MenuItemState.checked
              : MenuItemState.unchecked;
        } catch (_) {}
        auto.addListener((ev) async {
          if (ev is MenuItemClickedEvent) {
            await onToggleAutostart();
            try {
              auto.state = await isAutostartOn()
                  ? MenuItemState.checked
                  : MenuItemState.unchecked;
            } catch (_) {}
          }
        });
        menu.addItem(auto);
      }
    }
    menu.addSeparator();
    final quit =
        MenuItem.createWithLabelAndType('Выйти', MenuItemType.normal);
    quit?.addListener((ev) {
      if (ev is MenuItemClickedEvent) onQuit();
    });
    if (quit != null) menu.addItem(quit);
    tray.setContextMenu(menu);
  }
}
