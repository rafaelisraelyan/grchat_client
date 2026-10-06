import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:livekit_client/livekit_client.dart';

import '../widgets/avatar.dart';
import '../widgets/toast.dart';
import 'group_call.dart';

/// Group (SFU) call surface. Same visual language as the 1-1 CallWindow:
/// centered, elevated, chat stays usable behind it. v1 has no minimize.
class GroupCallHost extends ConsumerWidget {
  const GroupCallHost({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final call = ref.watch(groupCallProvider);
    if (call == null) return const SizedBox.shrink();
    return Stack(children: [
      if (call.phase == GroupPhase.ringing)
        const IgnorePointer(
          child: ModalBarrier(color: Colors.black38),
        ),
      Center(child: GroupCallWindow(call: call)),
    ]);
  }
}

class GroupCallWindow extends ConsumerWidget {
  const GroupCallWindow({super.key, required this.call});

  final GroupCall call;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final st = ref.read(groupCallProvider.notifier);
    final size = MediaQuery.sizeOf(context);
    final width = call.phase == GroupPhase.active && call.video
        ? (size.width - 96).clamp(320.0, 880.0)
        : (size.width - 64).clamp(300.0, 480.0);
    return Material(
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      borderRadius: BorderRadius.circular(18),
      elevation: 12,
      shadowColor: Colors.black.withValues(alpha: 0.5),
      child: Container(
        width: width,
        padding: const EdgeInsets.all(18),
        decoration: BoxDecoration(
          border: Border.all(
              color:
                  Theme.of(context).dividerColor.withValues(alpha: 0.5)),
          borderRadius: BorderRadius.circular(18),
        ),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          _identity(),
          const SizedBox(height: 10),
          if (call.phase == GroupPhase.active && call.video)
            SizedBox(
              height: 400,
              child: Consumer(builder: (ctx, ref2, _) {
                final cur = ref2.watch(groupCallProvider);
                if (cur == null) return const SizedBox.shrink();
                return _gridFor(
                    cur, ref2.read(groupCallProvider.notifier));
              }),
            ),
          if (call.phase == GroupPhase.active && call.video)
            const SizedBox(height: 12),
          _controls(context, st),
        ]),
      ),
    );
  }

  Widget _identity() {
    return Column(mainAxisSize: MainAxisSize.min, children: [
      Avatar(call.title, radius: 34),
      const SizedBox(height: 10),
      Text(call.title,
          style: const TextStyle(
              fontSize: 18, fontWeight: FontWeight.w700)),
      const SizedBox(height: 2),
      Text(
          call.phase == GroupPhase.ringing
              ? (call.video
                  ? 'Входящий групповой видеозвонок'
                  : 'Входящий групповой звонок')
              : (call.peers.isEmpty && call.outgoing
                  ? 'Вызов…'
                  : 'Подключено · ${call.peers.length} уч.'),
          style: const TextStyle(fontSize: 13, color: Colors.grey)),
    ]);
  }

  Widget _gridFor(GroupCall cur, GroupCallState st) {
    final tiles = <Widget>[];
    for (final p in cur.peers) {
      tiles.add(_peerTile(p));
    }
    tiles.add(_selfTile(cur, st));
    final cols = tiles.length <= 2 ? tiles.length : 3;
    return GridView.count(
      crossAxisCount: cols,
      crossAxisSpacing: 8,
      mainAxisSpacing: 8,
      childAspectRatio: 4 / 3,
      children: tiles,
    );
  }

  Widget _peerTile(GroupPeer p) {
    return Container(
      decoration: BoxDecoration(
          color: Colors.black,
          borderRadius: BorderRadius.circular(12)),
      clipBehavior: Clip.antiAlias,
      child: Stack(children: [
        if (p.videoTrack != null)
          Positioned.fill(
              child: VideoTrackRenderer(p.videoTrack!))
        else
          Center(
              child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                Avatar(p.name, radius: 24),
                const SizedBox(height: 4),
                Text(p.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 12)),
              ])),
        Positioned(
          left: 8,
          bottom: 6,
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Text(p.name,
                style: const TextStyle(
                    fontSize: 11, color: Colors.white70)),
            if (p.audioMuted) ...[
              const SizedBox(width: 4),
              const Icon(Icons.mic_off,
                  size: 12, color: Colors.white70),
            ],
          ]),
        ),
      ]),
    );
  }

  Widget _selfTile(GroupCall cur, GroupCallState st) {
    final track = st.localVideoTrack;
    final showVideo =
        cur.video && !cur.cameraOff && track != null;
    return Container(
      decoration: BoxDecoration(
          color: Colors.black,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: Colors.grey.shade700)),
      clipBehavior: Clip.antiAlias,
      child: Stack(children: [
        if (showVideo)
          Positioned.fill(child: VideoTrackRenderer(track))
        else
          const Center(
              child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                Avatar('Вы', radius: 24),
                SizedBox(height: 4),
                Text('Вы',
                    style: TextStyle(fontSize: 12)),
              ])),
        const Positioned(
          left: 8,
          bottom: 6,
          child: Text('Вы',
              style:
                  TextStyle(fontSize: 11, color: Colors.white70)),
        ),
      ]),
    );
  }

  Widget _controls(BuildContext context, GroupCallState st) {
    if (call.phase == GroupPhase.ringing && !call.outgoing) {
      return Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            _roundBtn(Colors.red, Icons.call_end, 'Отклонить',
                () async {
              try {
                await st.decline();
              } catch (e) {
                if (context.mounted) Toast.show(context, '$e');
              }
            }),
            const SizedBox(width: 28),
            _roundBtn(Colors.green, Icons.call, 'Принять',
                () async {
              try {
                await st.acceptIncoming();
              } catch (e) {
                if (context.mounted) {
                  Toast.show(context, friendlyGroupError(e));
                }
              }
            }),
          ]);
    }
    return Row(mainAxisAlignment: MainAxisAlignment.center, children: [
      _roundBtn(
          call.muted ? Colors.red : null,
          call.muted ? Icons.mic_off : Icons.mic,
          call.muted ? 'Включить микрофон' : 'Выключить микрофон',
          () => st.toggleMute()),
      const SizedBox(width: 12),
      if (call.video)
        _roundBtn(
            call.cameraOff ? Colors.red : null,
            call.cameraOff ? Icons.videocam_off : Icons.videocam,
            call.cameraOff ? 'Включить камеру' : 'Выключить камеру',
            () => st.toggleCamera()),
      if (call.video) const SizedBox(width: 12),
      _roundBtn(Colors.red, Icons.call_end, 'Завершить', () {
        st.hangup();
      }),
    ]);
  }

  Widget _roundBtn(
      Color? bg, IconData icon, String tip, VoidCallback onTap) {
    return Tooltip(
      message: tip,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(27),
        child: Container(
          width: 54,
          height: 54,
          decoration: BoxDecoration(
              color: bg ?? Colors.grey.withValues(alpha: 0.25),
              shape: BoxShape.circle),
          child: Icon(icon, color: Colors.white),
        ),
      ),
    );
  }
}
