// AuthClient unit tests. Drives the real client through a
// ProgrammableAdapter so the JSON parsing, error mapping, and header
// wiring all exercise the production code paths.

import 'package:dio/dio.dart';
import 'package:echo_client/services/auth_client.dart';
import 'package:flutter_test/flutter_test.dart';

import '../_helpers/fakes.dart';

AuthClient _clientWith(ProgrammableAdapter adapter) {
  final dio = Dio()..httpClientAdapter = adapter;
  return AuthClient(
    kratosBaseUrl: 'http://kratos.test',
    coreBaseUrl: 'http://core.test',
    dio: dio,
  );
}

void main() {
  group('preflight', () {
    test('returns allowed adult', () async {
      final adapter = ProgrammableAdapter()
        ..registerJson(
          method: 'POST',
          path: RegExp(r'/auth/preflight$'),
          status: 200,
          body: <String, dynamic>{'allowed': true, 'band': 'adult'},
        );
      final result = await _clientWith(adapter).preflight('1990-06-15');
      expect(result.allowed, isTrue);
      expect(result.band, 'adult');
      expect(result.isYouth, isFalse);
    });

    test('returns under-13 rejection', () async {
      final adapter = ProgrammableAdapter()
        ..registerJson(
          method: 'POST',
          path: RegExp(r'/auth/preflight$'),
          status: 200,
          body: <String, dynamic>{
            'allowed': false,
            'reason': 'under_13',
          },
        );
      final result = await _clientWith(adapter).preflight('2018-06-15');
      expect(result.allowed, isFalse);
      expect(result.reason, 'under_13');
    });

    test('returns invalid_birthdate on 400 instead of throwing', () async {
      final adapter = ProgrammableAdapter()
        ..registerJson(
          method: 'POST',
          path: RegExp(r'/auth/preflight$'),
          status: 400,
          body: <String, dynamic>{'reason': 'invalid_birthdate'},
        );
      final result = await _clientWith(adapter).preflight('not-a-date');
      expect(result.allowed, isFalse);
      expect(result.reason, 'invalid_birthdate');
    });
  });

  group('signUp', () {
    test('happy path returns an AuthSession with token + identity',
        () async {
      final adapter = ProgrammableAdapter()
        ..registerJson(
          method: 'GET',
          path: RegExp(r'/self-service/registration/api$'),
          status: 200,
          body: <String, dynamic>{'id': 'flow-1'},
        )
        ..registerJson(
          method: 'POST',
          path: RegExp(r'/self-service/registration$'),
          status: 200,
          body: <String, dynamic>{
            'session_token': 'tok-abc',
            'session': <String, dynamic>{
              'identity': <String, dynamic>{
                'id': 'id-1',
                'traits': <String, dynamic>{
                  'email': 'a@x',
                  'display_name': 'Alice',
                  'birthdate': '1990-06-15',
                },
              },
            },
          },
        );
      final session = await _clientWith(adapter).signUp(
        email: 'a@x',
        password: 'correct-horse',
        displayName: 'Alice',
        birthdate: '1990-06-15',
      );
      expect(session.token, 'tok-abc');
      expect(session.identityId, 'id-1');
      expect(session.email, 'a@x');
      expect(session.displayName, 'Alice');
    });

    test('under-13 hook rejection maps to AuthFailureKind.under13',
        () async {
      final adapter = ProgrammableAdapter()
        ..registerJson(
          method: 'GET',
          path: RegExp(r'/self-service/registration/api$'),
          status: 200,
          body: <String, dynamic>{'id': 'flow-2'},
        )
        ..registerJson(
          method: 'POST',
          path: RegExp(r'/self-service/registration$'),
          status: 400,
          body: <String, dynamic>{
            'ui': <String, dynamic>{
              'nodes': <Map<String, dynamic>>[
                <String, dynamic>{
                  'attributes': <String, dynamic>{'name': 'traits.birthdate'},
                  'messages': <Map<String, dynamic>>[
                    <String, dynamic>{
                      'id': 4000001,
                      'type': 'error',
                      'text': 'Echo is for users 13 and up — under 13 is not allowed.',
                    },
                  ],
                },
              ],
            },
          },
        );
      try {
        await _clientWith(adapter).signUp(
          email: 'kid@x',
          password: 'whatever12',
          displayName: 'Kid',
          birthdate: '2018-01-01',
        );
        fail('expected AuthException');
      } on AuthException catch (e) {
        expect(e.kind, AuthFailureKind.under13);
        expect(e.field, 'traits.birthdate');
      }
    });

    test('duplicate email surfaces as a field-level validation error',
        () async {
      final adapter = ProgrammableAdapter()
        ..registerJson(
          method: 'GET',
          path: RegExp(r'/self-service/registration/api$'),
          status: 200,
          body: <String, dynamic>{'id': 'flow-3'},
        )
        ..registerJson(
          method: 'POST',
          path: RegExp(r'/self-service/registration$'),
          status: 400,
          body: <String, dynamic>{
            'ui': <String, dynamic>{
              'nodes': <Map<String, dynamic>>[
                <String, dynamic>{
                  'attributes': <String, dynamic>{'name': 'traits.email'},
                  'messages': <Map<String, dynamic>>[
                    <String, dynamic>{
                      'id': 4000007,
                      'type': 'error',
                      'text': 'An account with the same identifier exists already.',
                    },
                  ],
                },
              ],
            },
          },
        );
      try {
        await _clientWith(adapter).signUp(
          email: 'taken@x',
          password: 'whatever12',
          displayName: 'A',
          birthdate: '1990-01-01',
        );
        fail('expected AuthException');
      } on AuthException catch (e) {
        expect(e.kind, AuthFailureKind.validation);
        expect(e.field, 'traits.email');
      }
    });
  });

  group('login', () {
    test('happy path returns a session', () async {
      final adapter = ProgrammableAdapter()
        ..registerJson(
          method: 'GET',
          path: RegExp(r'/self-service/login/api$'),
          status: 200,
          body: <String, dynamic>{'id': 'login-1'},
        )
        ..registerJson(
          method: 'POST',
          path: RegExp(r'/self-service/login$'),
          status: 200,
          body: <String, dynamic>{
            'session_token': 'tok-x',
            'session': <String, dynamic>{
              'identity': <String, dynamic>{
                'id': 'id-x',
                'traits': <String, dynamic>{
                  'email': 'a@x',
                  'display_name': 'Alice',
                  'birthdate': '1990-06-15',
                },
              },
            },
          },
        );
      final session = await _clientWith(adapter).login(
        email: 'a@x',
        password: 'pw',
      );
      expect(session.token, 'tok-x');
      expect(session.email, 'a@x');
    });

    test('invalid credentials map to AuthFailureKind.invalidCredentials',
        () async {
      final adapter = ProgrammableAdapter()
        ..registerJson(
          method: 'GET',
          path: RegExp(r'/self-service/login/api$'),
          status: 200,
          body: <String, dynamic>{'id': 'login-2'},
        )
        ..registerJson(
          method: 'POST',
          path: RegExp(r'/self-service/login$'),
          status: 400,
          body: <String, dynamic>{
            'ui': <String, dynamic>{
              'messages': <Map<String, dynamic>>[
                <String, dynamic>{
                  'id': 4000006,
                  'type': 'error',
                  'text': 'The provided credentials are invalid, check for spelling mistakes.',
                },
              ],
            },
          },
        );
      try {
        await _clientWith(adapter).login(email: 'a@x', password: 'wrong');
        fail('expected AuthException');
      } on AuthException catch (e) {
        expect(e.kind, AuthFailureKind.invalidCredentials);
      }
    });
  });

  group('recoverPassword', () {
    test('completes normally even when Kratos returns 4xx (privacy)',
        () async {
      final adapter = ProgrammableAdapter()
        ..registerJson(
          method: 'GET',
          path: RegExp(r'/self-service/recovery/api$'),
          status: 200,
          body: <String, dynamic>{'id': 'rec-1'},
        )
        ..registerJson(
          method: 'POST',
          path: RegExp(r'/self-service/recovery$'),
          status: 400,
          body: <String, dynamic>{},
        );
      // Should NOT throw — we don't leak whether the email exists.
      await _clientWith(adapter).recoverPassword('maybe@x');
    });
  });

  group('whoami', () {
    test('attaches X-Session-Token and returns the payload', () async {
      final adapter = ProgrammableAdapter()
        ..register(
          method: 'GET',
          path: RegExp(r'/whoami$'),
          handler: (req, _) async {
            // Verify the token actually gets sent.
            expect(req.headers['X-Session-Token'], 'tok-w');
            return Reply(
              status: 200,
              body:
                  '{"identity_id":"id-1","email":"a@x","display_name":"A","age_band":"adult","youth_safe":false}',
            );
          },
        );
      final w = await _clientWith(adapter).whoami('tok-w');
      expect(w, isNotNull);
      expect(w!.ageBand, 'adult');
      expect(w.youthSafe, isFalse);
      expect(w.isYouth, isFalse);
    });

    test('returns null on 401 instead of throwing', () async {
      final adapter = ProgrammableAdapter()
        ..registerJson(
          method: 'GET',
          path: RegExp(r'/whoami$'),
          status: 401,
        );
      final w = await _clientWith(adapter).whoami('tok-x');
      expect(w, isNull);
    });

    test('youth payload surfaces youthSafe=true', () async {
      final adapter = ProgrammableAdapter()
        ..registerJson(
          method: 'GET',
          path: RegExp(r'/whoami$'),
          status: 200,
          body: <String, dynamic>{
            'identity_id': 'id-y',
            'email': 'y@x',
            'age_band': 'youth',
            'youth_safe': true,
          },
        );
      final w = await _clientWith(adapter).whoami('tok-y');
      expect(w!.ageBand, 'youth');
      expect(w.youthSafe, isTrue);
      expect(w.isYouth, isTrue);
    });
  });

  group('deleteAccount', () {
    test('returns normally on 204', () async {
      final adapter = ProgrammableAdapter()
        ..registerJson(
          method: 'DELETE',
          path: RegExp(r'/me$'),
          status: 204,
        );
      await _clientWith(adapter).deleteAccount('tok-d');
    });

    test('treats 404 as success (idempotent)', () async {
      final adapter = ProgrammableAdapter()
        ..registerJson(
          method: 'DELETE',
          path: RegExp(r'/me$'),
          status: 404,
        );
      await _clientWith(adapter).deleteAccount('tok-d');
    });

    test('401 surfaces as AuthFailureKind.unauthorised', () async {
      final adapter = ProgrammableAdapter()
        ..registerJson(
          method: 'DELETE',
          path: RegExp(r'/me$'),
          status: 401,
        );
      try {
        await _clientWith(adapter).deleteAccount('tok-d');
        fail('expected AuthException');
      } on AuthException catch (e) {
        expect(e.kind, AuthFailureKind.unauthorised);
      }
    });
  });
}
