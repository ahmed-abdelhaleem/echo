// VignetteController behaviour: load, advance, complete, error.

import 'package:echo_client/data/choice_repository.dart';
import 'package:echo_client/data/local/database.dart';
import 'package:echo_client/data/playthrough_repository.dart';
import 'package:echo_client/features/vignette/vignette_controller.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../_helpers/fakes.dart';

void main() {
  late EchoDatabase db;

  setUp(() {
    db = newInMemoryDatabase();
  });

  tearDown(() async {
    await db.close();
  });

  VignetteController buildController({
    required FakeContentRepository content,
    StepClock? clock,
  }) {
    final now = clock?.now ?? DateTime.now;
    return VignetteController(
      content: content,
      choices: ChoiceRepository(db: db, now: now),
      playthroughs: PlaythroughRepository(db: db, now: now),
      now: now,
    );
  }

  test('start() loads season and lands on the first vignette', () async {
    final season = seasonWithVignettes(id: 'season-001');
    final content =
        FakeContentRepository(<String, dynamic>{'season-001': season}.cast());
    final c = buildController(content: content);

    await c.start(seasonId: 'season-001');

    expect(c.state, isA<VignettePlaying>());
    final s = c.state as VignettePlaying;
    expect(s.index, 0);
    expect(s.currentVignette.id, 'v-1');
    expect(s.localPlaythroughId, isNotEmpty);
    expect(content.calls, <String>['season-001']);
  });

  test('selectChoice() persists, advances, and completes', () async {
    final season = seasonWithVignettes(id: 'season-001');
    final content =
        FakeContentRepository(<String, dynamic>{'season-001': season}.cast());
    final clock =
        StepClock(DateTime.utc(2026, 5, 21), const Duration(seconds: 1));
    final c = buildController(content: content, clock: clock);

    await c.start(seasonId: 'season-001');
    final playing = c.state as VignettePlaying;

    await c.selectChoice('c-1a');
    expect(c.state, isA<VignettePlaying>());
    final after = c.state as VignettePlaying;
    expect(after.index, 1);
    expect(after.lastResolutionBeat, 'You held your tongue.');

    await c.selectChoice('c-2b');
    expect(c.state, isA<VignetteComplete>());

    // Both choices made it to the pending queue.
    final pending = await db.listPendingChoices();
    expect(pending, hasLength(2));
    expect(pending.first.vignetteId, 'v-1');
    expect(pending.first.choiceId, 'c-1a');
    expect(pending.first.localPlaythroughId, playing.localPlaythroughId);
    expect(pending.first.deliberationMs, isNotNull);
    expect(pending.first.deliberationMs! >= 0, isTrue);
    expect(pending[1].vignetteId, 'v-2');
    expect(pending[1].choiceId, 'c-2b');
  });

  test('start() surfaces VignetteSeasonMissing on 404', () async {
    final content = FakeContentRepository(<String, dynamic>{}.cast());
    final c = buildController(content: content);

    await c.start(seasonId: 'season-404');

    expect(c.state, isA<VignetteSeasonMissing>());
    final s = c.state as VignetteSeasonMissing;
    expect(s.seasonId, 'season-404');
  });

  test('selectChoice() rejects an unknown choice id', () async {
    final season = seasonWithVignettes(id: 'season-001');
    final content =
        FakeContentRepository(<String, dynamic>{'season-001': season}.cast());
    final c = buildController(content: content);

    await c.start(seasonId: 'season-001');
    await c.selectChoice('not-authored');

    expect(c.state, isA<VignetteError>());
    final s = c.state as VignetteError;
    expect(s.message, contains('not-authored'));

    // Nothing was written to the queue.
    final pending = await db.listPendingChoices();
    expect(pending, isEmpty);
  });
}
