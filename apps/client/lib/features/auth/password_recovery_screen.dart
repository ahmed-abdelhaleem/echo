// PasswordRecoveryScreen — single-field flow that triggers a Kratos
// recovery email. By design we always show the same confirmation copy
// regardless of whether the email is registered — that's the
// privacy-correct behaviour (don't leak account existence).

import 'package:echo_client/features/auth/auth_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

class PasswordRecoveryScreen extends ConsumerStatefulWidget {
  const PasswordRecoveryScreen({super.key});

  @override
  ConsumerState<PasswordRecoveryScreen> createState() =>
      _PasswordRecoveryScreenState();
}

class _PasswordRecoveryScreenState
    extends ConsumerState<PasswordRecoveryScreen> {
  final _formKey = GlobalKey<FormState>();
  final _emailCtrl = TextEditingController();

  bool _busy = false;
  bool _submitted = false;
  String? _topError;

  @override
  void dispose() {
    _emailCtrl.dispose();
    super.dispose();
  }

  Future<void> _onSubmit() async {
    setState(() => _topError = null);
    if (!(_formKey.currentState?.validate() ?? false)) return;
    setState(() => _busy = true);
    try {
      await ref
          .read(authControllerProvider.notifier)
          .recoverPassword(_emailCtrl.text.trim());
      if (!mounted) return;
      setState(() => _submitted = true);
    } catch (_) {
      if (!mounted) return;
      setState(
        () => _topError = 'Echo is having a moment. Please try again.',
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Reset your Echo password')),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 480),
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: _submitted ? _buildConfirmation() : _buildForm(),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildConfirmation() {
    return Column(
      key: const Key('recover.confirmation'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Text(
          'Check your email',
          style: Theme.of(context).textTheme.headlineSmall,
        ),
        const SizedBox(height: 12),
        const Text(
          'If an Echo account exists for that email, we\'ve sent a link to '
          'reset your password. The link is valid for 1 hour.',
        ),
        const SizedBox(height: 24),
        FilledButton(
          key: const Key('recover.toLogin'),
          onPressed: () => context.goNamed('login'),
          child: const Text('Back to sign in'),
        ),
      ],
    );
  }

  Widget _buildForm() {
    return Form(
      key: _formKey,
      child: ListView(
        shrinkWrap: true,
        children: <Widget>[
          if (_topError != null) ...<Widget>[
            Container(
              key: const Key('recover.topError'),
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
            const SizedBox(height: 12),
          ],
          TextFormField(
            key: const Key('recover.email'),
            controller: _emailCtrl,
            keyboardType: TextInputType.emailAddress,
            autocorrect: false,
            decoration: const InputDecoration(
              labelText: 'Email',
              helperText: 'We\'ll email you a link to set a new password.',
            ),
            validator: (v) {
              final s = (v ?? '').trim();
              if (s.isEmpty) return 'Please enter your email.';
              if (!s.contains('@') || !s.contains('.')) {
                return 'That doesn\'t look like an email.';
              }
              return null;
            },
          ),
          const SizedBox(height: 24),
          FilledButton(
            key: const Key('recover.submit'),
            onPressed: _busy ? null : _onSubmit,
            child: Text(_busy ? 'Sending…' : 'Send reset link'),
          ),
          const SizedBox(height: 12),
          TextButton(
            key: const Key('recover.toLogin'),
            onPressed: _busy ? null : () => context.goNamed('login'),
            child: const Text('Back to sign in'),
          ),
        ],
      ),
    );
  }
}
