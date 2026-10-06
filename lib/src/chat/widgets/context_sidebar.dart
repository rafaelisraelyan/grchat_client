import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../app/theme.dart';
import '../../search/search_address.dart';
import '../../settings/settings_screen.dart';
import '../../voice/voice_state.dart';
import '../../widgets/avatar.dart';
import '../home_state.dart';
import '../../widgets/toast.dart';
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
            padding: const EdgeInsets.fromLTRB(12, 12, 4, 4),
            child: Row(children: [
              if (comm != null) ...[
                Avatar(comm.name, radius: 14),
                const SizedBox(width: 8),
              ],
              Expanded(
                child: Text(comm?.name ?? 'grchat',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontWeight: FontWeight.w700)),
              ),
              if ((comm?.alias ?? '').isNotEmpty)
                IconButton(
                    tooltip: 'Копировать адрес сервера',
                    icon: const Icon(Icons.link, size: 18),
                    onPressed: () {
                      Clipboard.setData(ClipboardData(
                          text: addressOf(SearchTargetType.server,
                              comm!.alias)));
                      Toast.show(context, 'Адрес скопирован');
                    }),
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
                if (comm != null) ...[
                  groupLabel('Текстовые каналы'),
                  for (final ch
                      in comm.channels.where((c) => c.type == 'text'))
                    ChannelTile(
                        title: ch.name,
                        selected: scope?.key == 'c:${ch.id}',
                        onTap: () => st.selectChannel(comm, ch),
                        unread: data.unread['c:${ch.id}']),
                  groupLabel('Голосовые каналы'),
                  for (final ch
                      in comm.channels.where((c) => c.type != 'text'))
                    VoiceTile(channel: ch, members: data.members),
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
        padding: const EdgeInsets.fromLTRB(12, 12, 4, 4),
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
              DmRow(
                thread: dm,
                myId: myId,
                selected: scope?.key == 'd:${dm.id}',
                onTap: () => st.selectDm(dm),
                unread: data.unread['d:${dm.id}'],
              ),
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

/// Channel row, 36px, subtle selected tint, unread dot.
class ChannelTile extends StatelessWidget {
  const ChannelTile({
    super.key,
    required this.title,
    required this.selected,
    required this.onTap,
    this.unread,
  });

  final String title;
  final bool selected;
  final VoidCallback onTap;
  final int? unread;

  @override
  Widget build(BuildContext context) {
    final c = GrchatColors.of(context);
    return InkWell(
      borderRadius: BorderRadius.circular(8),
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        height: 36,
        padding: const EdgeInsets.symmetric(horizontal: 8),
        decoration: BoxDecoration(
          color: selected ? c.surfaceSelected : Colors.transparent,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(children: [
          Text('#',
              style: TextStyle(
                  color: selected ? c.accent : c.textMuted,
                  fontWeight: FontWeight.w700)),
          const SizedBox(width: 6),
          Expanded(
            child: Text(title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                    color: selected ? c.textPrimary : c.textSecondary,
                    fontWeight:
                        selected ? FontWeight.w700 : FontWeight.w400)),
          ),
          if ((unread ?? 0) > 0)
            Container(
                width: 8,
                height: 8,
                decoration: BoxDecoration(
                    color: c.accent, shape: BoxShape.circle)),
        ]),
      ),
    );
  }
}

class VoiceTile extends ConsumerWidget {
  const VoiceTile(
      {super.key, required this.channel, required this.members});

  final Channel channel;
  final List<Member> members;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = GrchatColors.of(context);
    final voice = ref.watch(voiceStateProvider);
    final notifier = ref.read(voiceStateProvider.notifier);
    final joined =
        notifier.joinedChannelId == channel.id;
    final ids = voice[channel.id] ?? const {};
    String nick(String id) {
      for (final m in members) {
        if (m.userId == id) return m.nick;
      }
      return id.substring(0, 8);
    }

    return InkWell(
      borderRadius: BorderRadius.circular(8),
      onTap: () async {
        try {
          if (joined) {
            await notifier.leave();
          } else {
            await notifier.join(channel.id);
          }
        } catch (e) {
          if (context.mounted) Toast.show(context, '$e');
        }
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: joined ? c.surfaceSelected : Colors.transparent,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                height: 36,
                child: Row(children: [
                  Icon(Icons.volume_up,
                      size: 18,
                      color: joined ? c.accent : c.textMuted),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(channel.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            color: joined
                                ? c.textPrimary
                                : c.textSecondary,
                            fontWeight: joined
                                ? FontWeight.w700
                                : FontWeight.w400)),
                  ),
                  if (joined)
                    const Icon(Icons.logout, size: 14),
                ]),
              ),
              for (final id in ids)
                Padding(
                  padding:
                      const EdgeInsets.only(left: 24, top: 1, bottom: 1),
                  child: Text(nick(id),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          fontSize: 12, color: c.textSecondary)),
                ),
            ]),
      ),
    );
  }
}

/// DM conversation row: avatar, name, last message, unread badge.
class DmRow extends StatelessWidget {
  const DmRow({
    super.key,
    required this.thread,
    required this.myId,
    required this.selected,
    required this.onTap,
    this.unread,
  });

  final DmThread thread;
  final String myId;
  final bool selected;
  final VoidCallback onTap;
  final int? unread;

  @override
  Widget build(BuildContext context) {
    final c = GrchatColors.of(context);
    final others =
        thread.members.where((m) => m.userId != myId).toList();
    final name = thread.title(myId);
    final hasUnread = (unread ?? 0) > 0;
    return InkWell(
      borderRadius: BorderRadius.circular(8),
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 7),
        decoration: BoxDecoration(
          color: selected ? c.surfaceSelected : Colors.transparent,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(children: [
          thread.isGroup
              ? _GroupAvatar(members: others)
              : Avatar(others.isEmpty ? name : others.first.nick,
                  radius: 16),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          fontWeight: hasUnread || selected
                              ? FontWeight.w700
                              : FontWeight.w400,
                          color: hasUnread
                              ? c.textPrimary
                              : c.textSecondary)),
                  if ((thread.lastText ?? '').isNotEmpty)
                    Text(thread.lastText!,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            fontSize: 12, color: c.textMuted)),
                ]),
          ),
          if (hasUnread)
            Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
              decoration: BoxDecoration(
                  color: c.accent,
                  borderRadius: BorderRadius.circular(10)),
              child: Text('$unread',
                  style: const TextStyle(
                      fontSize: 11, color: Colors.white)),
            ),
        ]),
      ),
    );
  }
}

class _GroupAvatar extends StatelessWidget {
  const _GroupAvatar({required this.members});

  final List<DmMember> members;

  @override
  Widget build(BuildContext context) {
    if (members.isEmpty) return const Avatar('?', radius: 16);
    if (members.length == 1) return Avatar(members.first.nick, radius: 16);
    return SizedBox(
      width: 36,
      height: 32,
      child: Stack(children: [
        Positioned(
            left: 0,
            top: 0,
            child: Avatar(members[0].nick, radius: 11)),
        Positioned(
            right: 0,
            bottom: 0,
            child: Avatar(
                members.length > 1 ? members[1].nick : members[0].nick,
                radius: 11)),
      ]),
    );
  }
}

/// Bottom of the sidebar: me + settings. Theme/logout live in Settings.
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
      ]),
    );
  }
}
