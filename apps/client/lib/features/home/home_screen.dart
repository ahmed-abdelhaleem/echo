// HomeScreen — entry surface for the Echo client.
//
// In M1 (T-CLIENT-010) this was the launchpad for the single packaged
// Season. M2 (T-CLIENT-020) adds the auth-aware top bar: anonymous
// users see a "Sign in" entry; signed-in users see a settings entry
// in the app bar.

import 'package:echo_client/features/auth/auth_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

class HomeScreen extends ConsumerWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final auth = ref.watch(authControllerProvider);
    final signedIn = auth is AuthStateSignedIn;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Echo'),
        actions: <Widget>[
          if (signedIn)
            IconButton(
              key: const Key('home.toSettings'),
              icon: const Icon(Icons.settings_outlined),
              onPressed: () => context.goNamed('settings'),
              tooltip: 'Settings',
            )
          else
            TextButton(
              key: const Key('home.toLogin'),
              onPressed: () => context.goNamed('login'),
              child: const Text('Sign in'),
            ),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(
              'Echo',
              style: Theme.of(context).textTheme.headlineSmall,
            ),
            const SizedBox(height: 12),
            const Text(
              'Play through a short narrative season. Your choices are saved '
              'on this device and sync to the server in the background.',
            ),
            const Spacer(),
            FilledButton(
              key: const Key('home.startSeason'),
              onPressed: () => context
                  .goNamed('season', pathParameters: {'id': 'season-001'}),
              child: const Text('Start season'),
            ),
          ],
        ),
      ),
    );
  }
}
