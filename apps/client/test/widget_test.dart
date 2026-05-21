// Smoke test: the app boots and shows the HomeScreen content.
//
// This is the bare-minimum guarantee that routing, theming, and Riverpod
// wiring are all healthy. Feature-specific widget tests live next to their
// features in test/features/.

import 'package:echo_client/app/app.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('HomeScreen renders the M0 scaffold message', (tester) async {
    await tester.pumpWidget(const ProviderScope(child: EchoApp()));
    await tester.pumpAndSettle();

    expect(find.text('Echo'), findsOneWidget);
    expect(find.text('Echo client (M0 scaffold)'), findsOneWidget);
    expect(find.byType(FilledButton), findsOneWidget);
  });
}
