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

  Dio get raw => _dio;
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
