// Thin Dio wrapper. Future PRs add interceptors for auth (T-CORE-020/021),
// retries (T-CLIENT-016), and OTel propagation (T-INFRA-040).
//
// In M1 we expose two endpoint groups:
//   - content (public, no auth): GET /content/seasons/{id}
//   - playthrough (authed, used by the sync in PR 8): POST /playthroughs,
//     POST /playthroughs/{id}/choices.

import 'package:dio/dio.dart';
import 'package:echo_client/data/models/content.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Minimal surface the [SyncService] consumes. Extracted so tests can
/// substitute a fake without taking on the rest of the HTTP client.
abstract class SyncApi {
  Future<PlaythroughEnvelope> createPlaythrough({required String seasonId});
  Future<ChoiceSyncOutcome> recordChoice({
    required String playthroughId,
    required String vignetteId,
    required String choiceId,
    int? deliberationMs,
    DateTime? clientTimestamp,
  });
}

class ApiClient implements SyncApi {
  ApiClient({required this.baseUrl, Dio? dio})
      : _dio = dio ??
            Dio(
              BaseOptions(
                baseUrl: baseUrl,
                connectTimeout: const Duration(seconds: 5),
                receiveTimeout: const Duration(seconds: 10),
              ),
            ) {
    // Treat 4xx as data, not exceptions — the repositories need to
    // distinguish 404 (cache fallback / null) from 5xx (transient,
    // rethrow) and a Dio that throws on every non-2xx makes that
    // needlessly complicated. We apply this on the underlying Dio
    // unconditionally so test fixtures that hand us a configured Dio
    // get the same behaviour without having to remember the knob.
    _dio.options.validateStatus = (status) => status != null && status < 500;
  }

  final String baseUrl;
  final Dio _dio;

  Future<bool> healthz() async {
    final response = await _dio.get<Map<String, dynamic>>('/healthz');
    return response.statusCode == 200;
  }

  /// GET /content/seasons/{id}. Returns null on 404 so the caller can
  /// fall back to a cached copy; throws on any other transport error so
  /// the renderer can show a connection-lost banner.
  Future<Season?> getSeason(String id) async {
    final response =
        await _dio.get<Map<String, dynamic>>('/content/seasons/$id');
    if (response.statusCode == 404) {
      return null;
    }
    if (response.statusCode != 200) {
      throw DioException(
        requestOptions: response.requestOptions,
        response: response,
        message: 'Unexpected status ${response.statusCode} from getSeason',
      );
    }
    final body = response.data;
    if (body == null || body['season'] == null) {
      throw DioException(
        requestOptions: response.requestOptions,
        response: response,
        message: 'Malformed envelope from getSeason',
      );
    }
    return Season.fromJson(body['season'] as Map<String, dynamic>);
  }

  /// POST /playthroughs.
  ///
  /// Returns the server's response envelope. The sync worker is the only
  /// caller in M1; the renderer never invokes this directly.
  ///
  /// Throws [SyncTransient] on 5xx / network failure, [SyncUnauthorized]
  /// on 401/403, [SyncFatal] on any other unexpected status. This is the
  /// classification the worker expects so it can decide whether to retry
  /// the row or drop it.
  @override
  Future<PlaythroughEnvelope> createPlaythrough({
    required String seasonId,
  }) async {
    final Response<Map<String, dynamic>> response;
    try {
      response = await _dio.post<Map<String, dynamic>>(
        '/playthroughs',
        data: <String, dynamic>{'season_id': seasonId},
      );
    } on DioException catch (e) {
      throw SyncTransient('createPlaythrough network error: ${e.message}');
    }
    final status = response.statusCode ?? 0;
    if (status == 401 || status == 403) {
      throw SyncUnauthorized(
        'createPlaythrough returned $status (auth required)',
      );
    }
    if (status != 201 && status != 200) {
      throw SyncFatal(
        'createPlaythrough returned $status (body: ${response.data})',
      );
    }
    final body = response.data;
    if (body == null || body['playthrough'] == null) {
      throw const SyncFatal('createPlaythrough returned malformed envelope');
    }
    return PlaythroughEnvelope.fromJson(
      body['playthrough'] as Map<String, dynamic>,
    );
  }

  /// POST /playthroughs/{id}/choices. Returns the server-recorded choice
  /// event on success.
  ///
  /// Translates the server's HTTP status into a [ChoiceSyncOutcome]:
  ///   * 200 -> accepted (new or idempotent replay)
  ///   * 409 -> conflict (same vignette already has a different choice on
  ///     the server — the server is authoritative; we drop the local row)
  ///   * 400/404 -> fatal (malformed request or unknown playthrough)
  ///   * 401/403 -> [SyncUnauthorized]
  ///   * 5xx / network -> [SyncTransient]
  @override
  Future<ChoiceSyncOutcome> recordChoice({
    required String playthroughId,
    required String vignetteId,
    required String choiceId,
    int? deliberationMs,
    DateTime? clientTimestamp,
  }) async {
    final body = <String, dynamic>{
      'vignette_id': vignetteId,
      'choice_id': choiceId,
      if (deliberationMs != null) 'deliberation_ms': deliberationMs,
      if (clientTimestamp != null)
        'client_timestamp': clientTimestamp.toUtc().toIso8601String(),
    };
    final Response<Map<String, dynamic>> response;
    try {
      response = await _dio.post<Map<String, dynamic>>(
        '/playthroughs/$playthroughId/choices',
        data: body,
      );
    } on DioException catch (e) {
      throw SyncTransient('recordChoice network error: ${e.message}');
    }
    final status = response.statusCode ?? 0;
    switch (status) {
      case 200:
      case 201:
        return ChoiceSyncOutcome.accepted;
      case 409:
        return ChoiceSyncOutcome.conflict;
      case 400:
      case 404:
        throw SyncFatal(
          'recordChoice returned $status for $playthroughId/$vignetteId',
        );
      case 401:
      case 403:
        throw SyncUnauthorized(
          'recordChoice returned $status (auth required)',
        );
      default:
        throw SyncFatal(
          'recordChoice returned unexpected status $status',
        );
    }
  }

  Dio get raw => _dio;
}

/// Server playthrough envelope as returned by POST /playthroughs.
class PlaythroughEnvelope {
  const PlaythroughEnvelope({
    required this.id,
    required this.seasonId,
    required this.seasonVersion,
    required this.status,
  });

  factory PlaythroughEnvelope.fromJson(Map<String, dynamic> json) {
    return PlaythroughEnvelope(
      id: json['id'] as String,
      seasonId: json['season_id'] as String,
      seasonVersion: (json['season_version'] as num).toInt(),
      status: json['status'] as String,
    );
  }

  final String id;
  final String seasonId;
  final int seasonVersion;
  final String status;
}

/// Three-valued classification of POST /choices outcomes — see [ApiClient.recordChoice].
enum ChoiceSyncOutcome { accepted, conflict }

/// Marker exception type the sync worker uses to decide whether to keep a
/// pending row in the queue or drop it.
sealed class SyncException implements Exception {
  const SyncException(this.message);
  final String message;

  @override
  String toString() => '$runtimeType: $message';
}

/// Network or 5xx — the caller should keep the row and retry later.
class SyncTransient extends SyncException {
  const SyncTransient(super.message);
}

/// The server rejected the request because we lack credentials. The
/// queue should not be drained until the user authenticates (or until
/// PR 9's auth flow is in place).
class SyncUnauthorized extends SyncException {
  const SyncUnauthorized(super.message);
}

/// The row will never succeed — drop it.
class SyncFatal extends SyncException {
  const SyncFatal(super.message);
}

/// Override `apiBaseUrlProvider` in tests / per-flavour bootstrap to point
/// the client at a local or staging gateway. The default is the local
/// `services/core-go` listener defined in the repo's docker-compose.
final Provider<String> apiBaseUrlProvider = Provider<String>((Ref ref) {
  return 'http://localhost:8080';
});

final Provider<ApiClient> apiClientProvider = Provider<ApiClient>((Ref ref) {
  return ApiClient(baseUrl: ref.watch(apiBaseUrlProvider));
});
