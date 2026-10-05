import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../home_state.dart';

/// Missed calls accumulated while offline. Dismiss or jump to the DM.
class MissedBanner extends ConsumerWidget {
  const MissedBanner({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final missed = ref.watch(homeStateProvider).missed;
    if (missed.isEmpty) return const SizedBox.shrink();
    final names =
        missed.map((m) => m.fromNick).toSet().take(3).join(', ');
    final extra = missed.length > 1 ? ' (${missed.length})' : '';
    return Container(
      width: double.infinity,
      color: Colors.red.withValues(alpha: 0.92),
      padding:
          const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
      child: Row(children: [
        const Icon(Icons.phone_missed,
            size: 16, color: Colors.white),
        const SizedBox(width: 8),
        Expanded(
          child: Text('Пропущенные звонки$extra: $names',
              style: const TextStyle(
                  color: Colors.white, fontSize: 13)),
        ),
        TextButton(
            onPressed: () =>
                ref.read(homeStateProvider.notifier).openMissed(),
            child: const Text('Открыть',
                style: TextStyle(color: Colors.white))),
        IconButton(
          iconSize: 16,
          color: Colors.white,
          icon: const Icon(Icons.close),
          onPressed: () =>
              ref.read(homeStateProvider.notifier).clearMissed(),
        ),
      ]),
    );
  }
}
