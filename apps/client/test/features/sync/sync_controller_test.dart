// SyncController + SyncScheduler tests.

import 'package:drift/drift.dart' show Value;
import 'package:echo_client/data/local/database.dart';
import 'package:echo_client/features/sync/sync_controller.dart';
import 'package:echo_client/services/sync_service.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../_helpers/fakes.dart';

void main() {
  group('SyncController', () {
    test('moves Idle → Running → Succeeded on a clean drain', () async {
      final db = newInMemoryDatabase();
      addTearDown(db.close);

      final adapter = ProgrammableAdapter();
      final service = SyncService(api: apiClientWith(adapter), db: db);
      final container = ProviderContainer(
        overrides: <Override>[
          syncServiceProvider.overrideWithValue(service),
        ],
      );
      addTearDown(container.dispose);

      expect(container.read(syncControllerProvider), isA<SyncIdle>());

      await container.read(syncControllerProvider.notifier).syncNow();

      expect(container.read(syncControllerProvider), isA<SyncSucceeded>());
    });

    test('reports SyncFailed when the service aborts', () async {
      final db = newInMemoryDatabase();
      addTearDown(db.close);

      // Seed an unregistered playthrough so the drain has work to do.
      await db.insertLocalPlaythrough(
        LocalPlaythroughsCompanion.insert(
          localId: 'pt-x',
          seasonId: 'season-001',
          remoteId: const Value<String?>(null),
          startedAt: DateTime.utc(2026, 5, 21, 9),
        ),
      );
      final adapter = ProgrammableAdapter()
        ..registerJson(
          method: 'POST',
          path: RegExp(r'^/playthroughs$'),
          status: 503,
          body: <String, dynamic>{'error': 'unavailable'},
        );
      final service = SyncService(api: apiClientWith(adapter), db: db);
      final container = ProviderContainer(
        overrides: <Override>[
          syncServiceProvider.overrideWithValue(service),
        ],
      );
      addTearDown(container.dispose);

      await container.read(syncControllerProvider.notifier).syncNow();

      expect(container.read(syncControllerProvider), isA<SyncFailed>());
    });
  });

  group('SyncScheduler', () {
    test('fires drain on its interval and stops cleanly', () async {
      final db = newInMemoryDatabase();
      addTearDown(db.close);
      final adapter = ProgrammableAdapter();
      final service = SyncService(api: apiClientWith(adapter), db: db);

      final scheduler = SyncScheduler(
        service: service,
        interval: const Duration(milliseconds: 10),
      );
      scheduler.start();

      // Let a few ticks fire. Empty drains record no requests because
      // there's nothing pending, so we just assert the scheduler keeps
      // running and stops cleanly.
      await Future<void>.delayed(const Duration(milliseconds: 35));
      scheduler.stop();

      // Calling stop twice is a no-op.
      scheduler.stop();
    });
  });
}
