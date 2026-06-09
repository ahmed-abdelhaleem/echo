// AuthController tests — drives the controller through a real
// AuthClient backed by a ProgrammableAdapter. We assert the state
// transitions plus the side effects (whoami refresh after sign-in).

import 'package:dio/dio.dart';
import 'package:echo_client/features/auth/auth_controller.dart';
import 'package:echo_client/services/auth_client.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../_helpers/fakes.dart';

AuthClient _clientWith(ProgrammableAdapter adapter) {
  final dio = Dio()..httpClientAdapter = adapter;
  return AuthClient(
    kratosBaseUrl: 'http://kratos.test',
    coreBaseUrl: 'http://core.test',
    dio: dio,
  );
}

void main() {
  test('starts anonymous', () {
    final adapter = ProgrammableAdapter();
    final ctrl = AuthController(_clientWith(adapter));
    expect(ctrl.state, isA<AuthStateAnonymous>());
  });

  test('signUp transitions to signed-in and refreshes whoami', () async {
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
          'session_token': 'tok-1',
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
      )
      ..registerJson(
        method: 'GET',
        path: RegExp(r'/whoami$'),
        status: 200,
        body: <String, dynamic>{
          'identity_id': 'id-1',
          'email': 'a@x',
          'display_name': 'Alice',
          'age_band': 'adult',
          'youth_safe': false,
        },
      );
    final ctrl = AuthController(_clientWith(adapter));
    await ctrl.signUp(
      email: 'a@x',
      password: 'strong-password',
      displayName: 'Alice',
      birthdate: '1990-06-15',
    );
    final state = ctrl.state;
    expect(state, isA<AuthStateSignedIn>());
    final signedIn = state as AuthStateSignedIn;
    expect(signedIn.session.token, 'tok-1');
    expect(signedIn.whoami?.ageBand, 'adult');
    expect(signedIn.youthSafe, isFalse);
  });

  test('signUp surfaces youth_safe=true for 13–17 users', () async {
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
        status: 200,
        body: <String, dynamic>{
          'session_token': 'tok-y',
          'session': <String, dynamic>{
            'identity': <String, dynamic>{
              'id': 'id-y',
              'traits': <String, dynamic>{
                'email': 'y@x',
                'display_name': 'Yara',
                'birthdate': '2012-06-15',
              },
            },
          },
        },
      )
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
    final ctrl = AuthController(_clientWith(adapter));
    await ctrl.signUp(
      email: 'y@x',
      password: 'long-enough',
      displayName: 'Yara',
      birthdate: '2012-06-15',
    );
    final signedIn = ctrl.state as AuthStateSignedIn;
    expect(signedIn.whoami?.isYouth, isTrue);
    expect(signedIn.youthSafe, isTrue);
  });

  test('signUp propagates under-13 AuthException', () async {
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
                'attributes': <String, dynamic>{'name': 'traits.birthdate'},
                'messages': <Map<String, dynamic>>[
                  <String, dynamic>{
                    'id': 4000001,
                    'type': 'error',
                    'text':
                        'Registrants must be at least 13 years old; under 13 is not allowed.',
                  },
                ],
              },
            ],
          },
        },
      );
    final ctrl = AuthController(_clientWith(adapter));
    try {
      await ctrl.signUp(
        email: 'kid@x',
        password: 'long-enough',
        displayName: 'Kid',
        birthdate: '2018-01-01',
      );
      fail('expected AuthException');
    } on AuthException catch (e) {
      expect(e.kind, AuthFailureKind.under13);
    }
    expect(ctrl.state, isA<AuthStateAnonymous>());
  });

  test('signOut returns to anonymous without server call', () async {
    final adapter = ProgrammableAdapter()
      ..registerJson(
        method: 'GET',
        path: RegExp(r'/self-service/login/api$'),
        status: 200,
        body: <String, dynamic>{'id': 'l-1'},
      )
      ..registerJson(
        method: 'POST',
        path: RegExp(r'/self-service/login$'),
        status: 200,
        body: <String, dynamic>{
          'session_token': 'tok-l',
          'session': <String, dynamic>{
            'identity': <String, dynamic>{
              'id': 'id-l',
              'traits': <String, dynamic>{
                'email': 'a@x',
                'display_name': 'Alice',
                'birthdate': '1990-06-15',
              },
            },
          },
        },
      )
      ..registerJson(
        method: 'GET',
        path: RegExp(r'/whoami$'),
        status: 200,
        body: <String, dynamic>{
          'identity_id': 'id-l',
          'email': 'a@x',
          'age_band': 'adult',
          'youth_safe': false,
        },
      );
    final ctrl = AuthController(_clientWith(adapter));
    await ctrl.login(email: 'a@x', password: 'pw-strong');
    expect(ctrl.state, isA<AuthStateSignedIn>());
    ctrl.signOut();
    expect(ctrl.state, isA<AuthStateAnonymous>());
  });

  test('delete calls DELETE /me and rotates to anonymous', () async {
    final adapter = ProgrammableAdapter()
      ..registerJson(
        method: 'GET',
        path: RegExp(r'/self-service/login/api$'),
        status: 200,
        body: <String, dynamic>{'id': 'l-2'},
      )
      ..registerJson(
        method: 'POST',
        path: RegExp(r'/self-service/login$'),
        status: 200,
        body: <String, dynamic>{
          'session_token': 'tok-d',
          'session': <String, dynamic>{
            'identity': <String, dynamic>{
              'id': 'id-d',
              'traits': <String, dynamic>{
                'email': 'd@x',
                'display_name': 'D',
                'birthdate': '1990-06-15',
              },
            },
          },
        },
      )
      ..registerJson(
        method: 'GET',
        path: RegExp(r'/whoami$'),
        status: 200,
        body: <String, dynamic>{
          'identity_id': 'id-d',
          'email': 'd@x',
          'age_band': 'adult',
          'youth_safe': false,
        },
      )
      ..registerJson(
        method: 'DELETE',
        path: RegExp(r'/me$'),
        status: 204,
      );
    final ctrl = AuthController(_clientWith(adapter));
    await ctrl.login(email: 'd@x', password: 'pw-strong');
    await ctrl.delete();
    expect(ctrl.state, isA<AuthStateAnonymous>());
    // Verify DELETE was actually invoked.
    final deletes =
        adapter.recorded.where((r) => r.method == 'DELETE').toList();
    expect(deletes, hasLength(1));
  });

  test('delete from anonymous is a no-op', () async {
    final adapter = ProgrammableAdapter();
    final ctrl = AuthController(_clientWith(adapter));
    await ctrl.delete();
    expect(ctrl.state, isA<AuthStateAnonymous>());
    expect(adapter.recorded, isEmpty);
  });

  test('whoami refresh failure drops back to anonymous', () async {
    final adapter = ProgrammableAdapter()
      ..registerJson(
        method: 'GET',
        path: RegExp(r'/self-service/login/api$'),
        status: 200,
        body: <String, dynamic>{'id': 'l-3'},
      )
      ..registerJson(
        method: 'POST',
        path: RegExp(r'/self-service/login$'),
        status: 200,
        body: <String, dynamic>{
          'session_token': 'tok-3',
          'session': <String, dynamic>{
            'identity': <String, dynamic>{
              'id': 'id-3',
              'traits': <String, dynamic>{
                'email': 'a@x',
                'display_name': 'A',
                'birthdate': '1990-06-15',
              },
            },
          },
        },
      )
      ..registerJson(
        method: 'GET',
        path: RegExp(r'/whoami$'),
        status: 401,
      );
    final ctrl = AuthController(_clientWith(adapter));
    await ctrl.login(email: 'a@x', password: 'pw-strong');
    expect(ctrl.state, isA<AuthStateAnonymous>());
  });
}
