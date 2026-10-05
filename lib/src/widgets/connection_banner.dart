import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../app/providers.dart';
import '../transport/grchat_connection.dart';

/// Top banner for transport state. Silent when connected; shows
/// reconnect progress offline and a brief "restored" notice after.
class ConnectionBanner extends ConsumerStatefulWidget {
  const ConnectionBanner({super.key});

  @override
  ConsumerState<ConnectionBanner> createState() =>
      _ConnectionBannerState();
}

class _ConnectionBannerState extends ConsumerState<ConnectionBanner> {
  bool _wasDown = false;
  Timer? _hideTimer;
  bool _showRestored = false;

  @override
  void dispose() {
    _hideTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final status = ref.watch(connStatusProvider).value;
    final session = ref.watch(sessionProvider);
    // StreamProvider starts with loading (null) before the first socket
    // event — treat as healthy to avoid a flash on startup/in tests.
    if (status == null) return const SizedBox.shrink();
    if (status == ConnStatus.connected) {
      if (_wasDown) {
        _wasDown = false;
        _showRestored = true;
        _hideTimer?.cancel();
        _hideTimer = Timer(const Duration(seconds: 3), () {
          if (mounted) setState(() => _showRestored = false);
        });
      }
      if (!_showRestored || session == null) {
        return const SizedBox.shrink();
      }
      return _bar(context, 'Соединение восстановлено', Colors.green,
          inProgress: false, onRetry: null);
    }
    if (session == null) return const SizedBox.shrink();
    _wasDown = true;
    _showRestored = false;
    return _bar(
        context,
        status == ConnStatus.connecting
            ? 'Подключение…'
            : 'Соединение потеряно. Переподключаемся…',
        Colors.orange,
        inProgress: true,
        onRetry: () =>
            ref.read(connectionProvider).retryNow());
  }

  Widget _bar(BuildContext context, String text, Color color,
      {required bool inProgress, VoidCallback? onRetry}) {
    return Container(
      width: double.infinity,
      color: color.withValues(alpha: 0.92),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
      child: Row(children: [
        if (inProgress)
          const SizedBox(
              width: 14,
              height: 14,
              child: CircularProgressIndicator(
                  strokeWidth: 2, color: Colors.white))
        else
          const Icon(Icons.check, size: 14, color: Colors.white),
        const SizedBox(width: 8),
        Expanded(
          child: Text(text,
              style: const TextStyle(
                  color: Colors.white, fontSize: 13)),
        ),
        if (onRetry != null)
          TextButton(
              onPressed: onRetry,
              child: const Text('Повторить',
                  style: TextStyle(color: Colors.white))),
      ]),
    );
  }
}
