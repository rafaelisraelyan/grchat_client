import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../app/providers.dart';
import '../app/theme.dart';
import '../desktop/autostart.dart';
import '../desktop/desktop.dart';
import '../desktop/desktop_log.dart';
import '../notify/notify.dart';
import '../update/update_service.dart';

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

class _AutostartRow extends StatefulWidget {
  const _AutostartRow();

  @override
  State<_AutostartRow> createState() => _AutostartRowState();
}

class _AutostartRowState extends State<_AutostartRow> {
  bool? _on;

  @override
  void initState() {
    super.initState();
    Autostart.isOn().then((v) {
      if (mounted) setState(() => _on = v);
    });
  }

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: const Icon(Icons.rocket_launch),
      title: const Text('Запускать вместе с системой'),
      trailing: Switch(
        value: _on ?? false,
        onChanged: _on == null
            ? null
            : (_) async {
                await Autostart.toggle();
                if (mounted) {
                  setState(() => _on = !(_on ?? false));
                }
              },
      ),
    );
  }
}

class _NotificationsRow extends ConsumerStatefulWidget {
  const _NotificationsRow();

  @override
  ConsumerState<_NotificationsRow> createState() =>
      _NotificationsRowState();
}

class _NotificationsRowState
    extends ConsumerState<_NotificationsRow> {
  bool? _on;

  @override
  void initState() {
    super.initState();
    ref.read(notifyBackendProvider).enabled().then((v) {
      if (mounted) setState(() => _on = v);
    });
  }

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: const Icon(Icons.notifications),
      title: const Text('Уведомления'),
      trailing: Switch(
        value: _on ?? true,
        onChanged: _on == null
            ? null
            : (_) async {
                final next = !(_on ?? true);
                await ref
                    .read(notifyBackendProvider)
                    .setEnabled(next);
                if (mounted) setState(() => _on = next);
              },
      ),
    );
  }
}

class SettingsScreen extends ConsumerWidget {  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Scaffold(
      appBar: AppBar(title: const Text('Настройки')),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560),
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              _section(context, 'Аккаунт', [
                _row(context,
                    icon: Icons.person,
                    title: ref.watch(sessionProvider)?.nick ?? '?',
                    subtitle: 'Никнейм'),
              ]),
              _section(context, 'Оформление', [
                _themeRow(context, ref),
              ]),
              _section(context, 'Хранилище', [
                _storageRow(ref),
              ]),
              if (Autostart.supported)
                _section(context, 'Система', [
                  const _AutostartRow(),
                  const _NotificationsRow(),
                  _row(context,
                      icon: Icons.notifications,
                      title:
                          'Уведомления: ${DesktopKit.notify?.status ?? '—'}',
                      subtitle: 'Системные тосты'),
                  _row(context,
                      icon: Icons.web_asset,
                      title: 'Трей: ${DesktopKit.tray?.status ?? '—'}',
                      subtitle: 'Иконка и меню'),
                  _row(context,
                      icon: Icons.description,
                      title: 'Лог трея и тостов',
                      subtitle: DesktopLog.path),
                ]),
              _section(context, 'Обновления', [
                _updateRows(context, ref),
              ]),
              const SizedBox(height: 8),
              OutlinedButton.icon(
                icon: const Icon(Icons.logout, color: Colors.red),
                label: const Text('Выйти',
                    style: TextStyle(color: Colors.red)),
                onPressed: () async {
                  await ref.read(connectionProvider).dispose();
                  ref.read(sessionProvider.notifier).set(null);
                  if (context.mounted) Navigator.pop(context);
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _section(BuildContext context, String title, List<Widget> rows) {
    final c = GrchatColors.of(context);
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(4, 12, 4, 6),
        child: Text(title,
            style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w700,
                color: c.textMuted)),
      ),
      Container(
        decoration: BoxDecoration(
            color: c.surface,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: c.borderSubtle)),
        child: Column(children: rows),
      ),
    ]);
  }

  Widget _row(BuildContext context,
      {required IconData icon,
      required String title,
      required String subtitle}) {
    return ListTile(
      leading: Icon(icon),
      title: Text(title),
      subtitle: Text(subtitle),
    );
  }

  Widget _themeRow(BuildContext context, WidgetRef ref) {
    final mode = ref.watch(themeModeProvider);
    return ListTile(
      leading: const Icon(Icons.brightness_6),
      title: const Text('Тема'),
      trailing: SegmentedButton<ThemeMode>(
        segments: const [
          ButtonSegment(
              value: ThemeMode.dark,
              icon: Icon(Icons.dark_mode, size: 18)),
          ButtonSegment(
              value: ThemeMode.light,
              icon: Icon(Icons.light_mode, size: 18)),
        ],
        selected: {mode == ThemeMode.system ? ThemeMode.dark : mode},
        onSelectionChanged: (s) {
          final want = s.first;
          final cur = ref.read(themeModeProvider);
          if ((cur == ThemeMode.dark) != (want == ThemeMode.dark)) {
            ref.read(themeModeProvider.notifier).toggle();
          }
        },
      ),
    );
  }

  Widget _storageRow(WidgetRef ref) {
    final usage = ref.watch(storageUsageProvider);
    return usage.when(
      data: (u) {
        final used = u['used_bytes']!;
        final quota = u['quota_bytes']!;
        final frac = quota == 0 ? 0.0 : (used / quota).clamp(0.0, 1.0);
        return ListTile(
          leading: const Icon(Icons.cloud),
          title: Text(
              '${_size(used)} из ${_size(quota)} использовано'),
          subtitle: Padding(
            padding: const EdgeInsets.only(top: 8),
            child: LinearProgressIndicator(value: frac),
          ),
        );
      },
      loading: () => const ListTile(
          leading: Icon(Icons.cloud), title: Text('…')),
      error: (_, _) => const ListTile(
          leading: Icon(Icons.cloud), title: Text('—')),
    );
  }

  String _size(int b) => b < 1048576
      ? '${(b / 1024).toStringAsFixed(1)} КБ'
      : '${(b / 1048576).toStringAsFixed(1)} МБ';

  Widget _updateRows(BuildContext context, WidgetRef ref) {
    final channel = ref.watch(updateChannelProvider);
    final upd = ref.watch(updateCenterProvider);
    final center = ref.read(updateCenterProvider.notifier);
    // Transparent Material: tappable ListTiles below need a Material
    // ancestor inside the section's background container for ink.
    return Material(
      color: Colors.transparent,
      child:
          Column(mainAxisSize: MainAxisSize.min, children: [
      FutureBuilder<String>(
        future: center.currentVersion(),
        builder: (ctx, snap) => ListTile(
          leading: const Icon(Icons.system_update),
          title: Text('Версия ${snap.data ?? '…'}'),
          subtitle: channel.when(
            data: (c) => Text(
                c == UpdateChannel.beta ? 'Канал: бета' : 'Канал: релиз'),
            loading: () => const Text('Канал: …'),
            error: (_, _) => const Text('Канал: релиз'),
          ),
          trailing: SegmentedButton<UpdateChannel>(
            segments: const [
              ButtonSegment(
                  value: UpdateChannel.release,
                  label: Text('Релиз')),
              ButtonSegment(
                  value: UpdateChannel.beta, label: Text('Бета')),
            ],
            selected: {
              channel.value ?? UpdateChannel.release
            },
            onSelectionChanged: (s) => center.setChannel(s.first),
          ),
        ),
      ),
      _updateStatus(context, ref, upd),
          ]),
    );
  }

  Widget _updateStatus(
      BuildContext context, WidgetRef ref, UpdateUiState upd) {
    final center = ref.read(updateCenterProvider.notifier);
    switch (upd.status) {
      case UpdateStatus.idle:
        return ListTile(
          leading: const Icon(Icons.refresh),
          title: const Text('Проверить обновления'),
          onTap: () => center.check(),
        );
      case UpdateStatus.checking:
        return const ListTile(
          leading: SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(strokeWidth: 2)),
          title: Text('Проверяем…'),
        );
      case UpdateStatus.uptodate:
        return ListTile(
          leading:
              Icon(Icons.check, color: GrchatColors.of(context).success),
          title: const Text('Установлена последняя версия'),
          onTap: () => center.check(),
        );
      case UpdateStatus.available:
        final info = upd.info!;
        return ListTile(
          leading: const Icon(Icons.download),
          title: Text(
              'Доступна ${info.version}${info.prerelease ? ' (бета)' : ''}'),
          subtitle: Text(
              '${(info.sizeBytes / 1048576).toStringAsFixed(1)} МБ — скачивание закроет приложение и установит обновление'),
          onTap: () => center.downloadAndInstall(),
        );
      case UpdateStatus.downloading:
        return ListTile(
          leading: const Icon(Icons.download),
          title: const Text('Скачиваем обновление…'),
          subtitle: Padding(
            padding: const EdgeInsets.only(top: 8),
            child:
                LinearProgressIndicator(value: upd.progress ?? 0),
          ),
        );
      case UpdateStatus.error:
        return ListTile(
          leading:
              Icon(Icons.error_outline, color: GrchatColors.of(context).danger),
          title: Text(upd.message ?? 'Ошибка'),
          onTap: () => center.check(),
        );
    }
  }
}
