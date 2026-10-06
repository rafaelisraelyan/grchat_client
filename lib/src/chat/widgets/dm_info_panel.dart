import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../app/theme.dart';
import '../../call/call_state.dart';
import '../../search/search_address.dart';
import '../../widgets/avatar.dart';
import '../../widgets/toast.dart';
import '../home_state.dart';
import '../models.dart';

/// Right column for a 1-1 DM: peer profile + shared media from loaded
/// messages. No presence/last-seen: the backend has no presence feed,
/// so nothing is faked. Group DMs keep the members list instead.
class DmInfoPanel extends ConsumerWidget {
  const DmInfoPanel({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final data = ref.watch(homeStateProvider);
    final scope = data.scope;
    if (scope is! DmScope || scope.thread.isGroup) {
      return const SizedBox.shrink();
    }
    final myId = ref.watch(sessionProvider)?.userId ?? '';
    final others = scope.thread.members
        .where((m) => m.userId != myId)
        .toList();
    if (others.isEmpty) return const SizedBox.shrink();
    final peer = others.first;

    final images = <Attachment>[];
    final videos = <Attachment>[];
    final files = <Attachment>[];
    for (final m in data.messages) {
      if (m.dmId != scope.thread.id) continue;
      for (final a in m.attachments) {
        if (a.mime.startsWith('image/')) {
          if (images.length < 9) images.add(a);
        } else if (a.mime.startsWith('video/')) {
          if (videos.length < 10) videos.add(a);
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
              Center(child: Avatar(peer.nick, radius: 30)),
              const SizedBox(height: 8),
              Center(
                child: Text(peer.nick,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                        fontSize: 16, fontWeight: FontWeight.w700)),
              ),
              Center(
                child: InkWell(
                  onTap: () {
                    Clipboard.setData(ClipboardData(
                        text: addressOf(
                            SearchTargetType.user, peer.nick)));
                    Toast.show(context, 'Адрес скопирован');
                  },
                  child: Padding(
                    padding:
                        const EdgeInsets.symmetric(vertical: 4),
                    child: Text(
                        addressOf(
                            SearchTargetType.user, peer.nick),
                        style: TextStyle(
                            fontSize: 12,
                            color:
                                GrchatColors.of(context).accent)),
                  ),
                ),
              ),
              const SizedBox(height: 8),
              Row(
                  mainAxisAlignment:
                      MainAxisAlignment.spaceEvenly,
                  children: [
                    _action(context, ref, Icons.call, 'Аудио',
                        () => _call(ref, context, peer.nick, false)),
                    _action(context, ref, Icons.videocam, 'Видео',
                        () => _call(ref, context, peer.nick, true)),
                  ]),
              if (images.isNotEmpty) ...[
                const SizedBox(height: 12),
                const _SectionTitle('Фото'),
                const SizedBox(height: 6),
                _MediaGrid(images: images),
              ],
              if (videos.isNotEmpty) ...[
                const SizedBox(height: 12),
                const _SectionTitle('Видео'),
                const SizedBox(height: 6),
                for (final a in videos)
                  _FileRow(attachment: a),
              ],
              if (files.isNotEmpty) ...[
                const SizedBox(height: 12),
                const _SectionTitle('Файлы'),
                const SizedBox(height: 6),
                for (final a in files)
                  _FileRow(attachment: a),
              ],
            ]),
      ),
    );
  }

  Widget _action(BuildContext context, WidgetRef ref, IconData icon,
      String label, VoidCallback onTap) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(10),
      child: Container(
        width: 64,
        padding: const EdgeInsets.symmetric(vertical: 8),
        decoration: BoxDecoration(
          color: Colors.grey.withValues(alpha: 0.15),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Icon(icon, size: 20),
          const SizedBox(height: 2),
          Text(label, style: const TextStyle(fontSize: 11)),
        ]),
      ),
    );
  }

  Future<void> _call(
      WidgetRef ref, BuildContext context, String nick, bool video) async {
    try {
      await ref
          .read(callStateProvider.notifier)
          .startCall(peerNick: nick, video: video);
    } catch (e) {
      if (context.mounted) Toast.show(context, friendlyCallError(e));
    }
  }
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.text);
  final String text;

  @override
  Widget build(BuildContext context) {
    return Text(text,
        style: const TextStyle(
            fontSize: 11,
            color: Colors.grey,
            fontWeight: FontWeight.w600));
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

class _FileRow extends StatelessWidget {
  const _FileRow({required this.attachment});
  final Attachment attachment;

  @override
  Widget build(BuildContext context) {
    final a = attachment;
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
                Text(_size(a.sizeBytes),
                    style: const TextStyle(
                        fontSize: 11, color: Colors.grey)),
              ]),
        ),
      ]),
    );
  }
}

String _size(int b) => b < 1024
    ? '$b Б'
    : b < 1048576
        ? '${(b / 1024).toStringAsFixed(1)} КБ'
        : '${(b / 1048576).toStringAsFixed(1)} МБ';
