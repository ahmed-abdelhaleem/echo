// VignetteScreen — placeholder for the vignette renderer.
//
// The real renderer is T-CLIENT-014 (M1). It will:
//   - fetch the vignette from core-go's GraphQL endpoint,
//   - render the setting beat with the design-token typography stack,
//   - present 2–4 natural-language choices,
//   - record hesitation timing per docs/04 §"Telemetry".

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

class VignetteScreen extends StatelessWidget {
  const VignetteScreen({required this.vignetteId, super.key});

  final String vignetteId;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Vignette')),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(
              'Vignette: $vignetteId',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 12),
            const Text(
              'The vignette renderer is implemented in M1 (T-CLIENT-014). '
              'This placeholder simply confirms that routing is wired and '
              'that path parameters reach the destination.',
            ),
            const Spacer(),
            OutlinedButton(
              onPressed: () => context.goNamed('home'),
              child: const Text('Back to home'),
            ),
          ],
        ),
      ),
    );
  }
}
