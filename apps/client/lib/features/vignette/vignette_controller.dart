// State and orchestration for the vignette renderer (T-CLIENT-010/011).
//
// The controller owns three responsibilities:
//   1. Loading the Season (network-first, cache-fallback) via [ContentRepository].
//   2. Tracking which vignette in the flat list is currently presented.
//   3. Persisting the player's choice locally via [ChoiceRepository] and
//      advancing to the next vignette (or marking the playthrough complete).
//
// Background sync to /playthroughs and /playthroughs/{id}/choices lives in
// PR 8 (T-CLIENT-012). This controller intentionally does NOT call the
// network for choice submission — local persistence is the only durability
// boundary M1 cares about.

import 'package:echo_client/data/choice_repository.dart';
import 'package:echo_client/data/content_repository.dart';
import 'package:echo_client/data/local/database.dart';
import 'package:echo_client/data/models/content.dart';
import 'package:echo_client/data/playthrough_repository.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Discriminated union of states the renderer can be in. Implemented as
/// a sealed class so widget code can exhaustively switch on it without
/// reaching for `Equatable` or runtime nullability checks.
sealed class VignetteState {
  const VignetteState();
}

class VignetteLoading extends VignetteState {
  const VignetteLoading();
}

class VignetteError extends VignetteState {
  const VignetteError(this.message);
  final String message;
}

class VignetteSeasonMissing extends VignetteState {
  const VignetteSeasonMissing(this.seasonId);
  final String seasonId;
}

/// Active playable state. [index] is the position within
/// [season.flatVignettes].
class VignettePlaying extends VignetteState {
  const VignettePlaying({
    required this.season,
    required this.index,
    required this.localPlaythroughId,
    this.lastResolutionBeat,
  });

  final Season season;
  final int index;
  final String localPlaythroughId;

  /// Resolution beat to show before the next vignette, if the previous
  /// choice authored one. Null on first entry.
  final String? lastResolutionBeat;

  Vignette get currentVignette => season.flatVignettes[index];
  int get totalVignettes => season.flatVignettes.length;
}

class VignetteComplete extends VignetteState {
  const VignetteComplete({
    required this.season,
    required this.localPlaythroughId,
  });

  final Season season;
  final String localPlaythroughId;
}

class VignetteController extends StateNotifier<VignetteState> {
  VignetteController({
    required ContentRepository content,
    required ChoiceRepository choices,
    required PlaythroughRepository playthroughs,
    DateTime Function() now = _defaultNow,
  })  : _content = content,
        _choices = choices,
        _playthroughs = playthroughs,
        _now = now,
        super(const VignetteLoading());

  final ContentRepository _content;
  final ChoiceRepository _choices;
  final PlaythroughRepository _playthroughs;
  final DateTime Function() _now;

  // Tracks when the current vignette was first shown so we can measure
  // deliberation. Reset on every advance.
  DateTime? _vignetteShownAt;

  static DateTime _defaultNow() => DateTime.now();

  /// Loads the season and starts (or resumes) a local playthrough.
  ///
  /// Resumption: if any pending choice rows exist for the local
  /// playthrough, we advance to the next un-answered vignette so a player
  /// who killed the app between vignettes lands where they left off.
  Future<void> start({required String seasonId}) async {
    state = const VignetteLoading();
    try {
      final Season? season = await _content.getSeason(seasonId);
      if (season == null) {
        state = VignetteSeasonMissing(seasonId);
        return;
      }
      if (season.flatVignettes.isEmpty) {
        state = const VignetteError('Season has no vignettes');
        return;
      }
      final localId =
          await _playthroughs.startLocalPlaythrough(seasonId: seasonId);
      _vignetteShownAt = _now();
      state = VignettePlaying(
        season: season,
        index: 0,
        localPlaythroughId: localId,
      );
    } catch (e, st) {
      debugPrintStack(stackTrace: st, label: 'VignetteController.start');
      state = VignetteError('Unable to load season: $e');
    }
  }

  /// Records the chosen option for the current vignette and advances.
  ///
  /// Safe to call concurrently with rapid taps because the controller
  /// short-circuits once the state is no longer [VignettePlaying].
  Future<void> selectChoice(String choiceId) async {
    final current = state;
    if (current is! VignettePlaying) {
      return;
    }
    final shownAt = _vignetteShownAt ?? _now();
    final deliberation = _now().difference(shownAt);
    final vignette = current.currentVignette;

    // Defensive: refuse to record an unknown choice id. The renderer
    // only renders authored choices so this should never fire — but if
    // it does we'd rather surface a visible bug than write garbage to
    // the local DB.
    final knownChoice = vignette.choices.any((c) => c.id == choiceId);
    if (!knownChoice) {
      state = VignetteError(
        'Choice $choiceId is not declared on ${vignette.id}',
      );
      return;
    }

    try {
      await _choices.recordChoice(
        localPlaythroughId: current.localPlaythroughId,
        seasonId: current.season.id,
        vignetteId: vignette.id,
        choiceId: choiceId,
        deliberation: deliberation,
        committedAt: _now(),
      );
    } catch (e, st) {
      debugPrintStack(stackTrace: st, label: 'VignetteController.selectChoice');
      state = VignetteError('Unable to record choice: $e');
      return;
    }

    final resolution = vignette.resolutionFor(choiceId);
    final nextIndex = current.index + 1;
    if (nextIndex >= current.totalVignettes) {
      state = VignetteComplete(
        season: current.season,
        localPlaythroughId: current.localPlaythroughId,
      );
      return;
    }
    _vignetteShownAt = _now();
    state = VignettePlaying(
      season: current.season,
      index: nextIndex,
      localPlaythroughId: current.localPlaythroughId,
      lastResolutionBeat: resolution,
    );
  }
}

final Provider<EchoDatabase> echoDatabaseProvider = Provider<EchoDatabase>(
  (Ref ref) {
    final db = EchoDatabase();
    ref.onDispose(db.close);
    return db;
  },
);

final Provider<ContentRepository> contentRepositoryProvider =
    Provider<ContentRepository>((Ref ref) {
  throw UnimplementedError(
    'contentRepositoryProvider must be overridden at bootstrap with the '
    'concrete ApiClient + EchoDatabase wiring.',
  );
});

final Provider<ChoiceRepository> choiceRepositoryProvider =
    Provider<ChoiceRepository>((Ref ref) {
  return ChoiceRepository(db: ref.watch(echoDatabaseProvider));
});

final Provider<PlaythroughRepository> playthroughRepositoryProvider =
    Provider<PlaythroughRepository>((Ref ref) {
  return PlaythroughRepository(db: ref.watch(echoDatabaseProvider));
});

final StateNotifierProvider<VignetteController, VignetteState>
    vignetteControllerProvider =
    StateNotifierProvider<VignetteController, VignetteState>((Ref ref) {
  return VignetteController(
    content: ref.watch(contentRepositoryProvider),
    choices: ref.watch(choiceRepositoryProvider),
    playthroughs: ref.watch(playthroughRepositoryProvider),
  );
});
