// Choice repository for the Echo client.
//
// In M1 the renderer commits choices locally first and lets the
// background sync (PR 8 / T-CLIENT-012) reconcile with the server. That
// path is what makes the vignette experience feel snappy and survive a
// flaky connection.
//
// One row per choice. Idempotency on the server side is enforced by the
// UNIQUE (playthrough_id, vignette_id) constraint in core-go; the client
// is free to write multiple local rows for the same vignette if a crash
// or restart causes it to forget that it has already drained one. The
// sync de-duplicates by inspecting server response status.

import 'package:drift/drift.dart' show Value;
import 'package:echo_client/data/local/database.dart';
import 'package:uuid/uuid.dart';

class ChoiceRepository {
  ChoiceRepository({
    required EchoDatabase db,
    Uuid uuid = const Uuid(),
    DateTime Function() now = _defaultNow,
  })  : _db = db,
        _uuid = uuid,
        _now = now;

  final EchoDatabase _db;
  final Uuid _uuid;
  final DateTime Function() _now;

  static DateTime _defaultNow() => DateTime.now();

  /// Persists a choice the player committed in the renderer. Returns the
  /// local id of the row so callers can correlate it with the sync log
  /// when the row is later drained.
  Future<String> recordChoice({
    required String localPlaythroughId,
    required String seasonId,
    required String vignetteId,
    required String choiceId,
    required Duration deliberation,
    DateTime? committedAt,
  }) async {
    final localId = _uuid.v4();
    final committed = committedAt ?? _now();
    await _db.insertPendingChoice(
      PendingChoiceEventsCompanion.insert(
        localId: localId,
        localPlaythroughId: localPlaythroughId,
        seasonId: seasonId,
        vignetteId: vignetteId,
        choiceId: choiceId,
        committedAt: committed,
        deliberationMs: Value<int?>(deliberation.inMilliseconds),
        createdAt: _now(),
      ),
    );
    return localId;
  }

  /// Returns the choices the player has committed for this playthrough,
  /// in the order they were committed. Used by the renderer to resume
  /// mid-playthrough after a restart.
  Future<List<PendingChoiceEventRow>> choicesForPlaythrough(
    String localPlaythroughId,
  ) {
    return _db.listPendingChoicesForPlaythrough(localPlaythroughId);
  }
}
