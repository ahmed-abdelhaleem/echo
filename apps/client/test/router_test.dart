// Routing tests: deep-link navigation for compare invite and view routes.

import 'package:echo_client/app/app.dart';
import 'package:echo_client/data/models/content.dart';
import 'package:echo_client/features/auth/login_screen.dart';
import 'package:echo_client/features/compare/compare_screen.dart';
import 'package:echo_client/services/api_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

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

  testWidgets(
    'Deep-link to /compare/accept/:token redirects to login for anonymous user',
    (tester) async {
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

      // Navigate to the acceptance deep-link without a session. Use a
      // descendant Scaffold element so GoRouter.of can locate the router.
      final BuildContext ctx = tester.element(find.byType(Scaffold).first);
      GoRouter.of(ctx).go('/compare/accept/tok-deep-link-test');
      await tester.pumpAndSettle();

      // Anonymous users must be redirected to the login screen per router rules.
      expect(find.byType(LoginScreen), findsOneWidget);
    },
  );

  testWidgets(
    'Deep-link to /compare/:token mounts CompareScreen',
    (tester) async {
      // The compare view route is public (no auth required). Provide a minimal
      // API stub so CompareScreen can complete its initial load.
      final adapter = ProgrammableAdapter()
        ..registerJson(
          method: 'GET',
          path: RegExp(r'^/compare/tok-view-test$'),
          status: 200,
          body: <String, dynamic>{
            'season_id': 'season-001',
            'status': 'accepted',
            'divergence': <String, dynamic>{
              'vignette_id': 'vignette-001',
              'inviter_choice': 'choice-a',
              'invitee_choice': 'choice-b',
            },
            'inviter_png_url':
                'https://api.echo.test/compare/tok-view-test/portrait?side=inviter',
            'invitee_png_url':
                'https://api.echo.test/compare/tok-view-test/portrait?side=invitee',
          },
        );

      await tester.pumpWidget(
        ProviderScope(
          overrides: <Override>[
            ...testOverrides(seasons: <String, Season>{}),
            apiClientProvider.overrideWithValue(apiClientWith(adapter)),
          ],
          child: const EchoApp(),
        ),
      );
      await tester.pumpAndSettle();

      // Navigate from inside the router context.
      final BuildContext ctx = tester.element(find.byType(Scaffold).first);
      GoRouter.of(ctx).go('/compare/tok-view-test');
      await tester.pumpAndSettle();

      // CompareScreen must be in the widget tree.
      expect(find.byType(CompareScreen), findsOneWidget);
      // After successful load the screen title is visible.
      expect(find.text('Friend comparison'), findsOneWidget);
    },
  );
}


