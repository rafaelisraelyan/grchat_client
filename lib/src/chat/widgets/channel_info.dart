import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/theme.dart';
import '../../search/search_address.dart';
import '../../widgets/avatar.dart';
import '../../widgets/toast.dart';
import '../home_state.dart';
import '../models.dart';
import 'dialogs.dart';

/// Right column for a broadcast channel (§14): identity, subscription,
/// real media/files index from loaded posts, owner management.
/// No fake sections: notifications and link index need backend support.
class ChannelInfoPanel extends ConsumerWidget {
  const ChannelInfoPanel({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final data = ref.watch(homeStateProvider);
    final scope = data.scope;
    if (scope is! ChannelScope || scope.community != null) {
      return const SizedBox.shrink();
    }
    final ch = scope.channel;
    final posts = data.messages.where((m) => m.isPost).toList();
    final images = <Attachment>[];
    final files = <Attachment>[];
    for (final p in posts) {
      for (final a in p.attachments) {
        if (a.mime.startsWith('image/')) {
          if (images.length < 6) images.add(a);
        } else if (files.length < 10) {
          files.add(a);
        }
      }
    }
    return SizedBox(
      width: 230,
      child: Material(
        color: GrchatColors.of(context).bgSidebar,
        child: ListView(
            padding: const EdgeInsets.fromLTRB(12, 16, 12, 12),
            children: [
              Center(child: Avatar(ch.name, radius: 30)),
              const SizedBox(height: 8),
              Center(
                child: Text(ch.name,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                        fontSize: 16, fontWeight: FontWeight.w700)),
              ),
              if (ch.alias.isNotEmpty)
                Center(
                  child: InkWell(
                    onTap: () {
                      Clipboard.setData(ClipboardData(
                          text: addressOf(
                              SearchTargetType.channel, ch.alias)));
                      Toast.show(context, 'Адрес скопирован');
                    },
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 4),
                      child: Text(
                          addressOf(
                              SearchTargetType.channel, ch.alias),
                          style: TextStyle(
                              fontSize: 12,
                              color: GrchatColors.of(context).accent)),
                    ),
                  ),
                ),
              Center(
                child: Text(
                    ch.subscribersCount >= 0
                        ? '${ch.subscribersCount} подписчиков'
                        : 'Канал',
                    style: const TextStyle(
                        fontSize: 12, color: Colors.grey)),
              ),
              if (ch.description.isNotEmpty) ...[
                const SizedBox(height: 8),
                Text(ch.description,
                    style: const TextStyle(fontSize: 13)),
              ],
              const SizedBox(height: 12),
              _subscribeButton(context, ref, ch),
              if (ch.role == 'owner') ...[
                const SizedBox(height: 8),
                OutlinedButton(
                    onPressed: () => showChannelGrantDialog(
                        context, ref, ch.id,
                        adminChoice: true),
                    child: const Text('Управление каналом')),
              ],
              if (images.isNotEmpty) ...[
                const SizedBox(height: 12),
                const Text('Медиа',
                    style: TextStyle(
                        fontSize: 11,
                        color: Colors.grey,
                        fontWeight: FontWeight.w600)),
                const SizedBox(height: 6),
                _MediaGrid(images: images),
              ],
              if (files.isNotEmpty) ...[
                const SizedBox(height: 12),
                const Text('Файлы',
                    style: TextStyle(
                        fontSize: 11,
                        color: Colors.grey,
                        fontWeight: FontWeight.w600)),
                const SizedBox(height: 6),
                for (final a in files)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 6),
                    child: Row(children: [
                      const Icon(Icons.insert_drive_file,
                          size: 16, color: Colors.grey),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Column(
                            crossAxisAlignment:
                                CrossAxisAlignment.start,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(a.filename,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                      fontSize: 13)),
                              Text(_size(a.sizeBytes),
                                  style: const TextStyle(
                                      fontSize: 11,
                                      color: Colors.grey)),
                            ]),
                      ),
                    ]),
                  ),
              ],
            ]),
      ),
    );
  }

  Widget _subscribeButton(
      BuildContext context, WidgetRef ref, Channel ch) {
    if (ch.role == 'member' || ch.role == 'admin') {
      return OutlinedButton(
          onPressed: () async {
            try {
              await ref
                  .read(chatRepositoryProvider)
                  .unsubscribeChannel(ch.alias);
              await ref.read(homeStateProvider.notifier).refresh();
            } catch (e) {
              if (context.mounted) Toast.show(context, '$e');
            }
          },
          child: const Text('Отписаться'));
    }
    if (ch.role.isEmpty && ch.alias.isNotEmpty) {
      return FilledButton(
          onPressed: () async {
            final st = ref.read(homeStateProvider.notifier);
            try {
              await ref
                  .read(chatRepositoryProvider)
                  .subscribeChannel(ch.alias);
              await st.refresh();
              final mine = ref
                  .read(homeStateProvider)
                  .myChannels
                  .where((c) => c.alias == ch.alias);
              if (mine.isNotEmpty && context.mounted) {
                await st.selectStandaloneChannel(mine.first);
              }
            } catch (e) {
              if (context.mounted) Toast.show(context, '$e');
            }
          },
          child: const Text('Подписаться'));
    }
    return const SizedBox.shrink();
  }
}

class _MediaGrid extends ConsumerWidget {
  const _MediaGrid({required this.images});
  final List<Attachment> images;

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

String _size(int b) => b < 1024
    ? '$b Б'
    : b < 1048576
        ? '${(b / 1024).toStringAsFixed(1)} КБ'
        : '${(b / 1048576).toStringAsFixed(1)} МБ';
