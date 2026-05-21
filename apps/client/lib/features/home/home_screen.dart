// HomeScreen — entry surface for the Echo client.
//
// In M1 (T-CLIENT-010) this is the launchpad for the single packaged
// Season. A future PR replaces the single button with a Season picker
// and a "continue where you left off" lane backed by LocalPlaythroughs.

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Echo')),
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
