// Test doubles for the M1 vignette renderer (T-CLIENT-010/011).
//
// We keep the fakes hand-rolled rather than reaching for mockito so the
// behaviour under test stays obvious in the assertions. Production code
// is small enough that the marginal benefit of a mocking framework is
// negative.

import 'dart:async';

import 'package:drift/native.dart';
import 'package:echo_client/data/choice_repository.dart';
import 'package:echo_client/data/content_repository.dart';
import 'package:echo_client/data/local/database.dart';
import 'package:echo_client/data/models/content.dart';
import 'package:echo_client/data/playthrough_repository.dart';
import 'package:echo_client/features/vignette/vignette_controller.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// In-memory Drift database — used by repository and widget tests.
EchoDatabase newInMemoryDatabase() {
  return EchoDatabase(NativeDatabase.memory());
}

/// In-memory [ContentRepository] that returns the provided [seasons] and
/// records each [getSeason] call for assertions.
class FakeContentRepository implements ContentRepository {
  FakeContentRepository(this.seasons);

  final Map<String, Season> seasons;
  final List<String> calls = <String>[];

  @override
  Future<Season?> getSeason(String id) async {
    calls.add(id);
    return seasons[id];
  }
}

/// Builds a Season with a single act and the provided vignettes. Useful
/// for keeping tests terse.
Season seasonWithVignettes({
  String id = 'season-test',
  String title = 'Test Season',
  List<Vignette>? vignettes,
}) {
  final list = vignettes ??
      <Vignette>[
        const Vignette(
          id: 'v-1',
          settingBeat: 'The first scene begins.',
          choices: <Choice>[
            Choice(
              id: 'c-1a',
              label: 'Stay quiet.',
              weights: <TraitWeight>[
                TraitWeight(dimension: 'OCEAN-O', delta: 0.1),
              ],
            ),
            Choice(
              id: 'c-1b',
              label: 'Speak up.',
              weights: <TraitWeight>[
                TraitWeight(dimension: 'OCEAN-E', delta: 0.1),
              ],
            ),
          ],
          resolutionBeats: <String, String>{
            'c-1a': 'You held your tongue.',
            'c-1b': 'Your voice cut through.',
          },
        ),
        const Vignette(
          id: 'v-2',
          settingBeat: 'The second scene unfolds.',
          choices: <Choice>[
            Choice(
              id: 'c-2a',
              label: 'Help.',
              weights: <TraitWeight>[
                TraitWeight(dimension: 'OCEAN-A', delta: 0.1),
              ],
            ),
            Choice(
              id: 'c-2b',
              label: 'Walk on.',
              weights: <TraitWeight>[
                TraitWeight(dimension: 'OCEAN-A', delta: -0.1),
              ],
            ),
          ],
        ),
      ];
  return Season(
    id: id,
    title: title,
    locale: 'en-GB',
    version: 1,
    description: 'Fixture',
    acts: <Act>[
      Act(id: 'act-1', name: 'Morning', vignettes: list),
    ],
  );
}

/// Builds a fresh ProviderScope override list backed by:
///   * an in-memory [EchoDatabase],
///   * a [FakeContentRepository] holding [seasons].
/// The disposing of the DB is owned by the caller via [onDispose] hooks.
List<Override> testOverrides({
  required Map<String, Season> seasons,
  EchoDatabase? db,
  DateTime Function()? now,
}) {
  final database = db ?? newInMemoryDatabase();
  return <Override>[
    echoDatabaseProvider.overrideWith((Ref ref) {
      ref.onDispose(database.close);
      return database;
    }),
    contentRepositoryProvider.overrideWith((Ref ref) {
      return FakeContentRepository(seasons);
    }),
    choiceRepositoryProvider.overrideWith((Ref ref) {
      return ChoiceRepository(
        db: ref.watch(echoDatabaseProvider),
        now: now ?? DateTime.now,
      );
    }),
    playthroughRepositoryProvider.overrideWith((Ref ref) {
      return PlaythroughRepository(
        db: ref.watch(echoDatabaseProvider),
        now: now ?? DateTime.now,
      );
    }),
  ];
}

/// A simple "advance by N ms each call" clock — handy for deterministic
/// deliberation_ms measurements.
class StepClock {
  StepClock(this._initial, this._step);

  DateTime _initial;
  final Duration _step;

  DateTime now() {
    final t = _initial;
    _initial = _initial.add(_step);
    return t;
  }
}

/// Awaits microtask flush — convenient when [VignetteController.start]
/// kicks off a Future and we want the resulting state transition before
/// asserting.
Future<void> flushMicrotasks() => Future<void>(() {});
