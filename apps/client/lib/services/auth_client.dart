// AuthClient — wraps the Kratos public API (native / API flow) and the
// Echo auth endpoints that live on the core-go gateway.
//
// We use Kratos' *native API flow* (not the browser flow) because the
// Flutter client targets iOS / Android / Windows / macOS / web with the
// same code path, and the API flow returns a session_token we can
// attach to subsequent requests via the X-Session-Token header. That
// keeps cross-platform code identical and lets us avoid a cookie store
// dependency in M2.
//
// Surface (matches T-CLIENT-020's "full account lifecycle" acceptance):
//   - preflight(birthdate)         -> {allowed, band?, reason?}
//   - signUp(...)                  -> AuthSession (token + identity)
//   - login(email, password)       -> AuthSession
//   - recoverPassword(email)       -> void   (Kratos emails a link)
//   - whoami(token)                -> WhoamiResponse (age_band, youth_safe)
//   - deleteAccount(token)         -> void   (admin delete via core-go)
//
// Google OIDC uses Kratos' browser redirect (`redirect_browser_to`).
// The client opens the URL, then `/auth/callback` completes the flow.
//
// Error model: any 4xx is surfaced as a typed [AuthException] so the
// screen layer can show the right copy without parsing strings. 5xx
// and transport errors throw DioException unchanged so the higher-level
// error handler can decide on retry vs. "we're down" copy.

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'api_client.dart';

/// Two-way response from `POST /auth/preflight`. The client uses this
/// to surface under-13 rejection at the birthdate field *before* the
/// full registration form is submitted — Kratos' before-registration
/// hook is the authoritative gate, but a preflight saves a network
/// round-trip-plus-form-error cycle for the most common rejection case.
class PreflightDecision {
  const PreflightDecision({
    required this.allowed,
    this.band,
    this.reason,
  });

  factory PreflightDecision.fromJson(Map<String, dynamic> json) {
    final allowed = json['allowed'] as bool? ?? false;
    final band = json['band'] as String?;
    final reason = json['reason'] as String?;
    return PreflightDecision(allowed: allowed, band: band, reason: reason);
  }

  /// True if the supplied birthdate is allowed to proceed to
  /// registration. False if rejected (under-13).
  final bool allowed;

  /// 'youth' or 'adult' when [allowed] is true; null otherwise.
  final String? band;

  /// Machine-readable reason ('under_13', 'invalid_birthdate', ...)
  /// when [allowed] is false.
  final String? reason;

  bool get isYouth => band == 'youth';
}

/// The session a successful sign-up / login returns. The token is what
/// the client subsequently attaches as X-Session-Token to every
/// authenticated request.
class AuthSession {
  const AuthSession({
    required this.token,
    required this.identityId,
    required this.email,
    this.displayName,
  });

  factory AuthSession.fromKratosResponse(Map<String, dynamic> json) {
    final token = json['session_token'] as String?;
    if (token == null) {
      throw const AuthException._('Kratos response missing session_token');
    }
    final session = json['session'] as Map<String, dynamic>?;
    final identity = session?['identity'] as Map<String, dynamic>?;
    if (identity == null) {
      throw const AuthException._('Kratos response missing identity');
    }
    final traits = identity['traits'] as Map<String, dynamic>? ?? {};
    return AuthSession(
      token: token,
      identityId: identity['id'] as String,
      email: traits['email'] as String? ?? '',
      displayName: traits['display_name'] as String?,
    );
  }

  /// X-Session-Token value the client attaches to authenticated
  /// requests. Treat as a secret.
  final String token;
  final String identityId;
  final String email;
  final String? displayName;
}

/// The shape of /whoami after T-CORE-021. age_band and youth_safe are
/// nullable here because they can be absent when the user row hasn't
/// been provisioned yet (e.g. a transient lookup failure).
class WhoamiResponse {
  const WhoamiResponse({
    required this.identityId,
    required this.email,
    this.displayName,
    this.ageBand,
    this.youthSafe,
  });

  factory WhoamiResponse.fromJson(Map<String, dynamic> json) {
    return WhoamiResponse(
      identityId: json['identity_id'] as String? ?? '',
      email: json['email'] as String? ?? '',
      displayName: json['display_name'] as String?,
      ageBand: json['age_band'] as String?,
      youthSafe: json['youth_safe'] as bool?,
    );
  }

  final String identityId;
  final String email;
  final String? displayName;
  final String? ageBand;
  final bool? youthSafe;

  bool get isYouth => ageBand == 'youth';
}

/// Reasons a sign-up / login can fail in ways the UI must show
/// differently. Mapping comes from Kratos' problem JSON shapes plus
/// our own 422-from-before-registration-hook shape.
enum AuthFailureKind {
  /// Kratos rejected the credentials (login) or duplicate email
  /// (signup). UI shows a field-level error.
  invalidCredentials,

  /// before-registration hook rejected the birthdate as under-13.
  /// UI surfaces this on the birthdate field with consent / parent
  /// copy.
  under13,

  /// Field-shaped validation error from Kratos (e.g. malformed email,
  /// weak password). The [field] property names the offending field.
  validation,

  /// Kratos session is gone (401). UI routes back to login.
  unauthorised,

  /// Anything else 4xx — generic UI banner.
  other,
}

class AuthException implements Exception {
  const AuthException(
    this.kind, {
    this.field,
    this.message,
  });

  const AuthException._(this.message)
      : kind = AuthFailureKind.other,
        field = null;

  final AuthFailureKind kind;

  /// Field path the error applies to (Kratos field id, e.g.
  /// 'traits.birthdate'). Null for non-field errors.
  final String? field;

  final String? message;

  @override
  String toString() =>
      'AuthException(kind=$kind, field=$field, message=$message)';
}

class AuthClient {
  /// [kratosBaseUrl] is the Kratos public listener (e.g.
  /// http://localhost:4433 in dev). [coreBaseUrl] is the Echo core-go
  /// gateway. Both can point at the same host when going through a
  /// reverse proxy.
  AuthClient({
    required this.kratosBaseUrl,
    required this.coreBaseUrl,
    Dio? dio,
  }) : _dio = dio ??
            Dio(
              BaseOptions(
                connectTimeout: const Duration(seconds: 5),
                receiveTimeout: const Duration(seconds: 10),
              ),
            ) {
    // We treat 4xx as data so we can produce typed AuthException
    // values rather than parsing exceptions. 5xx remains an exception
    // so the screen layer can show "Echo is having a moment" copy.
    _dio.options.validateStatus = (status) => status != null && status < 500;
  }

  final String kratosBaseUrl;
  final String coreBaseUrl;
  final Dio _dio;

  /// Asks Echo whether a birthdate would be accepted before the user
  /// fills in the rest of the registration form. Never throws on a
  /// 4xx from Echo — the under-13 case is data, not failure.
  Future<PreflightDecision> preflight(String birthdate) async {
    final response = await _dio.post<Map<String, dynamic>>(
      '$coreBaseUrl/auth/preflight',
      data: <String, dynamic>{'birthdate': birthdate},
    );
    final status = response.statusCode ?? 0;
    if (status == 200) {
      return PreflightDecision.fromJson(response.data ?? const {});
    }
    if (status == 400) {
      // Malformed birthdate input — treat as "not allowed" with a
      // typed reason rather than throwing, because the most common
      // cause is the user typing an invalid date in the form.
      final body = response.data ?? const {};
      return PreflightDecision(
        allowed: false,
        reason: body['reason'] as String? ?? 'invalid_birthdate',
      );
    }
    throw DioException(
      requestOptions: response.requestOptions,
      response: response,
      message: 'preflight: unexpected status $status',
    );
  }

  /// Native registration flow. We init the flow, POST the password
  /// method with the form payload, and on success return the
  /// session_token that Kratos issues.
  ///
  /// The before-registration web hook rejects under-13 birthdates;
  /// when that fires Kratos surfaces it as a 400 with a Kratos-shaped
  /// `ui.messages` body. We detect under-13 by the message id we set
  /// in the hook (`under_13`) so the UI can show the right copy.
  Future<AuthSession> signUp({
    required String email,
    required String password,
    required String displayName,
    required String birthdate,
  }) async {
    final flowResponse = await _dio.get<Map<String, dynamic>>(
      '$kratosBaseUrl/self-service/registration/api',
    );
    if ((flowResponse.statusCode ?? 0) != 200) {
      throw DioException(
        requestOptions: flowResponse.requestOptions,
        response: flowResponse,
        message: 'signUp: failed to init flow',
      );
    }
    final flowId = (flowResponse.data ?? const {})['id'] as String?;
    if (flowId == null) {
      throw const AuthException._('signUp: registration flow missing id');
    }

    final submit = await _dio.post<Map<String, dynamic>>(
      '$kratosBaseUrl/self-service/registration',
      queryParameters: <String, dynamic>{'flow': flowId},
      data: <String, dynamic>{
        'method': 'password',
        'password': password,
        'traits': <String, dynamic>{
          'email': email,
          'display_name': displayName,
          'birthdate': birthdate,
          'consent': consentTraits(),
        },
      },
    );
    final status = submit.statusCode ?? 0;
    final body = submit.data ?? const <String, dynamic>{};
    if (status == 200) {
      return AuthSession.fromKratosResponse(body);
    }
    if (status == 400) {
      throw _kratosErrorToException(body);
    }
    throw DioException(
      requestOptions: submit.requestOptions,
      response: submit,
      message: 'signUp: unexpected status $status',
    );
  }

  /// Native login flow. Same shape as [signUp].
  Future<AuthSession> login({
    required String email,
    required String password,
  }) async {
    final flowResponse = await _dio.get<Map<String, dynamic>>(
      '$kratosBaseUrl/self-service/login/api',
    );
    if ((flowResponse.statusCode ?? 0) != 200) {
      throw DioException(
        requestOptions: flowResponse.requestOptions,
        response: flowResponse,
        message: 'login: failed to init flow',
      );
    }
    final flowId = (flowResponse.data ?? const {})['id'] as String?;
    if (flowId == null) {
      throw const AuthException._('login: login flow missing id');
    }

    final submit = await _dio.post<Map<String, dynamic>>(
      '$kratosBaseUrl/self-service/login',
      queryParameters: <String, dynamic>{'flow': flowId},
      data: <String, dynamic>{
        'method': 'password',
        'password': password,
        'identifier': email,
      },
    );
    final status = submit.statusCode ?? 0;
    final body = submit.data ?? const <String, dynamic>{};
    if (status == 200) {
      return AuthSession.fromKratosResponse(body);
    }
    if (status == 400) {
      throw _kratosErrorToException(body);
    }
    throw DioException(
      requestOptions: submit.requestOptions,
      response: submit,
      message: 'login: unexpected status $status',
    );
  }

  /// Starts Google registration. Returns the URL the browser should open.
  /// [returnTo] must be listed in Kratos `allowed_return_urls` (see
  /// infra/kratos/kratos.yml). [birthdate] and [displayName] are sent
  /// as traits before the redirect so the age gate can run.
  Future<String> startGoogleSignUp({
    required String birthdate,
    required String displayName,
    required String returnTo,
  }) {
    return _startGoogleOidc(
      flow: _OidcFlow.registration,
      returnTo: returnTo,
      traits: <String, dynamic>{
        'display_name': displayName,
        'birthdate': birthdate,
        'consent': consentTraits(),
      },
    );
  }

  /// Starts Google login. Returns the provider URL to open in a browser.
  Future<String> startGoogleLogin({required String returnTo}) {
    return _startGoogleOidc(flow: _OidcFlow.login, returnTo: returnTo);
  }

  /// After the browser returns to `/auth/callback?flow=…`, poll Kratos
  /// for the completed flow and extract the session token.
  Future<AuthSession> completeOidcCallback({
    required String flowId,
    required bool isRegistration,
  }) async {
    final path = isRegistration ? 'registration' : 'login';
    final response = await _dio.get<Map<String, dynamic>>(
      '$kratosBaseUrl/self-service/$path/flows',
      queryParameters: <String, dynamic>{'id': flowId},
    );
    final status = response.statusCode ?? 0;
    final body = response.data ?? const <String, dynamic>{};
    if (status == 200 && body['session_token'] != null) {
      return AuthSession.fromKratosResponse(body);
    }
    if (status == 200 && body['session'] != null) {
      // Some Kratos versions nest the token only under session.
      final token = body['session_token'] as String?;
      if (token != null) {
        return AuthSession.fromKratosResponse(
          <String, dynamic>{'session_token': token, 'session': body['session']},
        );
      }
    }
    if (status == 410 || status == 404) {
      throw const AuthException(
        AuthFailureKind.other,
        message: 'Sign-in session expired. Please try again.',
      );
    }
    throw DioException(
      requestOptions: response.requestOptions,
      response: response,
      message: 'completeOidcCallback: flow not ready (status $status)',
    );
  }

  Future<String> _startGoogleOidc({
    required _OidcFlow flow,
    required String returnTo,
    Map<String, dynamic>? traits,
  }) async {
    final path = flow.apiPath;
    final flowResponse = await _dio.get<Map<String, dynamic>>(
      '$kratosBaseUrl/self-service/$path/api',
      queryParameters: <String, dynamic>{'return_to': returnTo},
    );
    final flowStatus = flowResponse.statusCode ?? 0;
    final flowBody = flowResponse.data ?? const <String, dynamic>{};
    if (flowStatus == 400) {
      throw _kratosErrorToException(flowBody);
    }
    if (flowStatus != 200) {
      throw DioException(
        requestOptions: flowResponse.requestOptions,
        response: flowResponse,
        message: 'oidc: failed to init ${flow.name} flow (status $flowStatus)',
      );
    }
    final flowId = flowBody['id'] as String?;
    if (flowId == null) {
      throw const AuthException._('oidc: flow missing id');
    }

    final payload = <String, dynamic>{
      'method': 'oidc',
      'provider': 'google',
      if (traits != null) 'traits': traits,
    };
    final submit = await _dio.post<Map<String, dynamic>>(
      '$kratosBaseUrl/self-service/$path',
      queryParameters: <String, dynamic>{'flow': flowId},
      data: payload,
    );
    final status = submit.statusCode ?? 0;
    final body = submit.data ?? const <String, dynamic>{};
    final redirect = body['redirect_browser_to'] as String?;
    if (redirect != null && redirect.isNotEmpty) {
      return redirect;
    }
    if (status == 400) {
      throw _kratosErrorToException(body);
    }
    throw DioException(
      requestOptions: submit.requestOptions,
      response: submit,
      message: 'oidc: missing redirect_browser_to (status $status)',
    );
  }

  /// Kratos password recovery. Always returns "we sent an email if
  /// the address exists" semantics — the actual email goes through
  /// the MailHog dev SMTP in local; production uses the configured
  /// provider.
  Future<void> recoverPassword(String email) async {
    final flowResponse = await _dio.get<Map<String, dynamic>>(
      '$kratosBaseUrl/self-service/recovery/api',
    );
    if ((flowResponse.statusCode ?? 0) != 200) {
      throw DioException(
        requestOptions: flowResponse.requestOptions,
        response: flowResponse,
        message: 'recover: failed to init flow',
      );
    }
    final flowId = (flowResponse.data ?? const {})['id'] as String?;
    if (flowId == null) {
      throw const AuthException._('recover: recovery flow missing id');
    }
    final submit = await _dio.post<Map<String, dynamic>>(
      '$kratosBaseUrl/self-service/recovery',
      queryParameters: <String, dynamic>{'flow': flowId},
      data: <String, dynamic>{
        'method': 'code',
        'email': email,
      },
    );
    final status = submit.statusCode ?? 0;
    if (status == 200) return;
    // Kratos returns 4xx with a Kratos-shaped problem body for
    // recovery; we surface a generic "we tried" success to the UI
    // because that's the privacy-correct response (don't leak whether
    // an email is registered). The screen always shows the same copy.
    if (status >= 400 && status < 500) return;
    throw DioException(
      requestOptions: submit.requestOptions,
      response: submit,
      message: 'recover: unexpected status $status',
    );
  }

  /// Echo /whoami — uses the token, returns the user's identity +
  /// age band so the client can choose between the youth-safe and
  /// adult UX.
  Future<WhoamiResponse?> whoami(String token) async {
    final response = await _dio.get<Map<String, dynamic>>(
      '$coreBaseUrl/whoami',
      options: Options(
        headers: <String, String>{
          'X-Session-Token': token,
        },
      ),
    );
    final status = response.statusCode ?? 0;
    if (status == 200) {
      return WhoamiResponse.fromJson(response.data ?? const {});
    }
    if (status == 401) {
      return null;
    }
    throw DioException(
      requestOptions: response.requestOptions,
      response: response,
      message: 'whoami: unexpected status $status',
    );
  }

  /// Echo DELETE /me — soft-deletes the user row and tears down the
  /// Kratos identity (terminating sessions). Idempotent: a 404 from
  /// Kratos is treated as success because the row was already gone.
  Future<void> deleteAccount(String token) async {
    final response = await _dio.delete<Map<String, dynamic>>(
      '$coreBaseUrl/me',
      options: Options(
        headers: <String, String>{
          'X-Session-Token': token,
        },
      ),
    );
    final status = response.statusCode ?? 0;
    if (status == 204 || status == 200 || status == 404) return;
    if (status == 401) {
      throw const AuthException(AuthFailureKind.unauthorised);
    }
    throw DioException(
      requestOptions: response.requestOptions,
      response: response,
      message: 'deleteAccount: unexpected status $status',
    );
  }
}

/// Turns a Kratos-shaped 400 body into a typed AuthException.
///
/// Kratos returns:
///   { "ui": { "messages": [{ "id": <int>, "text": "...", "type": "error" }],
///             "nodes": [{ "messages": [...], "meta": {"label": {...}}, ... }]
///           },
///     ... }
///
/// The before-registration hook surfaces under-13 as a node-level
/// message on traits.birthdate. We detect it by message text because
/// the hook produces the same canonical text for that case.
AuthException _kratosErrorToException(Map<String, dynamic> body) {
  final ui = body['ui'] as Map<String, dynamic>? ?? const {};
  final nodes = (ui['nodes'] as List<dynamic>? ?? const [])
      .whereType<Map<String, dynamic>>();
  for (final node in nodes) {
    final attrs = node['attributes'] as Map<String, dynamic>? ?? const {};
    final fieldName = attrs['name'] as String?;
    final messages = (node['messages'] as List<dynamic>? ?? const [])
        .whereType<Map<String, dynamic>>();
    for (final m in messages) {
      final text = (m['text'] as String? ?? '').toLowerCase();
      final type = m['type'] as String?;
      if (type != 'error') continue;
      if (fieldName == 'traits.birthdate' && text.contains('under 13')) {
        return const AuthException(
          AuthFailureKind.under13,
          field: 'traits.birthdate',
          message: 'Echo is for ages 13 and up.',
        );
      }
      if (fieldName != null) {
        return AuthException(
          AuthFailureKind.validation,
          field: fieldName,
          message: m['text'] as String?,
        );
      }
    }
  }
  // Top-level messages (e.g. "the provided credentials are invalid").
  final topMessages = (ui['messages'] as List<dynamic>? ?? const [])
      .whereType<Map<String, dynamic>>();
  for (final m in topMessages) {
    final text = (m['text'] as String? ?? '').toLowerCase();
    if (text.contains('credentials are invalid') ||
        text.contains('invalid credentials')) {
      return const AuthException(
        AuthFailureKind.invalidCredentials,
        message: 'Email or password is incorrect.',
      );
    }
  }
  final errorID = body['error'] as Map<String, dynamic>?;
  final reasonRaw = errorID?['reason'] as String? ?? '';
  final reason = reasonRaw.toLowerCase();
  if (reason.contains('return_to') && reason.contains('not allowed')) {
    return const AuthException(
      AuthFailureKind.other,
      message:
          'OAuth return URL is not allow-listed in Kratos. Restart web on port 8082 and retry.',
    );
  }
  if (reason.contains('exists') || reason.contains('duplicate')) {
    return const AuthException(
      AuthFailureKind.invalidCredentials,
      message: 'An account with that email already exists.',
    );
  }
  return const AuthException(AuthFailureKind.other);
}

/// M1 placeholder consent record — mirrors services/core-go/auth/users_repo.
Map<String, dynamic> consentTraits() {
  final now = DateTime.now().toUtc().toIso8601String();
  return <String, dynamic>{
    'tos_version': 'v1.0',
    'tos_accepted_at': now,
    'privacy_version': 'v1.0',
    'privacy_accepted_at': now,
  };
}

enum _OidcFlow {
  registration('registration'),
  login('login');

  const _OidcFlow(this.apiPath);
  final String apiPath;
}

/// Kratos is proxied through core-go at `/auth/kratos` so Flutter web
/// shares one origin with the API (avoids a second CORS surface).
final Provider<String> kratosBaseUrlProvider = Provider<String>((Ref ref) {
  final core = ref.watch(apiBaseUrlProvider);
  return '$core/auth/kratos';
});

final Provider<AuthClient> authClientProvider = Provider<AuthClient>((Ref ref) {
  return AuthClient(
    kratosBaseUrl: ref.watch(kratosBaseUrlProvider),
    coreBaseUrl: ref.watch(apiBaseUrlProvider),
  );
});
