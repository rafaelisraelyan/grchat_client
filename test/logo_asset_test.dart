import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('logo asset loads', (t) async {
    await t.pumpWidget(const MaterialApp(
        home: Image(image: AssetImage('assets/logo-icon.png'))));
    await t.pumpAndSettle();
    expect(find.byType(Image), findsOneWidget);
    final img =
        t.widget<Image>(find.byType(Image)).image
            as AssetImage;
    final data = await img.obtainKey(
        createLocalImageConfiguration(t.element(find.byType(Image))));
    expect(data.name, 'assets/logo-icon.png');
  });
}
