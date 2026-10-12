import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart' show MediaDeviceInfo;

import '../app/providers.dart';
import '../app/theme.dart';
import '../desktop/autostart.dart';
import '../desktop/desktop.dart';
import '../desktop/desktop_log.dart';
import '../media/media_prefs.dart';
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

/// «Аудио и видео»: выбор камеры и микрофона из устройств системы.
/// Выбор сохраняется и используется при открытии медиа в звонках; OBS
/// Virtual Camera подсвечивается как универсальный вариант (честные 30
/// fps через её MJPG-капчу) и становится default'ом, если выбор не задан.
class _MediaDevicesSection extends StatefulWidget {
  const _MediaDevicesSection();

  @override
  State<_MediaDevicesSection> createState() => _MediaDevicesSectionState();
}

class _MediaDevicesSectionState extends State<_MediaDevicesSection> {
  String? _cameraId;
  String? _micId;
  List<MediaDeviceInfo>? _cameras;
  List<MediaDeviceInfo>? _mics;
  String? _obsId;
  bool _loading = false;

  @override
  void initState() {
    super.initState();
    _loadSelection();
  }

  /// Only reads the persisted selection: device enumeration touches native
  /// capture plumbing, which must not run on every settings open (and in
  /// tests would raise plugin exceptions).
  Future<void> _loadSelection() async {
    final camId = await MediaPrefs.cameraDeviceId();
    final micId = await MediaPrefs.micDeviceId();
    if (mounted) {
      setState(() {
        _cameraId = camId;
        _micId = micId;
      });
    }
  }

  Future<void> _refresh() async {
    if (_loading) return;
    setState(() => _loading = true);
    try {
      // Enumerating walks platform channels; errors (e.g. no plugin in
      // tests) are surfaced as an empty list.
      final cams = await MediaPrefs.cameras();
      final mics = await MediaPrefs.mics();
      final obsId = await MediaPrefs.obsVirtualCamera();
      if (!mounted) return;
      setState(() {
        _cameras = cams;
        _mics = mics;
        _obsId = obsId;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _cameras = const [];
        _mics = const [];
        _obsId = null;
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return _mediaSection(context, 'Аудио и видео', [
      _pickRow(
        icon: Icons.videocam,
        title: 'Камера',
        entries: _cameras,
        currentId: _cameraId,
        obsId: _obsId,
        onChange: (id) async {
          await MediaPrefs.setCameraDeviceId(id);
          await _loadSelection();
          await _refresh();
        },
      ),
      _pickRow(
        icon: Icons.mic,
        title: 'Микрофон',
        entries: _mics,
        currentId: _micId,
        obsId: null,
        onChange: (id) async {
          await MediaPrefs.setMicDeviceId(id);
          await _loadSelection();
          await _refresh();
        },
      ),
      if (_obsId == null &&
          _cameras != null &&
          !_cameras!.any((d) => MediaPrefs.looksLikeObs(d.label)))
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 10),
          child: Text(
            'Универсальный вариант для 30 fps — OBS Virtual Camera: установи '
            'OBS и нажми «Start Virtual Camera», камера появится в списке '
            'и станет автоматическим выбором.',
            style: TextStyle(
                fontSize: 12, color: GrchatColors.of(context).textMuted),
          ),
        ),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        child: Align(
          alignment: Alignment.centerRight,
          child: OutlinedButton.icon(
            icon: _loading
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.refresh, size: 18),
            label: Text(_cameras == null
                ? 'Загрузить список устройств'
                : 'Перечитать устройства'),
            onPressed: _loading ? null : _refresh,
          ),
        ),
      ),
    ]);
  }

  Widget _mediaSection(BuildContext context, String title, List<Widget> rows) {
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

  Widget _pickRow(
      {required IconData icon,
      required String title,
      required List<MediaDeviceInfo>? entries,
      required String? currentId,
      required String? obsId,
      required Future<void> Function(String?) onChange}) {
    return ListTile(
      leading: Icon(icon),
      title: Text(title),
      subtitle: (entries == null || entries.isEmpty)
          ? const Text('Нажми «Загрузить список устройств»')
          : DropdownButtonHideUnderline(
              child: DropdownButton<String>(
                isExpanded: true,
                value: entries.any((d) => d.deviceId == currentId)
                    ? currentId
                    : null,
                hint: Text(_labelFor(entries, currentId)),
                items: [
                  DropdownMenuItem<String>(
                    value: '',
                    child: Text(currentId == null || currentId.isEmpty
                        ? 'Автоматически'
                        : 'Автоматически (сбросить выбор)'),
                  ),
                  for (final d in entries)
                    DropdownMenuItem<String>(
                      value: d.deviceId,
                      child: Row(children: [
                        Expanded(
                          child: Text(
                            _devLabel(d),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        if (MediaPrefs.looksLikeObs(d.label) ||
                            d.deviceId == obsId)
                          const Padding(
                            padding: EdgeInsets.only(left: 6),
                            child: Icon(Icons.stars, size: 16),
                          ),
                      ]),
                    ),
                ],
                onChanged: (v) => onChange(v),
              ),
            ),
    );
  }

  String _devLabel(MediaDeviceInfo d) {
    final label = d.label.isEmpty ? 'Устройство ${d.deviceId}' : d.label;
    return MediaPrefs.looksLikeObs(d.label) ? '$label (30 fps)' : label;
  }

  String _labelFor(List<MediaDeviceInfo> entries, String? currentId) {
    if (currentId == null || currentId.isEmpty) {
      return 'Автоматически (по умолчанию)';
    }
    final d = entries.where((e) => e.deviceId == currentId).toList();
    if (d.isEmpty) return 'Автоматически (устройство недоступно)';
    return _devLabel(d.first);
  }
}

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
              const _MediaDevicesSection(),
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
        final size =
            '${(info.sizeBytes / 1048576).toStringAsFixed(1)} МБ';
        if (!UpdateCenter.supportsInstall) {
          // macOS/Linux: no in-place install yet, the dmg is fetched by hand.
          return ListTile(
            leading: const Icon(Icons.download),
            title: Text(
                'Доступна ${info.version}${info.prerelease ? ' (бета)' : ''}'),
            subtitle: Text(
                '$size — для этой платформы скачайте сборку из grchat-releases вручную'),
          );
        }
        return ListTile(
          leading: const Icon(Icons.download),
          title: Text(
              'Доступна ${info.version}${info.prerelease ? ' (бета)' : ''}'),
          subtitle: Text(
              '$size — скачивание закроет приложение и установит обновление'),
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
