import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:window_manager/window_manager.dart';

import 'src/app/providers.dart';
import 'src/app/theme.dart';
import 'src/auth/auth_screen.dart';
import 'src/chat/home_screen.dart';
import 'src/desktop/autostart.dart';
import 'src/desktop/tray_backend.dart';
import 'src/desktop/window.dart';
import 'src/notify/notify.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (isDesktop) {
    try {
      await windowManager.ensureInitialized();
      await windowManager.setPreventClose(true);
      await windowManager.setTitle('GRChat');
    } catch (_) {}
  }
  runApp(const ProviderScope(child: GrchatApp()));
}

class GrchatApp extends ConsumerStatefulWidget {
  const GrchatApp({super.key});

  @override
  ConsumerState<GrchatApp> createState() => _GrchatAppState();
}

class _GrchatAppState extends ConsumerState<GrchatApp> with WindowListener {
  TrayBackend? _tray;
  var _desktopReady = false;

  @override
  void initState() {
    super.initState();
    if (isDesktop) {
      windowManager.addListener(this);
      _initDesktop();
    }
  }

  Future<void> _initDesktop() async {
    if (_desktopReady) return;
    _desktopReady = true;
    Autostart.setup();
    try {
      await ref.read(notifyBackendProvider).init();
    } catch (_) {}
    if (!mounted) return;
    _tray = TrayBackend(
      onShow: () => focusWindow(),
      onToggleAutostart: () async {
        await Autostart.toggle();
        await _tray?.refreshMenu();
      },
      isAutostartOn: () => Autostart.isOn(),
      autostartSupported: Autostart.supported,
      onQuit: () async {
        try {
          await ref.read(connectionProvider).dispose();
        } catch (_) {}
        await destroyWindow();
        exit(0);
      },
    );
    await _tray!.init();
  }

  @override
  void dispose() {
    if (isDesktop) windowManager.removeListener(this);
    super.dispose();
  }

  @override
  void onWindowClose() async {
    // Logged out (auth screen): real quit. Logged in: hide to tray.
    if (ref.read(sessionProvider) == null) {
      await destroyWindow();
    } else {
      await hideWindow();
    }
  }

  @override
  Widget build(BuildContext context) {
    final mode = ref.watch(themeModeProvider);
    return MaterialApp(
      title: 'grchat',
      theme: grchatLight,
      darkTheme: grchatDark,
      themeMode: mode,
      home: const _Root(),
    );
  }
}

class _Root extends ConsumerWidget {
  const _Root();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final session = ref.watch(sessionProvider);
    if (session == null) return const AuthScreen();
    return const HomeScreen();
  }
}
