// Test doubles for the M1 vignette renderer (T-CLIENT-010/011) and
// background sync (T-CLIENT-012).
//
// We keep the fakes hand-rolled rather than reaching for mockito so the
// behaviour under test stays obvious in the assertions. Production code
// is small enough that the marginal benefit of a mocking framework is
// negative.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:echo_client/data/choice_repository.dart';
import 'package:echo_client/data/content_repository.dart';
import 'package:echo_client/data/local/database.dart';
import 'package:echo_client/data/models/content.dart';
import 'package:echo_client/data/playthrough_repository.dart';
import 'package:echo_client/features/vignette/vignette_controller.dart';
import 'package:echo_client/services/api_client.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// In-memory Drift database — used by repository and widget tests.
EchoDatabase newInMemoryDatabase() {
  return EchoDatabase(NativeDatabase.memory());
}

/// In-memory [ContentRepository] that returns the provided [seasons] and
/// records each [getSeason] call for assertions.
class FakeContentRepository implements ContentRepository {
  FakeContentRepository(this.seasons);

  final Map<String, Season> seasons;
  final List<String> calls = <String>[];

  @override
  Future<Season?> getSeason(String id) async {
    calls.add(id);
    return seasons[id];
  }
}

/// Builds a Season with a single act and the provided vignettes. Useful
/// for keeping tests terse.
Season seasonWithVignettes({
  String id = 'season-test',
  String title = 'Test Season',
  List<Vignette>? vignettes,
}) {
  final list = vignettes ??
      <Vignette>[
        const Vignette(
          id: 'v-1',
          settingBeat: 'The first scene begins.',
          choices: <Choice>[
            Choice(
              id: 'c-1a',
              label: 'Stay quiet.',
              weights: <TraitWeight>[
                TraitWeight(dimension: 'OCEAN-O', delta: 0.1),
              ],
            ),
            Choice(
              id: 'c-1b',
              label: 'Speak up.',
              weights: <TraitWeight>[
                TraitWeight(dimension: 'OCEAN-E', delta: 0.1),
              ],
            ),
          ],
          resolutionBeats: <String, String>{
            'c-1a': 'You held your tongue.',
            'c-1b': 'Your voice cut through.',
          },
        ),
        const Vignette(
          id: 'v-2',
          settingBeat: 'The second scene unfolds.',
          choices: <Choice>[
            Choice(
              id: 'c-2a',
              label: 'Help.',
              weights: <TraitWeight>[
                TraitWeight(dimension: 'OCEAN-A', delta: 0.1),
              ],
            ),
            Choice(
              id: 'c-2b',
              label: 'Walk on.',
              weights: <TraitWeight>[
                TraitWeight(dimension: 'OCEAN-A', delta: -0.1),
              ],
            ),
          ],
        ),
      ];
  return Season(
    id: id,
    title: title,
    locale: 'en-GB',
    version: 1,
    description: 'Fixture',
    acts: <Act>[
      Act(id: 'act-1', name: 'Morning', vignettes: list),
    ],
  );
}

/// Builds a fresh ProviderScope override list backed by:
///   * an in-memory [EchoDatabase],
///   * a [FakeContentRepository] holding [seasons].
/// The disposing of the DB is owned by the caller via [onDispose] hooks.
List<Override> testOverrides({
  required Map<String, Season> seasons,
  EchoDatabase? db,
  DateTime Function()? now,
}) {
  final database = db ?? newInMemoryDatabase();
  return <Override>[
    echoDatabaseProvider.overrideWith((Ref ref) {
      ref.onDispose(database.close);
      return database;
    }),
    contentRepositoryProvider.overrideWith((Ref ref) {
      return FakeContentRepository(seasons);
    }),
    choiceRepositoryProvider.overrideWith((Ref ref) {
      return ChoiceRepository(
        db: ref.watch(echoDatabaseProvider),
        now: now ?? DateTime.now,
      );
    }),
    playthroughRepositoryProvider.overrideWith((Ref ref) {
      return PlaythroughRepository(
        db: ref.watch(echoDatabaseProvider),
        now: now ?? DateTime.now,
      );
    }),
  ];
}

/// A simple "advance by N ms each call" clock — handy for deterministic
/// deliberation_ms measurements.
class StepClock {
  StepClock(this._initial, this._step);

  DateTime _initial;
  final Duration _step;

  DateTime now() {
    final t = _initial;
    _initial = _initial.add(_step);
    return t;
  }
}

/// Awaits microtask flush — convenient when [VignetteController.start]
/// kicks off a Future and we want the resulting state transition before
/// asserting.
Future<void> flushMicrotasks() => Future<void>(() {});

/// Programmable HTTP adapter for unit tests against the real
/// [ApiClient]. Caller registers handlers per (method, path-pattern) and
/// the adapter dispatches the first match. Default behaviour for an
/// unmatched request is 500 — the loud failure makes a missing fixture
/// obvious in the test output.
class ProgrammableAdapter implements HttpClientAdapter {
  ProgrammableAdapter();

  final List<_Route> _routes = <_Route>[];
  final List<RecordedRequest> recorded = <RecordedRequest>[];

  void register({
    required String method,
    required RegExp path,
    required Future<Reply> Function(RequestOptions, String) handler,
  }) {
    _routes.add(_Route(method: method, path: path, handler: handler));
  }

  void registerJson({
    required String method,
    required RegExp path,
    required int status,
    Map<String, dynamic>? body,
  }) {
    register(
      method: method,
      path: path,
      handler: (req, raw) async {
        return Reply(
          status: status,
          body: body == null ? '' : jsonEncode(body),
        );
      },
    );
  }

  @override
  void close({bool force = false}) {}

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<List<int>>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final rawBody =
        requestStream == null ? '' : await utf8.decodeStream(requestStream);
    recorded.add(
      RecordedRequest(
        method: options.method.toUpperCase(),
        path: options.path,
        body: rawBody,
      ),
    );
    for (final route in _routes) {
      if (route.method.toUpperCase() != options.method.toUpperCase()) continue;
      if (!route.path.hasMatch(options.path)) continue;
      final reply = await route.handler(options, rawBody);
      return ResponseBody.fromString(
        reply.body,
        reply.status,
        headers: <String, List<String>>{
          HttpHeaders.contentTypeHeader: <String>['application/json'],
        },
      );
    }
    return ResponseBody.fromString(
      '{"error":"no fixture for ${options.method} ${options.path}"}',
      500,
      headers: <String, List<String>>{
        HttpHeaders.contentTypeHeader: <String>['application/json'],
      },
    );
  }
}

class _Route {
  _Route({
    required this.method,
    required this.path,
    required this.handler,
  });
  final String method;
  final RegExp path;
  final Future<Reply> Function(RequestOptions, String) handler;
}

/// A canned HTTP reply for [ProgrammableAdapter]. Public so test
/// fixtures can hand-roll replies (eg sequential 503-then-200 retries).
class Reply {
  Reply({required this.status, required this.body});
  final int status;
  final String body;
}

class RecordedRequest {
  RecordedRequest({
    required this.method,
    required this.path,
    required this.body,
  });
  final String method;
  final String path;
  final String body;
}

/// Builds an [ApiClient] with a Dio wired to [adapter]. Useful when a
/// test wants to exercise the real client code paths.
ApiClient apiClientWith(ProgrammableAdapter adapter, {String? baseUrl}) {
  final dio = Dio(BaseOptions(baseUrl: baseUrl ?? 'http://test'))
    ..httpClientAdapter = adapter;
  return ApiClient(baseUrl: baseUrl ?? 'http://test', dio: dio);
}
