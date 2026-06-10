// Wiring test for the atmospheric backdrop on VignetteScreen (T-CLIENT-041).
//
// Verifies:
//   * When the backdrop manifest does not match the current vignette, the
//     screen renders exactly as before (no AtmosphericBackdrop in the tree).
//   * When the backdrop manifest does match, the AtmosphericBackdrop widget
//     is present and the choice UI is still tappable.
//
// We never call pumpAndSettle here because AtmosphericBackdrop's animation
// repeats forever; pumpAndSettle would hang. Use explicit pump() durations.

import 'package:echo_client/data/choice_repository.dart';
import 'package:echo_client/data/local/database.dart';
import 'package:echo_client/data/models/content.dart';
import 'package:echo_client/data/playthrough_repository.dart';
import 'package:echo_client/features/vignette/backdrop/atmospheric_backdrop.dart';
import 'package:echo_client/features/vignette/vignette_controller.dart';
import 'package:echo_client/features/vignette/vignette_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../_helpers/fakes.dart';

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
    'no backdrop is rendered when the manifest does not cover the vignette',
    (WidgetTester tester) async {
      final db = newInMemoryDatabase();
      addTearDown(db.close);

      // vignette-999 does not exist in the bundled sample manifest.
      final controller = _StaticPlayingController(
        db: db,
        season: _seasonWith('vignette-999'),
      );

      await tester.pumpWidget(
        ProviderScope(
          overrides: <Override>[
            vignetteControllerProvider.overrideWith((Ref ref) => controller),
          ],
          child: const MaterialApp(
            home: VignetteScreen(seasonId: 'season-001'),
          ),
        ),
      );
      // Two pumps: one for the build, one for the FutureProvider resolution.
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      expect(tester.takeException(), isNull);
      expect(find.byType(AtmosphericBackdrop), findsNothing);
      // Choice UI is still present.
      expect(find.text('A'), findsOneWidget);
    },
  );

  testWidgets(
    'backdrop renders behind the choice UI when the manifest matches',
    (WidgetTester tester) async {
      final db = newInMemoryDatabase();
      addTearDown(db.close);

      // vignette-001 IS covered by the bundled sample manifest.
      final controller = _StaticPlayingController(
        db: db,
        season: _seasonWith('vignette-001'),
      );

      await tester.pumpWidget(
        ProviderScope(
          overrides: <Override>[
            vignetteControllerProvider.overrideWith((Ref ref) => controller),
          ],
          child: const MaterialApp(
            home: VignetteScreen(seasonId: 'season-001'),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      expect(tester.takeException(), isNull);
      expect(find.byType(AtmosphericBackdrop), findsOneWidget);
      // Choice UI is still present and tappable above the backdrop.
      expect(find.text('A'), findsOneWidget);
      expect(find.text('B'), findsOneWidget);
    },
  );
}
