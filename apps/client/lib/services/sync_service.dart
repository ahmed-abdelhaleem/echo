// Background sync (T-CLIENT-012).
//
// The renderer commits choices into Drift's pending_choice_events queue.
// This service drains that queue against the core-go endpoints introduced
// in T-CORE-010 (PR 6):
//
//   POST /playthroughs                  -> resolves a remote_id for the
//                                          local playthrough header.
//   POST /playthroughs/{id}/choices     -> idempotent choice upload.
//
// Sync semantics:
//   * One drain pass per tick. Multiple ticks per session are fine —
//     [flushOnce] is reentrant-safe via a single in-flight flag.
//   * Per playthrough: ensure remote_id, then POST choices in commit
//     order. The server enforces idempotency on
//     (playthrough_id, vignette_id), so a retried row gets 200 if the
//     choice matches and 409 if a different choice was already recorded
//     for that vignette. In either case we delete the local row — the
//     server is authoritative.
//   * Transient failures (network / 5xx) abort the drain so we don't
//     burn the queue against a half-broken backend. The next tick tries
//     again with exponential backoff.
//   * 401/403 also aborts — the sync waits until auth is in place
//     (T-CLIENT-020 lands the actual login flow; until then this branch
//     is exercised by tests and surfaces in logs).
//
// We intentionally do not depend on a connectivity package. The
// transient-error backoff is the only signal we use, which keeps the
// dep surface small. PR 9 / T-CLIENT-016 will add proper retry+OTel.

import 'dart:async';

import 'package:echo_client/data/local/database.dart';
import 'package:echo_client/services/api_client.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Aggregated outcome of one [SyncService.flushOnce] call. Used by tests
/// and surfaced to the (currently no-op) telemetry hook.
class SyncReport {
  const SyncReport({
    required this.uploaded,
    required this.conflicted,
    required this.dropped,
    required this.deferred,
    required this.unauthorized,
  });

  const SyncReport.empty()
      : uploaded = 0,
        conflicted = 0,
        dropped = 0,
        deferred = 0,
        unauthorized = false;

  /// Rows the server accepted (200/201).
  final int uploaded;

  /// Rows the server rejected with 409. The local row is deleted because
  /// the server already has an authoritative choice for that vignette.
  final int conflicted;

  /// Rows dropped because the server returned a fatal client error
  /// (400/404 or a malformed envelope) that won't go away on retry.
  final int dropped;

  /// Rows left in the queue because we hit a transient (network / 5xx)
  /// failure mid-drain.
  final int deferred;

  /// True if any request returned 401/403 — the user needs to
  /// authenticate before the next tick attempts a drain.
  final bool unauthorized;

  bool get hasWork =>
      uploaded > 0 || conflicted > 0 || dropped > 0 || deferred > 0;

  @override
  String toString() => 'SyncReport(uploaded=$uploaded, conflicted=$conflicted, '
      'dropped=$dropped, deferred=$deferred, unauthorized=$unauthorized)';
}

class SyncService {
  SyncService({
    required EchoDatabase db,
    required SyncApi api,
    Duration initialDelay = const Duration(seconds: 30),
    Duration maxDelay = const Duration(minutes: 5),
  })  : _db = db,
        _api = api,
        _initialDelay = initialDelay,
        _maxDelay = maxDelay;

  final EchoDatabase _db;
  final SyncApi _api;
  final Duration _initialDelay;
  final Duration _maxDelay;

  // Periodic-loop state. Null when stopped.
  Timer? _timer;
  Duration _nextDelay = const Duration(seconds: 15);
  bool _inFlight = false;

  // Used by tests to observe loop scheduling without hooking the Timer.
  @visibleForTesting
  Duration get nextDelayForTest => _nextDelay;

  /// Run a single drain pass. Safe to call from tests, from `start`'s
  /// loop, or from a manual "Sync now" button.
  Future<SyncReport> flushOnce() async {
    if (_inFlight) {
      return const SyncReport.empty();
    }
    _inFlight = true;
    try {
      return await _drain();
    } finally {
      _inFlight = false;
    }
  }

  /// Start a background loop that calls [flushOnce] periodically. The
  /// loop uses exponential backoff on transient failures and resets to
  /// [_initialDelay] on a successful drain.
  void start() {
    if (_timer != null) {
      return;
    }
    _nextDelay = _initialDelay;
    _scheduleNext();
  }

  /// Stop the loop. Safe to call multiple times.
  Future<void> stop() async {
    _timer?.cancel();
    _timer = null;
  }

  void _scheduleNext() {
    _timer = Timer(_nextDelay, () async {
      final report = await flushOnce();
      if (report.deferred > 0 || report.unauthorized) {
        // Back off. We double the delay each transient failure, capped
        // at _maxDelay, so a backend outage doesn't spin the device.
        final next = _nextDelay * 2;
        _nextDelay = next > _maxDelay ? _maxDelay : next;
      } else {
        _nextDelay = _initialDelay;
      }
      if (_timer != null) {
        _scheduleNext();
      }
    });
  }

  Future<SyncReport> _drain() async {
    final localPlaythroughIds =
        await _db.listPlaythroughIdsWithPendingChoices();
    if (localPlaythroughIds.isEmpty) {
      return const SyncReport.empty();
    }

    var uploaded = 0;
    var conflicted = 0;
    var dropped = 0;
    var deferred = 0;
    var unauthorized = false;

    for (final localPlaythroughId in localPlaythroughIds) {
      final header = await _db.findLocalPlaythrough(localPlaythroughId);
      if (header == null) {
        // Orphaned pending rows. Defensive: drop them so the queue
        // doesn't poison future drains.
        final orphans =
            await _db.listPendingChoicesForPlaythrough(localPlaythroughId);
        for (final o in orphans) {
          await _db.deletePendingChoice(o.localId);
          dropped += 1;
        }
        continue;
      }

      // Resolve the server playthrough id, opening one if we don't have
      // it yet. A SyncTransient/SyncUnauthorized here defers the entire
      // playthrough so we don't race POST /playthroughs against a flaky
      // backend.
      String remoteId;
      if (header.remoteId == null) {
        try {
          final env = await _api.createPlaythrough(seasonId: header.seasonId);
          await _db.setLocalPlaythroughRemoteId(
            localId: header.localId,
            remoteId: env.id,
          );
          remoteId = env.id;
        } on SyncTransient catch (e) {
          deferred += await _countDeferred(localPlaythroughId);
          debugPrint('sync deferred for ${header.localId}: $e');
          continue;
        } on SyncUnauthorized catch (e) {
          unauthorized = true;
          deferred += await _countDeferred(localPlaythroughId);
          debugPrint('sync unauthorized for ${header.localId}: $e');
          continue;
        } on SyncFatal catch (e) {
          // The server refused to open a playthrough for this season
          // (404 season, 400 bad request). Drop the queue for this
          // playthrough — no amount of retry will change the outcome.
          debugPrint('sync fatal for ${header.localId}: $e');
          final orphans =
              await _db.listPendingChoicesForPlaythrough(localPlaythroughId);
          for (final o in orphans) {
            await _db.deletePendingChoice(o.localId);
            dropped += 1;
          }
          continue;
        }
      } else {
        remoteId = header.remoteId!;
      }

      final pending =
          await _db.listPendingChoicesForPlaythrough(localPlaythroughId);
      var deferredForPlaythrough = false;
      for (final row in pending) {
        if (deferredForPlaythrough) {
          deferred += 1;
          continue;
        }
        try {
          final outcome = await _api.recordChoice(
            playthroughId: remoteId,
            vignetteId: row.vignetteId,
            choiceId: row.choiceId,
            deliberationMs: row.deliberationMs,
            clientTimestamp: row.committedAt,
          );
          await _db.deletePendingChoice(row.localId);
          if (outcome == ChoiceSyncOutcome.accepted) {
            uploaded += 1;
          } else {
            conflicted += 1;
          }
        } on SyncTransient catch (e) {
          debugPrint('sync transient for ${row.localId}: $e');
          deferred += 1;
          deferredForPlaythrough = true;
        } on SyncUnauthorized catch (e) {
          debugPrint('sync unauthorized for ${row.localId}: $e');
          unauthorized = true;
          deferred += 1;
          deferredForPlaythrough = true;
        } on SyncFatal catch (e) {
          debugPrint('sync fatal for ${row.localId}: $e');
          await _db.deletePendingChoice(row.localId);
          dropped += 1;
        }
      }
    }

    return SyncReport(
      uploaded: uploaded,
      conflicted: conflicted,
      dropped: dropped,
      deferred: deferred,
      unauthorized: unauthorized,
    );
  }

  Future<int> _countDeferred(String localPlaythroughId) async {
    final rows = await _db.listPendingChoicesForPlaythrough(localPlaythroughId);
    return rows.length;
  }
}

/// Provider wiring. Tests use [overrideWith] to inject fakes; production
/// reads this provider once at app boot via [bootSyncService] below.
final Provider<SyncService> syncServiceProvider = Provider<SyncService>(
  (Ref ref) {
    throw UnimplementedError(
      'syncServiceProvider must be overridden at bootstrap with the '
      'concrete ApiClient + EchoDatabase wiring.',
    );
  },
);
