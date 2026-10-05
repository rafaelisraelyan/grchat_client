import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/theme.dart';
import '../home_state.dart';
import '../../widgets/avatar.dart';

/// Left 64px strip: DM stand button, communities, add.
class CommunityRail extends ConsumerWidget {
  const CommunityRail({super.key, required this.onAddServer});

  final VoidCallback onAddServer;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final data = ref.watch(homeStateProvider);
    final st = ref.read(homeStateProvider.notifier);
    final scope = data.scope;
    final curId = scope is ChannelScope ? scope.community?.id : null;
    final homeOn = data.activeCommunityId == null;
    return SizedBox(
      width: 64,
      child: Material(
        color: GrchatColors.of(context).bgRail,
        child: Column(children: [
          const SizedBox(height: 10),
          HomeTile(selected: homeOn, onTap: st.goHome),
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Container(
                height: 1,
                width: 32,
                color: Colors.grey.withValues(alpha: 0.4)),
          ),
          for (var i = 0; i < data.communities.length; i++)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: InkWell(
                onTap: () {
                  final c = data.communities[i];
                  if (c.channels.any((ch) => ch.type == 'text')) {
                    st.selectChannel(
                        c, c.channels.firstWhere((ch) => ch.type == 'text'));
                  }
                },
                child: ServerTile(
                  data.communities[i].name.isEmpty
                      ? '?'
                      : data.communities[i].name[0].toUpperCase(),
                  color: _srvColor(i),
                  selected: data.communities[i].id == curId,
                ),
              ),
            ),
          IconButton(
              tooltip: 'Создать сервер / войти по инвайту',
              onPressed: onAddServer,
              icon: const Icon(Icons.add)),
        ]),
      ),
    );
  }

  Color _srvColor(int i) {
    const palette = [
      Color(0xFF574CC9),
      Color(0xFF2E7D5B),
      Color(0xFFB5651D),
      Color(0xFF4A90D9),
    ];
    return palette[i % palette.length];
  }
}
