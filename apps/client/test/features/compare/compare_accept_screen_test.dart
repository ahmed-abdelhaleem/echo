import 'package:echo_client/features/auth/auth_controller.dart';
import 'package:echo_client/features/compare/compare_screen.dart';
import 'package:echo_client/features/vignette/vignette_controller.dart';
import 'package:echo_client/data/playthrough_repository.dart';
import 'package:echo_client/services/auth_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../_helpers/fakes.dart';

void main() {
  testWidgets(
    'CompareAcceptScreen lists known remote playthrough ids and pre-fills single candidate',
    (tester) async {
      final db = newInMemoryDatabase();
      addTearDown(db.close);

      final playthroughRepo = PlaythroughRepository(db: db);
      final localId =
          await playthroughRepo.startLocalPlaythrough(seasonId: 'season-001');
      await db.setLocalPlaythroughRemoteId(
        localId: localId,
        remoteId: '11111111-1111-4111-8111-111111111111',
      );

      final signedIn = AuthStateSignedIn(
        session: const AuthSession(
          token: 'token-1',
          identityId: 'identity-1',
          email: 'user@example.test',
        ),
      );
      final authController = AuthController(
        AuthClient(
          kratosBaseUrl: 'http://kratos.test',
          coreBaseUrl: 'http://core.test',
        ),
      )..state = signedIn;

      await tester.pumpWidget(
        ProviderScope(
          overrides: <Override>[
            echoDatabaseProvider.overrideWithValue(db),
            playthroughRepositoryProvider.overrideWithValue(playthroughRepo),
            authControllerProvider.overrideWith(
              (ref) => authController,
            ),
          ],
          child: const MaterialApp(
            home: CompareAcceptScreen(token: 'tok-123'),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('compare.accept.knownPlaythroughs')),
          findsOneWidget);
      expect(
        find.text('11111111-1111-4111-8111-111111111111'),
        findsAtLeastNWidgets(1),
      );
    },
  );
}
