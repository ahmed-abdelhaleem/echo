// Routing configuration for the Echo client.
//
// M2 (T-CLIENT-020) adds the auth surface — sign-up, login, password
// recovery, and settings. The router is auth-aware via a redirect
// callback that reads [authControllerProvider]:
//   - anonymous users on a "protected" route (settings) -> /login
//   - signed-in users on an auth-only route (login, signup, recover)
//     -> /
//   - everything else passes through
//
// Listenable wiring: GoRouter's `refreshListenable` lets us nudge
// the redirect logic whenever the auth state changes (sign-in,
// sign-out, account deletion). We bridge Riverpod's state to a
// ChangeNotifier so GoRouter can listen.

import 'package:echo_client/features/auth/auth_controller.dart';
import 'package:echo_client/features/auth/auth_callback_screen.dart';
import 'package:echo_client/features/auth/login_screen.dart';
import 'package:echo_client/features/auth/password_recovery_screen.dart';
import 'package:echo_client/features/auth/settings_screen.dart';
import 'package:echo_client/features/auth/sign_up_screen.dart';
import 'package:echo_client/features/compare/compare_screen.dart';
import 'package:echo_client/features/home/home_screen.dart';
import 'package:echo_client/features/vignette/vignette_screen.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

/// Routes that require a signed-in user. Anonymous visitors are
/// redirected to /login.
const Set<String> _authRequiredPaths = <String>{'/settings'};

/// Routes that should not be visible to signed-in users (no point
/// signing in when you're already signed in). Visitors here are
/// redirected to /.
const Set<String> _anonymousOnlyPaths = <String>{
  '/login',
  '/signup',
  '/recover',
  '/auth/callback',
};

final Provider<GoRouter> appRouterProvider = Provider<GoRouter>((Ref ref) {
  final authListenable = _AuthStateListenable(ref);
  ref.onDispose(authListenable.dispose);

  return GoRouter(
    initialLocation: '/',
    refreshListenable: authListenable,
    redirect: (context, state) {
      final auth = ref.read(authControllerProvider);
      final signedIn = auth is AuthStateSignedIn;
      final loc = state.matchedLocation;
      if (!signedIn && _isAuthRequiredPath(loc)) {
        return '/login';
      }
      if (signedIn && _anonymousOnlyPaths.contains(loc)) {
        return '/';
      }
      return null;
    },
    routes: <RouteBase>[
      GoRoute(
        path: '/',
        name: 'home',
        builder: (context, state) => const HomeScreen(),
      ),
      GoRoute(
        path: '/compare/accept/:token',
        name: 'compareAccept',
        builder: (context, state) {
          final token = state.pathParameters['token'] ?? '';
          return CompareAcceptScreen(token: token);
        },
      ),
      GoRoute(
        path: '/compare/:token',
        name: 'compare',
        builder: (context, state) {
          final token = state.pathParameters['token'] ?? '';
          return CompareScreen(token: token);
        },
      ),
      GoRoute(
        path: '/season/:id',
        name: 'season',
        builder: (context, state) {
          final id = state.pathParameters['id'] ?? 'season-001';
          return VignetteScreen(seasonId: id);
        },
      ),
      GoRoute(
        path: '/login',
        name: 'login',
        builder: (context, state) => const LoginScreen(),
      ),
      GoRoute(
        path: '/signup',
        name: 'signup',
        builder: (context, state) => const SignUpScreen(),
      ),
      GoRoute(
        path: '/recover',
        name: 'recover',
        builder: (context, state) => const PasswordRecoveryScreen(),
      ),
      GoRoute(
        path: '/settings',
        name: 'settings',
        builder: (context, state) => const SettingsScreen(),
      ),
      GoRoute(
        path: '/auth/callback',
        name: 'authCallback',
        builder: (context, state) => const AuthCallbackScreen(),
      ),
    ],
  );
});

bool _isAuthRequiredPath(String loc) {
  if (_authRequiredPaths.contains(loc)) {
    return true;
  }
  return loc.startsWith('/compare/accept/');
}

/// Bridges [authControllerProvider] to a [Listenable] so GoRouter's
/// refresh hook fires whenever the user signs in / out / deletes.
class _AuthStateListenable extends ChangeNotifier {
  _AuthStateListenable(this._ref) {
    _subscription = _ref.listen<AuthState>(authControllerProvider, (_, __) {
      notifyListeners();
    });
  }

  final Ref _ref;
  late final ProviderSubscription<AuthState> _subscription;

  @override
  void dispose() {
    _subscription.close();
    super.dispose();
  }
}
