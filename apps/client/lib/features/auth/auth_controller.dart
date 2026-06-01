// AuthController — Riverpod-managed session state for the Echo client.
//
// Holds either [AuthStateAnonymous] (no session) or [AuthStateSignedIn]
// (token + identity + age band). Mutators are intentionally minimal:
//   - signUp(...) / login(...) / signOut() rotate the state
//   - delete() tears the account down and rotates to anonymous
//
// We keep the auth token in memory only in M2. Persisting it across
// app restarts requires platform secure storage (Keychain on
// iOS/macOS, EncryptedSharedPreferences on Android, etc.), which we
// add in a follow-up PR after we've decided on the storage abstraction.
// Within a single session the surface is fully functional.

import 'package:echo_client/services/auth_client.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Sum type for the current auth state. Sealed to force exhaustive
/// switches at the screen layer.
sealed class AuthState {
  const AuthState();
}

class AuthStateAnonymous extends AuthState {
  const AuthStateAnonymous();
}

class AuthStateSignedIn extends AuthState {
  const AuthStateSignedIn({
    required this.session,
    this.whoami,
  });

  final AuthSession session;

  /// Latest /whoami payload — null until the first whoami round-trip
  /// finishes. The UI uses [youthSafe] off the whoami to gate sharing
  /// and other adult-only surfaces, falling back to "treat as youth"
  /// (the safer default) when null.
  final WhoamiResponse? whoami;

  bool get youthSafe => whoami?.youthSafe ?? true;
  String? get ageBand => whoami?.ageBand;

  AuthStateSignedIn withWhoami(WhoamiResponse w) {
    return AuthStateSignedIn(session: session, whoami: w);
  }
}

/// Notifier that produces [AuthState] values from auth-flow calls.
///
/// We expose explicit methods (signUp / login / signOut / delete)
/// rather than a generic `state = ...` setter because every transition
/// has side effects (HTTP calls, whoami refresh) that the UI shouldn't
/// have to remember to run.
class AuthController extends StateNotifier<AuthState> {
  AuthController(this._client) : super(const AuthStateAnonymous());

  final AuthClient _client;

  /// Calls /auth/preflight. Lifted to the controller so the sign-up
  /// screen doesn't need a direct AuthClient handle (and so tests
  /// can mock the controller wholesale).
  Future<PreflightDecision> preflight(String birthdate) {
    return _client.preflight(birthdate);
  }

  /// Submits the Kratos registration flow. On success, transitions
  /// to AuthStateSignedIn and fires off a whoami refresh in the
  /// background to populate age_band / youth_safe.
  Future<void> signUp({
    required String email,
    required String password,
    required String displayName,
    required String birthdate,
  }) async {
    final session = await _client.signUp(
      email: email,
      password: password,
      displayName: displayName,
      birthdate: birthdate,
    );
    state = AuthStateSignedIn(session: session);
    await _refreshWhoami();
  }

  /// Submits the Kratos login flow. Same shape as [signUp].
  Future<void> login({
    required String email,
    required String password,
  }) async {
    final session = await _client.login(email: email, password: password);
    state = AuthStateSignedIn(session: session);
    await _refreshWhoami();
  }

  /// Triggers Kratos password recovery. The state is not affected —
  /// the screen shows a confirmation regardless of whether the email
  /// is registered (privacy: don't leak account existence).
  Future<void> recoverPassword(String email) {
    return _client.recoverPassword(email);
  }

  /// Drops the in-memory token. We do NOT call Kratos logout here —
  /// that's a no-op for native flows (the token is the source of
  /// truth, and the server will GC it at expiry). A future PR can
  /// add explicit revocation.
  void signOut() {
    state = const AuthStateAnonymous();
  }

  /// Permanent account deletion. Calls DELETE /me, then transitions
  /// to anonymous. If the server says 401 we still go anonymous —
  /// the session is gone either way.
  Future<void> delete() async {
    final current = state;
    if (current is! AuthStateSignedIn) {
      // Idempotent: deleting from an anonymous state is a no-op.
      return;
    }
    try {
      await _client.deleteAccount(current.session.token);
    } on AuthException catch (e) {
      if (e.kind != AuthFailureKind.unauthorised) {
        rethrow;
      }
    }
    state = const AuthStateAnonymous();
  }

  Future<void> _refreshWhoami() async {
    final current = state;
    if (current is! AuthStateSignedIn) return;
    final w = await _client.whoami(current.session.token);
    if (w == null) {
      // Session no longer valid — drop to anonymous so the router
      // can redirect to login.
      state = const AuthStateAnonymous();
      return;
    }
    // Only apply if the state hasn't been swapped out from under us.
    if (state is AuthStateSignedIn) {
      state = (state as AuthStateSignedIn).withWhoami(w);
    }
  }
}

final StateNotifierProvider<AuthController, AuthState> authControllerProvider =
    StateNotifierProvider<AuthController, AuthState>((Ref ref) {
  return AuthController(ref.watch(authClientProvider));
});
