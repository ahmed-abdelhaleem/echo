// Routing configuration for the Echo client.
//
// In M1 the router exposes:
//   /             -> HomeScreen
//   /season/:id   -> VignetteScreen (drives the whole season — see PR 7)
//
// Route registration is centralised here so tests can drive navigation by
// route name without depending on widget structure.

import 'package:echo_client/features/home/home_screen.dart';
import 'package:echo_client/features/vignette/vignette_screen.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

final Provider<GoRouter> appRouterProvider = Provider<GoRouter>((Ref ref) {
  return GoRouter(
    initialLocation: '/',
    routes: <RouteBase>[
      GoRoute(
        path: '/',
        name: 'home',
        builder: (context, state) => const HomeScreen(),
      ),
      GoRoute(
        path: '/season/:id',
        name: 'season',
        builder: (context, state) {
          final id = state.pathParameters['id'] ?? 'season-001';
          return VignetteScreen(seasonId: id);
        },
      ),
    ],
  );
});
