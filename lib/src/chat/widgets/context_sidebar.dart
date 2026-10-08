import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../app/theme.dart';
import '../../call/call_session.dart';
import '../../call/media_session.dart';
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
  });

  final VoidCallback onSearch;
  final VoidCallback onNewDm;

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
                    VoiceTile(
                        channel: ch,
                        community: comm,
                        members: data.members),
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
    return Semantics(
      button: true,
      excludeSemantics: true,
      label: 'Канал $title',
      child: InkWell(
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
      ),
    );
  }
}

class VoiceTile extends ConsumerWidget {
  const VoiceTile(
      {super.key,
      required this.channel,
      required this.community,
      required this.members});

  final Channel channel;
  final Community? community;
  final List<Member> members;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = GrchatColors.of(context);
    final voice = ref.watch(voiceStateProvider);
    final session = ref.watch(voiceSessionProvider);
    final sessionSt = ref.read(voiceSessionProvider.notifier);
    final homeSt = ref.read(homeStateProvider.notifier);
    final myId = ref.read(sessionProvider)?.userId ?? '';
    final joined = session?.channelId == channel.id;
    final ids = voice[channel.id] ?? const {};
    final limit = sessionSt.limits[channel.id] ?? 0;
    String nick(String id) {
      for (final m in members) {
        if (m.userId == id) return m.nick;
      }
      final peer = session != null && session.channelId == channel.id
          ? session.peers.where((p) => p.id == id)
          : const <VoicePeer>[];
      if (peer.isNotEmpty) return peer.first.nick;
      return id.length > 8 ? id.substring(0, 8) : id;
    }

    bool speaking(String id) {
      if (session == null || session.channelId != channel.id) return false;
      for (final p in session.peers) {
        if (p.id == id) return p.speaking;
      }
      return false;
    }

    VoicePeer? peerOf(String id) {
      if (session == null || session.channelId != channel.id) return null;
      for (final p in session.peers) {
        if (p.id == id) return p;
      }
      return null;
    }

    // Moderation power for this community (owner/admin/mod).
    String myRole = '';
    for (final m in members) {
      if (m.userId == myId) myRole = m.role;
    }
    final canMod =
        myRole == 'owner' || myRole == 'admin' || myRole == 'mod';
    final canManage = myRole == 'owner' || myRole == 'admin';

    return InkWell(
      borderRadius: BorderRadius.circular(8),
      onTap: () async {
        // Click is focus-or-join, never blind rejoin (§18/§22): already
        // here → select scope + expand; elsewhere → move; new → join.
        // A live session of any kind gates through the coordinator (§43):
        // confirm ends it first, never two at once (§1).
        if (joined) {
          homeSt.selectVoiceScope(community, channel);
          return;
        }
        // Warm the waiting-GIF decode in parallel with the connect.
        precacheWaitingGif(context);
        final started = await runMediaStart(context, ref,
            title: 'Подключиться к ${channel.name}?',
            action: 'подключиться',
            start: () => sessionSt.join(
                channelId: channel.id, title: channel.name),
            label: 'voice ${channel.name}',
            friendlyError: friendlyVoiceError);
        if (started) {
          homeSt.selectVoiceScope(community, channel);
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
                    child: Text(
                        limit > 0
                            ? '${channel.name} · ${ids.length}/$limit'
                            : channel.name,
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
                  if (canManage)
                    Tooltip(
                      message: 'Лимит участников',
                      child: InkWell(
                        borderRadius: BorderRadius.circular(12),
                        onTap: () => _limitDialog(context, sessionSt,
                            channel, limit),
                        child: const Padding(
                          padding: EdgeInsets.all(4),
                          child: Icon(Icons.group_add,
                              size: 14, color: Colors.grey),
                        ),
                      ),
                    ),
                  if (joined)
                    Tooltip(
                      message: 'Выйти из войса',
                      child: InkWell(
                        borderRadius: BorderRadius.circular(12),
                        onTap: () async {
                          try {
                            await leaveVoice(
                                ref.read(
                                    voiceSessionProvider.notifier),
                                ref.read(homeStateProvider.notifier),
                                ref.read(homeStateProvider).scope,
                                channel.id);
                          } catch (e) {
                            if (context.mounted) {
                              Toast.show(
                                  context, friendlyVoiceError(e));
                            }
                          }
                        },
                        child: const Padding(
                          padding: EdgeInsets.all(4),
                          child: Icon(Icons.logout, size: 14),
                        ),
                      ),
                    ),
                ]),
              ),
              for (final id in ids)
                Padding(
                  padding:
                      const EdgeInsets.only(left: 24, top: 1, bottom: 1),
                  child: _VoiceRowButton(
                      id: id,
                      nick: nick(id),
                      speaking: speaking(id),
                      peer: peerOf(id),
                      canMod: canMod,
                      onMenu: () => _peerMenu(
                          context, sessionSt, channel.id, id, nick(id),
                          peerOf(id), canMod,
                          inChannel: joined)),
                ),
            ]),
      ),
    );
  }
}

/// Speaking-ring green (Discord-style): fixed hue, loudness drives opacity.
const _speakGreen = Color(0xFF57F287);

/// Roster row: avatar with a loudness-driven green ring while speaking,
/// mic-off when muted. Tappable for the peer menu
/// (local mute for everyone, server mute for moderators).
class _VoiceRowButton extends StatelessWidget {
  const _VoiceRowButton(
      {required this.id,
      required this.nick,
      required this.speaking,
      required this.peer,
      required this.canMod,
      required this.onMenu});

  final String id;
  final String nick;
  final bool speaking;
  final VoicePeer? peer;
  final bool canMod;
  final VoidCallback onMenu;

  @override
  Widget build(BuildContext context) {
    final self = peer?.self ?? false;
    return InkWell(
      borderRadius: BorderRadius.circular(8),
      onTap: self ? null : onMenu,
      child: _VoiceRow(
          nick: nick,
          speaking: speaking,
          muted: peer?.muted ?? true,
          serverMuted: peer?.serverMuted ?? false,
          level: peer?.audioLevel ?? 0.0),
    );
  }
}

/// Roster row: avatar with a loudness-driven green ring while speaking,
/// mic-off when muted.
class _VoiceRow extends StatelessWidget {
  const _VoiceRow(
      {required this.nick,
      required this.speaking,
      required this.muted,
      this.serverMuted = false,
      this.level = 0.0});

  final String nick;
  final bool speaking;
  final bool muted;
  final bool serverMuted;

  /// Mic loudness 0..1: louder = more solid green. Silent = no ring.
  final double level;

  @override
  Widget build(BuildContext context) {
    final c = GrchatColors.of(context);
    // Discord-style speaking ring: fixed 2px, only the opacity breathes
    // with the voice. Speaking always shows at least a faint ring (quiet
    // frames quantize to 0 but must not blink out); louder = more solid.
    final ring = speaking
        ? _speakGreen.withValues(
            alpha: 0.35 + 0.65 * level.clamp(0.0, 1.0))
        : Colors.transparent;
    return Row(mainAxisSize: MainAxisSize.min, children: [
      AnimatedContainer(
        // Appear fast (voice already audible), fade out smoothly.
        duration: Duration(milliseconds: speaking ? 120 : 250),
        padding: const EdgeInsets.all(2),
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          border: Border.all(color: ring, width: 2),
        ),
        child: Avatar(nick, radius: 10),
      ),
      const SizedBox(width: 6),
      Flexible(
        child: Text(nick,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 12, color: c.textSecondary)),
      ),
      if (muted) ...[
        const SizedBox(width: 4),
        Tooltip(
          message: serverMuted ? 'Замучен модератором' : 'Микрофон выключен',
          child: Icon(Icons.mic_off,
              size: 12,
              color: serverMuted ? Colors.red : c.textMuted),
        ),
      ],
    ]);
  }
}

Future<void> _peerMenu(
    BuildContext context,
    VoiceSessionState st,
    String channelId,
    String id,
    String nick,
    VoicePeer? peer,
    bool canMod, {
    bool inChannel = true,
  }) async {
  final locallyMuted = peer?.localMuted ?? false;
  final sm = peer?.serverMuted ?? false;
  final action = await showDialog<String>(
      context: context,
      builder: (ctx) => SimpleDialog(
            title: Text(nick,
                maxLines: 1, overflow: TextOverflow.ellipsis),
            children: [
              SimpleDialogOption(
                onPressed: () => Navigator.pop(ctx, 'local'),
                child: Text(locallyMuted
                    ? 'Включить звук для себя'
                    : 'Заглушить для себя'),
              ),
              if (canMod)
                SimpleDialogOption(
                  onPressed: () => Navigator.pop(ctx, 'server'),
                  child: Text(
                      sm ? 'Размутить (модер)' : 'Замутить (модер)',
                      style: const TextStyle(color: Colors.red)),
                ),
            ],
          ));
  if (action == null || !context.mounted) return;
  if (action == 'local' && !inChannel) {
    // Local mute only affects what I hear in my current room.
    Toast.show(context, 'Зайди в войс, чтобы заглушить');
    return;
  }
  try {
    final s = st;
    if (action == 'local') {
      await s.setPeerMuted(id, !locallyMuted);
    } else {
      final r = await s.serverMute(
          channelId: channelId, userId: id, muted: !sm);
      if (context.mounted && r != null) Toast.show(context, r);
    }
  } catch (e) {
    if (context.mounted) Toast.show(context, friendlyVoiceError(e));
  }
}

Future<void> _limitDialog(BuildContext context, VoiceSessionState st,
    Channel channel, int current) async {
  final ctl = TextEditingController(text: current == 0 ? '' : '$current');
  final value = await showDialog<int>(
      context: context,
      builder: (ctx) => AlertDialog(
            title: Text('Лимит: ${channel.name}'),
            content: TextField(
              controller: ctl,
              keyboardType: TextInputType.number,
              autofocus: true,
              decoration: const InputDecoration(
                  hintText: '0–99, пусто = без лимита'),
            ),
            actions: [
              TextButton(
                  onPressed: () => Navigator.pop(ctx),
                  child: const Text('Отмена')),
              TextButton(
                  onPressed: () {
                    final v = int.tryParse(ctl.text.trim());
                    Navigator.pop(ctx, ctl.text.trim().isEmpty ? 0 : v);
                  },
                  child: const Text('Сохранить')),
            ],
          ));
  if (value == null || value < 0 || value > 99) return;
  if (!context.mounted) return;
  try {
    await st.setLimit(channelId: channel.id, limit: value);
    if (context.mounted) {
      Toast.show(context,
          value == 0 ? 'Лимит снят' : 'Лимит: $value уч.');
    }
  } catch (e) {
    if (context.mounted) Toast.show(context, friendlyVoiceError(e));
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
    return Semantics(
      button: true,
      excludeSemantics: true,
      label: name,
      child: InkWell(
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
