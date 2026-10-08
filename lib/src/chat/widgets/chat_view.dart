import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../home_state.dart';
import '../../voice/voice_state.dart';
import '../../call/media_session.dart';
import '../../desktop/desktop_log.dart';
import '../../search/search_address.dart';
import '../../widgets/avatar.dart';
import '../../widgets/toast.dart';
import 'empty_chat.dart';
import '../models.dart';
import '../../app/providers.dart';
import '../../app/theme.dart';
import '../../call/call_state.dart';
import '../../call/group_call.dart';
import 'message_list.dart';
import 'channel_feed.dart';
import 'dialogs.dart';

/// Center column: header, message list, composer.
class ChatView extends ConsumerStatefulWidget {
  const ChatView(
      {super.key,
      required this.onToggleMembers,
      required this.onInvite});

  final VoidCallback onToggleMembers;
  final VoidCallback onInvite;

  @override
  ConsumerState<ChatView> createState() => _ChatViewState();
}

class _ChatViewState extends ConsumerState<ChatView> {
  final _input = TextEditingController();
  final _inputFocus = FocusNode();
  final _scroll = ScrollController();
  bool _typingSent = false;
  double? _uploading;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
  }

  @override
  void dispose() {
    _scroll.removeListener(_onScroll);
    _input.dispose();
    _inputFocus.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (!_scroll.hasClients || _scroll.position.pixels > 200) return;
    final st = ref.read(homeStateProvider.notifier);
    final data = ref.read(homeStateProvider);
    if (data.loadingOlder || !data.hasMore || data.messages.isEmpty) return;
    final prevMax = _scroll.position.maxScrollExtent;
    final prevPixels = _scroll.position.pixels;
    st.loadOlder().then((n) {
      if (n > 0 && mounted && _scroll.hasClients) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!_scroll.hasClients) return;
          final grown = _scroll.position.maxScrollExtent - prevMax;
          _scroll.jumpTo((prevPixels + grown)
              .clamp(0.0, _scroll.position.maxScrollExtent));
        });
      }
    });
  }

  void _scrollDown() {
    if (!_scroll.hasClients) return;
    _scroll.animateTo(_scroll.position.maxScrollExtent,
        duration: const Duration(milliseconds: 200), curve: Curves.easeOut);
  }

  @override
  Widget build(BuildContext context) {
    final data = ref.watch(homeStateProvider);
    final scope = data.scope;
    ref.listen(homeStateProvider, (_, next) {
      if (next.messages.isNotEmpty) {
        WidgetsBinding.instance.addPostFrameCallback((_) => _scrollDown());
      }
    });
    // Inline edit prefill: once per edit session, then focus the field.
    ref.listen<Message?>(editingMessageProvider, (prev, next) {
      if (next != null && prev?.id != next.id) {
        _input.text = next.text;
        _inputFocus.requestFocus();
      }
    });
    // Standalone channels are broadcast feeds, not chatrooms (§4, §19).
    if (scope is ChannelScope && scope.community == null) {
      return _buildBroadcast(context, data, scope);
    }
    // A selected voice channel shows no chat UI: the Call Window overlay
    // carries the call, this panel only offers joining/expanding.
    if (scope is ChannelScope && scope.channel.type == 'voice') {
      return _buildVoiceScope(context, ref, scope);
    }
    return Column(children: [
      Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        decoration: BoxDecoration(
            border: Border(
                bottom: BorderSide(
                    color: Theme.of(context)
                        .dividerColor
                        .withValues(alpha: 0.3)))),
        child: Row(children: [
          Expanded(
              child: Text(scope?.title ?? 'Выбери чат',
                  style: const TextStyle(
                      fontSize: 16, fontWeight: FontWeight.w700))),
          if (scope is ChannelScope) ...[
            if (scope.channel.alias.isNotEmpty)
              IconButton(
                  tooltip: 'Копировать адрес канала',
                  icon: const Icon(Icons.link, size: 20),
                  onPressed: () {
                    Clipboard.setData(ClipboardData(
                        text: addressOf(SearchTargetType.channel,
                            scope.channel.alias)));
                    Toast.show(context, 'Адрес скопирован');
                  }),
            IconButton(
                tooltip: scope.community == null
                    ? 'Добавить участника'
                    : 'Скопировать инвайт',
                icon: const Icon(Icons.person_add, size: 20),
                onPressed: widget.onInvite),
          ],
          if (scope is DmScope) ...[
            IconButton(
                tooltip: 'Позвонить',
                icon: const Icon(Icons.call, size: 20),
                onPressed: () => _startCall(video: false)),
            IconButton(
                tooltip: 'Видеозвонок',
                icon: const Icon(Icons.videocam, size: 20),
                onPressed: () => _startCall(video: true)),
          ],
          IconButton(
              tooltip: scope is DmScope && !scope.thread.isGroup
                  ? 'Профиль'
                  : 'Участники',
              icon: const Icon(Icons.people, size: 20),
              onPressed: widget.onToggleMembers),
        ]),
      ),
      Expanded(
        child: data.loading
            ? const Center(child: CircularProgressIndicator())
            : data.scope == null
                ? const Center(child: Text('Выбери канал или личку слева'))
                : data.messages.isEmpty
                    ? EmptyChat(
                        scope: data.scope!,
                        myId:
                            ref.watch(sessionProvider)?.userId ?? '',
                      )
                    : MessageList(
                        controller: _scroll,
                        messages: data.messages,
                        myId:
                            ref.watch(sessionProvider)?.userId ?? '',
                      ),
      ),
      if (scope != null)
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 14),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            if (data.typing.isNotEmpty)
              Align(
                alignment: Alignment.centerLeft,
                child: Padding(
                  padding: const EdgeInsets.only(left: 4, bottom: 4),
                  child: Text('${data.typing.join(', ')} печатает…',
                      style: TextStyle(
                          color: GrchatColors.of(context).textMuted,
                          fontSize: 12)),
                ),
              ),
            if (_uploading != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: LinearProgressIndicator(value: _uploading),
              ),
            const _EditBanner(),
            Container(
              constraints: const BoxConstraints(minHeight: 48),
              decoration: BoxDecoration(
                border: Border.all(
                    color: GrchatColors.of(context).borderSubtle),
                borderRadius: BorderRadius.circular(12),
              ),
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: Row(children: [
                IconButton(
                    tooltip: 'Прикрепить файл',
                    icon: const Icon(Icons.attach_file, size: 20),
                    onPressed:
                        _uploading == null ? _pickAndSend : null),
                Expanded(
                  child: Focus(
                    onKeyEvent: (node, event) =>
                        _composerKeys(event),
                    child: TextField(
                    controller: _input,
                    focusNode: _inputFocus,
                    minLines: 1,
                    maxLines: 4,
                    decoration: InputDecoration(
                      hintText: 'Написать в ${scope.title}…',
                      border: InputBorder.none,
                      contentPadding: const EdgeInsets.symmetric(
                          horizontal: 8, vertical: 12),
                    ),
                    onChanged: (_) {
                      if (!_typingSent) {
                        _typingSent = true;
                        ref
                            .read(homeStateProvider.notifier)
                            .sendTyping(true);
                        Future.delayed(const Duration(seconds: 3), () {
                          _typingSent = false;
                          ref
                              .read(homeStateProvider.notifier)
                              .sendTyping(false);
                        });
                      }
                    },
                    onSubmitted: (_) => _send(),
                  ),
                ),
                ),
                _ComposerSendButton(input: _input, onSend: _send),
              ]),
            ),
          ]),
        ),
    ]);
  }

  /// Broadcast feed layout (§4, §6, §19): header, posts, publish
  /// composer for owners/admins, subscription state for the rest.
  /// Central content for a selected voice channel: no chat, no composer.
  /// The Call Window overlay carries the call; this panel shows context and
  /// offers joining (fresh) or expanding (already in, minimized).
  Widget _buildVoiceScope(
      BuildContext context, WidgetRef ref, ChannelScope scope) {
    final ch = scope.channel;
    final session = ref.watch(voiceSessionProvider);
    final inHere =
        session != null && session.channelId == ch.id;
    final count =
        ref.watch(voiceStateProvider)[ch.id]?.length ?? 0;
    return Column(children: [
      Container(
        padding:
            const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        decoration: BoxDecoration(
            border: Border(
                bottom: BorderSide(
                    color: Theme.of(context)
                        .dividerColor
                        .withValues(alpha: 0.3)))),
        child: Row(children: [
          const Icon(Icons.volume_up, size: 20),
          const SizedBox(width: 10),
          Expanded(
              child: Text(ch.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w700))),
        ]),
      ),
      Expanded(
        child: Center(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Avatar(ch.name, radius: 34),
            const SizedBox(height: 12),
            Text(ch.name,
                style: const TextStyle(
                    fontSize: 18, fontWeight: FontWeight.w700)),
            const SizedBox(height: 4),
            Text(
                inHere
                    ? '$count ${_plural(count, 'участник', 'участника', 'участников')}'
                    : count > 0
                        ? 'Внутри: $count — присоединяйся'
                        : 'Пока пусто — заходи первым',
                style:
                    const TextStyle(fontSize: 13, color: Colors.grey)),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: () async {
                if (inHere) {
                  ref.read(voiceSessionProvider.notifier).setMinimized(false);
                  return;
                }
                // Warm the waiting-GIF decode in parallel with the connect.
                precacheWaitingGif(context);
                await runMediaStart(context, ref,
                    title: 'Подключиться к ${ch.name}?',
                    action: 'подключиться',
                    start: () => ref
                        .read(voiceSessionProvider.notifier)
                        .join(channelId: ch.id, title: ch.name),
                    label: 'voice ${ch.name}',
                    friendlyError: friendlyVoiceError);
              },
              icon: Icon(inHere ? Icons.open_in_full : Icons.call,
                  size: 18),
              label:
                  Text(inHere ? 'Развернуть звонок' : 'Подключиться'),
            ),
          ]),
        ),
      ),
    ]);
  }

  static String _plural(int n, String one, String few, String many) {
    if (n % 10 == 1 && n % 100 != 11) return one;
    if (n % 10 >= 2 && n % 10 <= 4 && (n % 100 < 12 || n % 100 > 14)) {
      return few;
    }
    return many;
  }

  Widget _buildBroadcast(
      BuildContext context, HomeData data, ChannelScope scope) {
    final ch = scope.channel;
    final posts = data.messages.where((m) => m.isPost).toList();
    return Column(children: [
      _broadcastHeader(context, scope),
      Expanded(
        child: data.loading
            ? const Center(child: CircularProgressIndicator())
            : posts.isEmpty
                ? _broadcastEmpty(ch)
                : _feedList(posts),
      ),
      _broadcastFooter(context, scope),
    ]);
  }

  Widget _broadcastHeader(BuildContext context, ChannelScope scope) {
    final ch = scope.channel;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
          border: Border(
              bottom: BorderSide(
                  color: Theme.of(context)
                      .dividerColor
                      .withValues(alpha: 0.3)))),
      child: Row(children: [
        Avatar(ch.name, radius: 18),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(ch.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        fontSize: 16, fontWeight: FontWeight.w700)),
                Text(
                    ch.subscribersCount >= 0
                        ? '${ch.subscribersCount} подписчиков'
                        : 'Канал',
                    style: const TextStyle(
                        fontSize: 12, color: Colors.grey)),
              ]),
        ),
        if (ch.alias.isNotEmpty)
          IconButton(
              tooltip: 'Копировать адрес канала',
              icon: const Icon(Icons.link, size: 20),
              onPressed: () {
                Clipboard.setData(ClipboardData(
                    text: addressOf(
                        SearchTargetType.channel, ch.alias)));
                Toast.show(context, 'Адрес скопирован');
              }),
        PopupMenuButton<String>(
          icon: const Icon(Icons.more_vert, size: 20),
          tooltip: 'Ещё',
          onSelected: (a) => _broadcastMenu(a, scope),
          itemBuilder: (ctx) => [
            if (ch.role == 'owner') ...[
              const PopupMenuItem(
                  value: 'grant-member',
                  child: Text('Добавить участника')),
              const PopupMenuItem(
                  value: 'grant-admin',
                  child: Text('Добавить администратора')),
            ],
            if (ch.role == 'member' || ch.role == 'admin')
              const PopupMenuItem(
                  value: 'unsub', child: Text('Отписаться')),
            const PopupMenuItem(
                value: 'copy', child: Text('Копировать адрес')),
          ],
        ),
        IconButton(
            tooltip: 'О канале',
            icon: const Icon(Icons.info_outline, size: 20),
            onPressed: widget.onToggleMembers),
      ]),
    );
  }

  Future<void> _broadcastMenu(String action, ChannelScope scope) async {
    final ch = scope.channel;
    final repo = ref.read(chatRepositoryProvider);
    switch (action) {
      case 'copy':
        if (ch.alias.isNotEmpty) {
          await Clipboard.setData(ClipboardData(
              text:
                  addressOf(SearchTargetType.channel, ch.alias)));
          if (mounted) Toast.show(context, 'Адрес скопирован');
        }
      case 'grant-member':
        if (mounted) {
          await showChannelGrantDialog(context, ref, ch.id);
        }
      case 'grant-admin':
        if (mounted) {
          await showChannelGrantDialog(context, ref, ch.id,
              adminChoice: true);
        }
      case 'unsub':
        try {
          await repo.unsubscribeChannel(ch.alias);
          await _reselectBroadcast(ch.alias);
        } catch (e) {
          if (mounted) Toast.show(context, '$e');
        }
    }
  }

  /// Refreshes lists and reselects the channel by alias (role/counts
  /// may have changed after subscribe/unsubscribe).
  Future<void> _reselectBroadcast(String alias) async {
    final st = ref.read(homeStateProvider.notifier);
    await st.refresh();
    final mine = ref
        .read(homeStateProvider)
        .myChannels
        .where((c) => c.alias == alias);
    if (mine.isNotEmpty) {
      await st.selectStandaloneChannel(mine.first);
    } else {
      try {
        final hit = await ref.read(chatRepositoryProvider).findChannel(alias);
        if (hit.hasAccess) await st.selectStandaloneChannel(hit.toChannel());
      } catch (_) {}
    }
  }

  Widget _feedList(List<Message> posts) {
    final items = <Widget>[];
    String? curDay;
    for (final m in posts) {
      final day = _dayKey(m.createdAt);
      if (day != curDay) {
        curDay = day;
        items.add(Padding(
          padding: const EdgeInsets.only(top: 12),
          child: Center(
              child: Text(day,
                  style: const TextStyle(
                      fontSize: 12, color: Colors.grey))),
        ));
      }
      items.add(PostCard(
          message: m,
          canModerate: _broadcastRole().canPublish));
    }
    return Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 760),
        child: ListView.builder(
          controller: _scroll,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          itemCount: items.length,
          itemBuilder: (ctx, i) => items[i],
        ),
      ),
    );
  }

  /// My channel role for the current broadcast scope.
  Channel _broadcastRole() {
    final scope = ref.read(homeStateProvider).scope;
    if (scope is ChannelScope) return scope.channel;
    return Channel(id: '', name: '', type: 'broadcast');
  }

  String _dayKey(String createdAt) {
    final dt = DateTime.tryParse(createdAt)?.toLocal();
    if (dt == null) return '';
    final now = DateTime.now();
    final key =
        '${dt.day.toString().padLeft(2, '0')}.${dt.month.toString().padLeft(2, '0')}.${dt.year}';
    if (dt.year == now.year && dt.month == now.month && dt.day == now.day) {
      return 'Сегодня';
    }
    return key;
  }

  Widget _broadcastEmpty(Channel channel) {
    final text = channel.canPublish
        ? 'Создайте первую публикацию.'
        : (channel.role == 'member' || channel.role == 'admin'
            ? 'Новые публикации появятся здесь.'
            : 'Публикаций пока нет.');
    return Center(
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Text(channel.name,
            style: const TextStyle(
                fontSize: 18, fontWeight: FontWeight.w700)),
        const SizedBox(height: 8),
        Text(text, style: const TextStyle(color: Colors.grey)),
        if (channel.role.isEmpty && channel.alias.isNotEmpty) ...[
          const SizedBox(height: 12),
          FilledButton(
              onPressed: () => _subscribe(channel),
              child: const Text('Подписаться')),
        ],
      ]),
    );
  }

  Widget _broadcastFooter(BuildContext context, ChannelScope scope) {
    final ch = scope.channel;
    if (ch.canPublish) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 14),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          if (_uploading != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: LinearProgressIndicator(value: _uploading),
            ),
          ConstrainedBox(
            constraints:
                const BoxConstraints(maxWidth: 760, minHeight: 48),
            child: Row(children: [
              IconButton(
                  tooltip: 'Прикрепить',
                  icon: const Icon(Icons.attach_file, size: 20),
                  onPressed:
                      _uploading == null ? _pickAndSend : null),
              Expanded(
                child: Focus(
                  onKeyEvent: (node, event) =>
                      _enterToSend(event, _publish),
                  child: TextField(
                  controller: _input,
                  minLines: 1,
                  maxLines: 5,
                  decoration: const InputDecoration(
                      hintText: 'Новая публикация...',
                      border: InputBorder.none),
                  onSubmitted: (_) => _publish(),
                ),
              ),
              ),
              FilledButton(
                  onPressed: _publish,
                  child: const Text('Опубликовать')),
            ]),
          ),
        ]),
      );
    }
    if (ch.role == 'member' || ch.role == 'admin') {
      return const Padding(
        padding: EdgeInsets.fromLTRB(16, 4, 16, 14),
        child: Text('Вы подписаны на канал',
            style: TextStyle(color: Colors.grey)),
      );
    }
    if (ch.alias.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 14),
      child: FilledButton(
          onPressed: () => _subscribe(ch),
          child: const Text('Подписаться')),
    );
  }

  void _publish() {
    final t = _input.text;
    if (t.trim().isEmpty) return;
    _input.clear();
    _typingSent = false;
    ref.read(homeStateProvider.notifier).send(t);
  }

  Future<void> _subscribe(Channel channel) async {
    try {
      await ref
          .read(chatRepositoryProvider)
          .subscribeChannel(channel.alias);
      await _reselectBroadcast(channel.alias);
    } catch (e) {
      if (mounted) Toast.show(context, '$e');
    }
  }

  /// Enter sends, Shift+Enter inserts a newline.
  KeyEventResult _enterToSend(KeyEvent event, VoidCallback send) {
    if (event is KeyDownEvent &&
        event.logicalKey == LogicalKeyboardKey.enter &&
        !HardwareKeyboard.instance.isShiftPressed &&
        !HardwareKeyboard.instance.isControlPressed) {
      send();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  KeyEventResult _composerKeys(KeyEvent event) {
    // Esc cancels inline editing; Enter sends/saves.
    if (event is KeyDownEvent &&
        event.logicalKey == LogicalKeyboardKey.escape &&
        ref.read(editingMessageProvider) != null) {
      _cancelEdit();
      return KeyEventResult.handled;
    }
    // Up in an empty composer edits my last message (§81).
    if (event is KeyDownEvent &&
        event.logicalKey == LogicalKeyboardKey.arrowUp &&
        _input.text.isEmpty &&
        ref.read(editingMessageProvider) == null) {
      final last = _lastOwnMessage();
      if (last != null) {
        ref.read(editingMessageProvider.notifier).begin(last);
        return KeyEventResult.handled;
      }
    }
    return _enterToSend(event, _send);
  }

  Message? _lastOwnMessage() {
    final myId = ref.read(sessionProvider)?.userId;
    if (myId == null) return null;
    final messages = ref.read(homeStateProvider).messages;
    for (var i = messages.length - 1; i >= 0; i--) {
      final m = messages[i];
      // Only plain text messages I authored (posts live in their dialog).
      if (m.authorId == myId && m.kind == 'text') return m;
    }
    return null;
  }

  void _send() {
    final editing = ref.read(editingMessageProvider);
    final t = _input.text;
    if (t.trim().isEmpty) return;
    if (editing != null) {
      _saveEdit(editing, t);
      return;
    }
    _input.clear();
    _typingSent = false;
    ref.read(homeStateProvider.notifier).send(t);
  }

  Future<void> _saveEdit(Message message, String text) async {
    try {
      await ref
          .read(homeStateProvider.notifier)
          .editMessage(message.id, text);
      ref.read(editingMessageProvider.notifier).clear();
      _input.clear();
    } catch (e) {
      if (mounted) Toast.show(context, '$e');
    }
  }

  void _cancelEdit() {
    ref.read(editingMessageProvider.notifier).clear();
    _input.clear();
  }

  Future<void> _startCall({required bool video}) async {
    final scope = ref.read(homeStateProvider).scope;
    if (scope is! DmScope) return;
    final myId = ref.read(sessionProvider)?.userId;
    final others =
        scope.thread.members.where((m) => m.userId != myId).toList();
    final group = scope.thread.isGroup || others.length != 1;
    if (!group) {
      final nick = others.first.nick;
      await runMediaStart(context, ref,
          title: 'Позвонить $nick?',
          action: 'позвонить',
          start: () => ref
              .read(callStateProvider.notifier)
              .startCall(peerNick: nick, video: video),
          label: 'direct $nick',
          friendlyError: friendlyCallError);
    } else {
      // Group DMs go through the SFU; 1-1 stays on direct P2P.
      final title = scope.thread.title(myId ?? '');
      await runMediaStart(context, ref,
          title: 'Присоединиться к «$title»?',
          action: 'присоединиться',
          start: () => ref
              .read(groupCallProvider.notifier)
              .join(
                  dmId: scope.thread.id, title: title, video: video),
          label: 'group $title',
          friendlyError: friendlyGroupError);
    }
  }

  static String _mimeOf(String name) {
    final ext =
        name.contains('.') ? name.split('.').last.toLowerCase() : '';
    return switch (ext) {
      'png' => 'image/png',
      'jpg' || 'jpeg' => 'image/jpeg',
      'gif' => 'image/gif',
      'webp' => 'image/webp',
      'mp3' => 'audio/mpeg',
      'mp4' => 'video/mp4',
      'pdf' => 'application/pdf',
      'txt' || 'md' => 'text/plain',
      'zip' => 'application/zip',
      _ => 'application/octet-stream',
    };
  }

  Future<void> _pickAndSend() async {
    final scope = ref.read(homeStateProvider).scope;
    if (scope == null) return;
    DesktopLog.write('picker: requested');
    List<PlatformFile> picked;
    try {
      picked = await FilePicker.pickFiles();
    } catch (e) {
      DesktopLog.write('picker: open failed $e');
      if (mounted) Toast.show(context, 'Не удалось открыть выбор файла.');
      return;
    }
    if (picked.isEmpty) {
      DesktopLog.write('picker: cancelled by user');
      return;
    }
    final file = picked.first;
    DesktopLog.write('picker: selected ${picked.length} first=${file.name}');
    late final Uint8List bytes;
    try {
      bytes = await file.xFile.readAsBytes();
      DesktopLog.write('picker: read ${bytes.length} bytes');
    } catch (e) {
      DesktopLog.write('picker: read failed $e');
      if (mounted) Toast.show(context, 'Не удалось прочитать файл.');
      return;
    }
    if (!mounted) return;
    setState(() => _uploading = 0);
    try {
      final caption = _input.text.trim();
      _input.clear();
      final api = ref.read(fileApiProvider);
      if (scope is ChannelScope) {
        await api.upload(
            channelId: scope.channel.id,
            dmId: null,
            filename: file.name,
            bytes: bytes,
            mime: _mimeOf(file.name),
            text: caption,
            onProgress: (p) {
              if (mounted) setState(() => _uploading = p);
            });
      } else if (scope is DmScope) {
        await api.upload(
            channelId: null,
            dmId: scope.thread.id,
            filename: file.name,
            bytes: bytes,
            mime: _mimeOf(file.name),
            text: caption,
            onProgress: (p) {
              if (mounted) setState(() => _uploading = p);
            });
      }
    } catch (e) {
      if (mounted) Toast.show(context, friendlyUploadError(e));
    } finally {
      if (mounted) setState(() => _uploading = null);
    }
  }
}

/// Telegram-style edit banner above the composer: original text + cancel.
class _EditBanner extends ConsumerWidget {
  const _EditBanner();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final editing = ref.watch(editingMessageProvider);
    if (editing == null) return const SizedBox.shrink();
    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        border: Border(
            left: BorderSide(
                color: GrchatColors.of(context).accent, width: 2)),
      ),
      child: Row(children: [
        const Padding(
          padding: EdgeInsets.only(right: 8),
          child: Icon(Icons.edit, size: 18, color: Colors.blue),
        ),
        Expanded(
          child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text('Редактирование',
                    style: TextStyle(
                        color: Colors.blue,
                        fontWeight: FontWeight.w600)),
                Text(editing.text,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 13)),
              ]),
        ),
        IconButton(
            tooltip: 'Отменить',
            icon: const Icon(Icons.close, size: 18),
            onPressed: () =>
                ref.read(editingMessageProvider.notifier).clear()),
      ]),
    );
  }
}

/// Send button: checkmark while editing, plane otherwise.
class _ComposerSendButton extends ConsumerWidget {
  const _ComposerSendButton(
      {required this.input, required this.onSend});

  final TextEditingController input;
  final VoidCallback onSend;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final editing = ref.watch(editingMessageProvider) != null;
    return ValueListenableBuilder<TextEditingValue>(
      valueListenable: input,
      builder: (ctx, v, _) {
        final can = v.text.trim().isNotEmpty;
        return IconButton(
            tooltip: editing ? 'Сохранить' : 'Отправить',
            icon: Icon(editing ? Icons.check : Icons.send, size: 20),
            color: can
                ? GrchatColors.of(context).accent
                : GrchatColors.of(context).textMuted,
            onPressed: can ? onSend : null);
      },
    );
  }
}
