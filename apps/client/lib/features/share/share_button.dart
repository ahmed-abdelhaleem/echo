// ShareButton — surface for the public-Portrait share flow
// (T-CLIENT-030).
//
// The button itself is intentionally tiny — it watches the
// [shareControllerProvider] and dispatches `shareNow(...)` on tap.
// Youth-safe gating happens in two places: the parent screen hides
// the button entirely for `age_band == youth`, and the server
// re-checks the gate when /playthroughs/{id}/share is called. The
// button surface here trusts the parent — it does not query the
// auth controller — so it stays unit-testable in isolation.

import 'package:echo_client/features/share/share_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

class ShareButton extends ConsumerWidget {
  const ShareButton({
    required this.playthroughId,
    this.label = 'Share my Portrait',
    super.key,
  });

  /// Server-assigned playthrough id (NOT the local Drift id).
  /// The button only renders once the sync has propagated this row to
  /// the server; the parent screen is responsible for that gating.
  final String playthroughId;

  /// Override the button label for surfaces that want narrower copy
  /// (eg "Share" in compact toolbars). Defaults to the explicit
  /// "Share my Portrait" label per the docs/04 brand-voice guidance.
  final String label;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(shareControllerProvider);
    final isBusy = state is SharePreparing;
    final theme = Theme.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        FilledButton.icon(
          key: const Key('share-button'),
          onPressed: isBusy
              ? null
              : () => ref
                  .read(shareControllerProvider.notifier)
                  .shareNow(playthroughId: playthroughId),
          icon: isBusy
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.ios_share),
          label: Text(isBusy ? 'Preparing…' : label),
        ),
        if (state is ShareError) ...<Widget>[
          const SizedBox(height: 8),
          Text(
            state.message,
            key: const Key('share-error'),
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.error,
            ),
          ),
        ],
        if (state is ShareReady) ...<Widget>[
          const SizedBox(height: 8),
          Text(
            'Share link minted. ${state.shareUrl}',
            key: const Key('share-success'),
            style: theme.textTheme.bodySmall,
          ),
        ],
      ],
    );
  }
}
