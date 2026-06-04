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

  /// POST /playthroughs/{id}/share. Returns a [SharePayload] with the
  /// public share URL + the public portrait endpoint URLs.
  ///
  /// Auth required. The server enforces the youth-safe / ownership /
  /// completeness gates; this client only translates wire status codes
  /// into typed outcomes so the controller can render the right UX.
  Future<SharePayload> createShare({required String playthroughId}) async {
    final response = await _dio.post<Map<String, dynamic>>(
      '/playthroughs/$playthroughId/share',
    );
    final status = response.statusCode ?? 0;
    if (status == 401) {
      throw ShareUnauthorised();
    }
    if (status == 403) {
      // Sharing is disabled for youth-safe accounts. The button
      // shouldn't have been visible — but the server is the source of
      // truth so we still need to surface this in case the client
      // state was stale.
      throw ShareForbidden();
    }
    if (status == 404) {
      throw ShareNotFound();
    }
    if (status == 409) {
      throw SharePlaythroughIncomplete();
    }
    if (status != 201) {
      throw DioException(
        requestOptions: response.requestOptions,
        response: response,
        message: 'Unexpected status $status from createShare',
      );
    }
    final body = response.data;
    if (body == null) {
      throw DioException(
        requestOptions: response.requestOptions,
        response: response,
        message: 'Empty body from createShare',
      );
    }
    return SharePayload.fromJson(body);
  }

  /// DELETE /share/{token}. Idempotent — server returns 204 on first
  /// call and on any subsequent call too.
  Future<void> revokeShare({required String token}) async {
    final response = await _dio.delete<void>('/share/$token');
    final status = response.statusCode ?? 0;
    if (status == 401) {
      throw ShareUnauthorised();
    }
    if (status == 404) {
      throw ShareNotFound();
    }
    if (status != 204) {
      throw DioException(
        requestOptions: response.requestOptions,
        response: response,
        message: 'Unexpected status $status from revokeShare',
      );
    }
  }

  /// GET on an arbitrary URL the server already vended (the portrait
  /// PNG / WebP endpoints). Returns raw bytes; the controller then
  /// hands them to the system share sheet. Implemented here so the
  /// share controller doesn't have to own a second Dio instance.
  Future<List<int>> fetchBytes(String url) async {
    final response = await _dio.get<List<int>>(
      url,
      options: Options(
        responseType: ResponseType.bytes,
        validateStatus: (s) => s != null && s < 500,
      ),
    );
    final status = response.statusCode ?? 0;
    if (status != 200) {
      throw DioException(
        requestOptions: response.requestOptions,
        response: response,
        message: 'Unexpected status $status from fetchBytes($url)',
      );
    }
    final data = response.data;
    if (data == null) {
      throw DioException(
        requestOptions: response.requestOptions,
        response: response,
        message: 'Empty body from fetchBytes($url)',
      );
    }
    return data;
  }

  /// POST /compare/accept. Binds the caller's completed playthrough to
  /// an invite token minted by another user.
  Future<void> acceptComparisonInvite({
    required String token,
    required String playthroughId,
  }) async {
    final response = await _dio.post<Map<String, dynamic>>(
      '/compare/accept',
      data: <String, dynamic>{
        'token': token,
        'playthrough_id': playthroughId,
      },
    );
    final status = response.statusCode ?? 0;
    if (status == 401) {
      throw CompareUnauthorised();
    }
    if (status == 403) {
      throw CompareForbidden();
    }
    if (status == 404) {
      throw CompareNotFound();
    }
    if (status == 409) {
      throw CompareConflict();
    }
    if (status == 410) {
      throw CompareExpired();
    }
    if (status != 200) {
      throw DioException(
        requestOptions: response.requestOptions,
        response: response,
        message: 'Unexpected status $status from acceptComparisonInvite',
      );
    }
  }

  /// GET /compare/{token}. Public payload used by client + share-web.
  Future<ComparisonPublicPayload> getComparisonPublic({
    required String token,
  }) async {
    final response = await _dio.get<Map<String, dynamic>>('/compare/$token');
    final status = response.statusCode ?? 0;
    if (status == 404) {
      throw CompareNotFound();
    }
    if (status == 409) {
      throw CompareConflict();
    }
    if (status == 410) {
      throw CompareExpired();
    }
    if (status != 200) {
      throw DioException(
        requestOptions: response.requestOptions,
        response: response,
        message: 'Unexpected status $status from getComparisonPublic',
      );
    }
    final body = response.data;
    if (body == null) {
      throw DioException(
        requestOptions: response.requestOptions,
        response: response,
        message: 'Empty body from getComparisonPublic',
      );
    }
    return ComparisonPublicPayload.fromJson(body);
  }

  /// POST /compare/{token}/share-enable. Requires auth and ownership.
  Future<ComparisonSharePayload> enableComparisonShare({
    required String token,
  }) async {
    final response =
        await _dio.post<Map<String, dynamic>>('/compare/$token/share-enable');
    final status = response.statusCode ?? 0;
    if (status == 401) {
      throw CompareUnauthorised();
    }
    if (status == 403) {
      throw CompareForbidden();
    }
    if (status == 404) {
      throw CompareNotFound();
    }
    if (status == 409) {
      throw CompareConflict();
    }
    if (status != 200) {
      throw DioException(
        requestOptions: response.requestOptions,
        response: response,
        message: 'Unexpected status $status from enableComparisonShare',
      );
    }
    final body = response.data;
    if (body == null) {
      throw DioException(
        requestOptions: response.requestOptions,
        response: response,
        message: 'Empty body from enableComparisonShare',
      );
    }
    return ComparisonSharePayload.fromJson(body);
  }

  /// DELETE /compare/{token}. Revokes the comparison for both participants.
  Future<void> revokeComparison({required String token}) async {
    final response = await _dio.delete<void>('/compare/$token');
    final status = response.statusCode ?? 0;
    if (status == 401) {
      throw CompareUnauthorised();
    }
    if (status == 404) {
      throw CompareNotFound();
    }
    if (status != 204) {
      throw DioException(
        requestOptions: response.requestOptions,
        response: response,
        message: 'Unexpected status $status from revokeComparison',
      );
    }
  }

  /// POST /playthroughs/{id}/finalize. Returns the trait vector as a map.
  Future<Map<String, dynamic>> finalizePlaythrough({
    required String playthroughId,
  }) async {
    final response = await _dio.post<Map<String, dynamic>>(
      '/playthroughs/$playthroughId/finalize',
    );
    final status = response.statusCode ?? 0;
    if (status != 200) {
      throw DioException(
        requestOptions: response.requestOptions,
        response: response,
        message: 'Unexpected status $status from finalizePlaythrough',
      );
    }
    final body = response.data;
    if (body == null || body['trait_vector'] == null) {
      throw DioException(
        requestOptions: response.requestOptions,
        response: response,
        message: 'Malformed envelope from finalizePlaythrough',
      );
    }
    return body['trait_vector'] as Map<String, dynamic>;
  }

  /// GET /playthroughs/{id}/reflection. Returns the reflection text.
  Future<String> getReflection({
    required String playthroughId,
  }) async {
    final response = await _dio.get<Map<String, dynamic>>(
      '/playthroughs/$playthroughId/reflection',
    );
    final status = response.statusCode ?? 0;
    if (status != 200) {
      throw DioException(
        requestOptions: response.requestOptions,
        response: response,
        message: 'Unexpected status $status from getReflection',
      );
    }
    final body = response.data;
    if (body == null || body['reflection'] == null) {
      throw DioException(
        requestOptions: response.requestOptions,
        response: response,
        message: 'Malformed envelope from getReflection',
      );
    }
    return body['reflection']['text'] as String;
  }

  /// GET /playthroughs/{id}/portrait. Returns the image bytes.
  Future<List<int>> getPortraitBytes({
    required String playthroughId,
    bool animate = false,
  }) async {
    final format = animate ? 'webp' : 'png';
    final response = await _dio.get<List<int>>(
      '/playthroughs/$playthroughId/portrait',
      queryParameters: <String, dynamic>{'format': format},
      options: Options(
        responseType: ResponseType.bytes,
        validateStatus: (s) => s != null && s < 500,
      ),
    );
    final status = response.statusCode ?? 0;
    if (status != 200) {
      throw DioException(
        requestOptions: response.requestOptions,
        response: response,
        message: 'Unexpected status $status from getPortraitBytes',
      );
    }
    final data = response.data;
    if (data == null) {
      throw DioException(
        requestOptions: response.requestOptions,
        response: response,
        message: 'Empty body from getPortraitBytes',
      );
    }
    return data;
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

/// Wire shape of the response to POST /playthroughs/{id}/share. The
/// server returns the public-facing URL + the two portrait-asset URLs
/// the share sheet will embed. Kept structurally aligned with
/// `services/core-go/http/sharing.go::shareCreateResponse`.
class SharePayload {
  const SharePayload({
    required this.token,
    required this.playthroughId,
    required this.shareUrl,
    required this.portraitPngUrl,
    required this.portraitWebpUrl,
    required this.createdAt,
  });

  factory SharePayload.fromJson(Map<String, dynamic> json) {
    return SharePayload(
      token: json['token'] as String,
      playthroughId: json['playthrough_id'] as String,
      shareUrl: json['share_url'] as String,
      portraitPngUrl: json['portrait_png_url'] as String,
      portraitWebpUrl: json['portrait_webp_url'] as String,
      createdAt: json['created_at'] as String,
    );
  }

  final String token;
  final String playthroughId;
  final String shareUrl;
  final String portraitPngUrl;
  final String portraitWebpUrl;
  final String createdAt;
}

/// Marker exceptions for the share flow. The controller catches each
/// distinct case to render the right surface (auth-expired toast,
/// youth-safe lockout, server lag).
class ShareUnauthorised implements Exception {}

class ShareForbidden implements Exception {}

class ShareNotFound implements Exception {}

class SharePlaythroughIncomplete implements Exception {}

class ComparisonPublicPayload {
  const ComparisonPublicPayload({
    required this.seasonId,
    required this.status,
    required this.vignetteId,
    required this.inviterChoice,
    required this.inviteeChoice,
    required this.inviterPngUrl,
    required this.inviteePngUrl,
  });

  factory ComparisonPublicPayload.fromJson(Map<String, dynamic> json) {
    final divergence = json['divergence'];
    if (divergence is! Map<String, dynamic>) {
      throw const FormatException('missing divergence in comparison payload');
    }
    return ComparisonPublicPayload(
      seasonId: json['season_id'] as String,
      status: json['status'] as String,
      vignetteId: divergence['vignette_id'] as String,
      inviterChoice: divergence['inviter_choice'] as String,
      inviteeChoice: divergence['invitee_choice'] as String,
      inviterPngUrl: json['inviter_png_url'] as String,
      inviteePngUrl: json['invitee_png_url'] as String,
    );
  }

  final String seasonId;
  final String status;
  final String vignetteId;
  final String inviterChoice;
  final String inviteeChoice;
  final String inviterPngUrl;
  final String inviteePngUrl;
}

class ComparisonSharePayload {
  const ComparisonSharePayload({
    required this.shareToken,
    required this.shareUrl,
  });

  factory ComparisonSharePayload.fromJson(Map<String, dynamic> json) {
    return ComparisonSharePayload(
      shareToken: json['share_token'] as String,
      shareUrl: json['share_url'] as String,
    );
  }

  final String shareToken;
  final String shareUrl;
}

class CompareUnauthorised implements Exception {}

class CompareForbidden implements Exception {}

class CompareNotFound implements Exception {}

class CompareConflict implements Exception {}

class CompareExpired implements Exception {}

/// Override `apiBaseUrlProvider` in tests / per-flavour bootstrap to point
/// the client at a local or staging gateway. The default is the local
/// `services/core-go` listener defined in the repo's docker-compose.
final Provider<String> apiBaseUrlProvider = Provider<String>((Ref ref) {
  // Default matches `.env.example` `CORE_HTTP_ADDR` (:8081). Port 8080 is
  // commonly occupied by local nginx; override via ProviderScope in tests.
  return 'http://localhost:8081';
});

final Provider<ApiClient> apiClientProvider = Provider<ApiClient>((Ref ref) {
  return ApiClient(baseUrl: ref.watch(apiBaseUrlProvider));
});
