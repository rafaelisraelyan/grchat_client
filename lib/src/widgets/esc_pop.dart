import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// showDialog with Esc-to-close (§81). Drop-in replacement.
Future<T?> showEscDialog<T>(
    {required BuildContext context,
    required Widget Function(BuildContext) builder,
    bool autofocus = true}) {
  return showDialog<T>(
      context: context,
      builder: (ctx) =>
          EscPop(autofocus: autofocus, child: builder(ctx)));
}
/// Closes the enclosing dialog on Esc (§81). Wrap dialog content with it.
///
/// Needs focus somewhere in the subtree to receive the key: pass
/// [autofocus] false in dialogs whose own field already autofocuses.
class EscPop extends StatelessWidget {
  const EscPop({super.key, required this.child, this.autofocus = true});

  final Widget child;
  final bool autofocus;

  @override
  Widget build(BuildContext context) {
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.escape): () =>
            Navigator.maybePop(context),
      },
      child: Focus(autofocus: autofocus, child: child),
    );
  }
}
