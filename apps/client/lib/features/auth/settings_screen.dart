// SettingsScreen — minimal M2 settings surface:
//   - shows email + display name from /whoami (or session if whoami
//     hasn't returned yet)
//   - shows the youth-safe flag transparently to the user so 13–17
//     players know the experience is tailored
//   - "Sign out" rotates back to anonymous
//   - "Delete account" pops a confirmation dialog and, if confirmed,
//     calls DELETE /me, then rotates to anonymous
//
// We intentionally don't expose anything else here in M2 — additional
// settings (theme, notifications, data export, parental contact for
// minors) belong in follow-up PRs once the underlying servers exist.

import 'package:echo_client/features/auth/auth_controller.dart';
import 'package:echo_client/services/auth_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

class SettingsScreen extends ConsumerStatefulWidget {
  const SettingsScreen({super.key});

  @override
  ConsumerState<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends ConsumerState<SettingsScreen> {
  bool _busy = false;
  String? _topError;

  Future<void> _confirmAndDelete() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete your Echo account?'),
        content: const Text(
          'This permanently deletes your account and signs you out on '
          'every device. Your playthroughs are retained in anonymised '
          'form for safety review per Echo\'s privacy policy.',
        ),
        actions: <Widget>[
          TextButton(
            key: const Key('settings.deleteCancel'),
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton.tonal(
            key: const Key('settings.deleteConfirm'),
            style: FilledButton.styleFrom(
              foregroundColor: Theme.of(ctx).colorScheme.onErrorContainer,
              backgroundColor: Theme.of(ctx).colorScheme.errorContainer,
            ),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Delete forever'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() {
      _busy = true;
      _topError = null;
    });
    try {
      await ref.read(authControllerProvider.notifier).delete();
      if (!mounted) return;
      context.goNamed('login');
    } catch (_) {
      if (!mounted) return;
      setState(
          () => _topError = 'We couldn\'t delete your account. Please try again.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _signOut() {
    ref.read(authControllerProvider.notifier).signOut();
    context.goNamed('login');
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(authControllerProvider);
    if (state is! AuthStateSignedIn) {
      // The router redirect should prevent us from rendering this
      // screen anonymous, but if it ever does happen we fall through
      // to a benign empty state.
      return Scaffold(
        appBar: AppBar(title: const Text('Settings')),
        body: const Center(child: Text('You are signed out.')),
      );
    }
    final email = state.whoami?.email ?? state.session.email;
    final displayName =
        state.whoami?.displayName ?? state.session.displayName ?? '—';
    final youthSafe = state.youthSafe;

    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 600),
            child: ListView(
              padding: const EdgeInsets.all(24),
              children: <Widget>[
                if (_topError != null) ...<Widget>[
                  Container(
                    key: const Key('settings.topError'),
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: Theme.of(context).colorScheme.errorContainer,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(
                      _topError!,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.onErrorContainer,
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                ],
                Text('Account', style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: 8),
                ListTile(
                  key: const Key('settings.email'),
                  title: const Text('Email'),
                  subtitle: Text(email),
                ),
                ListTile(
                  key: const Key('settings.displayName'),
                  title: const Text('Display name'),
                  subtitle: Text(displayName),
                ),
                if (youthSafe)
                  Card(
                    key: const Key('settings.youthSafeCard'),
                    color: Theme.of(context).colorScheme.surfaceContainerHighest,
                    child: const Padding(
                      padding: EdgeInsets.all(16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          Text(
                            'Youth-safe mode is on',
                            style: TextStyle(fontWeight: FontWeight.w600),
                          ),
                          SizedBox(height: 8),
                          Text(
                            'Sharing is off, language is tightened, and your '
                            'data has stricter retention. This stays on until '
                            'you turn 18.',
                          ),
                        ],
                      ),
                    ),
                  ),
                const SizedBox(height: 24),
                FilledButton.tonal(
                  key: const Key('settings.signOut'),
                  onPressed: _busy ? null : _signOut,
                  child: const Text('Sign out'),
                ),
                const SizedBox(height: 12),
                TextButton(
                  key: const Key('settings.delete'),
                  onPressed: _busy ? null : _confirmAndDelete,
                  style: TextButton.styleFrom(
                    foregroundColor: Theme.of(context).colorScheme.error,
                  ),
                  child: Text(_busy ? 'Deleting…' : 'Delete account'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
