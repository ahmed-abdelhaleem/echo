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

class ApiClient {
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

  /// POST /playthroughs. Opens a server-side playthrough and returns the
  /// server-assigned id (along with the season version captured at
  /// creation time).
  ///
  /// Throws on any non-2xx so the sync caller can branch on the kind of
  /// failure (auth, transient, fatal). 401 is exposed as
  /// [CreatePlaythroughUnauthorised] so the sync can stop without
  /// retrying.
  Future<RemotePlaythrough> createPlaythrough({
    required String seasonId,
  }) async {
    final response = await _dio.post<Map<String, dynamic>>(
      '/playthroughs',
      data: <String, dynamic>{'season_id': seasonId},
    );
    final status = response.statusCode ?? 0;
    if (status == 401) {
      throw CreatePlaythroughUnauthorised();
    }
    if (status == 403) {
      throw CreatePlaythroughForbidden();
    }
    if (status != 201) {
      throw DioException(
        requestOptions: response.requestOptions,
        response: response,
        message: 'Unexpected status $status from createPlaythrough',
      );
    }
    final body = response.data;
    final p = body?['playthrough'];
    if (p is! Map<String, dynamic>) {
      throw DioException(
        requestOptions: response.requestOptions,
        response: response,
        message: 'Malformed envelope from createPlaythrough',
      );
    }
    return RemotePlaythrough.fromJson(p);
  }

  /// POST /playthroughs/{id}/choices. Returns a [RecordChoiceOutcome]
  /// the sync uses to decide whether to delete the local row (success or
  /// idempotent), surface a conflict (409 — different choice persisted),
  /// or keep the row for a later retry (5xx / transport).
  Future<RecordChoiceOutcome> recordChoice({
    required String playthroughId,
    required String vignetteId,
    required String choiceId,
    DateTime? clientTimestamp,
    int? deliberationMs,
  }) async {
    final response = await _dio.post<Map<String, dynamic>>(
      '/playthroughs/$playthroughId/choices',
      data: <String, dynamic>{
        'vignette_id': vignetteId,
        'choice_id': choiceId,
        if (clientTimestamp != null)
          'client_timestamp': clientTimestamp.toUtc().toIso8601String(),
        if (deliberationMs != null) 'deliberation_ms': deliberationMs,
      },
    );
    final status = response.statusCode ?? 0;
    switch (status) {
      case 200:
        return RecordChoiceOutcome.accepted;
      case 401:
        return RecordChoiceOutcome.unauthorised;
      case 404:
        // Playthrough id unknown to the server — could happen if the
        // server-side row was rolled back, or if we synced with the
        // wrong identity. Treat as fatal for this row.
        return RecordChoiceOutcome.notFound;
      case 409:
        return RecordChoiceOutcome.conflict;
      default:
        throw DioException(
          requestOptions: response.requestOptions,
          response: response,
          message: 'Unexpected status $status from recordChoice',
        );
    }
  }

  Dio get raw => _dio;
}

/// The subset of the server's playthrough payload the client needs to
/// remember locally. The trait vector / status / completion timestamps
/// land in a separate read later (PR 9+).
class RemotePlaythrough {
  const RemotePlaythrough({
    required this.id,
    required this.seasonId,
    required this.seasonVersion,
  });

  factory RemotePlaythrough.fromJson(Map<String, dynamic> json) {
    return RemotePlaythrough(
      id: json['id'] as String,
      seasonId: json['season_id'] as String,
      seasonVersion: (json['season_version'] as num).toInt(),
    );
  }

  final String id;
  final String seasonId;
  final int seasonVersion;
}

/// Outcomes of a recordChoice call. The sync logic switches on this
/// enum to decide whether to delete the local row, abort, or keep
/// retrying.
enum RecordChoiceOutcome {
  /// 200 — server accepted the choice (or returned the existing
  /// idempotent row). The local row should be deleted.
  accepted,

  /// 401 — session expired. Stop the drain; auth surface will recover.
  unauthorised,

  /// 404 — playthrough id unknown. Treat as fatal for this row; the
  /// sync deletes it to avoid a permanent retry loop.
  notFound,

  /// 409 — server already has a different choice for this vignette.
  /// The server is the source of truth. The sync deletes the local
  /// row and logs the divergence.
  conflict,
}

/// Marker exceptions for the createPlaythrough flow. Kept as classes
/// (not enum values) because they bubble up through Future.then and
/// the sync's per-row try/catch needs to discriminate them with
/// `on …` clauses.
class CreatePlaythroughUnauthorised implements Exception {}

class CreatePlaythroughForbidden implements Exception {}

/// Override `apiBaseUrlProvider` in tests / per-flavour bootstrap to point
/// the client at a local or staging gateway. The default is the local
/// `services/core-go` listener defined in the repo's docker-compose.
final Provider<String> apiBaseUrlProvider = Provider<String>((Ref ref) {
  return 'http://localhost:8080';
});

final Provider<ApiClient> apiClientProvider = Provider<ApiClient>((Ref ref) {
  return ApiClient(baseUrl: ref.watch(apiBaseUrlProvider));
});
