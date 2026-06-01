// SettingsScreen widget tests.

import 'package:dio/dio.dart';
import 'package:echo_client/app/app.dart';
import 'package:echo_client/app/router.dart';
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

Future<void> _loginAdult(WidgetTester tester) async {
  await tester.tap(find.byKey(const Key('home.toLogin')));
  await tester.pumpAndSettle();
  await tester.enterText(find.byKey(const Key('login.email')), 'a@x.io');
  await tester.enterText(
    find.byKey(const Key('login.password')),
    'pw-strong',
  );
  await tester.tap(find.byKey(const Key('login.submit')));
  await tester.pumpAndSettle();
}

ProgrammableAdapter _loginFixture({
  required String identityId,
  required String ageBand,
  required bool youthSafe,
}) {
  return ProgrammableAdapter()
    ..registerJson(
      method: 'GET',
      path: RegExp(r'/self-service/login/api$'),
      status: 200,
      body: <String, dynamic>{'id': 'l-x'},
    )
    ..registerJson(
      method: 'POST',
      path: RegExp(r'/self-service/login$'),
      status: 200,
      body: <String, dynamic>{
        'session_token': 'tok-x',
        'session': <String, dynamic>{
          'identity': <String, dynamic>{
            'id': identityId,
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
        'identity_id': identityId,
        'email': 'a@x.io',
        'display_name': 'Alice',
        'age_band': ageBand,
        'youth_safe': youthSafe,
      },
    );
}

void main() {
  testWidgets('redirects to /login when anonymous', (tester) async {
    final container = ProviderContainer(
      overrides: <Override>[
        ...testOverrides(seasons: const <String, Season>{}),
        authClientProvider.overrideWithValue(
          _clientWith(ProgrammableAdapter()),
        ),
      ],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const EchoApp(),
      ),
    );
    await tester.pumpAndSettle();
    // Try to navigate to /settings; redirect should kick in.
    container.read(appRouterProvider).go('/settings');
    await tester.pumpAndSettle();
    // We end up on the login screen.
    expect(find.text('Sign in to Echo'), findsOneWidget);
  });

  testWidgets('adult: shows email + display name; no youth-safe card',
      (tester) async {
    final adapter = _loginFixture(
      identityId: 'id-1',
      ageBand: 'adult',
      youthSafe: false,
    );
    await tester.pumpWidget(_bootApp(adapter));
    await tester.pumpAndSettle();
    await _loginAdult(tester);
    await tester.tap(find.byKey(const Key('home.toSettings')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('settings.email')), findsOneWidget);
    expect(find.text('a@x.io'), findsOneWidget);
    expect(find.byKey(const Key('settings.displayName')), findsOneWidget);
    expect(find.text('Alice'), findsOneWidget);
    expect(find.byKey(const Key('settings.youthSafeCard')), findsNothing);
  });

  testWidgets('youth: shows the youth-safe explainer card', (tester) async {
    final adapter = _loginFixture(
      identityId: 'id-y',
      ageBand: 'youth',
      youthSafe: true,
    );
    await tester.pumpWidget(_bootApp(adapter));
    await tester.pumpAndSettle();
    await _loginAdult(tester);
    await tester.tap(find.byKey(const Key('home.toSettings')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('settings.youthSafeCard')), findsOneWidget);
    expect(find.text('Youth-safe mode is on'), findsOneWidget);
  });

  testWidgets('sign out routes to login and clears state', (tester) async {
    final adapter = _loginFixture(
      identityId: 'id-1',
      ageBand: 'adult',
      youthSafe: false,
    );
    await tester.pumpWidget(_bootApp(adapter));
    await tester.pumpAndSettle();
    await _loginAdult(tester);
    await tester.tap(find.byKey(const Key('home.toSettings')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('settings.signOut')));
    await tester.pumpAndSettle();
    expect(find.text('Sign in to Echo'), findsOneWidget);
  });

  testWidgets('delete: confirm dialog -> DELETE /me -> routes to login',
      (tester) async {
    final adapter = _loginFixture(
      identityId: 'id-d',
      ageBand: 'adult',
      youthSafe: false,
    )..registerJson(
        method: 'DELETE',
        path: RegExp(r'/me$'),
        status: 204,
      );
    await tester.pumpWidget(_bootApp(adapter));
    await tester.pumpAndSettle();
    await _loginAdult(tester);
    await tester.tap(find.byKey(const Key('home.toSettings')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('settings.delete')));
    await tester.pumpAndSettle();
    // Dialog up.
    expect(find.text('Delete your Echo account?'), findsOneWidget);
    await tester.tap(find.byKey(const Key('settings.deleteConfirm')));
    await tester.pumpAndSettle();
    expect(find.text('Sign in to Echo'), findsOneWidget);
    // Verify the DELETE request actually went out.
    expect(adapter.recorded.any((r) => r.method == 'DELETE'), isTrue);
  });

  testWidgets('delete: cancel keeps us on settings', (tester) async {
    final adapter = _loginFixture(
      identityId: 'id-c',
      ageBand: 'adult',
      youthSafe: false,
    );
    await tester.pumpWidget(_bootApp(adapter));
    await tester.pumpAndSettle();
    await _loginAdult(tester);
    await tester.tap(find.byKey(const Key('home.toSettings')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('settings.delete')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('settings.deleteCancel')));
    await tester.pumpAndSettle();
    // Still on settings.
    expect(find.byKey(const Key('settings.delete')), findsOneWidget);
    expect(adapter.recorded.any((r) => r.method == 'DELETE'), isFalse);
  });
}
