import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:grchat_client/src/widgets/esc_pop.dart';

void main() {
  group('Esc', () {
    testWidgets('closes a dialog', (t) async {
      await t.pumpWidget(MaterialApp(
          home: Scaffold(
              body: TextButton(
                  onPressed: () => showEscDialog(
                      context: t.element(find.byType(TextButton)),
                      builder: (_) => const AlertDialog(
                          title: Text('Dialog'))),
                  child: const Text('Open')))));
      await t.tap(find.text('Open'));
      await t.pumpAndSettle();
      expect(find.text('Dialog'), findsOneWidget);
      await t.sendKeyEvent(LogicalKeyboardKey.escape);
      await t.pumpAndSettle();
      expect(find.text('Dialog'), findsNothing);
    });

    testWidgets('closes a popup menu', (t) async {
      await t.pumpWidget(MaterialApp(
          home: Scaffold(
              body: PopupMenuButton<String>(
                  itemBuilder: (ctx) => const [
                        PopupMenuItem(
                            value: 'a', child: Text('Item A')),
                      ]))));
      await t.tap(find.byType(PopupMenuButton<String>));
      await t.pumpAndSettle();
      expect(find.text('Item A'), findsOneWidget);
      await t.sendKeyEvent(LogicalKeyboardKey.escape);
      await t.pumpAndSettle();
      expect(find.text('Item A'), findsNothing);
    });
  });
}
