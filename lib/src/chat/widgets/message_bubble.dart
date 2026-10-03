import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../home_state.dart';
import '../models.dart';

String formatSize(int b) => b < 1024
    ? '$b Б'
    : b < 1048576
        ? '${(b / 1024).toStringAsFixed(1)} КБ'
        : '${(b / 1048576).toStringAsFixed(1)} МБ';

/// Single message bubble (grouped-stream rework comes in Stage 5).
class MessageBubble extends ConsumerWidget {
  const MessageBubble({super.key, required this.message});

  final Message message;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final m = message;
    final myId = ref.read(sessionProvider)?.userId;
    final mine = m.authorId == myId;
    return Align(
      alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        constraints: const BoxConstraints(maxWidth: 520),
        margin: const EdgeInsets.symmetric(vertical: 4),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: mine
              ? Theme.of(context).colorScheme.primary
              : Theme.of(context).colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            if (!mine)
              Text(m.authorNick,
                  style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                      color: Theme.of(context).colorScheme.primary)),
            Text(m.text,
                style: TextStyle(
                    color: mine
                        ? Colors.white
                        : Theme.of(context).colorScheme.onSurface)),
            for (final a in m.attachments)
              AttachmentView(attachment: a, mine: mine),
            if (m.editedAt != null)
              const Text('(изм.)',
                  style: TextStyle(fontSize: 10, color: Colors.grey)),
          ],
        ),
      ),
    );
  }
}

class AttachmentView extends ConsumerWidget {
  const AttachmentView(
      {super.key, required this.attachment, required this.mine});

  final Attachment attachment;
  final bool mine;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (attachment.mime.startsWith('image/')) {
      final cached = ref.watch(fileCacheProvider)[attachment.fileId];
      if (cached == null) {
        ref
            .read(fileCacheProvider.notifier)
            .fetch(attachment.fileId)
            .then((_) {})
            .catchError((_) {});
        return Container(
          margin: const EdgeInsets.only(top: 6),
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
              border:
                  Border.all(color: Colors.grey.withValues(alpha: 0.4)),
              borderRadius: BorderRadius.circular(8)),
          child: Text(
              '🖼 ${attachment.filename} · ${formatSize(attachment.sizeBytes)}'),
        );
      }
      return Container(
        margin: const EdgeInsets.only(top: 6),
        constraints: const BoxConstraints(maxHeight: 240, maxWidth: 320),
        decoration:
            BoxDecoration(borderRadius: BorderRadius.circular(8)),
        clipBehavior: Clip.antiAlias,
        child: Image.memory(cached, fit: BoxFit.cover),
      );
    }
    final color = mine ? Colors.white70 : null;
    return Container(
      margin: const EdgeInsets.only(top: 6),
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
          border: Border.all(color: Colors.grey.withValues(alpha: 0.4)),
          borderRadius: BorderRadius.circular(8)),
      child: Text(
          '📎 ${attachment.filename} · ${formatSize(attachment.sizeBytes)}',
          style: TextStyle(color: color)),
    );
  }
}
