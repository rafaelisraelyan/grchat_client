import 'package:flutter/material.dart';

import '../../app/theme.dart';
import '../home_state.dart';

/// Empty conversation placeholder (§72): small icon, no giant art.
class EmptyChat extends StatelessWidget {
  const EmptyChat({super.key, required this.scope, required this.myId});

  final Scope scope;
  final String myId;

  @override
  Widget build(BuildContext context) {
    final c = GrchatColors.of(context);
    final s = scope;
    late final IconData icon;
    late final String title;
    if (s is ChannelScope) {
      icon = Icons.tag;
      title = 'Это начало канала #${s.channel.name}';
    } else if (s is DmScope && !s.thread.isGroup) {
      icon = Icons.person_outline;
      final peers =
          s.thread.members.where((m) => m.userId != myId).toList();
      title = peers.isEmpty
          ? 'Начните переписку'
          : 'Начните переписку с ${peers.first.nick}';
    } else {
      icon = Icons.group_outlined;
      title = 'Это начало групповой переписки';
    }
    return Center(
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Container(
          width: 56,
          height: 56,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            border: Border.all(color: c.borderSubtle),
          ),
          child: Icon(icon, size: 24, color: c.textMuted),
        ),
        const SizedBox(height: 12),
        Text(title,
            textAlign: TextAlign.center,
            style: const TextStyle(
                fontSize: 15, fontWeight: FontWeight.w700)),
        const SizedBox(height: 4),
        Text('Сообщений пока нет',
            style: TextStyle(fontSize: 13, color: c.textMuted)),
      ]),
    );
  }
}
