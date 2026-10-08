import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../app/theme.dart';
import '../../call/call_state.dart';
import '../../call/media_session.dart';
import '../home_state.dart';
import '../models.dart';

String _mmss(int totalSec) {
  final s = totalSec < 0 ? 0 : totalSec;
  return '${(s ~/ 60).toString().padLeft(2, '0')}:${(s % 60).toString().padLeft(2, '0')}';
}

String _hhmm(String iso) {
  final dt = DateTime.tryParse(iso)?.toLocal();
  if (dt == null) return '';
  return '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
}

/// Centered system record of a finished/missed call. Direction is
/// viewer-relative (author == me means outgoing).
class CallCard extends ConsumerWidget {
  const CallCard({super.key, required this.message, required this.myId});

  final Message message;
  final String myId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = GrchatColors.of(context);
    final call = message.call!;
    final outgoing = message.authorId == myId;
    final myNick = ref.watch(sessionProvider)?.nick;
    final (title, sub, icon, iconColor) =
        _describe(outgoing, call, message.authorNick, myNick);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(children: [
        const Spacer(),
        Flexible(
          child: Container(
            padding:
                const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              border: Border.all(color: c.borderSubtle),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Icon(icon, size: 20, color: iconColor),
              const SizedBox(width: 10),
              Flexible(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(title,
                        style: const TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w600)),
                    Text('$sub · ${_hhmm(message.createdAt)}',
                        style: TextStyle(
                            fontSize: 12, color: c.textMuted)),
                  ],
                ),
              ),
              const SizedBox(width: 6),
              IconButton(
                tooltip: 'Перезвонить',
                iconSize: 20,
                color: c.accent,
                icon: const Icon(Icons.call),
                onPressed: () => _callback(context, ref),
              ),
            ]),
          ),
        ),
        const Spacer(),
      ]),
    );
  }

  (String, String, IconData, Color) _describe(
      bool outgoing, CallInfo call, String peerNick, String? myNick) {
    final kind = call.video ? 'Видеозвонок' : 'Звонок';
    switch (call.status) {
      case 'completed':
        return (
          outgoing ? 'Исходящий $kind' : 'Входящий $kind',
          _mmss(call.durationSec),
          call.video ? Icons.videocam : Icons.call,
          Colors.green,
        );
      case 'declined':
        if (outgoing) {
          final by = call.endedBy ?? peerNick;
          return (
            call.video
                ? '$by отклонил видеозвонок'
                : '$by отклонил звонок',
            'отклонён',
            Icons.call_end,
            Colors.grey,
          );
        }
        final iDeclined =
            call.endedBy != null && call.endedBy == myNick;
        return (
          iDeclined ? 'Вы отклонили $kind' : 'Пропущенный $kind',
          iDeclined ? 'отклонён' : 'пропущен',
          Icons.phone_missed,
          iDeclined ? Colors.grey : Colors.red,
        );
      case 'cancelled':
        return (
          outgoing ? 'Звонок отменён' : 'Пропущенный $kind',
          outgoing ? 'отменён' : 'пропущен',
          outgoing ? Icons.call_end : Icons.phone_missed,
          outgoing ? Colors.grey : Colors.red,
        );
      case 'offline':
        return (
          outgoing ? 'Абонент не в сети' : 'Пропущенный $kind',
          outgoing ? 'не доставлен' : 'пропущен',
          outgoing ? Icons.cloud_off : Icons.phone_missed,
          outgoing ? Colors.grey : Colors.red,
        );
      default: // missed
        return (
          outgoing ? 'Нет ответа' : 'Пропущенный $kind',
          outgoing ? 'без ответа' : 'пропущен',
          outgoing ? Icons.call_end : Icons.phone_missed,
          outgoing ? Colors.grey : Colors.red,
        );
    }
  }

  Future<void> _callback(BuildContext context, WidgetRef ref) async {
    final scope = ref.read(homeStateProvider).scope;
    if (scope is! DmScope) return;
    final notifier = ref.read(callStateProvider.notifier);
    if (!scope.thread.isGroup) {
      final others = scope.thread.members
          .where((m) => m.userId != myId)
          .toList();
      if (others.isEmpty) return;
      final nick = others.first.nick;
      await runMediaStart(context, ref,
          title: 'Позвонить $nick?',
          action: 'позвонить',
          start: () => notifier.startCall(
              peerNick: nick, video: message.call!.video),
          label: 'direct $nick',
          friendlyError: friendlyCallError);
    } else {
      await runMediaStart(context, ref,
          title: 'Позвонить в группу?',
          action: 'позвонить',
          start: () => notifier.startCall(
              dmId: scope.thread.id, video: message.call!.video),
          label: 'group ${scope.thread.id}',
          friendlyError: friendlyCallError);
    }
  }
}
