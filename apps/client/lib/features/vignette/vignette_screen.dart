// VignetteScreen — the M1 vignette renderer (T-CLIENT-010).
//
// Responsibilities:
//   * Drive the [VignetteController] for a given Season id.
//   * Render the setting beat with the design-token typography stack.
//   * Present 2–4 natural-language choices as full-width buttons.
//   * Record hesitation timing (deliberation_ms) automatically — the
//     controller measures from "vignette shown" to "tap committed".
//   * Show an optional resolution beat carried from the previous choice
//     and a completion surface once the Season is exhausted.
//
// The widget intentionally avoids talking to the network directly; the
// repositories and controller take care of cache-first reads and local
// persistence. PR 8 (T-CLIENT-012) will drain pending choices to the
// server in the background.

import 'package:echo_client/data/models/content.dart';
import 'package:echo_client/features/vignette/vignette_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

class VignetteScreen extends ConsumerStatefulWidget {
  const VignetteScreen({required this.seasonId, super.key});

  /// Season id matching the `:id` path parameter on `/vignette/:id`.
  final String seasonId;

  @override
  ConsumerState<VignetteScreen> createState() => _VignetteScreenState();
}

class _VignetteScreenState extends ConsumerState<VignetteScreen> {
  bool _started = false;

  @override
  void initState() {
    super.initState();
    // We kick off after the first frame so the loading surface paints
    // before any synchronous work begins. This is the recommended
    // pattern with Riverpod StateNotifiers — calling read() in initState
    // is safe but mutating state from there can race the first build.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_started) {
        return;
      }
      _started = true;
      ref.read(vignetteControllerProvider.notifier).start(
            seasonId: widget.seasonId,
          );
    });
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(vignetteControllerProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('Vignette')),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: switch (state) {
            VignetteLoading() => const _LoadingView(),
            VignetteError(message: final m) => _ErrorView(message: m),
            VignetteSeasonMissing(seasonId: final id) =>
              _SeasonMissingView(seasonId: id),
            VignettePlaying() => _PlayingView(state: state),
            VignetteComplete() => _CompleteView(state: state),
          },
        ),
      ),
    );
  }
}

class _LoadingView extends StatelessWidget {
  const _LoadingView();

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          CircularProgressIndicator(),
          SizedBox(height: 16),
          Text('Loading season…'),
        ],
      ),
    );
  }
}

class _ErrorView extends StatelessWidget {
  const _ErrorView({required this.message});
  final String message;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(
          'Something went wrong',
          style: Theme.of(context).textTheme.titleLarge,
        ),
        const SizedBox(height: 12),
        Text(message),
        const Spacer(),
        OutlinedButton(
          onPressed: () => context.goNamed('home'),
          child: const Text('Back to home'),
        ),
      ],
    );
  }
}

class _SeasonMissingView extends StatelessWidget {
  const _SeasonMissingView({required this.seasonId});
  final String seasonId;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(
          'Season not found',
          style: Theme.of(context).textTheme.titleLarge,
        ),
        const SizedBox(height: 12),
        Text(
          'The server doesn’t know about “$seasonId”. The season may have '
          'been removed or this client may be out of date.',
        ),
        const Spacer(),
        OutlinedButton(
          onPressed: () => context.goNamed('home'),
          child: const Text('Back to home'),
        ),
      ],
    );
  }
}

class _PlayingView extends ConsumerWidget {
  const _PlayingView({required this.state});
  final VignettePlaying state;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final Vignette v = state.currentVignette;
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        // Progress indicator. We show 1-indexed counts because that's
        // how players think about it (“1 of 4”, not “0 of 4”).
        Text(
          'Vignette ${state.index + 1} of ${state.totalVignettes}',
          style: theme.textTheme.labelMedium,
        ),
        const SizedBox(height: 8),
        if (state.lastResolutionBeat != null) ...<Widget>[
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: theme.colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text(
              state.lastResolutionBeat!,
              style: theme.textTheme.bodyMedium?.copyWith(
                fontStyle: FontStyle.italic,
              ),
            ),
          ),
          const SizedBox(height: 16),
        ],
        Text(
          v.settingBeat,
          // Setting beat uses the headline stack per the design-token
          // contract; choice labels use the body stack. Keeping this
          // explicit here so a future swap to a custom Text widget is
          // easy to spot.
          style: theme.textTheme.headlineSmall,
        ),
        const SizedBox(height: 24),
        for (final c in v.choices) ...<Widget>[
          SizedBox(
            width: double.infinity,
            child: FilledButton(
              key: Key('choice-${c.id}'),
              onPressed: () => ref
                  .read(vignetteControllerProvider.notifier)
                  .selectChoice(c.id),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 12),
                child: Text(c.label, textAlign: TextAlign.center),
              ),
            ),
          ),
          const SizedBox(height: 12),
        ],
      ],
    );
  }
}

class _CompleteView extends StatelessWidget {
  const _CompleteView({required this.state});
  final VignetteComplete state;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(
          'Season complete',
          style: Theme.of(context).textTheme.headlineSmall,
        ),
        const SizedBox(height: 12),
        Text(
          'Thanks for playing “${state.season.title}”. Your choices are '
          'saved locally and will sync the next time the device is online. '
          'The Portrait and reflection land in a later release.',
        ),
        const Spacer(),
        OutlinedButton(
          onPressed: () => context.goNamed('home'),
          child: const Text('Back to home'),
        ),
      ],
    );
  }
}
