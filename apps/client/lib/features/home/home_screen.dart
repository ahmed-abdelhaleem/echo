// HomeScreen — entry surface for the M0 scaffold.
//
// In M1 (T-CLIENT-010 onward) this becomes the Season picker and "continue
// where you left off" lane. For now it shows a brief description and a button
// that navigates to a placeholder Vignette so the routing graph is exercised.

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
              'Echo client (M0 scaffold)',
              style: Theme.of(context).textTheme.headlineSmall,
            ),
            const SizedBox(height: 12),
            const Text(
              'The vignette experience lands in M1. This build only exercises '
              'the routing, theming, and localisation rails so feature work '
              'has somewhere to land.',
            ),
            const Spacer(),
            FilledButton(
              onPressed: () => context
                  .goNamed('vignette', pathParameters: {'id': 'vignette-001'}),
              child: const Text('Open placeholder vignette'),
            ),
          ],
        ),
      ),
    );
  }
}
