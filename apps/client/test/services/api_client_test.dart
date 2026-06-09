// ApiClient unit test using Dio's adapter override.

import 'dart:io';

import 'package:dio/dio.dart';
import 'package:echo_client/services/api_client.dart';
import 'package:flutter_test/flutter_test.dart';

class _StubAdapter implements HttpClientAdapter {
  _StubAdapter(this.status);

  final int status;

  @override
  void close({bool force = false}) {}

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<List<int>>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    return ResponseBody.fromString(
      '{"status":"ok"}',
      status,
      headers: <String, List<String>>{
        HttpHeaders.contentTypeHeader: <String>['application/json'],
      },
    );
  }
}

void main() {
  test('ApiClient.healthz returns true on 200', () async {
    final dio = Dio()..httpClientAdapter = _StubAdapter(200);
    final client = ApiClient(baseUrl: 'http://example.test', dio: dio);

    expect(await client.healthz(), isTrue);
  });
}
