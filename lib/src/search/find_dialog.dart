import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../widgets/avatar.dart';
import '../widgets/toast.dart';
import 'search_address.dart';
import 'search_results.dart';

/// Backend half of the unified find dialog. Separated for tests.
abstract class FindSearchApi {
  Future<ServerHit> findServer(String alias);
  Future<ChannelHit> findChannel(String alias);
  Future<({String userId, String nick})> findUser(String nick);
}

/// Unified GRChat find: Канал / Сервер / Бот / Пользователь.
///
/// The type prefix (`channel/` …) is a non-editable leading token; the user
/// edits only the identifier. Pasting a full `server/CODE` address switches
/// the type automatically. `bot` stays present but inactive until Bot API.
class FindDialog extends StatefulWidget {
  const FindDialog({
    super.key,
    this.initialType = SearchTargetType.channel,
    required this.search,
    required this.onOpenServer,
    required this.onOpenChannel,
    required this.onWriteUser,
    required this.onJoinServer,
    required this.onSubscribeChannel,
  });

  final SearchTargetType initialType;
  final FindSearchApi search;
  final Future<void> Function(ServerHit hit) onOpenServer;
  final Future<void> Function(ChannelHit hit) onOpenChannel;
  final Future<void> Function(String nick) onWriteUser;
  final Future<void> Function(ServerHit hit) onJoinServer;
  final Future<void> Function(ChannelHit hit) onSubscribeChannel;

  @override
  State<FindDialog> createState() => FindDialogState();
}

/// Public for widget tests.
class FindDialogState extends State<FindDialog> {
  late SearchTargetType _type = widget.initialType;
  final _query = TextEditingController();
  bool _loading = false;
  String? _error;
  ServerHit? _server;
  ChannelHit? _channel;
  String? _userNick;
  bool _pasting = false;

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  String get _placeholder => switch (_type) {
        SearchTargetType.channel => 'Код канала',
        SearchTargetType.server => 'Код сервера',
        SearchTargetType.bot => 'Код бота',
        SearchTargetType.user => 'Никнейм',
      };

  void _setType(SearchTargetType t) {
    if (_type == t) return;
    setState(() {
      _type = t;
      _error = null;
      _server = null;
      _channel = null;
      _userNick = null;
    });
  }

  void _onChanged(String v) {
    if (_pasting) return;
    // Smart paste: a full address switches the type automatically.
    if (v.contains('/')) {
      final p = parseSearchAddress(v);
      if (p != null) {
        _pasting = true;
        setState(() {
          _type = p.type;
          _error = null;
          _server = null;
          _channel = null;
          _userNick = null;
        });
        _query.text = p.query;
        _query.selection =
            TextSelection.collapsed(offset: p.query.length);
        _pasting = false;
      }
    }
  }

  Future<void> _search() async {
    final q = _query.text.trim();
    if (q.isEmpty || _loading) return;
    setState(() {
      _loading = true;
      _error = null;
      _server = null;
      _channel = null;
      _userNick = null;
    });
    try {
      switch (_type) {
        case SearchTargetType.server:
          final hit = await widget.search.findServer(q);
          if (mounted) setState(() => _server = hit);
        case SearchTargetType.channel:
          final hit = await widget.search.findChannel(q);
          if (mounted) setState(() => _channel = hit);
        case SearchTargetType.user:
          final u = await widget.search.findUser(q);
          if (mounted) setState(() => _userNick = u.nick);
        case SearchTargetType.bot:
          if (mounted) setState(() => _error = 'Боты появятся позже.');
      }
    } catch (e) {
      if (mounted) setState(() => _error = searchErrorText(_type, e));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _act(Future<void> Function() fn) async {
    try {
      await fn();
      if (mounted) Navigator.pop(context);
    } catch (e) {
      if (mounted) {
        setState(() => _error = searchErrorText(_type, e));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    // Locals for promotion: pattern-ifs don't narrow private fields.
    final server = _server;
    final channel = _channel;
    final userNick = _userNick;
    return AlertDialog(
      title: const Text('Найти в GRChat'),
      content: SizedBox(
        width: 380,
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          SegmentedButton<SearchTargetType>(
            segments: const [
              ButtonSegment(
                  value: SearchTargetType.channel, label: Text('Канал')),
              ButtonSegment(
                  value: SearchTargetType.server, label: Text('Сервер')),
              ButtonSegment(
                  value: SearchTargetType.bot,
                  label: Text('Бот'),
                  enabled: false),
              ButtonSegment(
                  value: SearchTargetType.user,
                  label: Text('Пользователь')),
            ],
            selected: {_type},
            onSelectionChanged: (s) => _setType(s.first),
          ),
          const SizedBox(height: 12),
          if (_type == SearchTargetType.bot)
            const Text('Боты появятся позже.',
                style: TextStyle(color: Colors.grey))
          else
            Row(children: [
              Container(
                padding: const EdgeInsets.symmetric(
                    horizontal: 10, vertical: 15),
                decoration: BoxDecoration(
                  color: Theme.of(context)
                      .dividerColor
                      .withValues(alpha: 0.25),
                  borderRadius: const BorderRadius.horizontal(
                      left: Radius.circular(4)),
                ),
                child: Text(prefixOf(_type),
                    style: const TextStyle(fontWeight: FontWeight.w700)),
              ),
              Expanded(
                child: TextField(
                  controller: _query,
                  decoration: InputDecoration(
                      hintText: _placeholder,
                      border: const OutlineInputBorder(
                          borderRadius: BorderRadius.horizontal(
                              right: Radius.circular(4)))),
                  onChanged: _onChanged,
                  onSubmitted: (_) => _search(),
                  textInputAction: TextInputAction.search,
                ),
              ),
            ]),
          if (_loading) ...[
            const SizedBox(height: 12),
            const CircularProgressIndicator(),
          ],
          if (_error != null) ...[
            const SizedBox(height: 8),
            Text(_error!, style: const TextStyle(color: Colors.red)),
          ],
          if (server != null) ...[
            const SizedBox(height: 8),
            _ResultCard(
              avatarName: server.name,
              title: server.name,
              subtitle:
                  '${server.isPrivate ? 'Приватный сервер' : 'Сервер'}'
                  '${server.membersCount > 0 ? ' · ${server.membersCount} уч.' : ''}',
              actionLabel: resultActionLabel(SearchTargetType.server,
                  joined: server.isMember, isPrivate: server.isPrivate),
              actionEnabled:
                  server.isMember || !server.isPrivate,
              onAction: () => _act(() => server.isMember
                  ? widget.onOpenServer(server)
                  : widget.onJoinServer(server)),
              onCopy: () {
                Clipboard.setData(ClipboardData(text: server.address));
                Toast.show(context, 'Адрес скопирован');
              },
            ),
          ],
          if (channel != null) ...[
            const SizedBox(height: 8),
            _ResultCard(
              avatarName: channel.name,
              title: channel.name,
              subtitle:
                  '${channel.type == 'voice' ? 'Голосовой канал' : 'Канал'}'
                  '${channel.isPrivate ? ' · приватный' : ''}'
                  '${channel.subscribersCount > 0 ? ' · ${channel.subscribersCount} подп.' : ''}',
              actionLabel: resultActionLabel(SearchTargetType.channel,
                  joined: channel.hasAccess, isPrivate: channel.isPrivate),
              actionEnabled:
                  channel.hasAccess || !channel.isPrivate,
              onAction: () => _act(() => channel.hasAccess
                  ? widget.onOpenChannel(channel)
                  : widget.onSubscribeChannel(channel)),
              onCopy: () {
                Clipboard.setData(ClipboardData(text: channel.address));
                Toast.show(context, 'Адрес скопирован');
              },
            ),
          ],
          if (userNick != null) ...[
            const SizedBox(height: 8),
            _ResultCard(
              avatarName: userNick,
              title: userNick,
              subtitle: '@$userNick',
              actionLabel: resultActionLabel(SearchTargetType.user,
                  joined: false, isPrivate: false),
              actionEnabled: true,
              onAction: () => _act(() => widget.onWriteUser(userNick)),
              onCopy: () {
                Clipboard.setData(ClipboardData(
                    text: addressOf(SearchTargetType.user, userNick)));
                Toast.show(context, 'Адрес скопирован');
              },
            ),
          ],
        ]),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Закрыть')),
        if (_type != SearchTargetType.bot)
          FilledButton(onPressed: _search, child: const Text('Найти')),
      ],
    );
  }
}

class _ResultCard extends StatelessWidget {
  const _ResultCard({
    required this.avatarName,
    required this.title,
    required this.subtitle,
    required this.actionLabel,
    required this.actionEnabled,
    required this.onAction,
    required this.onCopy,
  });

  final String avatarName;
  final String title;
  final String subtitle;
  final String actionLabel;
  final bool actionEnabled;
  final VoidCallback onAction;
  final VoidCallback onCopy;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        border: Border.all(
            color: Theme.of(context).dividerColor.withValues(alpha: 0.5)),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(children: [
        Avatar(avatarName, radius: 18),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontWeight: FontWeight.w700)),
                Text(subtitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        fontSize: 12, color: Colors.grey)),
              ]),
        ),
        IconButton(
            tooltip: 'Копировать адрес',
            icon: const Icon(Icons.copy, size: 18),
            onPressed: onCopy),
        FilledButton.tonal(
            onPressed: actionEnabled ? onAction : null,
            child: Text(actionLabel)),
      ]),
    );
  }
}
