// Sync UI state + scheduling glue (T-CLIENT-012).
//
// The [SyncService] does the actual draining; this controller wraps it
// in a Riverpod StateNotifier so the renderer can show a banner when a
// drain is in flight, succeeded, or aborted.

import 'dart:async';

import 'package:echo_client/services/sync_service.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Snapshot of the most recent sync state. Kept deliberately small —
/// we only care about whether a drain is in flight and the outcome of
/// the last completed one for the banner.
sealed class SyncState {
  const SyncState();
}

class SyncIdle extends SyncState {
  const SyncIdle();
}

class SyncRunning extends SyncState {
  const SyncRunning();
}

class SyncSucceeded extends SyncState {
  const SyncSucceeded(this.result, this.at);
  final SyncResult result;
  final DateTime at;
}

class SyncFailed extends SyncState {
  const SyncFailed(this.result, this.at);
  final SyncResult result;
  final DateTime at;
}

class SyncController extends StateNotifier<SyncState> {
  SyncController({
    required SyncService service,
    DateTime Function() now = _defaultNow,
  })  : _service = service,
        _now = now,
        super(const SyncIdle());

  final SyncService _service;
  final DateTime Function() _now;

  static DateTime _defaultNow() => DateTime.now();

  /// Triggers a drain. Safe to call concurrently — [SyncService] coalesces.
  Future<SyncResult> syncNow() async {
    state = const SyncRunning();
    final result = await _service.drain();
    final now = _now();
    if (result.aborted) {
      state = SyncFailed(result, now);
    } else {
      state = SyncSucceeded(result, now);
    }
    return result;
  }
}

final StateNotifierProvider<SyncController, SyncState> syncControllerProvider =
    StateNotifierProvider<SyncController, SyncState>((Ref ref) {
  return SyncController(service: ref.watch(syncServiceProvider));
});

/// Materialises a [SyncScheduler] that lives for the app lifetime. The
/// scheduler starts its periodic timer in `start()` and stops it on
/// dispose. Override this in widget tests to inject a shorter interval
/// (or to swap in a fake that never fires).
final Provider<SyncScheduler> syncSchedulerProvider = Provider<SyncScheduler>(
  (Ref ref) {
    final scheduler = SyncScheduler(service: ref.watch(syncServiceProvider));
    scheduler.start();
    ref.onDispose(scheduler.stop);
    return scheduler;
  },
);
