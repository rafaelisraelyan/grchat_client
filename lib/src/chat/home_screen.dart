import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../app/providers.dart';
import '../transport/grchat_connection.dart';
import '../widgets/connection_banner.dart';
import 'home_state.dart';
import 'models.dart';
import '../call/call_overlay.dart';
import '../call/call_state.dart';
import '../voice/voice_state.dart';
import 'widgets/chat_view.dart';
import 'widgets/community_rail.dart';
import 'widgets/context_sidebar.dart';
import 'widgets/dialogs.dart';
import 'widgets/members_panel.dart';

class HomeScreen extends ConsumerStatefulWidget {
  const HomeScreen({super.key});

  @override
  ConsumerState<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends ConsumerState<HomeScreen> {
  bool _membersOpen = true;
  StreamSubscription<ConnStatus>? _connSub;
  bool _wasDown = false;

  @override
  void initState() {
    super.initState();
    Future.microtask(() {
      ref.read(homeStateProvider.notifier).init();
      ref.read(callStateProvider.notifier).ensureListening();
      ref.read(voiceStateProvider.notifier).ensureListening();
    });
    _connSub =
        ref.read(connectionProvider).status.listen((s) async {
      if (s != ConnStatus.connected) {
        _wasDown = true;
        return;
      }
      if (!_wasDown) return;
      _wasDown = false;
      final ok =
          await ref.read(homeStateProvider.notifier).resync();
      if (!ok && mounted) {
        await ref.read(connectionProvider).dispose();
        ref.read(sessionProvider.notifier).set(null);
      }
    });
  }

  @override
  void dispose() {
    _connSub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: LayoutBuilder(builder: (ctx, constraints) {
        // Plan §62: full layout above 1250px, members auto-hidden below.
        final showMembers =
            _membersOpen && constraints.maxWidth > 1250;
        return Stack(children: [
          Row(
            children: [
              CommunityRail(
                  onAddServer: () => showServerDialog(context, ref)),
              ContextSidebar(
                onSearch: () => showSearchDialog(context, ref),
                onNewDm: () => showNewDmDialog(context, ref),
                onVoice: _voiceStub,
              ),
              Expanded(
                  child: ChatView(
                onToggleMembers: () =>
                    setState(() => _membersOpen = !_membersOpen),
                onInvite: () => showInviteDialog(context, ref),
                onVoice: _voiceStub,
              )),
              if (showMembers) const MembersPanel(),
            ],
          ),
          const Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: ConnectionBanner(),
          ),
          const CallOverlay(),
        ]);
      }),
    );
  }

  void _voiceStub(Channel channel) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('Войс «${channel.name}» — звонки следующим шагом')));
  }
}
