import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/theme.dart';
import '../../widgets/avatar.dart';
import '../home_state.dart';
import '../models.dart';

const _months = [
  '',
  'января',
  'февраля',
  'марта',
  'апреля',
  'мая',
  'июня',
  'июля',
  'августа',
  'сентября',
  'октября',
  'ноября',
  'декабря'
];

String _hhmm(String iso) {
  final dt = DateTime.tryParse(iso)?.toLocal();
  if (dt == null) return '';
  final h = dt.hour.toString().padLeft(2, '0');
  final m = dt.minute.toString().padLeft(2, '0');
  return '$h:$m';
}

String _dayLabel(DateTime day) {
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  final d = DateTime(day.year, day.month, day.day);
  final diff = today.difference(d).inDays;
  if (diff == 0) return 'Сегодня';
  if (diff == 1) return 'Вчера';
  return '${day.day} ${_months[day.month]}';
}

/// Grouped message stream: one avatar+name per author run.
class MessageList extends StatelessWidget {
  const MessageList(
      {super.key,
      required this.messages,
      required this.myId,
      this.controller});

  final List<Message> messages;
  final String myId;
  final ScrollController? controller;

  @override
  Widget build(BuildContext context) {
    final items = <Widget>[];
    DateTime? curDay;
    List<Message> run = [];
    void flush() {
      if (run.isNotEmpty) {
        items.add(MessageGroup(messages: run, myId: myId));
        run = [];
      }
    }

    for (final m in messages) {
      final dt = DateTime.tryParse(m.createdAt)?.toLocal();
      if (dt != null) {
        final day = DateTime(dt.year, dt.month, dt.day);
        if (curDay == null || day != curDay) {
          flush();
          curDay = day;
          items.add(_DaySeparator(label: _dayLabel(day)));
        }
      }
      if (run.isNotEmpty &&
          (run.last.authorId != m.authorId || !_close(run.last, m))) {
        flush();
      }
      run.add(m);
    }
    flush();
    return ListView.builder(
      controller: controller,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      itemCount: items.length,
      itemBuilder: (ctx, i) => items[i],
    );
  }

  bool _close(Message a, Message b) {
    final ta = DateTime.tryParse(a.createdAt);
    final tb = DateTime.tryParse(b.createdAt);
    if (ta == null || tb == null) return true;
    return tb.difference(ta).abs().inMinutes <= 5;
  }
}

class _DaySeparator extends StatelessWidget {
  const _DaySeparator({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final c = GrchatColors.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: Row(children: [
        Expanded(child: Container(height: 1, color: c.borderSubtle)),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10),
          child: Text(label,
              style: TextStyle(fontSize: 12, color: c.textMuted)),
        ),
        Expanded(child: Container(height: 1, color: c.borderSubtle)),
      ]),
    );
  }
}

class MessageGroup extends ConsumerWidget {
  const MessageGroup({super.key, required this.messages, required this.myId});

  final List<Message> messages;
  final String myId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final first = messages.first;
    final mine = first.authorId == myId;
    final c = GrchatColors.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 7),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Avatar(first.authorNick, radius: 17),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(children: [
                    Text(first.authorNick,
                        style: const TextStyle(
                            fontWeight: FontWeight.w700, fontSize: 14)),
                    if (mine)
                      Text('  вы',
                          style: TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.w700,
                              color: c.accent)),
                    Text('  ${_hhmm(first.createdAt)}',
                        style:
                            TextStyle(fontSize: 12, color: c.textMuted)),
                  ]),
                  const SizedBox(height: 1),
                  for (final m in messages)
                    _MessageRow(message: m, mine: mine),
                ]),
          ),
        ],
      ),
    );
  }
}

class _MessageRow extends StatefulWidget {
  const _MessageRow({required this.message, required this.mine});

  final Message message;
  final bool mine;

  @override
  State<_MessageRow> createState() => _MessageRowState();
}

class _MessageRowState extends State<_MessageRow> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final m = widget.message;
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onSecondaryTapDown: widget.mine
            ? (d) => _rowMenu(context, d.globalPosition)
            : null,
        child: Stack(children: [
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              if (m.text.isNotEmpty)
                Padding(
                  padding:
                      const EdgeInsets.symmetric(vertical: 1),
                  child: _TextLine(message: m),
                ),
              for (final a in m.attachments)
                AttachmentView(attachment: a),
            ],
          ),
          if (_hover && widget.mine)
            Positioned(
              right: 4,
              top: 0,
              child: _HoverActions(message: m),
            ),
        ]),
      ),
    );
  }

  Future<void> _rowMenu(BuildContext context, Offset at) async {
    final v = await showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(at.dx, at.dy, at.dx, at.dy),
      items: const [
        PopupMenuItem(value: 'edit', child: Text('Изменить')),
        PopupMenuItem(value: 'delete', child: Text('Удалить')),
      ],
    );
    if (!context.mounted) return;
    if (v == 'edit') {
      _editDialog(context);
    } else if (v == 'delete') {
      _deleteConfirm(context);
    }
  }

  Future<void> _editDialog(BuildContext context) async {
    final ref = ProviderScope.containerOf(context);
    final tc = TextEditingController(text: widget.message.text);
    final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
              title: const Text('Изменить сообщение'),
              content: TextField(
                  controller: tc,
                  autofocus: true,
                  maxLines: 4,
                  decoration: const InputDecoration(
                      border: OutlineInputBorder())),
              actions: [
                TextButton(
                    onPressed: () => Navigator.pop(ctx, false),
                    child: const Text('Отмена')),
                FilledButton(
                    onPressed: () => Navigator.pop(ctx, true),
                    child: const Text('Сохранить')),
              ],
            ));
    if (ok == true && context.mounted) {
      try {
        await ref
            .read(homeStateProvider.notifier)
            .editMessage(widget.message.id, tc.text.trim());
      } catch (e) {
        if (context.mounted) {
          ScaffoldMessenger.of(context)
              .showSnackBar(SnackBar(content: Text('$e')));
        }
      }
    }
  }

  Future<void> _deleteConfirm(BuildContext context) async {
    final ref = ProviderScope.containerOf(context);
    final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
              title: const Text('Удалить сообщение?'),
              actions: [
                TextButton(
                    onPressed: () => Navigator.pop(ctx, false),
                    child: const Text('Отмена')),
                FilledButton(
                    onPressed: () => Navigator.pop(ctx, true),
                    child: const Text('Удалить')),
              ],
            ));
    if (ok == true && context.mounted) {
      try {
        await ref
            .read(homeStateProvider.notifier)
            .deleteMessage(widget.message.id);
      } catch (e) {
        if (context.mounted) {
          ScaffoldMessenger.of(context)
              .showSnackBar(SnackBar(content: Text('$e')));
        }
      }
    }
  }
}

class _TextLine extends ConsumerWidget {
  const _TextLine({required this.message});

  final Message message;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final m = message;
    final c = GrchatColors.of(context);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Text(m.text,
              style: const TextStyle(fontSize: 15, height: 1.4)),
        ),
        if (m.editedAt != null)
          Padding(
            padding: const EdgeInsets.only(left: 6, top: 2),
            child: Text('(изм.)',
                style: TextStyle(fontSize: 12, color: c.textMuted)),
          ),
      ],
    );
  }
}

class _HoverActions extends StatelessWidget {
  const _HoverActions({required this.message});

  final Message message;

  @override
  Widget build(BuildContext context) {
    final c = GrchatColors.of(context);
    return Material(
      color: c.surfaceElevated,
      borderRadius: BorderRadius.circular(10),
      elevation: 6,
      shadowColor: Colors.black.withValues(alpha: 0.5),
      child: Container(
        decoration: BoxDecoration(
            border: Border.all(color: c.borderSubtle),
            borderRadius: BorderRadius.circular(10)),
        padding: const EdgeInsets.symmetric(horizontal: 2),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          _HoverBtn(icon: Icons.edit, label: 'Изменить', message: message, isDelete: false),
          _HoverBtn(icon: Icons.delete, label: 'Удалить', message: message, isDelete: true),
        ]),
      ),
    );
  }
}

class _HoverBtn extends ConsumerWidget {
  const _HoverBtn({required this.icon, required this.label, required this.message, required this.isDelete});

  final IconData icon;
  final String label;
  final Message message;
  final bool isDelete;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = GrchatColors.of(context);
    return Tooltip(
      message: label,
      waitDuration: const Duration(seconds: 2),
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: () => isDelete ? _deleteConfirm(context, ref, message) : _editDialog(context, ref, message),
        child: Padding(
          padding: const EdgeInsets.all(9),
          child: Icon(icon, size: 20, color: isDelete ? c.danger : c.textPrimary),
        ),
      ),
    );
  }
}

Future<void> _editDialog(BuildContext context, WidgetRef ref, Message message) async {
  final tc = TextEditingController(text: message.text);
  final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
            title: const Text('Изменить сообщение'),
            content: TextField(controller: tc, autofocus: true, maxLines: 4, decoration: const InputDecoration(border: OutlineInputBorder())),
            actions: [
              TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Отмена')),
              FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Сохранить')),
            ],
          ));
  if (ok == true && context.mounted) {
    try {
      await ref.read(homeStateProvider.notifier).editMessage(message.id, tc.text.trim());
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
      }
    }
  }
}

Future<void> _deleteConfirm(BuildContext context, WidgetRef ref, Message message) async {
  final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
            title: const Text('Удалить сообщение?'),
            actions: [
              TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Отмена')),
              FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Удалить')),
            ],
          ));
  if (ok == true && context.mounted) {
    try {
      await ref.read(homeStateProvider.notifier).deleteMessage(message.id);
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
      }
    }
  }
}

class AttachmentView extends ConsumerWidget {
  const AttachmentView({super.key, required this.attachment});

  final Attachment attachment;

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
        return _FileCard(attachment: attachment);
      }
      return Container(
        margin: const EdgeInsets.only(top: 6),
        constraints: const BoxConstraints(maxWidth: 300),
        decoration:
            BoxDecoration(borderRadius: BorderRadius.circular(10)),
        clipBehavior: Clip.antiAlias,
        child: Image.memory(cached, fit: BoxFit.cover),
      );
    }
    return _FileCard(attachment: attachment);
  }
}

class _FileCard extends StatelessWidget {
  const _FileCard({required this.attachment});

  final Attachment attachment;

  @override
  Widget build(BuildContext context) {
    final c = GrchatColors.of(context);
    return Container(
      margin: const EdgeInsets.only(top: 6),
      constraints: const BoxConstraints(maxWidth: 300),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
          color: c.surface,
          border: Border.all(color: c.borderSubtle),
          borderRadius: BorderRadius.circular(10)),
      child: Row(children: [
        Container(
          width: 34,
          height: 34,
          decoration: BoxDecoration(
              color: c.surfaceElevated,
              borderRadius: BorderRadius.circular(8)),
          alignment: Alignment.center,
          child: Icon(Icons.insert_drive_file,
              size: 18, color: c.textSecondary),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(attachment.filename,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 14)),
                Text(formatSize(attachment.sizeBytes),
                    style:
                        TextStyle(fontSize: 12, color: c.textMuted)),
              ]),
        ),
      ]),
    );
  }
}

String formatSize(int b) => b < 1024
    ? '$b Б'
    : b < 1048576
        ? '${(b / 1024).toStringAsFixed(1)} КБ'
        : '${(b / 1048576).toStringAsFixed(1)} МБ';
