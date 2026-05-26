// Local persistence for the Echo client.
//
// Two tables in M1:
//   - cached_seasons: the JSON envelope returned by GET /content/seasons/{id}.
//     The renderer reads from this table first and falls back to the network;
//     this is what makes the renderer keep working without connectivity.
//   - pending_choice_events: choices the player has tapped but the background
//     sync (PR 8 / T-CLIENT-012) has not yet POSTed to the server.
//
// The schema is deliberately minimal. M2 will gain a Portrait/reflection
// cache, but those land behind their own schema_version bump.

import 'package:drift/drift.dart';
import 'package:drift_flutter/drift_flutter.dart';

part 'database.g.dart';

/// Cached Season JSON. Keyed by the Season id (which is also the URL path
/// param). [body] is the raw JSON envelope `{"season": {...}}` so we don't
/// have to re-encode on read; [version] is denormalised so the client can
/// detect a server-side bump and invalidate without parsing.
@DataClassName('CachedSeasonRow')
class CachedSeasons extends Table {
  TextColumn get id => text()();
  IntColumn get version => integer()();
  TextColumn get body => text()();
  DateTimeColumn get fetchedAt => dateTime()();

  @override
  Set<Column<Object>> get primaryKey => <Column<Object>>{id};
}

/// One row per choice the player has committed locally. The background
/// sync drains pending rows in `createdAt` order and deletes them on a
/// successful 200/409 from the server.
///
/// We keep `localId` as the primary key (a client-generated UUID) so the
/// row survives renaming the underlying playthrough id when the sync first
/// learns the server-assigned id. We do NOT enforce uniqueness on
/// (localPlaythroughId, vignetteId) here — the server is the source of
/// truth for that invariant, and the client is allowed to record local
/// retries (eg if the renderer was force-killed mid-write).
@DataClassName('PendingChoiceEventRow')
class PendingChoiceEvents extends Table {
  TextColumn get localId => text()();
  TextColumn get localPlaythroughId => text()();
  TextColumn get seasonId => text()();
  TextColumn get vignetteId => text()();
  TextColumn get choiceId => text()();

  /// Time the player committed the choice, on the device. Used by the
  /// sync to send `client_timestamp` to the server.
  DateTimeColumn get committedAt => dateTime()();

  /// Milliseconds between vignette presentation and the player's tap.
  /// Null if the renderer wasn't able to measure (eg restored from a
  /// crash).
  IntColumn get deliberationMs => integer().nullable()();

  DateTimeColumn get createdAt => dateTime()();

  @override
  Set<Column<Object>> get primaryKey => <Column<Object>>{localId};
}

/// Header row for a playthrough the client has started locally. The
/// `remoteId` column is null until the sync (PR 8) has POSTed the
/// playthrough header to /playthroughs and learned the server-assigned
/// UUID; subsequent sync passes use it to address /playthroughs/{id}/choices.
@DataClassName('LocalPlaythroughRow')
class LocalPlaythroughs extends Table {
  TextColumn get localId => text()();
  TextColumn get seasonId => text()();
  TextColumn get remoteId => text().nullable()();
  DateTimeColumn get startedAt => dateTime()();

  @override
  Set<Column<Object>> get primaryKey => <Column<Object>>{localId};
}

@DriftDatabase(
  tables: <Type>[
    CachedSeasons,
    PendingChoiceEvents,
    LocalPlaythroughs,
  ],
)
class EchoDatabase extends _$EchoDatabase {
  EchoDatabase([QueryExecutor? executor])
      : super(executor ?? _openDefault());

  /// Default executor used by the production app. On native targets
  /// (iOS / Android / macOS / Linux / Windows) `drift_flutter` picks a
  /// sensible NativeDatabase backed by `path_provider`. On the web,
  /// `drift_flutter >= 0.2.5` requires an explicit `DriftWebOptions`
  /// pointing at the sqlite3 wasm bundle + dedicated drift worker that
  /// `dart run drift_dev setup_web` drops into `web/`. Without these
  /// the helper throws `ArgumentError: When compiling to the web, the
  /// `web` parameter needs to be set.` at the first DB access.
  ///
  /// We keep the asset names matching the defaults written by
  /// `drift_dev setup_web` (sqlite3.wasm + drift_worker.js) so the
  /// command is the only step a contributor needs to run for the web
  /// build to come up.
  static QueryExecutor _openDefault() {
    return driftDatabase(
      name: 'echo_local',
      web: DriftWebOptions(
        sqlite3Wasm: Uri.parse('sqlite3.wasm'),
        driftWorker: Uri.parse('drift_worker.js'),
      ),
    );
  }

  @override
  int get schemaVersion => 1;

  // --- Cached seasons --------------------------------------------------

  Future<CachedSeasonRow?> findCachedSeason(String id) {
    return (select(cachedSeasons)..where((t) => t.id.equals(id)))
        .getSingleOrNull();
  }

  Future<int> upsertCachedSeason(CachedSeasonsCompanion row) {
    return into(cachedSeasons).insertOnConflictUpdate(row);
  }

  // --- Local playthroughs ---------------------------------------------

  Future<LocalPlaythroughRow?> findLocalPlaythrough(String localId) {
    return (select(localPlaythroughs)..where((t) => t.localId.equals(localId)))
        .getSingleOrNull();
  }

  Future<int> insertLocalPlaythrough(LocalPlaythroughsCompanion row) {
    return into(localPlaythroughs).insert(row);
  }

  /// Returns every local playthrough that hasn't yet learned its
  /// server-assigned id. The background sync (PR 8 / T-CLIENT-012) uses
  /// this to know which rows to register with the server first.
  Future<List<LocalPlaythroughRow>> listLocalPlaythroughsWithoutRemote() {
    return (select(localPlaythroughs)
          ..where((t) => t.remoteId.isNull())
          ..orderBy(<OrderClauseGenerator<LocalPlaythroughs>>[
            (t) => OrderingTerm.asc(t.startedAt),
          ]))
        .get();
  }

  /// Stamps a local playthrough with the server-assigned UUID returned
  /// from POST /playthroughs.
  Future<int> setLocalPlaythroughRemoteId({
    required String localId,
    required String remoteId,
  }) {
    return (update(localPlaythroughs)..where((t) => t.localId.equals(localId)))
        .write(LocalPlaythroughsCompanion(remoteId: Value<String?>(remoteId)));
  }

  // --- Pending choice events ------------------------------------------

  Future<int> insertPendingChoice(PendingChoiceEventsCompanion row) {
    return into(pendingChoiceEvents).insert(row);
  }

  Future<List<PendingChoiceEventRow>> listPendingChoices() {
    return (select(pendingChoiceEvents)
          ..orderBy(<OrderClauseGenerator<PendingChoiceEvents>>[
            (t) => OrderingTerm.asc(t.createdAt),
          ]))
        .get();
  }

  Future<List<PendingChoiceEventRow>> listPendingChoicesForPlaythrough(
    String localPlaythroughId,
  ) {
    return (select(pendingChoiceEvents)
          ..where((t) => t.localPlaythroughId.equals(localPlaythroughId))
          ..orderBy(<OrderClauseGenerator<PendingChoiceEvents>>[
            (t) => OrderingTerm.asc(t.createdAt),
          ]))
        .get();
  }

  /// Deletes a single pending row by its client-generated id. The sync
  /// loop calls this once the server has acknowledged the choice (either
  /// as a fresh write or as an idempotent re-write).
  Future<int> deletePendingChoice(String localId) {
    return (delete(pendingChoiceEvents)
          ..where((t) => t.localId.equals(localId)))
        .go();
  }
}
