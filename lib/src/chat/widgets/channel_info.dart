import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/theme.dart';
import '../../search/search_address.dart';
import '../../widgets/attachment_index_views.dart';
import '../../widgets/avatar.dart';
import '../../widgets/toast.dart';
import '../home_state.dart';
import '../models.dart';
import 'dialogs.dart';

/// Right column for a broadcast channel (§14): identity, subscription,
/// full attachments index (newest first), owner management.
/// No fake sections: notifications and link index need backend support.
class ChannelInfoPanel extends ConsumerStatefulWidget {
  const ChannelInfoPanel({super.key});

  @override
  ConsumerState<ChannelInfoPanel> createState() =>
      _ChannelInfoPanelState();
}

class _ChannelInfoPanelState extends ConsumerState<ChannelInfoPanel> {
  String? _channelId;
  List<AttachmentIndexEntry> _items = const [];
  bool _hasMore = false;
  bool _loading = true;

  Future<void> _load({bool more = false}) async {
    final id = _channelId;
    if (id == null) return;
    if (more) {
      if (!_hasMore || _loading) return;
    } else if (_loading && _items.isNotEmpty) {
      return;
    }
    if (!more) setState(() => _loading = true);
    try {
      final idx = await ref.read(fileApiProvider).attachmentsIndex(
          channelId: id,
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
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final data = ref.watch(homeStateProvider);
    final scope = data.scope;
    if (scope is! ChannelScope || scope.community != null) {
      return const SizedBox.shrink();
    }
    if (_channelId != scope.channel.id) {
      _channelId = scope.channel.id;
      _items = const [];
      _hasMore = false;
      _loading = true;
      Future.microtask(() => _load());
    }
    final ch = scope.channel;
    final images = _items.where((e) => e.isImage).toList();
    final files =
        _items.where((e) => !e.isImage).toList();
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
                AttachmentGrid(images: images),
              ],
              if (files.isNotEmpty) ...[
                const SizedBox(height: 12),
                const Text('Файлы',
                    style: TextStyle(
                        fontSize: 11,
                        color: Colors.grey,
                        fontWeight: FontWeight.w600)),
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
