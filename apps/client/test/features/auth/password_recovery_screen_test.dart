// PasswordRecoveryScreen widget tests.

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

Future<void> _go(WidgetTester tester) async {
  await tester.tap(find.byKey(const Key('home.toLogin')));
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(const Key('login.toRecover')));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('200: shows confirmation copy', (tester) async {
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
        status: 200,
        body: <String, dynamic>{},
      );
    await tester.pumpWidget(_bootApp(adapter));
    await tester.pumpAndSettle();
    await _go(tester);
    await tester.enterText(
      find.byKey(const Key('recover.email')),
      'a@x.io',
    );
    await tester.tap(find.byKey(const Key('recover.submit')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('recover.confirmation')), findsOneWidget);
    expect(find.textContaining('Check your email'), findsOneWidget);
  });

  testWidgets('4xx: also shows confirmation copy (privacy)', (tester) async {
    final adapter = ProgrammableAdapter()
      ..registerJson(
        method: 'GET',
        path: RegExp(r'/self-service/recovery/api$'),
        status: 200,
        body: <String, dynamic>{'id': 'rec-2'},
      )
      ..registerJson(
        method: 'POST',
        path: RegExp(r'/self-service/recovery$'),
        status: 400,
        body: <String, dynamic>{},
      );
    await tester.pumpWidget(_bootApp(adapter));
    await tester.pumpAndSettle();
    await _go(tester);
    await tester.enterText(
      find.byKey(const Key('recover.email')),
      'nobody@x.io',
    );
    await tester.tap(find.byKey(const Key('recover.submit')));
    await tester.pumpAndSettle();
    // Privacy: same confirmation copy regardless of whether the email
    // exists.
    expect(find.byKey(const Key('recover.confirmation')), findsOneWidget);
  });
}
