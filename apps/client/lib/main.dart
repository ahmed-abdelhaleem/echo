// Entry point for the Echo client.
//
// Keep this file thin: anything testable lives in `app/`, `features/`,
// or `services/`. `main()` is the only thing the Dart VM calls directly,
// so it stays a single statement plus the ProviderScope.
//
// The `vignetteControllerProvider` requires a [ContentRepository] bound
// to a real ApiClient + Drift database. We assemble that wiring as a
// ProviderScope override here so tests can supply fakes via the same
// seam. The sync service is started imperatively after the first frame
// so it doesn't block the splash.

import 'package:echo_client/app/app.dart';
import 'package:echo_client/data/content_repository.dart';
import 'package:echo_client/features/vignette/vignette_controller.dart';
import 'package:echo_client/services/api_client.dart';
import 'package:echo_client/services/sync_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

void main() {
  final container = ProviderContainer(
    overrides: <Override>[
      contentRepositoryProvider.overrideWith((Ref ref) {
        return ContentRepository(
          api: ref.watch(apiClientProvider),
          db: ref.watch(echoDatabaseProvider),
        );
      }),
      syncServiceProvider.overrideWith((Ref ref) {
        final service = SyncService(
          db: ref.watch(echoDatabaseProvider),
          api: ref.watch(apiClientProvider),
        );
        ref.onDispose(service.stop);
        return service;
      }),
    ],
  );

  // Start the background drain. Safe to call before `runApp` — the
  // service schedules its first tick after a delay and uses Drift's
  // background isolate.
  container.read(syncServiceProvider).start();

  runApp(
    UncontrolledProviderScope(
      container: container,
      child: const EchoApp(),
    ),
  );
}
