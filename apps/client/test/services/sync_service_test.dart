// SyncService drain semantics.
//
// We exercise the worker against an in-memory Drift DB and a hand-rolled
// fake ApiClient. The fakes deliberately mimic the same exception
// taxonomy production uses (SyncTransient / SyncUnauthorized / SyncFatal)
// so the test boundary matches the behaviour boundary.

import 'package:echo_client/data/choice_repository.dart';
import 'package:echo_client/data/local/database.dart';
import 'package:echo_client/data/playthrough_repository.dart';
import 'package:echo_client/services/api_client.dart';
import 'package:echo_client/services/sync_service.dart';
import 'package:flutter_test/flutter_test.dart';

import '../_helpers/fakes.dart';

class _FakeSyncApi implements SyncApi {
  _FakeSyncApi();

  // Behaviour knobs.
  String createPlaythroughId = 'remote-001';
  Object? createPlaythroughError;
  final List<Object?> recordChoiceErrors = <Object?>[];
  ChoiceSyncOutcome recordChoiceOutcome = ChoiceSyncOutcome.accepted;

  // Call log for assertions.
  final List<String> createPlaythroughCalls = <String>[];
  final List<_RecordedChoice> recordChoiceCalls = <_RecordedChoice>[];

  @override
  Future<PlaythroughEnvelope> createPlaythrough({
    required String seasonId,
  }) async {
    createPlaythroughCalls.add(seasonId);
    final err = createPlaythroughError;
    if (err != null) {
      throw err;
    }
    return PlaythroughEnvelope(
      id: createPlaythroughId,
      seasonId: seasonId,
      seasonVersion: 1,
      status: 'in_progress',
    );
  }

  @override
  Future<ChoiceSyncOutcome> recordChoice({
    required String playthroughId,
    required String vignetteId,
    required String choiceId,
    int? deliberationMs,
    DateTime? clientTimestamp,
  }) async {
    recordChoiceCalls.add(
      _RecordedChoice(playthroughId, vignetteId, choiceId, deliberationMs),
    );
    if (recordChoiceErrors.isNotEmpty) {
      final next = recordChoiceErrors.removeAt(0);
      if (next != null) {
        throw next;
      }
    }
    return recordChoiceOutcome;
  }
}

class _RecordedChoice {
  const _RecordedChoice(
    this.playthroughId,
    this.vignetteId,
    this.choiceId,
    this.deliberationMs,
  );
  final String playthroughId;
  final String vignetteId;
  final String choiceId;
  final int? deliberationMs;
}

void main() {
  late EchoDatabase db;
  late _FakeSyncApi api;
  late PlaythroughRepository playthroughs;
  late ChoiceRepository choices;

  setUp(() {
    db = newInMemoryDatabase();
    api = _FakeSyncApi();
    playthroughs = PlaythroughRepository(db: db);
    choices = ChoiceRepository(db: db);
  });

  tearDown(() async {
    await db.close();
  });

  Future<String> seedPlaythroughWithChoices(int n) async {
    final localId =
        await playthroughs.startLocalPlaythrough(seasonId: 'season-001');
    for (var i = 0; i < n; i++) {
      await choices.recordChoice(
        localPlaythroughId: localId,
        seasonId: 'season-001',
        vignetteId: 'v-${i + 1}',
        choiceId: 'c-${i + 1}',
        deliberation: Duration(milliseconds: 100 * (i + 1)),
        committedAt: DateTime.utc(2026, 5, 21, 9, i),
      );
    }
    return localId;
  }

  test('happy path: drains every pending row and stores remote_id', () async {
    final localId = await seedPlaythroughWithChoices(2);
    final svc = SyncService(db: db, api: api);

    final report = await svc.flushOnce();

    expect(report.uploaded, 2);
    expect(report.conflicted, 0);
    expect(report.deferred, 0);
    expect(report.dropped, 0);
    expect(report.unauthorized, isFalse);

    final remaining = await db.listPendingChoices();
    expect(remaining, isEmpty);

    final header = await playthroughs.findById(localId);
    expect(header?.remoteId, 'remote-001');

    expect(api.createPlaythroughCalls, <String>['season-001']);
    expect(api.recordChoiceCalls, hasLength(2));
    expect(api.recordChoiceCalls.first.vignetteId, 'v-1');
    expect(api.recordChoiceCalls.first.deliberationMs, 100);
  });

  test('409 conflict drops the row but reports it', () async {
    await seedPlaythroughWithChoices(1);
    api.recordChoiceOutcome = ChoiceSyncOutcome.conflict;
    final svc = SyncService(db: db, api: api);

    final report = await svc.flushOnce();

    expect(report.uploaded, 0);
    expect(report.conflicted, 1);
    expect(report.deferred, 0);
    final remaining = await db.listPendingChoices();
    expect(remaining, isEmpty);
  });

  test('transient failure mid-drain leaves remaining rows untouched', () async {
    await seedPlaythroughWithChoices(3);
    // First call succeeds, second errors transient.
    api.recordChoiceErrors.add(null);
    api.recordChoiceErrors.add(const SyncTransient('offline'));
    final svc = SyncService(db: db, api: api);

    final report = await svc.flushOnce();

    expect(report.uploaded, 1);
    expect(report.deferred, 2); // 2 rows left in the queue
    expect(report.unauthorized, isFalse);

    final remaining = await db.listPendingChoices();
    expect(remaining, hasLength(2));
    expect(
      remaining.map((r) => r.vignetteId),
      containsAll(<String>['v-2', 'v-3']),
    );
  });

  test('401 surfaces unauthorized and defers rather than dropping', () async {
    await seedPlaythroughWithChoices(2);
    api.recordChoiceErrors.add(const SyncUnauthorized('no session'));
    api.recordChoiceErrors.add(const SyncUnauthorized('no session'));
    final svc = SyncService(db: db, api: api);

    final report = await svc.flushOnce();

    expect(report.uploaded, 0);
    expect(report.unauthorized, isTrue);
    expect(report.deferred, 2);
    expect(await db.listPendingChoices(), hasLength(2));
  });

  test('fatal createPlaythrough drops the whole local playthrough', () async {
    await seedPlaythroughWithChoices(2);
    api.createPlaythroughError = const SyncFatal('season missing on server');
    final svc = SyncService(db: db, api: api);

    final report = await svc.flushOnce();

    expect(report.uploaded, 0);
    expect(report.dropped, 2);
    expect(await db.listPendingChoices(), isEmpty);
    expect(api.recordChoiceCalls, isEmpty);
  });

  test('transient createPlaythrough defers without consuming rows', () async {
    await seedPlaythroughWithChoices(2);
    api.createPlaythroughError = const SyncTransient('connection refused');
    final svc = SyncService(db: db, api: api);

    final report = await svc.flushOnce();

    expect(report.uploaded, 0);
    expect(report.deferred, 2);
    expect(report.unauthorized, isFalse);
    expect(await db.listPendingChoices(), hasLength(2));
    expect(api.recordChoiceCalls, isEmpty);
  });

  test('empty queue is a no-op', () async {
    final svc = SyncService(db: db, api: api);
    final report = await svc.flushOnce();
    expect(report.hasWork, isFalse);
    expect(api.createPlaythroughCalls, isEmpty);
  });

  test('reuses an existing remote_id without re-creating', () async {
    final localId = await seedPlaythroughWithChoices(1);
    await db.setLocalPlaythroughRemoteId(
      localId: localId,
      remoteId: 'remote-preset',
    );
    final svc = SyncService(db: db, api: api);

    final report = await svc.flushOnce();

    expect(report.uploaded, 1);
    expect(api.createPlaythroughCalls, isEmpty);
    expect(api.recordChoiceCalls.single.playthroughId, 'remote-preset');
  });
}
