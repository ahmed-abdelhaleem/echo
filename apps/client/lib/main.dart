// Entry point for the Echo client.
//
// Keep this file thin: anything testable lives in `app/`, `features/`,
// or `services/`. `main()` is the only thing the Dart VM calls directly,
// so it stays a single statement plus the ProviderScope.
//
// The `vignetteControllerProvider` requires a [ContentRepository] bound
// to a real ApiClient + Drift database. We assemble that wiring as a
// ProviderScope override here so tests can supply fakes via the same
// seam.

import 'package:echo_client/app/app.dart';
import 'package:echo_client/data/content_repository.dart';
import 'package:echo_client/features/vignette/vignette_controller.dart';
import 'package:echo_client/services/api_client.dart';
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
      ],
      child: const EchoApp(),
    ),
  );
}
