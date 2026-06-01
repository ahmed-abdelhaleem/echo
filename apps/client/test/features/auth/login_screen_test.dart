// LoginScreen widget tests.

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

void main() {
  testWidgets('happy path: login routes to home', (tester) async {
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
                'email': 'a@x.io',
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
          'email': 'a@x.io',
          'age_band': 'adult',
          'youth_safe': false,
        },
      );
    await tester.pumpWidget(_bootApp(adapter));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('home.toLogin')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('login.email')), 'a@x.io');
    await tester.enterText(
        find.byKey(const Key('login.password')), 'pw-strong');
    await tester.tap(find.byKey(const Key('login.submit')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('home.toSettings')), findsOneWidget);
  });

  testWidgets('invalid credentials show a top-level error banner',
      (tester) async {
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
        status: 400,
        body: <String, dynamic>{
          'ui': <String, dynamic>{
            'messages': <Map<String, dynamic>>[
              <String, dynamic>{
                'id': 4000006,
                'type': 'error',
                'text': 'The provided credentials are invalid.',
              },
            ],
          },
        },
      );
    await tester.pumpWidget(_bootApp(adapter));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('home.toLogin')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('login.email')), 'a@x.io');
    await tester.enterText(
        find.byKey(const Key('login.password')), 'wrong-password');
    await tester.tap(find.byKey(const Key('login.submit')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('login.topError')), findsOneWidget);
    expect(find.text('Email or password is incorrect.'), findsOneWidget);
  });

  testWidgets('toRecover navigates to /recover', (tester) async {
    await tester.pumpWidget(_bootApp(ProgrammableAdapter()));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('home.toLogin')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('login.toRecover')));
    await tester.pumpAndSettle();
    expect(find.text('Reset your Echo password'), findsOneWidget);
  });
}
