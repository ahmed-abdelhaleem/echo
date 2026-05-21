// ContentRepository: network-first with cache fallback.

import 'dart:io';

import 'package:dio/dio.dart';
import 'package:echo_client/data/content_repository.dart';
import 'package:echo_client/data/local/database.dart';
import 'package:echo_client/services/api_client.dart';
import 'package:flutter_test/flutter_test.dart';

import '../_helpers/fakes.dart';

class _ScriptedAdapter implements HttpClientAdapter {
  _ScriptedAdapter(this.responses);

  /// Each invocation pops the head of [responses] and returns it.
  final List<_Resp> responses;
  final List<RequestOptions> calls = <RequestOptions>[];

  @override
  void close({bool force = false}) {}

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<List<int>>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    calls.add(options);
    if (responses.isEmpty) {
      throw StateError('No more scripted responses');
    }
    final r = responses.removeAt(0);
    if (r.throws != null) {
      throw r.throws!;
    }
    return ResponseBody.fromString(
      r.body!,
      r.status!,
      headers: <String, List<String>>{
        HttpHeaders.contentTypeHeader: <String>['application/json'],
      },
    );
  }
}

class _Resp {
  _Resp.ok(this.status, this.body) : throws = null;
  _Resp.fail(DioException ex)
      : status = null,
        body = null,
        throws = ex;
  final int? status;
  final String? body;
  final DioException? throws;
}

void main() {
  late EchoDatabase db;

  setUp(() {
    db = newInMemoryDatabase();
  });

  tearDown(() async {
    await db.close();
  });

  String envelopeFor(String id) => '''
{
  "season": {
    "id": "$id",
    "title": "Smoke",
    "locale": "en-GB",
    "version": 1,
    "description": "Fixture",
    "acts": [
      {
        "id": "act-1",
        "name": "Morning",
        "vignettes": [
          {
            "id": "v-1",
            "setting_beat": "Hello.",
            "choices": [
              {
                "id": "c-1",
                "label": "Yes.",
                "weights": [
                  { "dimension": "OCEAN-O", "delta": 0.1 }
                ]
              }
            ]
          }
        ]
      }
    ]
  }
}
''';

  test('200 -> hydrates and caches; subsequent network failure -> cache hit',
      () async {
    final adapter = _ScriptedAdapter(<_Resp>[
      _Resp.ok(200, envelopeFor('season-001')),
      _Resp.fail(
        DioException.connectionError(
          requestOptions: RequestOptions(path: '/content/seasons/season-001'),
          reason: 'offline',
        ),
      ),
    ]);
    final dio = Dio()..httpClientAdapter = adapter;
    final api = ApiClient(baseUrl: 'http://example.test', dio: dio);
    final repo = ContentRepository(api: api, db: db);

    final s1 = await repo.getSeason('season-001');
    expect(s1, isNotNull);
    expect(s1!.id, 'season-001');
    expect(s1.flatVignettes.single.settingBeat, 'Hello.');

    // The next call simulates an outage. We should still get the season
    // back from the cache.
    final s2 = await repo.getSeason('season-001');
    expect(s2, isNotNull);
    expect(s2!.flatVignettes.single.settingBeat, 'Hello.');
    expect(adapter.calls, hasLength(2));

  });

  test('404 returns null without populating the cache', () async {
    final adapter = _ScriptedAdapter(<_Resp>[
      _Resp.ok(404, '{"error":"not found"}'),
    ]);
    final dio = Dio()..httpClientAdapter = adapter;
    final api = ApiClient(baseUrl: 'http://example.test', dio: dio);
    final repo = ContentRepository(api: api, db: db);

    final s = await repo.getSeason('season-404');
    expect(s, isNull);

    // Cache untouched.
    final cached = await db.findCachedSeason('season-404');
    expect(cached, isNull);
  });

  test('network failure with no cache rethrows', () async {
    final adapter = _ScriptedAdapter(<_Resp>[
      _Resp.fail(
        DioException.connectionError(
          requestOptions: RequestOptions(path: '/content/seasons/x'),
          reason: 'offline',
        ),
      ),
    ]);
    final dio = Dio()..httpClientAdapter = adapter;
    final api = ApiClient(baseUrl: 'http://example.test', dio: dio);
    final repo = ContentRepository(api: api, db: db);

    await expectLater(repo.getSeason('x'), throwsA(isA<DioException>()));

  });
}
