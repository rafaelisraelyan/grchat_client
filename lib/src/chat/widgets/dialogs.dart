import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../search/find_dialog.dart';
import '../../search/search_address.dart';
import '../../search/search_results.dart';
import '../../widgets/esc_pop.dart';
import '../home_state.dart';
import '../../widgets/toast.dart';

Future<void> showServerDialog(BuildContext context, WidgetRef ref) async {
  final name = TextEditingController();
  final alias = TextEditingController();
  final code = TextEditingController();
  var isPrivate = false;
  String? error;
  await showEscDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
            builder: (ctx, setD) => AlertDialog(
              title: const Text('Сервер'),
              content: Column(mainAxisSize: MainAxisSize.min, children: [
                TextField(
                    controller: name,
                    decoration: const InputDecoration(
                        hintText: 'Название нового сервера')),
                const SizedBox(height: 8),
                TextField(
                    controller: alias,
                    decoration: const InputDecoration(
                        hintText: 'Код, напр. GRAUDIO (необязательно)')),
                const SizedBox(height: 8),
                TextField(
                    controller: code,
                    decoration: const InputDecoration(
                        hintText: 'Инвайт-код для входа')),
                Row(children: [
                  Checkbox(
                      value: isPrivate,
                      onChanged: (v) =>
                          setD(() => isPrivate = v ?? false)),
                  const Text('Приватный'),
                ]),
                if (error != null) ...[
                  const SizedBox(height: 4),
                  Text(error!,
                      style: const TextStyle(color: Colors.red)),
                ],
              ]),
              actions: [
                TextButton(
                    onPressed: () => Navigator.pop(ctx),
                    child: const Text('Отмена')),
                TextButton(
                    onPressed: () async {
                      final repo = ref.read(chatRepositoryProvider);
                      try {
                        String? openedId;
                        if (code.text.trim().isNotEmpty) {
                          await repo.joinByInvite(code.text);
                        } else if (name.text.trim().isNotEmpty) {
                          final a = alias.text.trim();
                          final created = await repo.createCommunity(
                              name.text.trim(),
                              alias: a.isEmpty ? null : a,
                              isPrivate: isPrivate);
                          openedId = created.communityId;
                        }
                        final st = ref
                            .read(homeStateProvider.notifier);
                        await st.refresh();
                        if (openedId != null && context.mounted) {
                          await _openCommunity(
                              ref, st, openedId, context);
                        }
                      } catch (e) {
                        setD(() => error = searchErrorText(
                            SearchTargetType.server, e));
                        return;
                      }
                      if (ctx.mounted) Navigator.pop(ctx);
                    },
                    child: const Text('Ок')),
              ],
            ),
          ));
}

/// Selects the first text channel of a community (after create/join).
Future<void> _openCommunity(WidgetRef ref, HomeState st, String communityId,
    BuildContext context) async {
  try {
    final comms = ref
        .read(homeStateProvider)
        .communities
        .where((c) => c.id == communityId);
    if (comms.isNotEmpty) {
      final chs =
          comms.first.channels.where((c) => c.type == 'text');
      if (chs.isNotEmpty) await st.selectChannel(comms.first, chs.first);
    }
  } catch (e) {
    if (context.mounted) Toast.show(context, '$e');
  }
}

/// The "+" menu in the rail: find first, create second. Never mixed.
Future<void> showAddMenu(BuildContext context, WidgetRef ref) async {
  final pick = await showEscDialog<String>(
      context: context,
      builder: (ctx) => SimpleDialog(
            title: const Text('Добавить'),
            children: [
              SimpleDialogOption(
                  onPressed: () => Navigator.pop(ctx, 'find'),
                  child: const Text('Найти')),
              SimpleDialogOption(
                  onPressed: () => Navigator.pop(ctx, 'server'),
                  child: const Text('Создать сервер')),
              SimpleDialogOption(
                  onPressed: () => Navigator.pop(ctx, 'channel'),
                  child: const Text('Создать канал')),
              const SimpleDialogOption(
                  onPressed: null,
                  child: Text('Создать бота · Скоро')),
            ],
          ));
  if (!context.mounted) return;
  switch (pick) {
    case 'find':
      await showFindDialog(context, ref);
    case 'server':
      await showServerDialog(context, ref);
    case 'channel':
      await showCreateChannelDialog(context, ref);
  }
}

Future<void> showCreateChannelDialog(
    BuildContext context, WidgetRef ref) async {
  final name = TextEditingController();
  final alias = TextEditingController();
  final description = TextEditingController();
  var isPrivate = false;
  String? error;
  await showEscDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
            builder: (ctx, setD) => AlertDialog(
              title: const Text('Новый канал'),
              content: Column(mainAxisSize: MainAxisSize.min, children: [
                TextField(
                    controller: name,
                    decoration: const InputDecoration(
                        hintText: 'Название канала')),
                const SizedBox(height: 8),
                TextField(
                    controller: alias,
                    decoration: const InputDecoration(
                        hintText: 'Код, напр. NEWS (необязательно)')),
                const SizedBox(height: 8),
                TextField(
                    controller: description,
                    maxLines: 2,
                    decoration: const InputDecoration(
                        hintText: 'Описание (необязательно)')),
                Row(children: [
                  Checkbox(
                      value: isPrivate,
                      onChanged: (v) =>
                          setD(() => isPrivate = v ?? false)),
                  const Text('Приватный'),
                ]),
                if (error != null) ...[
                  const SizedBox(height: 4),
                  Text(error!,
                      style: const TextStyle(color: Colors.red)),
                ],
              ]),
              actions: [
                TextButton(
                    onPressed: () => Navigator.pop(ctx),
                    child: const Text('Отмена')),
                TextButton(
                    onPressed: () async {
                      if (name.text.trim().length < 2) {
                        setD(() => error = 'Некорректное название.');
                        return;
                      }
                      try {
                        final repo =
                            ref.read(chatRepositoryProvider);
                        final a = alias.text.trim();
                        final created = await repo.createChannel(
                            name: name.text.trim(),
                            type: 'broadcast',
                            alias: a.isEmpty ? null : a,
                            isPrivate: isPrivate,
                            description: description.text.trim().isEmpty
                                ? null
                                : description.text.trim());
                        final st = ref
                            .read(homeStateProvider.notifier);
                        await st.refresh();
                        final mine = ref
                            .read(homeStateProvider)
                            .myChannels
                            .where((c) => c.id == created.channelId);
                        if (mine.isNotEmpty) {
                          await st.selectStandaloneChannel(mine.first);
                        }
                      } catch (e) {
                        setD(() => error = searchErrorText(
                            SearchTargetType.channel, e));
                        return;
                      }
                      if (ctx.mounted) Navigator.pop(ctx);
                    },
                    child: const Text('Создать')),
              ],
            ),
          ));
}

Future<void> showChannelGrantDialog(
    BuildContext context, WidgetRef ref, String channelId,
    {bool adminChoice = false}) async {
  final nick = TextEditingController();
  var role = 'member';
  String? error;
  await showEscDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
            builder: (ctx, setD) => AlertDialog(
              title: const Text('Добавить участника'),
              content: Column(mainAxisSize: MainAxisSize.min, children: [
                TextField(
                    controller: nick,
                    decoration: const InputDecoration(
                        hintText: 'Ник пользователя')),
                if (adminChoice) ...[
                  const SizedBox(height: 8),
                  SegmentedButton<String>(
                    segments: const [
                      ButtonSegment(
                          value: 'member',
                          label: Text('Участник')),
                      ButtonSegment(
                          value: 'admin',
                          label: Text('Админ')),
                    ],
                    selected: {role},
                    onSelectionChanged: (s) =>
                        setD(() => role = s.first),
                  ),
                ],
                if (error != null) ...[
                  const SizedBox(height: 8),
                  Text(error!,
                      style: const TextStyle(color: Colors.red)),
                ],
              ]),
              actions: [
                TextButton(
                    onPressed: () => Navigator.pop(ctx),
                    child: const Text('Отмена')),
                TextButton(
                    onPressed: () async {
                      try {
                        await ref
                            .read(chatRepositoryProvider)
                            .channelGrant(channelId, nick.text.trim(),
                                role: role);
                      } catch (e) {
                        setD(() => error = searchErrorText(
                            SearchTargetType.channel, e));
                        return;
                      }
                      if (ctx.mounted) Navigator.pop(ctx);
                    },
                    child: const Text('Добавить')),
              ],
            ),
          ));
}

class _RepoFindApi implements FindSearchApi {
  _RepoFindApi(this.ref);
  final WidgetRef ref;

  @override
  Future<ServerHit> findServer(String alias) =>
      ref.read(chatRepositoryProvider).findServer(alias);

  @override
  Future<ChannelHit> findChannel(String alias) =>
      ref.read(chatRepositoryProvider).findChannel(alias);

  @override
  Future<({String userId, String nick})> findUser(String nick) =>
      ref.read(chatRepositoryProvider).findUser(nick);
}

/// Quick navigation palette (§81, future Ctrl+K): DMs, servers, channels.
/// Enter jumps to the first match, Esc closes.
Future<void> showQuickNav(BuildContext context, WidgetRef ref) async {
  final st = ref.read(homeStateProvider.notifier);
  final data = ref.read(homeStateProvider);
  final myId = ref.read(sessionProvider)?.userId ?? '';
  final query = TextEditingController();
  final entries = <_NavEntry>[];
  for (final d in data.dms) {
    entries.add(_NavEntry(
        label: d.title(myId),
        hint: d.isGroup ? 'Группа' : 'Личка',
        open: () => st.selectDm(d)));
  }
  for (final c in data.communities) {
    for (final ch in c.channels) {
      if (ch.type != 'text') continue;
      entries.add(_NavEntry(
          label: '# ${ch.name}',
          hint: c.name,
          open: () => st.selectChannel(c, ch)));
    }
  }
  for (final ch in data.myChannels) {
    entries.add(_NavEntry(
        label: ch.name, hint: 'Канал', open: () => st.selectStandaloneChannel(ch)));
  }
  if (entries.isEmpty) return;
  await showEscDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
            builder: (ctx, setD) {
              final q = query.text.trim().toLowerCase();
              final shown = q.isEmpty
                  ? entries
                  : entries
                      .where((e) =>
                          e.label.toLowerCase().contains(q) ||
                          e.hint.toLowerCase().contains(q))
                      .toList();
              return AlertDialog(
                title: const Text('Перейти'),
                content: SizedBox(
                  width: 360,
                  child: Column(mainAxisSize: MainAxisSize.min, children: [
                    TextField(
                      controller: query,
                      autofocus: true,
                      decoration: const InputDecoration(
                          hintText: 'Чат, сервер, канал…'),
                      onChanged: (_) => setD(() {}),
                      onSubmitted: (_) {
                        if (shown.isNotEmpty) {
                          Navigator.pop(ctx);
                          shown.first.open();
                        }
                      },
                    ),
                    const SizedBox(height: 8),
                    Flexible(
                      child: ListView.builder(
                        shrinkWrap: true,
                        itemCount: shown.length,
                        itemBuilder: (c2, i) => ListTile(
                          dense: true,
                          title: Text(shown[i].label,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis),
                          subtitle: Text(shown[i].hint,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis),
                          onTap: () {
                            Navigator.pop(ctx);
                            shown[i].open();
                          },
                        ),
                      ),
                    ),
                  ]),
                ),
                actions: [
                  TextButton(
                      onPressed: () => Navigator.pop(ctx),
                      child: const Text('Закрыть')),
                ],
              );
            },
          ));
}

class _NavEntry {
  _NavEntry({required this.label, required this.hint, required this.open});
  final String label;
  final String hint;
  final Future<void> Function() open;
}

/// Unified find dialog wired to the live backend + navigation.
Future<void> showFindDialog(BuildContext context, WidgetRef ref) async {
  final st = ref.read(homeStateProvider.notifier);
  await showEscDialog(
      context: context,
      builder: (ctx) => FindDialog(
            search: _RepoFindApi(ref),
            onOpenServer: (hit) async {
              await st.refresh();
              if (ctx.mounted) {
                await _openCommunity(ref, st, hit.communityId, ctx);
              }
            },
            onOpenChannel: (hit) async {
              await st.refresh();
              if (hit.communityId != null) {
                final comms = ref
                    .read(homeStateProvider)
                    .communities
                    .where((c) => c.id == hit.communityId);
                if (comms.isNotEmpty) {
                  final chs = comms.first.channels
                      .where((c) => c.id == hit.channelId);
                  if (chs.isNotEmpty) {
                    await st.selectChannel(comms.first, chs.first);
                  }
                }
              } else {
                final mine = ref
                    .read(homeStateProvider)
                    .myChannels
                    .where((c) => c.id == hit.channelId);
                if (mine.isNotEmpty) {
                  await st.selectStandaloneChannel(mine.first);
                } else {
                  await st.selectStandaloneChannel(hit.toChannel());
                }
              }
            },
            onWriteUser: (nick) async {
              final repo = ref.read(chatRepositoryProvider);
              final dmId = await repo.openDm(nick);
              await st.refresh();
              final match = ref
                  .read(homeStateProvider)
                  .dms
                  .where((d) => d.id == dmId);
              if (match.isNotEmpty) await st.selectDm(match.first);
            },
            onJoinServer: (hit) async {
              await ref
                  .read(chatRepositoryProvider)
                  .joinServer(hit.alias);
              await st.refresh();
              if (ctx.mounted) {
                await _openCommunity(ref, st, hit.communityId, ctx);
              }
            },
            onSubscribeChannel: (hit) async {
              await ref
                  .read(chatRepositoryProvider)
                  .subscribeChannel(hit.alias);
              await st.refresh();
              final mine = ref
                  .read(homeStateProvider)
                  .myChannels
                  .where((c) => c.id == hit.channelId);
              if (mine.isNotEmpty) {
                await st.selectStandaloneChannel(mine.first);
              } else {
                // Community-bound public channel: access via membership list.
                final comms =
                    ref.read(homeStateProvider).communities;
                for (final comm in comms) {
                  final chs = comm.channels
                      .where((c) => c.id == hit.channelId);
                  if (chs.isNotEmpty) {
                    await st.selectChannel(comm, chs.first);
                    return;
                  }
                }
                await st.selectStandaloneChannel(hit.toChannel());
              }
            },
          ));
}

Future<void> showInviteDialog(BuildContext context, WidgetRef ref) async {
  final scope = ref.read(homeStateProvider).scope;
  if (scope is! ChannelScope) return;
  final community = scope.community;
  // Standalone channels have no community invites: grant by nick instead.
  if (community == null) {
    await showChannelGrantDialog(context, ref, scope.channel.id);
    return;
  }
  try {
    final code = await ref
        .read(chatRepositoryProvider)
        .createInvite(community.id);
    if (!context.mounted) return;
    await showEscDialog(
        context: context,
        builder: (ctx) => AlertDialog(
              title: const Text('Инвайт-код'),
              content: SelectableText(code,
                  style: const TextStyle(
                      fontSize: 20, fontWeight: FontWeight.w700)),
              actions: [
                TextButton(
                    onPressed: () {
                      Clipboard.setData(ClipboardData(text: code));
                      Navigator.pop(ctx);
                      Toast.show(context, 'Код скопирован');
                    },
                    child: const Text('Копировать')),
              ],
            ));
  } catch (e) {
    if (context.mounted) Toast.show(context, '$e');
  }
}

Future<void> showNewDmDialog(BuildContext context, WidgetRef ref) async {
  final nick = TextEditingController();
  final id = await showEscDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
            title: const Text('Новая личка'),
            content: TextField(
                controller: nick,
                decoration:
                    const InputDecoration(hintText: 'Ник пользователя')),
            actions: [
              TextButton(
                  onPressed: () => Navigator.pop(ctx),
                  child: const Text('Отмена')),
              TextButton(
                  onPressed: () async {
                    try {
                      final dmId = await ref
                          .read(chatRepositoryProvider)
                          .openDm(nick.text.trim());
                      if (ctx.mounted) Navigator.pop(ctx, dmId);
                    } catch (e) {
                      if (context.mounted) Toast.show(context, '$e');
                    }
                  },
                  child: const Text('Открыть')),
            ],
          ));
  if (id != null && context.mounted) {
    await ref.read(homeStateProvider.notifier).refresh();
    final dms = ref.read(homeStateProvider).dms;
    final found = dms.where((d) => d.id == id);
    if (found.isNotEmpty && context.mounted) {
      await ref.read(homeStateProvider.notifier).selectDm(found.first);
    }
  }
}

Future<void> showSearchDialog(BuildContext context, WidgetRef ref) async {
  final nick = TextEditingController();
  String? found;
  String? error;
  await showEscDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
            builder: (ctx, setD) => AlertDialog(
              title: const Text('Найти пользователя'),
              content: Column(mainAxisSize: MainAxisSize.min, children: [
                TextField(
                    controller: nick,
                    decoration:
                        const InputDecoration(hintText: 'Точный ник')),
                if (error != null) ...[
                  const SizedBox(height: 8),
                  Text(error!, style: const TextStyle(color: Colors.red)),
                ],
                if (found != null) ...[
                  const SizedBox(height: 8),
                  Text('Найден: $found',
                      style:
                          const TextStyle(fontWeight: FontWeight.w700)),
                ],
              ]),
              actions: [
                TextButton(
                    onPressed: () => Navigator.pop(ctx),
                    child: const Text('Отмена')),
                TextButton(
                    onPressed: () async {
                      try {
                        final u = await ref
                            .read(chatRepositoryProvider)
                            .findUser(nick.text.trim());
                        setD(() {
                          found = u.nick;
                          error = null;
                        });
                      } catch (e) {
                        setD(() {
                          found = null;
                          error = 'Не найден';
                        });
                      }
                    },
                    child: const Text('Найти')),
                if (found != null)
                  FilledButton(
                      onPressed: () => Navigator.pop(ctx, found),
                      child: const Text('Написать')),
              ],
            ),
          ));
  if (found != null && context.mounted) {
    try {
      final dmId =
          await ref.read(chatRepositoryProvider).openDm(found!);
      await ref.read(homeStateProvider.notifier).refresh();
      final dms = ref.read(homeStateProvider).dms;
      final match = dms.where((d) => d.id == dmId);
      if (match.isNotEmpty && context.mounted) {
        await ref.read(homeStateProvider.notifier).selectDm(match.first);
      }
    } catch (e) {
      if (context.mounted) Toast.show(context, '$e');
    }
  }
}
