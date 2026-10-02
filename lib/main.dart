import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'src/app/providers.dart';
import 'src/app/theme.dart';
import 'src/auth/auth_screen.dart';

void main() {
  runApp(const ProviderScope(child: GrchatApp()));
}

class GrchatApp extends ConsumerWidget {
  const GrchatApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final mode = ref.watch(themeModeProvider);
    return MaterialApp(
      title: 'grchat',
      theme: grchatLight,
      darkTheme: grchatDark,
      themeMode: mode,
      home: const AuthScreen(),
    );
  }
}
