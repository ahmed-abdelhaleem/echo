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

import 'package:echo_client/data/local/database.dart';
import 'package:echo_client/data/models/content.dart';
import 'package:echo_client/features/vignette/backdrop/adaptive_backdrop.dart';
import 'package:echo_client/features/vignette/backdrop/backdrop_models.dart';
import 'package:echo_client/features/vignette/backdrop/backdrop_provider.dart';
import 'package:echo_client/features/vignette/backdrop/three_d_debug.dart';
import 'package:echo_client/features/vignette/vignette_controller.dart';
import 'package:echo_client/features/share/share_button.dart';
import 'package:echo_client/features/sync/sync_controller.dart';
import 'package:echo_client/services/api_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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
    // Look up the atmospheric backdrop only while a vignette is playing.
    // When the manifest is missing or the vignette has no backdrop authored,
    // [backdrop] is null and the screen renders exactly as before.
    final BackdropSpec? backdrop = state is VignettePlaying
        ? readBackdropFor(
            ref,
            seasonId: widget.seasonId,
            vignetteId: state.currentVignette.id,
          )
        : null;
    return Scaffold(
      appBar: AppBar(title: const Text('Vignette')),
      body: Stack(
        fit: StackFit.expand,
        children: <Widget>[
          if (backdrop != null) ...<Widget>[
            AdaptiveAtmosphericBackdrop(
              seasonId: widget.seasonId,
              spec: backdrop,
            ),
            // Scrim keeps the choice UI legible without disabling the
            // backdrop's continuous ambient motion behind it. Suppressed under
            // the 3D debug flag so the viewport is not washed toward white.
            if (!kEcho3dDebug) const _BackdropScrim(),
          ],
          SafeArea(
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
        ],
      ),
    );
  }
}

/// Soft translucent wash over the backdrop that keeps the choice UI legible
/// across light and dark moods. Sits between the backdrop and the content.
class _BackdropScrim extends StatelessWidget {
  const _BackdropScrim();

  @override
  Widget build(BuildContext context) {
    final surface = Theme.of(context).colorScheme.surface;
    return IgnorePointer(
      child: DecoratedBox(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: <Color>[
              surface.withValues(alpha: 0.40),
              surface.withValues(alpha: 0.70),
            ],
          ),
        ),
        child: const SizedBox.expand(),
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

class _CompleteView extends ConsumerStatefulWidget {
  const _CompleteView({required this.state});
  final VignetteComplete state;

  @override
  ConsumerState<_CompleteView> createState() => _CompleteViewState();
}

class _CompleteViewState extends ConsumerState<_CompleteView> {
  String? _remoteId;
  String? _reflection;
  Uint8List? _portraitBytes;
  String? _errorMessage;
  bool _loading = true;
  String _statusMessage = 'Finalizing playthrough…';

  // Compare-invite sub-state
  bool _creatingInvite = false;
  CompareInvitePayload? _compareInvite;
  String? _compareError;

  @override
  void initState() {
    super.initState();
    // _loadResults triggers syncController state mutations. Deferring to the
    // first post-frame callback avoids Riverpod's "modify provider while
    // building" guard in initState.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) {
        return;
      }
      _loadResults();
    });
  }

  Future<void> _createCompareInvite() async {
    final remoteId = _remoteId;
    if (remoteId == null) return;
    setState(() {
      _creatingInvite = true;
      _compareError = null;
    });
    try {
      final api = ref.read(apiClientProvider);
      final invite = await api.createComparisonInvite(playthroughId: remoteId);
      if (!mounted) return;
      setState(() {
        _compareInvite = invite;
        _creatingInvite = false;
      });
    } on CompareUnauthorised {
      if (!mounted) return;
      setState(() {
        _compareError = 'Sign in to compare with a friend.';
        _creatingInvite = false;
      });
    } on CompareForbidden {
      if (!mounted) return;
      setState(() {
        _compareError = 'Comparisons are disabled for your account.';
        _creatingInvite = false;
      });
    } on CompareConflict {
      if (!mounted) return;
      setState(() {
        _compareError = 'Finish the season before inviting a friend.';
        _creatingInvite = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _compareError = 'Could not create invite: $e';
        _creatingInvite = false;
      });
    }
  }

  Future<void> _loadResults() async {
    try {
      final playRepo = ref.read(playthroughRepositoryProvider);

      // Step 1: Ensure choices are synced and remoteId is acquired.
      setState(() {
        _statusMessage = 'Syncing choices to server…';
      });

      // Force a sync right now.
      await ref.read(syncControllerProvider.notifier).syncNow();

      // Check if remoteId is populated
      LocalPlaythroughRow? localPlay =
          await playRepo.findById(widget.state.localPlaythroughId);
      String? remoteId = localPlay?.remoteId;

      if (remoteId == null) {
        // If not synced, wait a bit and check again.
        int attempts = 0;
        while (remoteId == null && attempts < 5) {
          await Future<void>.delayed(const Duration(seconds: 2));
          await ref.read(syncControllerProvider.notifier).syncNow();
          localPlay = await playRepo.findById(widget.state.localPlaythroughId);
          remoteId = localPlay?.remoteId;
          attempts++;
        }
      }

      if (remoteId == null) {
        throw Exception(
          'Playthrough could not be registered on server. Please check your internet connection.',
        );
      }

      _remoteId = remoteId;

      // Step 2: Finalize the playthrough on the server.
      setState(() {
        _statusMessage = 'Reflecting on your choices…';
      });
      final api = ref.read(apiClientProvider);
      await api.finalizePlaythrough(playthroughId: remoteId);

      // Step 3: Fetch the reflection text.
      setState(() {
        _statusMessage = 'Composing personality reflection…';
      });
      final reflection = await api.getReflection(playthroughId: remoteId);

      // Step 4: Fetch the visual Portrait bytes.
      setState(() {
        _statusMessage = 'Generating visual Portrait…';
      });
      final bytes =
          await api.getPortraitBytes(playthroughId: remoteId, animate: false);

      if (mounted) {
        setState(() {
          _reflection = reflection;
          _portraitBytes = Uint8List.fromList(bytes);
          _loading = false;
        });
      }
    } catch (e, st) {
      debugPrintStack(stackTrace: st, label: '_CompleteView._loadResults');
      if (mounted) {
        setState(() {
          _errorMessage = e.toString();
          _loading = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    if (_loading) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            const CircularProgressIndicator(),
            const SizedBox(height: 24),
            Text(
              _statusMessage,
              style: theme.textTheme.titleMedium,
              textAlign: TextAlign.center,
            ),
          ],
        ),
      );
    }

    if (_errorMessage != null) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            'Unable to generate Portrait',
            style: theme.textTheme.headlineSmall
                ?.copyWith(color: theme.colorScheme.error),
          ),
          const SizedBox(height: 12),
          Text(_errorMessage!),
          const Spacer(),
          ElevatedButton(
            onPressed: () {
              setState(() {
                _loading = true;
                _errorMessage = null;
              });
              _loadResults();
            },
            child: const Text('Try Again'),
          ),
          const SizedBox(height: 12),
          OutlinedButton(
            onPressed: () => context.goNamed('home'),
            child: const Text('Back to home'),
          ),
        ],
      );
    }

    return Center(
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: <Widget>[
            Text(
              'Your Portrait',
              style: theme.textTheme.headlineMedium
                  ?.copyWith(fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 24),
            if (_portraitBytes != null)
              Container(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(16),
                  boxShadow: [
                    BoxShadow(
                      color: theme.colorScheme.shadow.withAlpha(51),
                      blurRadius: 15,
                      offset: const Offset(0, 5),
                    ),
                  ],
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(16),
                  child: Image.memory(
                    _portraitBytes!,
                    width: 320,
                    height: 320,
                    fit: BoxFit.cover,
                  ),
                ),
              ),
            const SizedBox(height: 24),
            if (_reflection != null)
              Container(
                padding: const EdgeInsets.all(20),
                decoration: BoxDecoration(
                  color: theme.colorScheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Text(
                  _reflection!,
                  style: theme.textTheme.bodyLarge?.copyWith(
                    fontStyle: FontStyle.italic,
                    height: 1.5,
                  ),
                  textAlign: TextAlign.center,
                ),
              ),
            const SizedBox(height: 32),
            if (_remoteId != null) ShareButton(playthroughId: _remoteId!),
            const SizedBox(height: 12),
            // ── Compare invite ──────────────────────────────────────────
            // CHOICE: show URL inline (copy-to-clipboard) rather than
            // auto-invoking the system share sheet — keeps the surface
            // simple and lets the user share when they're ready.
            // Alternative considered: share_plus XFile + URL (same as
            // portrait share). Deferred because compare links have no
            // image attachment.
            if (_compareInvite == null)
              OutlinedButton.icon(
                key: const Key('complete.compareInvite'),
                onPressed: _creatingInvite ? null : _createCompareInvite,
                icon: const Icon(Icons.people_outline),
                label: Text(
                  _creatingInvite
                      ? 'Creating invite…'
                      : 'Compare with a friend',
                ),
              )
            else ...<Widget>[
              const Text('Send this link to a friend:'),
              const SizedBox(height: 6),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Expanded(
                    child: SelectableText(
                      _compareInvite!.compareUrl,
                      key: const Key('complete.compareUrl'),
                    ),
                  ),
                  IconButton(
                    key: const Key('complete.copyCompareLink'),
                    tooltip: 'Copy invite link',
                    onPressed: () async {
                      await Clipboard.setData(
                        ClipboardData(text: _compareInvite!.compareUrl),
                      );
                      if (context.mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(
                            content: Text('Invite link copied'),
                          ),
                        );
                      }
                    },
                    icon: const Icon(Icons.copy_outlined),
                  ),
                ],
              ),
            ],
            if (_compareError != null) ...<Widget>[
              const SizedBox(height: 6),
              Text(
                _compareError!,
                key: const Key('complete.compareError'),
                style: TextStyle(
                  color: Theme.of(context).colorScheme.error,
                  fontSize: 12,
                ),
              ),
            ],
            const SizedBox(height: 12),
            OutlinedButton(
              onPressed: () => context.goNamed('home'),
              child: const Text('Back to home'),
            ),
            const SizedBox(height: 24),
          ],
        ),
      ),
    );
  }
}
