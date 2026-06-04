import 'package:dio/dio.dart';
import 'package:echo_client/services/api_client.dart';
import 'package:flutter_test/flutter_test.dart';

import '../_helpers/fakes.dart';

void main() {
  group('ApiClient.getComparisonPublic', () {
    test('parses 200 payload', () async {
      final adapter = ProgrammableAdapter()
        ..registerJson(
          method: 'GET',
          path: RegExp(r'^/compare/tok-1$'),
          status: 200,
          body: <String, dynamic>{
            'season_id': 'season-001',
            'status': 'accepted',
            'divergence': <String, dynamic>{
              'vignette_id': 'v-001',
              'inviter_choice': 'c-a',
              'invitee_choice': 'c-b',
            },
            'inviter_png_url':
                'https://api.echo.test/compare/tok-1/portrait?side=inviter',
            'invitee_png_url':
                'https://api.echo.test/compare/tok-1/portrait?side=invitee',
          },
        );

      final client = apiClientWith(adapter);
      final payload = await client.getComparisonPublic(token: 'tok-1');

      expect(payload.seasonId, 'season-001');
      expect(payload.vignetteId, 'v-001');
      expect(payload.inviterChoice, 'c-a');
      expect(payload.inviteeChoice, 'c-b');
    });

    test('404 surfaces as CompareNotFound', () async {
      final adapter = ProgrammableAdapter()
        ..registerJson(
          method: 'GET',
          path: RegExp(r'^/compare/missing$'),
          status: 404,
          body: <String, dynamic>{'error': 'not found'},
        );

      final client = apiClientWith(adapter);
      await expectLater(
        client.getComparisonPublic(token: 'missing'),
        throwsA(isA<CompareNotFound>()),
      );
    });

    test('410 surfaces as CompareExpired', () async {
      final adapter = ProgrammableAdapter()
        ..registerJson(
          method: 'GET',
          path: RegExp(r'^/compare/expired$'),
          status: 410,
          body: <String, dynamic>{'error': 'expired'},
        );

      final client = apiClientWith(adapter);
      await expectLater(
        client.getComparisonPublic(token: 'expired'),
        throwsA(isA<CompareExpired>()),
      );
    });
  });

  group('ApiClient.acceptComparisonInvite', () {
    test('200 accepted resolves normally', () async {
      final adapter = ProgrammableAdapter()
        ..registerJson(
          method: 'POST',
          path: RegExp(r'^/compare/accept$'),
          status: 200,
          body: <String, dynamic>{'status': 'accepted'},
        );

      final client = apiClientWith(adapter);
      await client.acceptComparisonInvite(
        token: 'tok-1',
        playthroughId: 'pt-1',
      );
    });

    test('403 surfaces as CompareForbidden', () async {
      final adapter = ProgrammableAdapter()
        ..registerJson(
          method: 'POST',
          path: RegExp(r'^/compare/accept$'),
          status: 403,
          body: <String, dynamic>{'error': 'forbidden'},
        );

      final client = apiClientWith(adapter);
      await expectLater(
        client.acceptComparisonInvite(token: 'tok-1', playthroughId: 'pt-1'),
        throwsA(isA<CompareForbidden>()),
      );
    });
  });

  group('ApiClient.enableComparisonShare', () {
    test('200 parses ComparisonSharePayload', () async {
      final adapter = ProgrammableAdapter()
        ..registerJson(
          method: 'POST',
          path: RegExp(r'^/compare/tok-2/share-enable$'),
          status: 200,
          body: <String, dynamic>{
            'share_token': 'share-tok-2',
            'share_url': 'https://share.echo.test/compare/share-tok-2',
          },
        );

      final client = apiClientWith(adapter);
      final payload = await client.enableComparisonShare(token: 'tok-2');

      expect(payload.shareToken, 'share-tok-2');
      expect(payload.shareUrl, 'https://share.echo.test/compare/share-tok-2');
    });

    test('500 throws DioException', () async {
      final adapter = ProgrammableAdapter()
        ..registerJson(
          method: 'POST',
          path: RegExp(r'^/compare/tok-2/share-enable$'),
          status: 500,
          body: <String, dynamic>{'error': 'oops'},
        );

      final client = apiClientWith(adapter);
      await expectLater(
        client.enableComparisonShare(token: 'tok-2'),
        throwsA(isA<DioException>()),
      );
    });
  });
}
