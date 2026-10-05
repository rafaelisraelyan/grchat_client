import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../app/theme.dart';
import '../../search/search_address.dart';
import '../../widgets/avatar.dart';
import '../chat_repository.dart';
import '../home_state.dart';
import '../../widgets/toast.dart';
import '../models.dart';

int _rank(String role) => switch (role) {
      'owner' => 4,
      'admin' => 3,
      'mod' => 2,
      _ => 1,
    };

/// Right column: community members or DM participants.
class MembersPanel extends ConsumerWidget {
  const MembersPanel({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final data = ref.watch(homeStateProvider);
    return SizedBox(
      width: 230,
      child: Material(
        color: GrchatColors.of(context).bgSidebar,
        child:
            Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Padding(
              padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
              child: Text('В СЕТИ — ${data.members.length}',
                  style: const TextStyle(
                      fontSize: 11,
                      color: Colors.grey,
                      fontWeight: FontWeight.w600))),
          Expanded(
            child: data.members.isEmpty
                ? const Padding(
                    padding: EdgeInsets.all(12),
                    child:
                        Text('—', style: TextStyle(color: Colors.grey)))
                : ListView.builder(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 8),
                    itemCount: data.members.length,
                    itemBuilder: (ctx, i) =>
                        _MemberRow(member: data.members[i]),
                  ),
          ),
        ]),
      ),
    );
  }
}

class _MemberRow extends ConsumerStatefulWidget {
  const _MemberRow({required this.member});

  final Member member;

  @override
  ConsumerState<_MemberRow> createState() => _MemberRowState();
}

class _MemberRowState extends ConsumerState<_MemberRow> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final m = widget.member;
    final repo = ref.read(chatRepositoryProvider);
    final data = ref.watch(homeStateProvider);
    final myId = ref.watch(sessionProvider)?.userId;
    final scope = data.scope;
    final communityId =
        scope is ChannelScope ? scope.community?.id : null;
    final myRole = scope is ChannelScope
        ? _roleOf(data.members, myId)
        : '';
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 5),
        child: Row(children: [
          Avatar(m.nick, radius: 14),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(m.nick,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 14)),
                  if (m.role.isNotEmpty && m.role != 'member')
                    Text(m.role,
                        style: TextStyle(
                            fontSize: 11,
                            color:
                                GrchatColors.of(context).textMuted)),
                ]),
          ),
          if (_hover)
            PopupMenuButton<_ModAction>(
              icon: const Icon(Icons.more_vert, size: 16),
              tooltip: 'Действия',
              onSelected: (a) =>
                  _run(context, ref, repo, communityId, m, a),
              itemBuilder: (ctx) => [
                for (final a in [
                  ..._actions(myRole, m, myId),
                  _ModAction.copy
                ])
                  PopupMenuItem(value: a, child: Text(a.label)),
              ],
            ),
        ]),
      ),
    );
  }

  static String _roleOf(List<Member> members, String? myId) {
    for (final m in members) {
      if (m.userId == myId) return m.role;
    }
    return '';
  }

  List<_ModAction> _actions(
      String myRole, Member target, String? myId) {
    if (myId == null || myId == target.userId) return const [];
    final mine = _rank(myRole);
    final theirs = _rank(target.role);
    if (mine <= theirs) return const [];
    final out = <_ModAction>[];
    if (mine >= 2) {
      out.add(_ModAction.kick);
      out.add(_ModAction.mute);
      out.add(_ModAction.unmute);
      if (mine >= 4 || (mine == 3 && theirs < 3)) {
        out.add(_ModAction.role);
      }
    }
    if (mine >= 3) {
      out.add(_ModAction.ban);
      out.add(_ModAction.unban);
    }
    return out;
  }

  Future<void> _run(BuildContext context, WidgetRef ref,
      ChatRepository repo, String? cid, Member target, _ModAction a) async {
    if (a == _ModAction.copy) {
      await Clipboard.setData(ClipboardData(
          text: addressOf(SearchTargetType.user, target.nick)));
      if (context.mounted) Toast.show(context, 'Адрес скопирован');
      return;
    }
    final id = cid;
    if (id == null) return;
    try {
      switch (a) {
        case _ModAction.copy:
          return; // handled above, kept for exhaustiveness
        case _ModAction.kick:
          await repo.kick(id, target.userId);
        case _ModAction.ban:
          final r = await _askMinutes(context, 'Бан (минут, пусто — навсегда)');
          if (!r.abort) await repo.ban(id, target.userId, untilMin: r.minutes);
        case _ModAction.unban:
          await repo.unban(id, target.userId);
        case _ModAction.mute:
          final r = await _askMinutes(context, 'Мут (минут)', required: true);
          if (!r.abort) {
            await repo.mute(id, target.userId, r.minutes ?? 60);
          }
        case _ModAction.unmute:
          await repo.unmute(id, target.userId);
        case _ModAction.role:
          final role = await _askRole(context, target.nick);
          if (role != null) {
            await repo.grantRole(id, target.userId, role);
          }
      }
    } catch (e) {
      if (context.mounted) Toast.show(context, '$e');
    }
  }

  Future<({bool abort, int? minutes})> _askMinutes(
      BuildContext context, String title,
      {bool required = false}) async {
    final tc = TextEditingController();
    final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
              title: Text(title),
              content: TextField(
                  controller: tc,
                  autofocus: true,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(hintText: 'Минут')),
              actions: [
                TextButton(
                    onPressed: () => Navigator.pop(ctx, false),
                    child: const Text('Отмена')),
                FilledButton(
                    onPressed: () => Navigator.pop(ctx, true),
                    child: const Text('Ок')),
              ],
            ));
    if (ok != true) return (abort: true, minutes: null);
    final v = int.tryParse(tc.text.trim());
    if (v == null) {
      return required ? (abort: true, minutes: null) : (abort: false, minutes: null);
    }
    return (abort: false, minutes: v);
  }

  Future<String?> _askRole(BuildContext context, String nick) {
    const roles = ['admin', 'mod', 'member'];
    return showDialog<String>(
        context: context,
        builder: (ctx) => SimpleDialog(
              title: Text('Роль для $nick'),
              children: [
                for (final r in roles)
                  SimpleDialogOption(
                      onPressed: () => Navigator.pop(ctx, r),
                      child: Text(r)),
              ],
            ));
  }
}

enum _ModAction {
  kick('Кикнуть'),
  ban('Забанить'),
  unban('Разбанить'),
  mute('Мут'),
  unmute('Размутить'),
  role('Выдать роль'),
  copy('Скопировать адрес');

  const _ModAction(this.label);
  final String label;
}
