import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../home_state.dart';
import '../models.dart';
import '../../app/providers.dart';
import 'message_list.dart';

/// Center column: header, message list, composer.
class ChatView extends ConsumerStatefulWidget {
  const ChatView(
      {super.key,
      required this.onToggleMembers,
      required this.onInvite,
      required this.onVoice});

  final VoidCallback onToggleMembers;
  final VoidCallback onInvite;
  final void Function(Channel channel) onVoice;

  @override
  ConsumerState<ChatView> createState() => _ChatViewState();
}

class _ChatViewState extends ConsumerState<ChatView> {
  final _input = TextEditingController();
  final _scroll = ScrollController();
  bool _typingSent = false;
  double? _uploading;

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
    final scope = data.scope;
    ref.listen(homeStateProvider, (_, next) {
      if (next.messages.isNotEmpty) {
        WidgetsBinding.instance.addPostFrameCallback((_) => _scrollDown());
      }
    });
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
            IconButton(
                tooltip: 'Скопировать инвайт',
                icon: const Icon(Icons.person_add, size: 20),
                onPressed: widget.onInvite),
            IconButton(
                tooltip: 'Позвонить (скоро)',
                icon: const Icon(Icons.call, size: 20),
                onPressed: () => ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                        content: Text('Звонки — следующим шагом')))),
          ],
          IconButton(
              tooltip: 'Участники',
              icon: const Icon(Icons.people, size: 20),
              onPressed: widget.onToggleMembers),
        ]),
      ),
      Expanded(
        child: data.loading
            ? const Center(child: CircularProgressIndicator())
            : data.scope == null
                ? const Center(child: Text('Выбери канал или личку слева'))
                : MessageList(
                    controller: _scroll,
                    messages: data.messages,
                    typing: data.typing,
                    myId: ref.watch(sessionProvider)?.userId ?? '',
                  ),
      ),
      if (scope != null)
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 14),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            if (_uploading != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: LinearProgressIndicator(value: _uploading),
              ),
            Row(children: [
              IconButton(
                  tooltip: 'Прикрепить файл',
                  icon: const Icon(Icons.attach_file),
                  onPressed: _uploading == null ? _pickAndSend : null),
              Expanded(
                child: TextField(
                  controller: _input,
                  decoration: InputDecoration(
                    hintText: 'Написать в ${scope.title}…',
                    border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(20)),
                    contentPadding: const EdgeInsets.symmetric(
                        horizontal: 16, vertical: 12),
                  ),
                  onChanged: (_) {
                    if (!_typingSent) {
                      _typingSent = true;
                      ref.read(homeStateProvider.notifier).sendTyping(true);
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
              IconButton(icon: const Icon(Icons.send), onPressed: _send),
            ]),
          ]),
        ),
    ]);
  }

  void _send() {
    final t = _input.text;
    if (t.trim().isEmpty) return;
    _input.clear();
    _typingSent = false;
    ref.read(homeStateProvider.notifier).send(t);
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
    final picked = await FilePicker.pickFiles();
    if (picked.isEmpty) return;
    final file = picked.first;
    final bytes = await file.xFile.readAsBytes();
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
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Не отправлено: $e')));
      }
    } finally {
      if (mounted) setState(() => _uploading = null);
    }
  }
}
