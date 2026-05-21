// The top-level widget for the Echo client.
//
// `EchoApp` wires the [MaterialApp.router] with the Riverpod-managed
// [appRouterProvider] and the M0 placeholder theme. The full design-token
// theme lands in M1 (T-CLIENT-013).

import 'package:echo_client/app/router.dart';
import 'package:echo_client/app/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

class EchoApp extends ConsumerWidget {
  const EchoApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final router = ref.watch(appRouterProvider);

    return MaterialApp.router(
      title: 'Echo',
      debugShowCheckedModeBanner: false,
      theme: buildLightTheme(),
      darkTheme: buildDarkTheme(),
      themeMode: ThemeMode.system,
      routerConfig: router,
      localizationsDelegates: const <LocalizationsDelegate<Object>>[
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      supportedLocales: const <Locale>[
        // Echo authors content in `en-GB` per docs/04_Game_Design.md §"Voice".
        Locale('en', 'GB'),
        Locale('en'),
      ],
    );
  }
}
