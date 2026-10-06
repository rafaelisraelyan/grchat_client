import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../app/providers.dart';
import '../desktop/window.dart';
import '../notify/notify.dart';
import '../transport/grchat_connection.dart';
import '../widgets/connection_banner.dart';
import 'home_state.dart';
import '../call/call_surface.dart';
import '../call/group_call.dart';
import '../call/group_call_window.dart';
import '../call/call_state.dart';
import '../voice/voice_state.dart';
import 'widgets/chat_view.dart';
import 'widgets/channel_info.dart';
import 'widgets/community_rail.dart';
import 'widgets/dm_info_panel.dart';
import 'widgets/context_sidebar.dart';
import 'widgets/dialogs.dart';
import 'widgets/members_panel.dart';
import 'widgets/missed_banner.dart';

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
      ref.read(groupCallProvider.notifier).ensureListening();
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
    // Incoming call: bring the window forward + system notification.
    // The overlay handles accept/decline; the toast covers tray mode.
    ref.listen<ActiveCall?>(callStateProvider, (prev, next) {
      final backend = ref.read(notifyBackendProvider);
      if (next != null &&
          !next.outgoing &&
          next.phase == CallPhase.ringing &&
          (prev?.callId != next.callId)) {
        () async {
          await focusWindow();
          final st = ref.read(callStateProvider.notifier);
          backend.showCall(
            tag: 'call:${next.callId}',
            title: next.video
                ? 'Входящий видеозвонок'
                : 'Входящий звонок',
            body: next.peerNick,
            onOpen: () => focusWindow(),
            onDecline: () => st.decline(),
          );
        }();
      }
      if (next == null && prev != null) {
        backend.cancel('call:${prev.callId}');
      }
    });
    return Scaffold(
      body: CallbackShortcuts(
        bindings: {
          const SingleActivator(LogicalKeyboardKey.keyK, control: true):
              () => showQuickNav(context, ref),
        },
        child: Focus(
          autofocus: true,
          child: LayoutBuilder(builder: (ctx, constraints) {
        // Plan §62: full layout above 1250px, members auto-hidden below.
        final showMembers =
            _membersOpen && constraints.maxWidth > 1250;
        // Broadcast workspace (§19): rail + wide feed + info panel,
        // no second left sidebar.
        final scope = ref.watch(homeStateProvider).scope;
        final isBroadcast =
            scope is ChannelScope && scope.community == null;
        return Stack(children: [
          Row(
            children: [
              CommunityRail(
                  onAddServer: () => showAddMenu(context, ref)),
              if (!isBroadcast)
                ContextSidebar(
                  onSearch: () => showSearchDialog(context, ref),
                  onNewDm: () => showNewDmDialog(context, ref),
                ),
              Expanded(
                  child: ChatView(
                onToggleMembers: () =>
                    setState(() => _membersOpen = !_membersOpen),
                onInvite: () => showInviteDialog(context, ref),
              )),
              if (showMembers)
                isBroadcast
                    ? const ChannelInfoPanel()
                    : scope is DmScope && !scope.thread.isGroup
                        ? const DmInfoPanel()
                        : const MembersPanel(),
            ],
          ),
          const Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [ConnectionBanner(), MissedBanner()]),
          ),
          const CallOverlayHost(),
          const GroupCallHost(),
        ]);
          }),
        ),
      ),
    );
  }
}
