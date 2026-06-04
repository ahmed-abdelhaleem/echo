import 'package:drift/drift.dart' show Value;
import 'package:echo_client/data/choice_repository.dart';
import 'package:echo_client/data/local/database.dart';
import 'package:echo_client/data/playthrough_repository.dart';
import 'package:echo_client/features/sync/sync_controller.dart';
import 'package:echo_client/features/vignette/vignette_controller.dart';
import 'package:echo_client/features/vignette/vignette_screen.dart';
import 'package:echo_client/services/api_client.dart';
import 'package:echo_client/services/sync_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../_helpers/fakes.dart';

class _StaticCompleteVignetteController extends VignetteController {
  _StaticCompleteVignetteController({
    required EchoDatabase db,
    required String localPlaythroughId,
  }) : super(
          content: FakeContentRepository(<String, dynamic>{}.cast()),
          choices: ChoiceRepository(db: db),
          playthroughs: PlaythroughRepository(db: db),
        ) {
    state = VignetteComplete(
      season: seasonWithVignettes(id: 'season-001'),
      localPlaythroughId: localPlaythroughId,
    );
  }

  @override
  Future<void> start({required String seasonId}) async {
    // Keep the test pinned on the complete state.
  }
}

void main() {
  testWidgets(
    'complete view defers sync work until after first frame',
    (WidgetTester tester) async {
      final db = newInMemoryDatabase();
      addTearDown(db.close);

      const localPlaythroughId = 'local-playthrough-1';
      const remotePlaythroughId = 'remote-playthrough-1';

      await db.insertLocalPlaythrough(
        LocalPlaythroughsCompanion.insert(
          localId: localPlaythroughId,
          seasonId: 'season-001',
          remoteId: const Value<String?>(remotePlaythroughId),
          startedAt: DateTime.utc(2026, 6, 4, 10, 30),
        ),
      );

      final adapter = ProgrammableAdapter()
        ..registerJson(
          method: 'POST',
          path: RegExp(r'^/playthroughs/remote-playthrough-1/finalize$'),
          status: 200,
          body: <String, dynamic>{
            'trait_vector': <String, dynamic>{
              'playthrough_id': remotePlaythroughId,
            },
          },
        )
        ..registerJson(
          method: 'GET',
          path: RegExp(r'^/playthroughs/remote-playthrough-1/reflection$'),
          status: 200,
          body: <String, dynamic>{
            'reflection': <String, dynamic>{
              'text': 'Reach for the unfamiliar.',
            },
          },
        )
        ..register(
          method: 'GET',
          path: RegExp(r'^/playthroughs/remote-playthrough-1/portrait$'),
          handler: (request, rawBody) async {
            return Reply(
              status: 503,
              body: '{"error":"portrait renderer unavailable"}',
            );
          },
        );
      final api = apiClientWith(adapter);

      final syncController = SyncController(
        service: SyncService(api: api, db: db),
      );

      final vignetteController = _StaticCompleteVignetteController(
        db: db,
        localPlaythroughId: localPlaythroughId,
      );

      await tester.pumpWidget(
        ProviderScope(
          overrides: <Override>[
            apiClientProvider.overrideWithValue(api),
            playthroughRepositoryProvider.overrideWith(
              (Ref ref) => PlaythroughRepository(db: db),
            ),
            syncControllerProvider.overrideWith((Ref ref) => syncController),
            vignetteControllerProvider.overrideWith(
              (Ref ref) => vignetteController,
            ),
          ],
          child: const MaterialApp(
            home: VignetteScreen(seasonId: 'season-001'),
          ),
        ),
      );

      // Regression check: old behavior threw a Riverpod exception here.
      expect(tester.takeException(), isNull);

      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(find.text('Unable to generate Portrait'), findsOneWidget);
      expect(syncController.state, isA<SyncSucceeded>());
    },
  );
}
