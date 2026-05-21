// ChoiceRepository: persistence and retrieval of pending choice events.

import 'package:echo_client/data/choice_repository.dart';
import 'package:echo_client/data/local/database.dart';
import 'package:echo_client/data/playthrough_repository.dart';
import 'package:flutter_test/flutter_test.dart';

import '../_helpers/fakes.dart';

void main() {
  late EchoDatabase db;

  setUp(() {
    db = newInMemoryDatabase();
  });

  tearDown(() async {
    await db.close();
  });

  test('recordChoice writes a pending row preserving deliberation', () async {
    final playthroughs = PlaythroughRepository(db: db);
    final choices = ChoiceRepository(db: db);
    final localId =
        await playthroughs.startLocalPlaythrough(seasonId: 'season-001');

    final id = await choices.recordChoice(
      localPlaythroughId: localId,
      seasonId: 'season-001',
      vignetteId: 'v-1',
      choiceId: 'c-1',
      deliberation: const Duration(milliseconds: 1234),
    );

    expect(id, isNotEmpty);
    final rows = await choices.choicesForPlaythrough(localId);
    expect(rows, hasLength(1));
    expect(rows.single.localId, id);
    expect(rows.single.vignetteId, 'v-1');
    expect(rows.single.choiceId, 'c-1');
    expect(rows.single.deliberationMs, 1234);
  });

  test('choicesForPlaythrough returns rows in commit order', () async {
    final playthroughs = PlaythroughRepository(db: db);
    final choices = ChoiceRepository(db: db);
    final localId =
        await playthroughs.startLocalPlaythrough(seasonId: 'season-001');

    await choices.recordChoice(
      localPlaythroughId: localId,
      seasonId: 'season-001',
      vignetteId: 'v-1',
      choiceId: 'c-1',
      deliberation: const Duration(milliseconds: 100),
      committedAt: DateTime.utc(2026, 5, 21, 9, 0),
    );
    await choices.recordChoice(
      localPlaythroughId: localId,
      seasonId: 'season-001',
      vignetteId: 'v-2',
      choiceId: 'c-2',
      deliberation: const Duration(milliseconds: 200),
      committedAt: DateTime.utc(2026, 5, 21, 9, 1),
    );

    final rows = await choices.choicesForPlaythrough(localId);
    expect(
      rows.map((r) => r.vignetteId).toList(),
      <String>['v-1', 'v-2'],
    );
  });
}
