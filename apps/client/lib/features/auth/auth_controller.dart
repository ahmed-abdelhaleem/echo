// AuthController — Riverpod-managed session state for the Echo client.
//
// Holds either [AuthStateAnonymous] (no session) or [AuthStateSignedIn]
// (token + identity + age band). Mutators are intentionally minimal:
//   - signUp(...) / login(...) / signOut() rotate the state
//   - delete() tears the account down and rotates to anonymous
//
// The token is persisted via [SessionTokenStorage] so users remain logged in
// across page reloads and cold restarts without exposing it to preferences.

import 'dart:async';

import 'package:echo_client/services/auth_client.dart';
import 'package:echo_client/services/session_token_storage.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

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
  AuthController(this._client, {SessionTokenStorage? storage})
      : _storage = storage,
        super(const AuthStateAnonymous()) {
    // Restore persisted session token synchronously so the very first
    // frame is already authenticated (no sign-in flash on reload).
    final saved = storage?.read();
    if (saved != null && saved.isNotEmpty) {
      state = AuthStateSignedIn(
        session: AuthSession(
          token: saved,
          identityId: '',
          email: '',
          displayName: null,
        ),
      );
      // Refresh whoami asynchronously — this updates age_band / youth_safe
      // without blocking startup. Transient network errors leave the saved
      // session in place; a 401 still clears it through _refreshWhoami.
      initialSessionRefresh = _restoreWhoami();
      unawaited(initialSessionRefresh);
    } else {
      initialSessionRefresh = Future<void>.value();
    }
  }

  final AuthClient _client;
  final SessionTokenStorage? _storage;

  /// Completes after a restored token has been checked with `/whoami`.
  ///
  /// The app does not await this before rendering because the token is applied
  /// synchronously. Tests and startup diagnostics can await it when they need
  /// the validated identity state.
  late final Future<void> initialSessionRefresh;

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
    await _storage?.write(session.token);
    state = AuthStateSignedIn(session: session);
    await _refreshWhoami();
  }

  /// Submits the Kratos login flow. Same shape as [signUp].
  Future<void> login({
    required String email,
    required String password,
  }) async {
    final session = await _client.login(email: email, password: password);
    await _storage?.write(session.token);
    state = AuthStateSignedIn(session: session);
    await _refreshWhoami();
  }

  /// Triggers Kratos password recovery. The state is not affected —
  /// the screen shows a confirmation regardless of whether the email
  /// is registered (privacy: don't leak account existence).
  Future<void> recoverPassword(String email) {
    return _client.recoverPassword(email);
  }

  /// Opens Google sign-up in the system browser (web: same tab).
  Future<void> signUpWithGoogle({
    required String birthdate,
    required String displayName,
    required String returnTo,
  }) async {
    final url = await _client.startGoogleSignUp(
      birthdate: birthdate,
      displayName: displayName,
      returnTo: returnTo,
    );
    await _launchOidcUrl(url);
  }

  /// Opens Google sign-in in the system browser.
  Future<void> loginWithGoogle({required String returnTo}) async {
    final url = await _client.startGoogleLogin(returnTo: returnTo);
    await _launchOidcUrl(url);
  }

  /// Finishes an OIDC round-trip after `/auth/callback`.
  Future<void> completeOidc({
    required String flowId,
    required bool isRegistration,
  }) async {
    final session = await _client.completeOidcCallback(
      flowId: flowId,
      isRegistration: isRegistration,
    );
    await _storage?.write(session.token);
    state = AuthStateSignedIn(session: session);
    await _refreshWhoami();
  }

  Future<void> _launchOidcUrl(String url) async {
    final uri = Uri.parse(url);
    final ok = await launchUrl(uri, webOnlyWindowName: '_self');
    if (!ok) {
      throw const AuthException(
        AuthFailureKind.other,
        message: 'Could not open Google sign-in',
      );
    }
  }

  /// Drops the in-memory token. We do NOT call Kratos logout here —
  /// that's a no-op for native flows (the token is the source of
  /// truth, and the server will GC it at expiry). A future PR can
  /// add explicit revocation.
  Future<void> signOut() async {
    await _storage?.clear();
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
    await _storage?.clear();
  }

  Future<void> _restoreWhoami() async {
    try {
      await _refreshWhoami();
    } on Object {
      // A cold start must still work offline. Only an explicit invalid-session
      // response (represented by null) removes the restored token.
    }
  }

  Future<void> _refreshWhoami() async {
    final current = state;
    if (current is! AuthStateSignedIn) return;
    final token = current.session.token;
    final w = await _client.whoami(token);
    final latest = state;
    if (latest is! AuthStateSignedIn || latest.session.token != token) {
      return;
    }
    if (w == null) {
      // Session no longer valid — drop to anonymous and erase the
      // stored token so the next cold start doesn't loop.
      state = const AuthStateAnonymous();
      await _storage?.clear();
      return;
    }
    state = latest.withWhoami(w);
  }
}

final StateNotifierProvider<AuthController, AuthState> authControllerProvider =
    StateNotifierProvider<AuthController, AuthState>((Ref ref) {
  return AuthController(
    ref.watch(authClientProvider),
    storage: ref.watch(sessionTokenStorageProvider),
  );
});
