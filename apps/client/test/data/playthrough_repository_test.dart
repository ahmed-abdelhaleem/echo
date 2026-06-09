import 'package:echo_client/data/playthrough_repository.dart';
import 'package:flutter_test/flutter_test.dart';

import '../_helpers/fakes.dart';

void main() {
  test(
      'listSyncedPlaythroughs returns only rows with remote ids ordered by latest start',
      () async {
    final db = newInMemoryDatabase();
    addTearDown(db.close);

    final clock = StepClock(
      DateTime.utc(2026, 1, 1, 10, 0, 0),
      const Duration(minutes: 1),
    );
    final repo = PlaythroughRepository(db: db, now: clock.now);

    final localA = await repo.startLocalPlaythrough(seasonId: 'season-001');
    final localB = await repo.startLocalPlaythrough(seasonId: 'season-001');
    final localC = await repo.startLocalPlaythrough(seasonId: 'season-002');

    await db.setLocalPlaythroughRemoteId(
      localId: localA,
      remoteId: '11111111-1111-4111-8111-111111111111',
    );
    await db.setLocalPlaythroughRemoteId(
      localId: localC,
      remoteId: '33333333-3333-4333-8333-333333333333',
    );

    final synced = await repo.listSyncedPlaythroughs();

    expect(synced.map((r) => r.localId).toList(), <String>[localC, localA]);
    expect(synced.map((r) => r.remoteId).toList(), <String?>[
      '33333333-3333-4333-8333-333333333333',
      '11111111-1111-4111-8111-111111111111',
    ]);
    expect(synced.any((r) => r.localId == localB), isFalse);
  });
}
