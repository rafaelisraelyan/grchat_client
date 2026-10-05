import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../home_state.dart';
import '../../widgets/toast.dart';

Future<void> showServerDialog(BuildContext context, WidgetRef ref) async {
  final name = TextEditingController();
  final code = TextEditingController();
  await showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
            title: const Text('Сервер'),
            content: Column(mainAxisSize: MainAxisSize.min, children: [
              TextField(
                  controller: name,
                  decoration: const InputDecoration(
                      hintText: 'Название нового сервера')),
              const SizedBox(height: 8),
              TextField(
                  controller: code,
                  decoration: const InputDecoration(
                      hintText: 'Инвайт-код для входа')),
            ]),
            actions: [
              TextButton(
                  onPressed: () => Navigator.pop(ctx),
                  child: const Text('Отмена')),
              TextButton(
                  onPressed: () async {
                    final repo = ref.read(chatRepositoryProvider);
                    try {
                      if (code.text.trim().isNotEmpty) {
                        await repo.joinByInvite(code.text);
                      } else if (name.text.trim().isNotEmpty) {
                        await repo.createCommunity(name.text.trim());
                      }
                      await ref
                          .read(homeStateProvider.notifier)
                          .refresh();
                    } catch (e) {
                      if (context.mounted) Toast.show(context, '$e');
                    }
                    if (ctx.mounted) Navigator.pop(ctx);
                  },
                  child: const Text('Ок')),
            ],
          ));
}

Future<void> showInviteDialog(BuildContext context, WidgetRef ref) async {
  final scope = ref.read(homeStateProvider).scope;
  if (scope is! ChannelScope) return;
  try {
    final code = await ref
        .read(chatRepositoryProvider)
        .createInvite(scope.community.id);
    if (!context.mounted) return;
    await showDialog(
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
  final id = await showDialog<String>(
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
  await showDialog(
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
