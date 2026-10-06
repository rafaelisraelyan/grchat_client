import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../app/theme.dart';
import '../../call/call_state.dart';
import '../../search/search_address.dart';
import '../../widgets/attachment_index_views.dart';
import '../../widgets/avatar.dart';
import '../../widgets/toast.dart';
import '../home_state.dart';
import '../models.dart';

/// Right column for a 1-1 DM: peer profile + shared media from the
/// attachments index (full history, newest first — not just the loaded
/// page). No presence/last-seen: the backend has no presence feed,
/// so nothing is faked. Group DMs keep the members list instead.
class DmInfoPanel extends ConsumerStatefulWidget {
  const DmInfoPanel({super.key});

  @override
  ConsumerState<DmInfoPanel> createState() => _DmInfoPanelState();
}

class _DmInfoPanelState extends ConsumerState<DmInfoPanel> {
  String? _dmId;
  List<AttachmentIndexEntry> _items = const [];
  bool _hasMore = false;
  bool _loading = true;

  Future<void> _load({bool more = false}) async {
    final id = _dmId;
    if (id == null) return;
    if (more) {
      if (!_hasMore || _loading) return;
    } else if (_loading && _items.isNotEmpty) {
      return;
    }
    if (!more) setState(() => _loading = true);
    try {
      final idx = await ref.read(fileApiProvider).attachmentsIndex(
          dmId: id,
          limit: 60,
          beforeId: more && _items.isNotEmpty
              ? _items.last.attachmentId
              : null);
      if (!mounted) return;
      final known = _items.map((e) => e.attachmentId).toSet();
      setState(() {
        _items = [
          ..._items,
          for (final e in idx.items)
            if (!known.contains(e.attachmentId)) e,
        ];
        _hasMore = idx.hasMore;
        _loading = false;
      });
    } catch (_) {
      // Old servers have no index endpoint: media sections stay hidden.
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final data = ref.watch(homeStateProvider);
    final scope = data.scope;
    if (scope is! DmScope || scope.thread.isGroup) {
      return const SizedBox.shrink();
    }
    if (_dmId != scope.thread.id) {
      _dmId = scope.thread.id;
      _items = const [];
      _hasMore = false;
      _loading = true;
      Future.microtask(() => _load());
    }
    final myId = ref.watch(sessionProvider)?.userId ?? '';
    final others = scope.thread.members
        .where((m) => m.userId != myId)
        .toList();
    if (others.isEmpty) return const SizedBox.shrink();
    final peer = others.first;

    final images = _items.where((e) => e.isImage).toList();
    final videos = _items.where((e) => e.isVideo).toList();
    final files = _items
        .where((e) => !e.isImage && !e.isVideo)
        .toList();

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
                AttachmentGrid(images: images),
              ],
              if (videos.isNotEmpty) ...[
                const SizedBox(height: 12),
                const _SectionTitle('Видео'),
                const SizedBox(height: 6),
                for (final a in videos) AttachmentFileRow(entry: a),
              ],
              if (files.isNotEmpty) ...[
                const SizedBox(height: 12),
                const _SectionTitle('Файлы'),
                const SizedBox(height: 6),
                for (final a in files) AttachmentFileRow(entry: a),
              ],
              if (_hasMore) ...[
                const SizedBox(height: 8),
                Center(
                  child: TextButton(
                      onPressed: _loading ? null : () => _load(more: true),
                      child: Text(_loading
                          ? 'Загрузка…'
                          : 'Показать ещё')),
                ),
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
