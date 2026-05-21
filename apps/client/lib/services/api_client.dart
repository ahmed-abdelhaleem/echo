// Thin Dio wrapper. Future PRs add interceptors for auth (T-CORE-020/021),
// retries (T-CLIENT-016), and OTel propagation (T-INFRA-040). Keeping the
// surface small in M0 so dependent code doesn't proliferate before the
// contract is firm.

import 'package:dio/dio.dart';
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
            );

  final String baseUrl;
  final Dio _dio;

  Future<bool> healthz() async {
    final response = await _dio.get<Map<String, dynamic>>('/healthz');
    return response.statusCode == 200;
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
