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
      width: 180,
      child: Material(
        color: GrchatColors.of(context).bgSidebar,
        child:
            Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Padding(
              padding: const EdgeInsets.all(12),
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
                    itemCount: data.members.length,
                    itemBuilder: (ctx, i) {
                      final m = data.members[i];
                      return ListTile(
                        dense: true,
                        leading: Avatar(m.nick, radius: 13),
                        title: Text(m.nick,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis),
                        trailing:
                            m.role.isEmpty ? null : RolePill(m.role),
                      );
                    },
                  ),
          ),
        ]),
      ),
    );
  }
}
