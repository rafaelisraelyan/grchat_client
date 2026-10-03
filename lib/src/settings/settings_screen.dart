import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../app/providers.dart';

final storageUsageProvider = FutureProvider<Map<String, int>>((ref) async {
  final s = ref.watch(sessionProvider);
  if (s == null) return {'used_bytes': 0, 'quota_bytes': 0};
  try {
    final r = await ref
        .watch(connectionProvider)
        .request('storage_usage', fields: {'session_token': s.token});
    if (r['type'] == 'error') throw Exception(r['code']);
    return {
      'used_bytes': (r['used_bytes'] as num).toInt(),
      'quota_bytes': (r['quota_bytes'] as num).toInt(),
    };
  } catch (_) {
    return {'used_bytes': 0, 'quota_bytes': 0};
  }
});

class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final mode = ref.watch(themeModeProvider);
    final usage = ref.watch(storageUsageProvider);
    final session = ref.watch(sessionProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('Настройки')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          ListTile(
            leading: const Icon(Icons.person),
            title: Text(session?.nick ?? '?'),
            subtitle: const Text('Мой аккаунт'),
          ),
          const Divider(),
          SwitchListTile(
            secondary: const Icon(Icons.brightness_6),
            title: const Text('Тёмная тема'),
            value: mode == ThemeMode.dark,
            onChanged: (_) =>
                ref.read(themeModeProvider.notifier).toggle(),
          ),
          ListTile(
            leading: const Icon(Icons.cloud),
            title: const Text('Файлы на сервере'),
            subtitle: usage.when(
              data: (u) => Text(
                  '${_size(u['used_bytes']!)} из ${_size(u['quota_bytes']!)}'),
              loading: () => const Text('…'),
              error: (_, _) => const Text('—'),
            ),
          ),
          const ListTile(
            leading: Icon(Icons.dns),
            title: Text('Сервер'),
            subtitle: Text('127.0.0.1:8181 (скоро — выбор в настройках)'),
          ),
          const Divider(),
          ListTile(
            leading: const Icon(Icons.logout, color: Colors.red),
            title:
                const Text('Выйти', style: TextStyle(color: Colors.red)),
            onTap: () async {
              await ref.read(connectionProvider).dispose();
              ref.read(sessionProvider.notifier).set(null);
              if (context.mounted) Navigator.pop(context);
            },
          ),
        ],
      ),
    );
  }

  String _size(int b) => b < 1048576
      ? '${(b / 1024).toStringAsFixed(1)} КБ'
      : '${(b / 1048576).toStringAsFixed(1)} МБ';
}
