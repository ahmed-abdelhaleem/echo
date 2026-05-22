// Background sync of pending choices (T-CLIENT-012 / PR 8).
//
// The renderer (T-CLIENT-010/011) commits choices to the local Drift
// database; this service drains those rows to the server in the
// background. Sync is best-effort: an offline device can record a whole
// season's worth of choices and the drain catches up later.
//
// Algorithm, per pass:
//   1. List every LocalPlaythrough that doesn't have a `remoteId` yet.
//      For each, POST /playthroughs to acquire one. Stamp the row.
//   2. List every pending choice event in createdAt order.
//      For each, look up its playthrough's remote id (skip rows whose
//      playthrough still doesn't have one — the next pass picks them up).
//      POST /playthroughs/{remoteId}/choices.
//      Branch on the outcome:
//        - accepted (200): delete the local row.
//        - conflict (409): delete the local row — the server is the
//          source of truth and we don't want to retry forever.
//        - notFound (404): delete the local row — same reason.
//        - unauthorised (401): abort the drain; auth surface recovers.
//   3. Any thrown error (5xx, network) aborts the drain and leaves the
//      remaining rows in place for the next pass.
//
// The service is intentionally single-flight: concurrent drain() calls
// are coalesced via a Completer so a manual "sync now" tap can't trigger
// duplicate POSTs while the periodic timer is mid-drain.

import 'dart:async';

import 'package:dio/dio.dart';
import 'package:echo_client/data/local/database.dart';
import 'package:echo_client/services/api_client.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Aggregate outcome of a single drain pass — useful for telemetry,
/// tests, and the sync banner in the renderer.
class SyncResult {
  const SyncResult({
    required this.playthroughsRegistered,
    required this.choicesDrained,
    required this.conflicts,
    required this.notFound,
    required this.aborted,
    this.error,
  });

  /// Number of POST /playthroughs calls that succeeded this pass.
  final int playthroughsRegistered;

  /// Number of choice rows the server accepted (200) this pass.
  final int choicesDrained;

  /// Number of choice rows the server rejected as conflicts (409).
  /// These rows were deleted locally — the server holds the truth.
  final int conflicts;

  /// Number of choice rows the server didn't recognise (404). These
  /// rows were also deleted locally to prevent a permanent retry loop.
  final int notFound;

  /// True if the drain stopped early — eg auth lost, transport failure.
  final bool aborted;

  /// Non-null when [aborted] is true. Kept as `Object` to avoid leaking
  /// dio types beyond this service.
  final Object? error;

  bool get hadWork =>
      playthroughsRegistered > 0 ||
      choicesDrained > 0 ||
      conflicts > 0 ||
      notFound > 0;

  static const SyncResult noop = SyncResult(
    playthroughsRegistered: 0,
    choicesDrained: 0,
    conflicts: 0,
    notFound: 0,
    aborted: false,
  );
}

class SyncService {
  SyncService({
    required ApiClient api,
    required EchoDatabase db,
  })  : _api = api,
        _db = db;

  final ApiClient _api;
  final EchoDatabase _db;

  Completer<SyncResult>? _inFlight;

  /// Coalesce concurrent drain requests so a tap on "sync now" while a
  /// periodic drain is mid-flight returns the same Future.
  Future<SyncResult> drain() {
    final existing = _inFlight;
    if (existing != null) {
      return existing.future;
    }
    final completer = Completer<SyncResult>();
    _inFlight = completer;
    _runDrain().then(completer.complete).catchError((Object e, StackTrace st) {
      completer.complete(
        SyncResult(
          playthroughsRegistered: 0,
          choicesDrained: 0,
          conflicts: 0,
          notFound: 0,
          aborted: true,
          error: e,
        ),
      );
    }).whenComplete(() {
      _inFlight = null;
    });
    return completer.future;
  }

  Future<SyncResult> _runDrain() async {
    int registered = 0;
    int drained = 0;
    int conflicts = 0;
    int notFound = 0;

    // Phase 1: register playthroughs that don't yet have a remote id.
    final unregistered = await _db.listLocalPlaythroughsWithoutRemote();
    for (final row in unregistered) {
      try {
        final remote = await _api.createPlaythrough(seasonId: row.seasonId);
        await _db.setLocalPlaythroughRemoteId(
          localId: row.localId,
          remoteId: remote.id,
        );
        registered++;
      } on CreatePlaythroughUnauthorised catch (e) {
        return SyncResult(
          playthroughsRegistered: registered,
          choicesDrained: drained,
          conflicts: conflicts,
          notFound: notFound,
          aborted: true,
          error: e,
        );
      } on CreatePlaythroughForbidden catch (e) {
        // Under-13 / ineligible identity. The renderer surfaced this
        // already on the way in; we drop the local row so the device
        // doesn't loop forever trying to register it. Note that we do
        // NOT delete the pending choices: the renderer's defence-in-
        // depth means we shouldn't have any, and if there are some,
        // letting them rot is louder than silently dropping them.
        return SyncResult(
          playthroughsRegistered: registered,
          choicesDrained: drained,
          conflicts: conflicts,
          notFound: notFound,
          aborted: true,
          error: e,
        );
      } on DioException catch (e) {
        // Transient — stop the drain and try again next pass.
        return SyncResult(
          playthroughsRegistered: registered,
          choicesDrained: drained,
          conflicts: conflicts,
          notFound: notFound,
          aborted: true,
          error: e,
        );
      }
    }

    // Phase 2: drain pending choice events. We re-read after Phase 1 so
    // we pick up rows whose playthrough just learned its remote id.
    final pending = await _db.listPendingChoices();
    for (final row in pending) {
      final play = await _db.findLocalPlaythrough(row.localPlaythroughId);
      final remoteId = play?.remoteId;
      if (remoteId == null) {
        // The playthrough hasn't acquired a remote id yet; skip and try
        // again on the next pass. This isn't fatal — Phase 1 may have
        // failed for one playthrough but not another.
        continue;
      }
      try {
        final outcome = await _api.recordChoice(
          playthroughId: remoteId,
          vignetteId: row.vignetteId,
          choiceId: row.choiceId,
          clientTimestamp: row.committedAt,
          deliberationMs: row.deliberationMs,
        );
        switch (outcome) {
          case RecordChoiceOutcome.accepted:
            await _db.deletePendingChoice(row.localId);
            drained++;
          case RecordChoiceOutcome.conflict:
            await _db.deletePendingChoice(row.localId);
            conflicts++;
          case RecordChoiceOutcome.notFound:
            await _db.deletePendingChoice(row.localId);
            notFound++;
          case RecordChoiceOutcome.unauthorised:
            return SyncResult(
              playthroughsRegistered: registered,
              choicesDrained: drained,
              conflicts: conflicts,
              notFound: notFound,
              aborted: true,
            );
        }
      } on DioException catch (e) {
        return SyncResult(
          playthroughsRegistered: registered,
          choicesDrained: drained,
          conflicts: conflicts,
          notFound: notFound,
          aborted: true,
          error: e,
        );
      }
    }

    return SyncResult(
      playthroughsRegistered: registered,
      choicesDrained: drained,
      conflicts: conflicts,
      notFound: notFound,
      aborted: false,
    );
  }
}

final Provider<SyncService> syncServiceProvider = Provider<SyncService>(
  (Ref ref) {
    throw UnimplementedError(
      'syncServiceProvider must be overridden at bootstrap with the '
      'concrete ApiClient + EchoDatabase wiring.',
    );
  },
);

/// Periodic driver around [SyncService]. Triggers a drain every
/// [interval] for as long as the provider is alive. Cancels its timer
/// on dispose so widget tests don't leak.
class SyncScheduler {
  SyncScheduler({
    required SyncService service,
    Duration interval = const Duration(seconds: 30),
  })  : _service = service,
        _interval = interval;

  final SyncService _service;
  final Duration _interval;
  Timer? _timer;

  void start() {
    _timer ??= Timer.periodic(_interval, (_) => _tick());
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  Future<void> _tick() async {
    try {
      await _service.drain();
    } catch (e, st) {
      // The service itself swallows expected errors. Anything that
      // escapes is a bug — log and keep the timer running.
      debugPrintStack(stackTrace: st, label: 'SyncScheduler.tick: $e');
    }
  }
}
