import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../app/theme.dart';
import '../../settings/settings_screen.dart';
import '../../widgets/avatar.dart';
import '../home_state.dart';
import '../models.dart';

/// Middle column: community channels or DM list, depending on rail context.
class ContextSidebar extends ConsumerWidget {
  const ContextSidebar({
    super.key,
    required this.onSearch,
    required this.onNewDm,
    required this.onVoice,
  });

  final VoidCallback onSearch;
  final VoidCallback onNewDm;
  final void Function(Channel channel) onVoice;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final data = ref.watch(homeStateProvider);
    final st = ref.read(homeStateProvider.notifier);
    final scope = data.scope;
    final myId = ref.read(sessionProvider)?.userId ?? '';
    if (data.activeCommunityId == null) {
      return SizedBox(
        width: 220,
        child: Material(
          color: GrchatColors.of(context).bgSidebar,
          child: _dmList(data, st, scope, myId),
        ),
      );
    }
    final found =
        data.communities.where((c) => c.id == data.activeCommunityId);
    final Community? comm = found.isNotEmpty ? found.first : null;
    return SizedBox(
      width: 220,
      child: Material(
        color: GrchatColors.of(context).bgSidebar,
        child:
            Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Padding(
            padding: const EdgeInsets.all(12),
            child: Text(comm?.name ?? 'grchat',
                style: const TextStyle(fontWeight: FontWeight.w700)),
          ),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              children: [
                if (comm != null) ...[
                  groupLabel('Текстовые каналы'),
                  for (final ch
                      in comm.channels.where((c) => c.type == 'text'))
                    ChannelTile(
                        title: '# ${ch.name}',
                        selected: scope?.key == 'c:${ch.id}',
                        onTap: () => st.selectChannel(comm, ch),
                        unread: data.unread['c:${ch.id}']),
                  groupLabel('Голосовые каналы'),
                  for (final ch
                      in comm.channels.where((c) => c.type != 'text'))
                    ListTile(
                        dense: true,
                        leading:
                            const Icon(Icons.volume_up, size: 18),
                        title: Text(ch.name),
                        onTap: () => onVoice(ch)),
                ],
              ],
            ),
          ),
          const UserPanel(),
        ]),
      ),
    );
  }

  Widget _dmList(HomeData data, HomeState st, Scope? scope, String myId) {
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Padding(
        padding: const EdgeInsets.all(12),
        child: Row(children: [
          const Expanded(
            child: Text('Личные сообщения',
                style: TextStyle(fontWeight: FontWeight.w700)),
          ),
          IconButton(
              tooltip: 'Найти пользователя',
              icon: const Icon(Icons.search, size: 18),
              onPressed: onSearch),
        ]),
      ),
      Expanded(
        child: ListView(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          children: [
            for (final dm in data.dms)
              ChannelTile(
                  title: dm.title(myId),
                  selected: scope?.key == 'd:${dm.id}',
                  onTap: () => st.selectDm(dm),
                  unread: data.unread['d:${dm.id}'],
                  icon: dm.isGroup ? Icons.group : Icons.person),
            ListTile(
                dense: true,
                leading: const Icon(Icons.add, size: 18),
                title: const Text('Новая личка'),
                onTap: onNewDm),
          ],
        ),
      ),
      const UserPanel(),
    ]);
  }
}

Widget groupLabel(String t) => Padding(
    padding: const EdgeInsets.fromLTRB(8, 12, 8, 4),
    child: Text(t,
        style: const TextStyle(
            fontSize: 11, color: Colors.grey, fontWeight: FontWeight.w600)));

class ChannelTile extends StatelessWidget {
  const ChannelTile({
    super.key,
    required this.title,
    required this.selected,
    required this.onTap,
    this.unread,
    this.icon,
  });

  final String title;
  final bool selected;
  final VoidCallback onTap;
  final int? unread;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      dense: true,
      selected: selected,
      selectedTileColor:
          Theme.of(context).colorScheme.primary.withValues(alpha: 0.15),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      leading: icon == null ? null : Icon(icon, size: 18),
      title: Text(title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(fontWeight: selected ? FontWeight.w700 : null)),
      trailing: (unread ?? 0) > 0
          ? CircleAvatar(
              radius: 10,
              backgroundColor: Theme.of(context).colorScheme.primary,
              child: Text('$unread',
                  style: const TextStyle(fontSize: 11, color: Colors.white)))
          : null,
      onTap: onTap,
    );
  }
}

/// Bottom of the sidebar: me + settings/theme/logout.
class UserPanel extends ConsumerWidget {
  const UserPanel({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(sessionProvider);
    return Container(
      padding: const EdgeInsets.all(8),
      child: Row(children: [
        Avatar(s?.nick ?? '?', radius: 14),
        const SizedBox(width: 8),
        Expanded(
            child: Text(s?.nick ?? '?',
                maxLines: 1, overflow: TextOverflow.ellipsis)),
        IconButton(
            tooltip: 'Настройки',
            icon: const Icon(Icons.settings, size: 18),
            onPressed: () => Navigator.push(
                context,
                MaterialPageRoute(
                    builder: (_) => const SettingsScreen()))),
        IconButton(
            tooltip: 'Тема',
            icon: const Icon(Icons.brightness_6, size: 18),
            onPressed: () =>
                ref.read(themeModeProvider.notifier).toggle()),
        IconButton(
            tooltip: 'Выйти',
            icon: const Icon(Icons.logout, size: 18),
            onPressed: () async {
              await ref.read(connectionProvider).dispose();
              ref.read(sessionProvider.notifier).set(null);
            }),
      ]),
    );
  }
}
