// SignUpScreen widget tests. We override [authClientProvider] with an
// AuthClient backed by a ProgrammableAdapter so the screen drives the
// real controller + real client; only the network is faked.

import 'package:dio/dio.dart';
import 'package:echo_client/app/app.dart';
import 'package:echo_client/data/models/content.dart';
import 'package:echo_client/services/auth_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
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

ProviderScope _bootApp(ProgrammableAdapter adapter) {
  return ProviderScope(
    overrides: <Override>[
      ...testOverrides(seasons: const <String, Season>{}),
      authClientProvider.overrideWithValue(_clientWith(adapter)),
    ],
    child: const EchoApp(),
  );
}

Future<void> _navigateToSignUp(WidgetTester tester) async {
  await tester.tap(find.byKey(const Key('home.toLogin')));
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(const Key('login.toSignUp')));
  await tester.pumpAndSettle();
}

Future<void> _fill(WidgetTester tester) async {
  await tester.enterText(find.byKey(const Key('signup.email')), 'alice@x.io');
  await tester.enterText(
      find.byKey(const Key('signup.displayName')), 'Alice');
  await tester.enterText(
      find.byKey(const Key('signup.password')), 'correct-horse');
  await tester.enterText(
      find.byKey(const Key('signup.birthdate')), '1990-06-15');
}

void main() {
  testWidgets('happy path: create adult account routes to home',
      (tester) async {
    final adapter = ProgrammableAdapter()
      ..registerJson(
        method: 'POST',
        path: RegExp(r'/auth/preflight$'),
        status: 200,
        body: <String, dynamic>{'allowed': true, 'band': 'adult'},
      )
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
                'email': 'alice@x.io',
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
          'email': 'alice@x.io',
          'display_name': 'Alice',
          'age_band': 'adult',
          'youth_safe': false,
        },
      );
    await tester.pumpWidget(_bootApp(adapter));
    await tester.pumpAndSettle();
    await _navigateToSignUp(tester);
    await _fill(tester);
    await tester.tap(find.byKey(const Key('signup.submit')));
    await tester.pumpAndSettle();

    // Back on Home, with the "Sign in" entry replaced by the settings
    // icon (proving we're signed in).
    expect(find.text('Start season'), findsOneWidget);
    expect(find.byKey(const Key('home.toSettings')), findsOneWidget);
    expect(find.byKey(const Key('home.toLogin')), findsNothing);
  });

  testWidgets('under-13: preflight surfaces field error and submit fails',
      (tester) async {
    final adapter = ProgrammableAdapter()
      ..registerJson(
        method: 'POST',
        path: RegExp(r'/auth/preflight$'),
        status: 200,
        body: <String, dynamic>{
          'allowed': false,
          'reason': 'under_13',
        },
      )
      // If the user bypasses preflight and submits, the before-hook
      // returns 400 with the under-13 message — verify the screen
      // surfaces it on the birthdate field.
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
                    'text':
                        'Echo is for ages 13 and up; under 13 is not allowed.',
                  },
                ],
              },
            ],
          },
        },
      );
    await tester.pumpWidget(_bootApp(adapter));
    await tester.pumpAndSettle();
    await _navigateToSignUp(tester);
    await tester.enterText(
        find.byKey(const Key('signup.email')), 'kid@x.io');
    await tester.enterText(
        find.byKey(const Key('signup.displayName')), 'Kid');
    await tester.enterText(
        find.byKey(const Key('signup.password')), 'correct-horse');
    await tester.enterText(
        find.byKey(const Key('signup.birthdate')), '2018-01-01');
    // Move focus to trigger the preflight call.
    await tester.tap(find.byKey(const Key('signup.email')));
    await tester.pumpAndSettle();

    // Birthdate field shows the under-13 copy.
    expect(find.text('Echo is for ages 13 and up.'), findsOneWidget);

    // Tap submit — screen short-circuits on the field error and we
    // stay on the sign-up screen.
    await tester.tap(find.byKey(const Key('signup.submit')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('signup.submit')), findsOneWidget);
  });

  testWidgets('youth path: 13–17 birthdate routes to home with youth-safe on',
      (tester) async {
    final adapter = ProgrammableAdapter()
      ..registerJson(
        method: 'POST',
        path: RegExp(r'/auth/preflight$'),
        status: 200,
        body: <String, dynamic>{'allowed': true, 'band': 'youth'},
      )
      ..registerJson(
        method: 'GET',
        path: RegExp(r'/self-service/registration/api$'),
        status: 200,
        body: <String, dynamic>{'id': 'flow-y'},
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
                'email': 'yara@x.io',
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
          'email': 'yara@x.io',
          'age_band': 'youth',
          'youth_safe': true,
        },
      );
    await tester.pumpWidget(_bootApp(adapter));
    await tester.pumpAndSettle();
    await _navigateToSignUp(tester);
    await tester.enterText(
        find.byKey(const Key('signup.email')), 'yara@x.io');
    await tester.enterText(
        find.byKey(const Key('signup.displayName')), 'Yara');
    await tester.enterText(
        find.byKey(const Key('signup.password')), 'correct-horse');
    await tester.enterText(
        find.byKey(const Key('signup.birthdate')), '2012-06-15');
    await tester.tap(find.byKey(const Key('signup.submit')));
    await tester.pumpAndSettle();

    // We're on Home and signed in (settings entry is present).
    expect(find.byKey(const Key('home.toSettings')), findsOneWidget);
  });
}
