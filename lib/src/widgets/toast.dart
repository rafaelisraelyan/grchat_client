import 'package:flutter/material.dart';

/// Single toast system (§77): floating pill, 3s, replaces the previous one.
/// Banners (connection, missed calls) stay separate on purpose.
abstract final class Toast {
  static void show(BuildContext context, String text) {
    final m = ScaffoldMessenger.of(context);
    m.hideCurrentSnackBar();
    m.showSnackBar(SnackBar(
      content: Text(text),
      duration: const Duration(seconds: 3),
    ));
  }
}
