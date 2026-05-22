// Tests for the M1 playthrough endpoints on [ApiClient].
//
// We focus on the wire-format / branching behaviour:
//   * 201 → typed RemotePlaythrough
//   * 401 / 403 → typed exceptions
//   * 200 / 404 / 409 / 401 from recordChoice → typed RecordChoiceOutcome

import 'package:dio/dio.dart';
import 'package:echo_client/services/api_client.dart';
import 'package:flutter_test/flutter_test.dart';

import '../_helpers/fakes.dart';

void main() {
  group('ApiClient.createPlaythrough', () {
    test('parses 201 envelope into RemotePlaythrough', () async {
      final adapter = ProgrammableAdapter()
        ..registerJson(
          method: 'POST',
          path: RegExp(r'^/playthroughs$'),
          status: 201,
          body: <String, dynamic>{
            'playthrough': <String, dynamic>{
              'id': 'pt-1',
              'user_id': 'user-1',
              'season_id': 'season-001',
              'season_version': 3,
              'status': 'in_progress',
              'started_at': '2026-05-21T10:00:00Z',
              'created_at': '2026-05-21T10:00:00Z',
              'updated_at': '2026-05-21T10:00:00Z',
            },
          },
        );

      final client = apiClientWith(adapter);
      final pt = await client.createPlaythrough(seasonId: 'season-001');

      expect(pt.id, 'pt-1');
      expect(pt.seasonId, 'season-001');
      expect(pt.seasonVersion, 3);
    });

    test('401 surfaces as CreatePlaythroughUnauthorised', () async {
      final adapter = ProgrammableAdapter()
        ..registerJson(
          method: 'POST',
          path: RegExp(r'^/playthroughs$'),
          status: 401,
          body: <String, dynamic>{'error': 'unauthenticated'},
        );

      final client = apiClientWith(adapter);
      await expectLater(
        client.createPlaythrough(seasonId: 'season-001'),
        throwsA(isA<CreatePlaythroughUnauthorised>()),
      );
    });

    test('403 surfaces as CreatePlaythroughForbidden', () async {
      final adapter = ProgrammableAdapter()
        ..registerJson(
          method: 'POST',
          path: RegExp(r'^/playthroughs$'),
          status: 403,
          body: <String, dynamic>{'error': 'ineligible'},
        );

      final client = apiClientWith(adapter);
      await expectLater(
        client.createPlaythrough(seasonId: 'season-001'),
        throwsA(isA<CreatePlaythroughForbidden>()),
      );
    });

    test('5xx throws DioException', () async {
      final adapter = ProgrammableAdapter()
        ..registerJson(
          method: 'POST',
          path: RegExp(r'^/playthroughs$'),
          status: 503,
          body: <String, dynamic>{'error': 'unavailable'},
        );

      final client = apiClientWith(adapter);
      await expectLater(
        client.createPlaythrough(seasonId: 'season-001'),
        throwsA(isA<DioException>()),
      );
    });
  });

  group('ApiClient.recordChoice', () {
    test('200 maps to accepted', () async {
      final adapter = ProgrammableAdapter()
        ..registerJson(
          method: 'POST',
          path: RegExp(r'^/playthroughs/pt-1/choices$'),
          status: 200,
          body: <String, dynamic>{'choice_event': <String, dynamic>{}},
        );

      final client = apiClientWith(adapter);
      final outcome = await client.recordChoice(
        playthroughId: 'pt-1',
        vignetteId: 'v-1',
        choiceId: 'c-1',
      );

      expect(outcome, RecordChoiceOutcome.accepted);
    });

    test('409 maps to conflict', () async {
      final adapter = ProgrammableAdapter()
        ..registerJson(
          method: 'POST',
          path: RegExp(r'^/playthroughs/pt-1/choices$'),
          status: 409,
          body: <String, dynamic>{'error': 'conflict'},
        );

      final client = apiClientWith(adapter);
      expect(
        await client.recordChoice(
          playthroughId: 'pt-1',
          vignetteId: 'v-1',
          choiceId: 'c-1',
        ),
        RecordChoiceOutcome.conflict,
      );
    });

    test('404 maps to notFound', () async {
      final adapter = ProgrammableAdapter()
        ..registerJson(
          method: 'POST',
          path: RegExp(r'^/playthroughs/pt-1/choices$'),
          status: 404,
          body: <String, dynamic>{'error': 'not found'},
        );

      final client = apiClientWith(adapter);
      expect(
        await client.recordChoice(
          playthroughId: 'pt-1',
          vignetteId: 'v-1',
          choiceId: 'c-1',
        ),
        RecordChoiceOutcome.notFound,
      );
    });

    test('401 maps to unauthorised', () async {
      final adapter = ProgrammableAdapter()
        ..registerJson(
          method: 'POST',
          path: RegExp(r'^/playthroughs/pt-1/choices$'),
          status: 401,
          body: <String, dynamic>{'error': 'unauthenticated'},
        );

      final client = apiClientWith(adapter);
      expect(
        await client.recordChoice(
          playthroughId: 'pt-1',
          vignetteId: 'v-1',
          choiceId: 'c-1',
        ),
        RecordChoiceOutcome.unauthorised,
      );
    });

    test('500 throws DioException', () async {
      final adapter = ProgrammableAdapter()
        ..registerJson(
          method: 'POST',
          path: RegExp(r'^/playthroughs/pt-1/choices$'),
          status: 500,
          body: <String, dynamic>{'error': 'oops'},
        );

      final client = apiClientWith(adapter);
      await expectLater(
        client.recordChoice(
          playthroughId: 'pt-1',
          vignetteId: 'v-1',
          choiceId: 'c-1',
        ),
        throwsA(isA<DioException>()),
      );
    });
  });
}
