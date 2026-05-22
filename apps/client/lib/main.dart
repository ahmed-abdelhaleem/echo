// Entry point for the Echo client.
//
// Keep this file thin: anything testable lives in `app/`, `features/`,
// or `services/`. `main()` is the only thing the Dart VM calls directly,
// so it stays a single statement plus the ProviderScope.
//
// The `vignetteControllerProvider` requires a [ContentRepository] bound
// to a real ApiClient + Drift database. We assemble that wiring as a
// ProviderScope override here so tests can supply fakes via the same
// seam. Same goes for [syncServiceProvider].

import 'package:echo_client/app/app.dart';
import 'package:echo_client/data/content_repository.dart';
import 'package:echo_client/features/sync/sync_controller.dart';
import 'package:echo_client/features/vignette/vignette_controller.dart';
import 'package:echo_client/services/api_client.dart';
import 'package:echo_client/services/sync_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

void main() {
  runApp(
    ProviderScope(
      overrides: <Override>[
        contentRepositoryProvider.overrideWith((Ref ref) {
          return ContentRepository(
            api: ref.watch(apiClientProvider),
            db: ref.watch(echoDatabaseProvider),
          );
        }),
        syncServiceProvider.overrideWith((Ref ref) {
          return SyncService(
            api: ref.watch(apiClientProvider),
            db: ref.watch(echoDatabaseProvider),
          );
        }),
      ],
      child: const _EchoBootstrap(),
    ),
  );
}

/// Thin wrapper that starts the periodic [SyncScheduler] for the
/// lifetime of the app. Kept private so the scheduling concern stays in
/// one place — feature widgets shouldn't need to know about it.
class _EchoBootstrap extends ConsumerStatefulWidget {
  const _EchoBootstrap();

  @override
  ConsumerState<_EchoBootstrap> createState() => _EchoBootstrapState();
}

class _EchoBootstrapState extends ConsumerState<_EchoBootstrap> {
  @override
  void initState() {
    super.initState();
    // Touching the provider materialises the scheduler; the scheduler
    // ctor starts the timer. ref.onDispose in the provider stops it.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(syncSchedulerProvider);
    });
  }

  @override
  Widget build(BuildContext context) {
    return const EchoApp();
  }
}
