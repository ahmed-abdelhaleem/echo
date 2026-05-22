// Tests for SyncService (T-CLIENT-012).
//
// We exercise the real SyncService against:
//   * an in-memory EchoDatabase pre-seeded with local playthroughs and
//     pending choices,
//   * an ApiClient bound to a ProgrammableAdapter that returns canned
//     responses keyed by URL.
//
// This is closer to integration than unit: we deliberately keep the
// Dio + sync path together so wire-format regressions (eg a misspelt
// JSON field) fail loudly.

import 'dart:convert';

import 'package:drift/drift.dart' show Value;
import 'package:echo_client/data/local/database.dart';
import 'package:echo_client/services/sync_service.dart';
import 'package:flutter_test/flutter_test.dart';

import '../_helpers/fakes.dart';

void main() {
  group('SyncService.drain', () {
    late EchoDatabase db;

    setUp(() async {
      db = newInMemoryDatabase();
    });

    tearDown(() async {
      await db.close();
    });

    test('noop when nothing pending', () async {
      final adapter = ProgrammableAdapter();
      final service = SyncService(api: apiClientWith(adapter), db: db);

      final result = await service.drain();

      expect(result.hadWork, isFalse);
      expect(result.aborted, isFalse);
      expect(adapter.recorded, isEmpty);
    });

    test('registers playthrough and drains its choice', () async {
      await db.insertLocalPlaythrough(
        LocalPlaythroughsCompanion.insert(
          localId: 'local-pt-1',
          seasonId: 'season-001',
          remoteId: const Value<String?>(null),
          startedAt: DateTime.utc(2026, 5, 21, 10),
        ),
      );
      await db.insertPendingChoice(
        PendingChoiceEventsCompanion.insert(
          localId: 'local-c-1',
          localPlaythroughId: 'local-pt-1',
          seasonId: 'season-001',
          vignetteId: 'v-1',
          choiceId: 'c-1a',
          committedAt: DateTime.utc(2026, 5, 21, 10, 1),
          deliberationMs: const Value<int?>(820),
          createdAt: DateTime.utc(2026, 5, 21, 10, 1),
        ),
      );

      final adapter = ProgrammableAdapter()
        ..registerJson(
          method: 'POST',
          path: RegExp(r'^/playthroughs$'),
          status: 201,
          body: <String, dynamic>{
            'playthrough': <String, dynamic>{
              'id': 'remote-pt-1',
              'user_id': 'user-1',
              'season_id': 'season-001',
              'season_version': 1,
              'status': 'in_progress',
              'started_at': '2026-05-21T10:00:00Z',
              'created_at': '2026-05-21T10:00:00Z',
              'updated_at': '2026-05-21T10:00:00Z',
            },
          },
        )
        ..registerJson(
          method: 'POST',
          path: RegExp(r'^/playthroughs/remote-pt-1/choices$'),
          status: 200,
          body: <String, dynamic>{
            'choice_event': <String, dynamic>{
              'id': 'e-1',
              'playthrough_id': 'remote-pt-1',
              'vignette_id': 'v-1',
              'choice_id': 'c-1a',
              'server_received_at': '2026-05-21T10:01:05Z',
              'created_at': '2026-05-21T10:01:05Z',
            },
          },
        );

      final service = SyncService(api: apiClientWith(adapter), db: db);
      final result = await service.drain();

      expect(result.playthroughsRegistered, 1);
      expect(result.choicesDrained, 1);
      expect(result.conflicts, 0);
      expect(result.notFound, 0);
      expect(result.aborted, isFalse);

      // The local playthrough now knows its remote id.
      final pt = await db.findLocalPlaythrough('local-pt-1');
      expect(pt?.remoteId, 'remote-pt-1');

      // The drained choice is gone from the pending table.
      final remaining = await db.listPendingChoices();
      expect(remaining, isEmpty);

      // The POST body carried the canonical wire format.
      final choiceCall = adapter.recorded.firstWhere(
        (r) => r.path.contains('/choices'),
      );
      final payload = jsonDecode(choiceCall.body) as Map<String, dynamic>;
      expect(payload['vignette_id'], 'v-1');
      expect(payload['choice_id'], 'c-1a');
      expect(payload['deliberation_ms'], 820);
      expect(payload['client_timestamp'], isA<String>());
    });

    test('409 conflict deletes the local row and counts it', () async {
      await db.insertLocalPlaythrough(
        LocalPlaythroughsCompanion.insert(
          localId: 'local-pt-2',
          seasonId: 'season-001',
          remoteId: const Value<String?>('remote-pt-2'),
          startedAt: DateTime.utc(2026, 5, 21, 11),
        ),
      );
      await db.insertPendingChoice(
        PendingChoiceEventsCompanion.insert(
          localId: 'local-c-2',
          localPlaythroughId: 'local-pt-2',
          seasonId: 'season-001',
          vignetteId: 'v-1',
          choiceId: 'c-1b',
          committedAt: DateTime.utc(2026, 5, 21, 11, 0, 5),
          deliberationMs: const Value<int?>(null),
          createdAt: DateTime.utc(2026, 5, 21, 11, 0, 5),
        ),
      );

      final adapter = ProgrammableAdapter()
        ..registerJson(
          method: 'POST',
          path: RegExp(r'^/playthroughs/remote-pt-2/choices$'),
          status: 409,
          body: <String, dynamic>{
            'error': 'choice already recorded with a different value',
          },
        );

      final result = await SyncService(
        api: apiClientWith(adapter),
        db: db,
      ).drain();

      expect(result.conflicts, 1);
      expect(result.choicesDrained, 0);
      expect(result.aborted, isFalse);

      final remaining = await db.listPendingChoices();
      expect(remaining, isEmpty);
    });

    test('aborts the drain on a transient 500 from createPlaythrough',
        () async {
      await db.insertLocalPlaythrough(
        LocalPlaythroughsCompanion.insert(
          localId: 'local-pt-3',
          seasonId: 'season-001',
          remoteId: const Value<String?>(null),
          startedAt: DateTime.utc(2026, 5, 21, 12),
        ),
      );
      await db.insertPendingChoice(
        PendingChoiceEventsCompanion.insert(
          localId: 'local-c-3',
          localPlaythroughId: 'local-pt-3',
          seasonId: 'season-001',
          vignetteId: 'v-1',
          choiceId: 'c-1a',
          committedAt: DateTime.utc(2026, 5, 21, 12, 0, 5),
          deliberationMs: const Value<int?>(null),
          createdAt: DateTime.utc(2026, 5, 21, 12, 0, 5),
        ),
      );

      final adapter = ProgrammableAdapter()
        ..registerJson(
          method: 'POST',
          path: RegExp(r'^/playthroughs$'),
          status: 503,
          body: <String, dynamic>{'error': 'service unavailable'},
        );

      final result = await SyncService(
        api: apiClientWith(adapter),
        db: db,
      ).drain();

      expect(result.aborted, isTrue);
      expect(result.playthroughsRegistered, 0);

      // Both rows survive for next pass.
      final pt = await db.findLocalPlaythrough('local-pt-3');
      expect(pt?.remoteId, isNull);
      final pending = await db.listPendingChoices();
      expect(pending.length, 1);
    });

    test('401 from createPlaythrough aborts cleanly', () async {
      await db.insertLocalPlaythrough(
        LocalPlaythroughsCompanion.insert(
          localId: 'local-pt-4',
          seasonId: 'season-001',
          remoteId: const Value<String?>(null),
          startedAt: DateTime.utc(2026, 5, 21, 13),
        ),
      );

      final adapter = ProgrammableAdapter()
        ..registerJson(
          method: 'POST',
          path: RegExp(r'^/playthroughs$'),
          status: 401,
          body: <String, dynamic>{'error': 'authentication required'},
        );

      final result = await SyncService(
        api: apiClientWith(adapter),
        db: db,
      ).drain();

      expect(result.aborted, isTrue);
      expect(result.playthroughsRegistered, 0);
    });

    test('idempotent across concurrent drain() calls', () async {
      await db.insertLocalPlaythrough(
        LocalPlaythroughsCompanion.insert(
          localId: 'local-pt-5',
          seasonId: 'season-001',
          remoteId: const Value<String?>('remote-pt-5'),
          startedAt: DateTime.utc(2026, 5, 21, 15),
        ),
      );
      await db.insertPendingChoice(
        PendingChoiceEventsCompanion.insert(
          localId: 'local-c-5',
          localPlaythroughId: 'local-pt-5',
          seasonId: 'season-001',
          vignetteId: 'v-1',
          choiceId: 'c-1a',
          committedAt: DateTime.utc(2026, 5, 21, 15, 1),
          deliberationMs: const Value<int?>(null),
          createdAt: DateTime.utc(2026, 5, 21, 15, 1),
        ),
      );

      final adapter = ProgrammableAdapter()
        ..registerJson(
          method: 'POST',
          path: RegExp(r'^/playthroughs/remote-pt-5/choices$'),
          status: 200,
          body: <String, dynamic>{
            'choice_event': <String, dynamic>{
              'id': 'e-5',
              'playthrough_id': 'remote-pt-5',
              'vignette_id': 'v-1',
              'choice_id': 'c-1a',
              'server_received_at': '2026-05-21T15:01:05Z',
              'created_at': '2026-05-21T15:01:05Z',
            },
          },
        );

      final service = SyncService(api: apiClientWith(adapter), db: db);
      final futures = <Future<SyncResult>>[
        service.drain(),
        service.drain(),
        service.drain(),
      ];
      final results = await Future.wait(futures);

      // Coalesced — only one drain happened on the wire.
      expect(adapter.recorded.length, 1);
      // All three futures share the same outcome.
      expect(results.first.choicesDrained, 1);
      expect(results[1].choicesDrained, 1);
      expect(results[2].choicesDrained, 1);
    });
  });
}
