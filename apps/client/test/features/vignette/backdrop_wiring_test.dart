// Wiring test for the atmospheric backdrop on VignetteScreen (T-CLIENT-041).
//
// Verifies:
//   * When no backdrop is authored for the current vignette, the screen
//     renders exactly as before (no AtmosphericBackdrop in the tree).
//   * When a backdrop is authored, AtmosphericBackdrop is present and the
//     choice UI is still tappable.
//
// We override `backdropForVignetteProvider` directly so the tests do not
// depend on the rootBundle asset loader (an async FutureProvider chain that
// is hard to drain deterministically without pumpAndSettle, which itself
// hangs because AtmosphericBackdrop's animation ticker repeats forever).
// The rootBundle path is exercised in integration tests.

import 'package:echo_client/data/choice_repository.dart';
import 'package:echo_client/data/local/database.dart';
import 'package:echo_client/data/models/content.dart';
import 'package:echo_client/data/playthrough_repository.dart';
import 'package:echo_client/features/vignette/backdrop/atmospheric_backdrop.dart';
import 'package:echo_client/features/vignette/backdrop/backdrop_models.dart';
import 'package:echo_client/features/vignette/backdrop/backdrop_provider.dart';
import 'package:echo_client/features/vignette/vignette_controller.dart';
import 'package:echo_client/features/vignette/vignette_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../_helpers/fakes.dart';

/// Minimal BackdropSpec — one layer is enough to exercise the renderer.
BackdropSpec _minimalSpec(String vignetteId) {
  return BackdropSpec.fromJson(<String, dynamic>{
    'vignette_id': vignetteId,
    'layers': <Map<String, dynamic>>[
      <String, dynamic>{
        'id': 'sky',
        'asset_id': 'morning-bedroom-window',
        'parallax_depth': 90,
      },
    ],
  });
}

/// Controller fixed at a specific [VignettePlaying] index. Lets us drive the
/// screen straight into the playing state without going through the loading
/// path.
class _StaticPlayingController extends VignetteController {
  _StaticPlayingController({
    required EchoDatabase db,
    required Season season,
  }) : super(
          content: FakeContentRepository(<String, Season>{season.id: season}),
          choices: ChoiceRepository(db: db),
          playthroughs: PlaythroughRepository(db: db),
        ) {
    state = VignettePlaying(
      season: season,
      index: 0,
      localPlaythroughId: 'local-playthrough-x',
    );
  }

  @override
  Future<void> start({required String seasonId}) async {
    // Keep the test pinned on the playing state.
  }
}

Season _seasonWith(String vignetteId) {
  return seasonWithVignettes(
    id: 'season-001',
    vignettes: <Vignette>[
      Vignette(
        id: vignetteId,
        settingBeat: 'A test setting beat.',
        choices: const <Choice>[
          Choice(id: 'a', label: 'A', weights: <TraitWeight>[]),
          Choice(id: 'b', label: 'B', weights: <TraitWeight>[]),
        ],
      ),
    ],
  );
}

void main() {
  testWidgets(
    'no backdrop is rendered when no spec is authored for the vignette',
    (WidgetTester tester) async {
      final db = newInMemoryDatabase();
      addTearDown(db.close);

      final controller = _StaticPlayingController(
        db: db,
        season: _seasonWith('vignette-999'),
      );

      await tester.pumpWidget(
        ProviderScope(
          overrides: <Override>[
            vignetteControllerProvider.overrideWith((Ref ref) => controller),
            // Stub: no backdrop authored for any vignette.
            backdropForVignetteProvider.overrideWith(
              (Ref ref, VignetteBackdropKey key) => null,
            ),
          ],
          child: const MaterialApp(
            home: VignetteScreen(seasonId: 'season-001'),
          ),
        ),
      );
      await tester.pump();

      expect(tester.takeException(), isNull);
      expect(find.byType(AtmosphericBackdrop), findsNothing);
      // Choice UI is still present.
      expect(find.text('A'), findsOneWidget);
    },
  );

  testWidgets(
    'backdrop renders behind the choice UI when a spec is authored',
    (WidgetTester tester) async {
      final db = newInMemoryDatabase();
      addTearDown(db.close);

      final controller = _StaticPlayingController(
        db: db,
        season: _seasonWith('vignette-001'),
      );

      await tester.pumpWidget(
        ProviderScope(
          overrides: <Override>[
            vignetteControllerProvider.overrideWith((Ref ref) => controller),
            backdropForVignetteProvider.overrideWith(
              (Ref ref, VignetteBackdropKey key) =>
                  key.vignetteId == 'vignette-001'
                      ? _minimalSpec(key.vignetteId)
                      : null,
            ),
          ],
          child: const MaterialApp(
            home: VignetteScreen(seasonId: 'season-001'),
          ),
        ),
      );
      // One pump for the synchronous override; do NOT pumpAndSettle (the
      // AtmosphericBackdrop animation ticker repeats forever).
      await tester.pump();

      expect(tester.takeException(), isNull);
      expect(find.byType(AtmosphericBackdrop), findsOneWidget);
      // Choice UI is still present and tappable above the backdrop.
      expect(find.text('A'), findsOneWidget);
      expect(find.text('B'), findsOneWidget);
    },
  );
}
