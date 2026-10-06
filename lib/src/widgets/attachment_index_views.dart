import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../chat/home_state.dart';
import '../chat/models.dart';

/// Shared side-panel attachments views (DM profile + channel info).
/// Data always comes from the attachments index (full history,
/// newest first) — never from the loaded chat page.
class AttachmentGrid extends ConsumerWidget {
  const AttachmentGrid({super.key, required this.images});
  final List<AttachmentIndexEntry> images;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cache = ref.watch(fileCacheProvider);
    return GridView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 3, crossAxisSpacing: 4, mainAxisSpacing: 4),
      itemCount: images.length,
      itemBuilder: (ctx, i) {
        final a = images[i];
        final bytes = cache[a.fileId];
        if (bytes == null) {
          ref
              .read(fileCacheProvider.notifier)
              .fetch(a.fileId)
              .then((_) {})
              .catchError((_) {});
          return Container(
              decoration: BoxDecoration(
                  color: Colors.grey.withValues(alpha: 0.2),
                  borderRadius: BorderRadius.circular(6)));
        }
        return ClipRRect(
          borderRadius: BorderRadius.circular(6),
          child: Image.memory(bytes, fit: BoxFit.cover),
        );
      },
    );
  }
}

class AttachmentFileRow extends StatelessWidget {
  const AttachmentFileRow({super.key, required this.entry});
  final AttachmentIndexEntry entry;

  @override
  Widget build(BuildContext context) {
    final a = entry;
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(children: [
        const Icon(Icons.insert_drive_file,
            size: 16, color: Colors.grey),
        const SizedBox(width: 6),
        Expanded(
          child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(a.filename,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 13)),
                Text(formatAttachmentSize(a.sizeBytes),
                    style: const TextStyle(
                        fontSize: 11, color: Colors.grey)),
              ]),
        ),
      ]),
    );
  }
}

String formatAttachmentSize(int b) => b < 1024
    ? '$b Б'
    : b < 1048576
        ? '${(b / 1024).toStringAsFixed(1)} КБ'
        : '${(b / 1048576).toStringAsFixed(1)} МБ';
