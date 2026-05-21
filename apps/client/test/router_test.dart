// Routing test: tapping the "Open placeholder vignette" button on Home
// navigates to /vignette/vignette-001 and shows VignetteScreen with the
// path parameter bound to the heading.

import 'package:echo_client/app/app.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('Home -> Vignette navigation passes the id through the route',
      (tester) async {
    await tester.pumpWidget(const ProviderScope(child: EchoApp()));
    await tester.pumpAndSettle();

    await tester.tap(find.byType(FilledButton));
    await tester.pumpAndSettle();

    expect(find.text('Vignette: vignette-001'), findsOneWidget);

    await tester.tap(find.byType(OutlinedButton));
    await tester.pumpAndSettle();

    expect(find.text('Echo client (M0 scaffold)'), findsOneWidget);
  });
}
