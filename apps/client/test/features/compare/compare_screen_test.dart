import 'package:echo_client/features/auth/auth_controller.dart';
import 'package:echo_client/features/compare/compare_screen.dart';
import 'package:echo_client/services/api_client.dart';
import 'package:echo_client/services/auth_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../_helpers/fakes.dart';

void main() {
  testWidgets(
    'CompareScreen shows copy-link affordance after share is enabled',
    (tester) async {
      final adapter = ProgrammableAdapter()
        ..registerJson(
          method: 'GET',
          path: RegExp(r'^/compare/tok-1$'),
          status: 200,
          body: <String, dynamic>{
            'season_id': 'season-001',
            'status': 'accepted',
            'divergence': <String, dynamic>{
              'vignette_id': 'vignette-002',
              'inviter_choice': 'choice-a',
              'invitee_choice': 'choice-b',
            },
            'inviter_png_url':
                'https://api.echo.test/compare/tok-1/portrait?side=inviter',
            'invitee_png_url':
                'https://api.echo.test/compare/tok-1/portrait?side=invitee',
          },
        )
        ..registerJson(
          method: 'POST',
          path: RegExp(r'^/compare/tok-1/share-enable$'),
          status: 200,
          body: <String, dynamic>{
            'share_token': 'share-1',
            'share_url': 'https://share.echo.test/compare/share-1',
          },
        );

      final authController = AuthController(
        AuthClient(
          kratosBaseUrl: 'http://kratos.test',
          coreBaseUrl: 'http://core.test',
        ),
      )..state = const AuthStateSignedIn(
          session: AuthSession(
            token: 'token-1',
            identityId: 'identity-1',
            email: 'user@example.test',
          ),
        );

      await tester.pumpWidget(
        ProviderScope(
          overrides: <Override>[
            apiClientProvider.overrideWithValue(apiClientWith(adapter)),
            authControllerProvider.overrideWith((ref) => authController),
          ],
          child: const MaterialApp(
            home: CompareScreen(token: 'tok-1'),
          ),
        ),
      );

      await tester.pumpAndSettle();
      expect(find.text('Enable public share link'), findsOneWidget);

      await tester.scrollUntilVisible(
        find.text('Enable public share link'),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Enable public share link'));
      await tester.pumpAndSettle();

      expect(find.text('Public share link:'), findsOneWidget);
      expect(find.byKey(const Key('compare.copyShareLink')), findsOneWidget);
    },
  );
}
