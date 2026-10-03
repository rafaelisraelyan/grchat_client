import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../app/providers.dart';
import 'home_state.dart';
import 'models.dart';

class HomeScreen extends ConsumerStatefulWidget {
  const HomeScreen({super.key});

  @override
  ConsumerState<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends ConsumerState<HomeScreen> {
  final _input = TextEditingController();
  final _scroll = ScrollController();
  bool _membersOpen = true;
  bool _typingSent = false;

  @override
  void initState() {
    super.initState();
    Future.microtask(
        () => ref.read(homeStateProvider.notifier).init());
  }

  @override
  void dispose() {
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _scrollDown() {
    if (!_scroll.hasClients) return;
    _scroll.animateTo(_scroll.position.maxScrollExtent,
        duration: const Duration(milliseconds: 200), curve: Curves.easeOut);
  }

  @override
  Widget build(BuildContext context) {
    final data = ref.watch(homeStateProvider);
    ref.listen(homeStateProvider, (_, next) {
      if (next.messages.isNotEmpty) {
        WidgetsBinding.instance.addPostFrameCallback((_) => _scrollDown());
      }
    });
    return Scaffold(
      body: Row(
        children: [
          _rail(data),
          _channelsPane(data),
          Expanded(child: _chatPane(data)),
          if (_membersOpen) _membersPane(data),
        ],
      ),
    );
  }

  Widget _rail(HomeData data) {
    final st = ref.read(homeStateProvider.notifier);
    return Container(
      width: 64,
      color: Theme.of(context).colorScheme.surfaceContainerHighest.withValues(alpha: 0.4),
      child: Column(children: [
        const SizedBox(height: 10),
        for (final c in data.communities)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: InkWell(
              onTap: () {
                if (c.channels.any((ch) => ch.type == 'text')) {
                  st.selectChannel(
                      c, c.channels.firstWhere((ch) => ch.type == 'text'));
                }
              },
              child: CircleAvatar(
                  backgroundColor: Theme.of(context).colorScheme.primary,
                  child: Text(c.name.isEmpty ? '?' : c.name[0])),
            ),
          ),
        IconButton(
            tooltip: 'Создать сервер / войти по инвайту',
            onPressed: _serverDialog,
            icon: const Icon(Icons.add)),
      ]),
    );
  }

  Widget _channelsPane(HomeData data) {
    final st = ref.read(homeStateProvider.notifier);
    final scope = data.scope;
    Community? curComm =
        scope is ChannelScope ? scope.community : null;
    curComm ??= data.communities.isNotEmpty ? data.communities.first : null;
    final myId = ref.read(sessionProvider)?.userId ?? '';
    return Container(
      width: 220,
      color: Theme.of(context).colorScheme.surfaceContainerHighest.withValues(alpha: 0.6),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Padding(
          padding: const EdgeInsets.all(12),
          child: Text(curComm?.name ?? 'grchat',
              style: const TextStyle(fontWeight: FontWeight.w700)),
        ),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            children: [
              if (curComm != null) ...[
                _groupLabel('Текстовые каналы'),
                for (final ch
                    in curComm.channels.where((c) => c.type == 'text'))
                  _chanTile(
                      '# ${ch.name}',
                      scope?.key == 'c:${ch.id}',
                      () => st.selectChannel(curComm!, ch),
                      data.unread['c:${ch.id}']),
                _groupLabel('Голосовые каналы'),
                for (final ch
                    in curComm.channels.where((c) => c.type != 'text'))
                  ListTile(
                      dense: true,
                      leading: const Icon(Icons.volume_up, size: 18),
                      title: Text(ch.name),
                      onTap: () => _voiceStub(ch)),
              ],
              _groupLabel('Личные сообщения'),
              for (final dm in data.dms)
                _chanTile(
                    dm.title(myId), scope?.key == 'd:${dm.id}',
                    () => st.selectDm(dm), data.unread['d:${dm.id}'],
                    icon: dm.isGroup ? Icons.group : Icons.person),
              ListTile(
                  dense: true,
                  leading: const Icon(Icons.add, size: 18),
                  title: const Text('Новая личка'),
                  onTap: _newDmDialog),
            ],
          ),
        ),
        _meRow(),
      ]),
    );
  }

  Widget _groupLabel(String t) => Padding(
      padding: const EdgeInsets.fromLTRB(8, 12, 8, 4),
      child: Text(t,
          style: const TextStyle(
              fontSize: 11, color: Colors.grey, fontWeight: FontWeight.w600)));

  Widget _chanTile(String title, bool on, VoidCallback tap, int? unread,
      {IconData? icon}) {
    return ListTile(
      dense: true,
      selected: on,
      selectedTileColor:
          Theme.of(context).colorScheme.primary.withValues(alpha: 0.15),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      leading: icon == null ? null : Icon(icon, size: 18),
      title: Text(title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(fontWeight: on ? FontWeight.w700 : null)),
      trailing: (unread ?? 0) > 0
          ? CircleAvatar(
              radius: 10,
              backgroundColor: Theme.of(context).colorScheme.primary,
              child: Text('$unread',
                  style: const TextStyle(fontSize: 11, color: Colors.white)))
          : null,
      onTap: tap,
    );
  }

  Widget _meRow() {
    final s = ref.watch(sessionProvider);
    return Container(
      padding: const EdgeInsets.all(8),
      child: Row(children: [
        CircleAvatar(
            radius: 14,
            backgroundColor: Theme.of(context).colorScheme.primary,
            child: Text(s == null || s.nick.isEmpty ? '?' : s.nick[0])),
        const SizedBox(width: 8),
        Expanded(
            child: Text(s?.nick ?? '?',
                maxLines: 1, overflow: TextOverflow.ellipsis)),
        IconButton(
            tooltip: 'Тема',
            icon: const Icon(Icons.brightness_6, size: 18),
            onPressed: () =>
                ref.read(themeModeProvider.notifier).toggle()),
        IconButton(
            tooltip: 'Выйти',
            icon: const Icon(Icons.logout, size: 18),
            onPressed: () async {
              await ref.read(connectionProvider).dispose();
              ref.read(sessionProvider.notifier).set(null);
            }),
      ]),
    );
  }

  Widget _chatPane(HomeData data) {
    final scope = data.scope;
    return Column(children: [
      Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        decoration: BoxDecoration(
            border: Border(
                bottom: BorderSide(
                    color: Theme.of(context).dividerColor.withValues(alpha: 0.3)))),
        child: Row(children: [
          Expanded(
              child: Text(scope?.title ?? 'Выбери чат',
                  style: const TextStyle(
                      fontSize: 16, fontWeight: FontWeight.w700))),
          if (scope is ChannelScope) ...[
            IconButton(
                tooltip: 'Скопировать инвайт',
                icon: const Icon(Icons.person_add, size: 20),
                onPressed: _inviteDialog),
          ],
          IconButton(
              tooltip: 'Участники',
              icon: const Icon(Icons.people, size: 20),
              onPressed: () =>
                  setState(() => _membersOpen = !_membersOpen)),
        ]),
      ),
      Expanded(
        child: data.loading
            ? const Center(child: CircularProgressIndicator())
            : data.scope == null
                ? const Center(child: Text('Выбери канал или личку слева'))
                : ListView.builder(
                    controller: _scroll,
                    padding: const EdgeInsets.all(16),
                    itemCount: data.messages.length +
                        (data.typing.isEmpty ? 0 : 1),
                    itemBuilder: (ctx, i) {
                      if (i >= data.messages.length) {
                        return Padding(
                          padding: const EdgeInsets.only(top: 4),
                          child: Text('${data.typing.join(', ')} печатает…',
                              style: const TextStyle(
                                  color: Colors.grey, fontSize: 12)),
                        );
                      }
                      return _bubble(data.messages[i]);
                    },
                  ),
      ),
      if (scope != null)
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 14),
          child: TextField(
            controller: _input,
            decoration: InputDecoration(
              hintText: 'Написать в ${scope.title}…',
              border: const OutlineInputBorder(),
              suffixIcon: IconButton(
                  icon: const Icon(Icons.send), onPressed: _send),
            ),
            onChanged: (_) {
              if (!_typingSent) {
                _typingSent = true;
                ref.read(homeStateProvider.notifier).sendTyping(true);
                Future.delayed(const Duration(seconds: 3), () {
                  _typingSent = false;
                  ref.read(homeStateProvider.notifier).sendTyping(false);
                });
              }
            },
            onSubmitted: (_) => _send(),
          ),
        ),
    ]);
  }

  Widget _bubble(Message m) {
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
              Container(
                margin: const EdgeInsets.only(top: 6),
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                    border: Border.all(color: Colors.grey.withValues(alpha: 0.4)),
                    borderRadius: BorderRadius.circular(8)),
                child: Text('📎 ${a.filename} · ${_size(a.sizeBytes)}'),
              ),
            if (m.editedAt != null)
              const Text('(изм.)',
                  style: TextStyle(fontSize: 10, color: Colors.grey)),
          ],
        ),
      ),
    );
  }

  String _size(int b) =>
      b < 1024 ? '$b Б' : b < 1048576 ? '${(b / 1024).toStringAsFixed(1)} КБ' : '${(b / 1048576).toStringAsFixed(1)} МБ';

  void _send() {
    final t = _input.text;
    if (t.trim().isEmpty) return;
    _input.clear();
    _typingSent = false;
    ref.read(homeStateProvider.notifier).send(t);
  }

  Widget _membersPane(HomeData data) {
    return Container(
      width: 180,
      color: Theme.of(context).colorScheme.surfaceContainerHighest.withValues(alpha: 0.6),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        const Padding(
            padding: EdgeInsets.all(12),
            child: Text('Участники',
                style: TextStyle(fontWeight: FontWeight.w700))),
        Expanded(
          child: data.members.isEmpty
              ? const Padding(
                  padding: EdgeInsets.all(12),
                  child: Text('—', style: TextStyle(color: Colors.grey)))
              : ListView.builder(
                  itemCount: data.members.length,
                  itemBuilder: (ctx, i) {
                    final m = data.members[i];
                    return ListTile(
                      dense: true,
                      leading: CircleAvatar(
                          radius: 13,
                          backgroundColor:
                              Theme.of(context).colorScheme.primary,
                          child: Text(
                              m.nick.isEmpty ? '?' : m.nick[0],
                              style: const TextStyle(fontSize: 12))),
                      title: Text(m.nick,
                          maxLines: 1, overflow: TextOverflow.ellipsis),
                      subtitle: Text(m.role,
                          style: const TextStyle(
                              fontSize: 11, color: Colors.grey)),
                    );
                  },
                ),
        ),
      ]),
    );
  }

  void _voiceStub(Channel ch) {
    ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Войс «${ch.name}» — звонки следующим шагом')));
  }

  Future<void> _serverDialog() async {
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
                      final messenger = ScaffoldMessenger.of(context);
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
                        messenger.showSnackBar(SnackBar(content: Text('$e')));
                      }
                      if (ctx.mounted) Navigator.pop(ctx);
                    },
                    child: const Text('Ок')),
              ],
            ));
  }

  Future<void> _inviteDialog() async {
    final scope = ref.read(homeStateProvider).scope;
    if (scope is! ChannelScope) return;
    try {
      final code =
          await ref.read(chatRepositoryProvider).createInvite(scope.community.id);
      if (!mounted) return;
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
                      },
                      child: const Text('Копировать')),
                ],
              ));
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('$e')));
      }
    }
  }

  Future<void> _newDmDialog() async {
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
                      final messenger = ScaffoldMessenger.of(context);
                      try {
                        final dmId = await ref
                            .read(chatRepositoryProvider)
                            .openDm(nick.text.trim());
                        if (ctx.mounted) Navigator.pop(ctx, dmId);
                      } catch (e) {
                        messenger.showSnackBar(SnackBar(content: Text('$e')));
                      }
                    },
                    child: const Text('Открыть')),
              ],
            ));
    if (id != null) {
      await ref.read(homeStateProvider.notifier).refresh();
      final dms = ref.read(homeStateProvider).dms;
      final found = dms.where((d) => d.id == id);
      if (found.isNotEmpty) {
        await ref.read(homeStateProvider.notifier).selectDm(found.first);
      }
    }
  }
}
