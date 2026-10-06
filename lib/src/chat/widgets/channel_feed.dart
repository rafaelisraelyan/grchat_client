import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../widgets/avatar.dart';
import '../../widgets/esc_pop.dart';
import '../../widgets/toast.dart';
import '../home_state.dart';
import '../models.dart';
import 'message_list.dart';

/// A broadcast post: standalone content block, not a chat bubble.
/// Moderators get edit/delete; subscribers get copy text.
class PostCard extends ConsumerStatefulWidget {
  const PostCard(
      {super.key, required this.message, required this.canModerate});

  final Message message;
  final bool canModerate;

  @override
  ConsumerState<PostCard> createState() => _PostCardState();
}

class _PostCardState extends ConsumerState<PostCard> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final m = widget.message;
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 8),
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: Theme.of(context).cardColor.withValues(alpha: 0.5),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
              color:
                  Theme.of(context).dividerColor.withValues(alpha: 0.4)),
        ),
        child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(children: [
                Avatar(m.authorNick, radius: 16),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(m.authorNick,
                            style: const TextStyle(
                                fontWeight: FontWeight.w700)),
                        Text(postTime(m.createdAt),
                            style: const TextStyle(
                                fontSize: 12, color: Colors.grey)),
                      ]),
                ),
                if (_hover)
                  IgnorePointer(
                    ignoring: !_hover,
                    child: AnimatedOpacity(
                      duration:
                          const Duration(milliseconds: 120),
                      opacity: _hover ? 1 : 0,
                      child: PopupMenuButton<String>(
                        icon: const Icon(Icons.more_horiz, size: 18),
                        tooltip: 'Действия',
                        onSelected: (a) => _run(a),
                        itemBuilder: (ctx) => [
                      if (widget.canModerate) ...[
                        const PopupMenuItem(
                            value: 'edit',
                            child: Text('Редактировать')),
                        const PopupMenuItem(
                            value: 'delete', child: Text('Удалить')),
                      ],
                      const PopupMenuItem(
                          value: 'copy',
                          child: Text('Копировать текст')),
                    ],
                  ),
                    ),
                  ),
              ]),
              if (m.text.isNotEmpty) ...[
                const SizedBox(height: 8),
                SelectableText(m.text),
              ],
              for (final a in m.attachments) ...[
                const SizedBox(height: 6),
                AttachmentView(attachment: a),
              ],
              if (m.editedAt != null) ...[
                const SizedBox(height: 6),
                const Text('изменено',
                    style: TextStyle(fontSize: 11, color: Colors.grey)),
              ],
            ]),
      ),
    );
  }

  Future<void> _run(String action) async {
    final m = widget.message;
    switch (action) {
      case 'copy':
        await Clipboard.setData(ClipboardData(text: m.text));
        if (mounted) Toast.show(context, 'Текст скопирован');
      case 'edit':
        final tc = TextEditingController(text: m.text);
        final ok = await showEscDialog<bool>(
            context: context,
            autofocus: false,
            builder: (ctx) => AlertDialog(
                  title: const Text('Редактировать публикацию'),
                  content: TextField(
                      controller: tc,
                      maxLines: 6,
                      autofocus: true,
                      decoration: const InputDecoration(
                          hintText: 'Текст публикации')),
                  actions: [
                    TextButton(
                        onPressed: () => Navigator.pop(ctx, false),
                        child: const Text('Отмена')),
                    FilledButton(
                        onPressed: () => Navigator.pop(ctx, true),
                        child: const Text('Сохранить')),
                  ],
                ));
        if (ok == true && mounted) {
          try {
            await ref
                .read(homeStateProvider.notifier)
                .editMessage(m.id, tc.text);
          } catch (e) {
            if (mounted) Toast.show(context, '$e');
          }
        }
      case 'delete':
        final hasFiles = m.attachments.isNotEmpty;
        final ok = await showEscDialog<bool>(
            context: context,
            builder: (ctx) => AlertDialog(
                  title: const Text('Удалить публикацию?'),
                  content: Text(hasFiles
                      ? 'Вложения этой публикации также будут удалены.'
                      : 'Публикация исчезнет из ленты.'),
                  actions: [
                    TextButton(
                        onPressed: () => Navigator.pop(ctx, false),
                        child: const Text('Отмена')),
                    FilledButton(
                        onPressed: () => Navigator.pop(ctx, true),
                        child: const Text('Удалить')),
                  ],
                ));
        if (ok == true && mounted) {
          try {
            await ref
                .read(homeStateProvider.notifier)
                .deleteMessage(m.id);
          } catch (e) {
            if (mounted) Toast.show(context, '$e');
          }
        }
    }
  }
}

String postTime(String createdAt) {
  final dt = DateTime.tryParse(createdAt)?.toLocal();
  if (dt == null) return '';
  final now = DateTime.now();
  final hm =
      '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
  if (dt.year == now.year && dt.month == now.month && dt.day == now.day) {
    return hm;
  }
  final yesterday = now.subtract(const Duration(days: 1));
  if (dt.year == yesterday.year &&
      dt.month == yesterday.month &&
      dt.day == yesterday.day) {
    return 'Вчера · $hm';
  }
  return '${dt.day.toString().padLeft(2, '0')}.${dt.month.toString().padLeft(2, '0')} · $hm';
}
