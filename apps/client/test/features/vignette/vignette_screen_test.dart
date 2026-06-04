import 'dart:convert';

import 'package:dio/dio.dart';
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

final List<int> _onePixelPngBytes = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+nm2cAAAAASUVORK5CYII=',
);

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

class _CompleteViewApiClientFake extends ApiClient {
  _CompleteViewApiClientFake({
    required this.reflectionText,
    required this.portraitBytes,
  }) : super(baseUrl: 'http://test.invalid');

  final String reflectionText;
  final List<int> portraitBytes;

  @override
  Future<Map<String, dynamic>> finalizePlaythrough({
    required String playthroughId,
  }) async {
    return <String, dynamic>{'playthrough_id': playthroughId};
  }

  @override
  Future<String> getReflection({required String playthroughId}) async {
    return reflectionText;
  }

  @override
  Future<List<int>> getPortraitBytes({
    required String playthroughId,
    bool animate = false,
  }) async {
    if (animate) {
      throw DioException(
        requestOptions:
            RequestOptions(path: '/playthroughs/$playthroughId/portrait'),
        message: 'animation not expected in this test',
      );
    }
    return portraitBytes;
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

  testWidgets(
    'complete view renders portrait + reflection without provider lifecycle errors',
    (WidgetTester tester) async {
      final db = newInMemoryDatabase();
      addTearDown(db.close);

      const localPlaythroughId = 'local-playthrough-2';
      const remotePlaythroughId = 'remote-playthrough-2';

      await db.insertLocalPlaythrough(
        LocalPlaythroughsCompanion.insert(
          localId: localPlaythroughId,
          seasonId: 'season-001',
          remoteId: const Value<String?>(remotePlaythroughId),
          startedAt: DateTime.utc(2026, 6, 4, 11, 0),
        ),
      );

      final api = _CompleteViewApiClientFake(
        reflectionText: 'Reach for the unfamiliar.',
        portraitBytes: _onePixelPngBytes,
      );
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

      expect(tester.takeException(), isNull);

      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(find.text('Your Portrait'), findsOneWidget);
      expect(find.text('Reach for the unfamiliar.'), findsOneWidget);
      expect(find.byType(Image), findsOneWidget);
      expect(syncController.state, isA<SyncSucceeded>());
    },
  );
}
