import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/theme.dart';
import '../../widgets/avatar.dart';
import '../home_state.dart';

/// Right column: community members or DM participants.
class MembersPanel extends ConsumerWidget {
  const MembersPanel({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final data = ref.watch(homeStateProvider);
    return SizedBox(
      width: 230,
      child: Material(
        color: GrchatColors.of(context).bgSidebar,
        child:
            Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Padding(
              padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
              child: Text('В СЕТИ — ${data.members.length}',
                  style: const TextStyle(
                      fontSize: 11,
                      color: Colors.grey,
                      fontWeight: FontWeight.w600))),
          Expanded(
            child: data.members.isEmpty
                ? const Padding(
                    padding: EdgeInsets.all(12),
                    child:
                        Text('—', style: TextStyle(color: Colors.grey)))
                : ListView.builder(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 8),
                    itemCount: data.members.length,
                    itemBuilder: (ctx, i) {
                      final m = data.members[i];
                      return Padding(
                        padding:
                            const EdgeInsets.symmetric(vertical: 5),
                        child: Row(children: [
                          Avatar(m.nick, radius: 14),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Column(
                                crossAxisAlignment:
                                    CrossAxisAlignment.start,
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Text(m.nick,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(
                                          fontSize: 14)),
                                  if (m.role.isNotEmpty &&
                                      m.role != 'member')
                                    Text(m.role,
                                        style: TextStyle(
                                            fontSize: 11,
                                            color: GrchatColors.of(
                                                    context)
                                                .textMuted)),
                                ]),
                          ),
                        ]),
                      );
                    },
                  ),
          ),
        ]),
      ),
    );
  }
}
