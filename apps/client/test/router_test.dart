// Routing test: tapping the "Start season" button on Home navigates to
// /season/:id and the vignette renderer mounts.

import 'package:echo_client/app/app.dart';
import 'package:echo_client/data/models/content.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '_helpers/fakes.dart';

void main() {
  testWidgets('Home → Season navigation loads the renderer', (tester) async {
    final season = seasonWithVignettes(id: 'season-001');
    await tester.pumpWidget(
      ProviderScope(
        overrides: testOverrides(
          seasons: <String, Season>{season.id: season},
        ),
        child: const EchoApp(),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Start season'));
    await tester.pumpAndSettle();

    // First vignette in the fixture.
    expect(find.text('The first scene begins.'), findsOneWidget);
    expect(find.text('Stay quiet.'), findsOneWidget);
    expect(find.text('Speak up.'), findsOneWidget);
  });
}
