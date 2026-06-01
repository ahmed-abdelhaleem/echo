// SignUpScreen — email + password + display name + birthdate.
//
// Flow:
//   1. User fills in birthdate.
//   2. On birthdate blur we call /auth/preflight; under-13 surfaces
//      a field-level error and disables the submit button.
//   3. On submit we run client-side validation (email shape, password
//      length, displayName non-empty) and then call Kratos via
//      AuthController.signUp.
//   4. Failures are mapped to typed AuthException kinds — under-13
//      (defense in depth: hook fires even if preflight was bypassed),
//      duplicate email (validation), password too weak (validation),
//      anything else (generic banner).
//
// We intentionally surface every rejection on the offending field
// rather than as a top-level banner where possible — that's what the
// AuthException.field plumbing is for.

import 'package:echo_client/features/auth/auth_controller.dart';
import 'package:echo_client/services/auth_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

class SignUpScreen extends ConsumerStatefulWidget {
  const SignUpScreen({super.key});

  @override
  ConsumerState<SignUpScreen> createState() => _SignUpScreenState();
}

class _SignUpScreenState extends ConsumerState<SignUpScreen> {
  final _formKey = GlobalKey<FormState>();
  final _emailCtrl = TextEditingController();
  final _passwordCtrl = TextEditingController();
  final _displayNameCtrl = TextEditingController();
  final _birthdateCtrl = TextEditingController();

  bool _busy = false;
  String? _emailError;
  String? _passwordError;
  String? _birthdateError;
  String? _topError;

  @override
  void dispose() {
    _emailCtrl.dispose();
    _passwordCtrl.dispose();
    _displayNameCtrl.dispose();
    _birthdateCtrl.dispose();
    super.dispose();
  }

  Future<void> _onBirthdateBlur() async {
    final value = _birthdateCtrl.text.trim();
    if (value.isEmpty) {
      setState(() => _birthdateError = null);
      return;
    }
    try {
      final decision =
          await ref.read(authControllerProvider.notifier).preflight(value);
      if (!mounted) return;
      if (decision.allowed) {
        setState(() => _birthdateError = null);
      } else if (decision.reason == 'under_13') {
        setState(() => _birthdateError = 'Echo is for ages 13 and up.');
      } else {
        setState(
            () => _birthdateError = 'Please enter a valid date (YYYY-MM-DD).');
      }
    } catch (_) {
      // Network blip during preflight — don't block the user; the
      // before-registration hook will still gate on submit.
      if (!mounted) return;
      setState(() => _birthdateError = null);
    }
  }

  Future<void> _onSubmit() async {
    setState(() => _topError = null);
    if (!(_formKey.currentState?.validate() ?? false)) return;
    if (_birthdateError != null) return;
    setState(() => _busy = true);
    try {
      await ref.read(authControllerProvider.notifier).signUp(
            email: _emailCtrl.text.trim(),
            password: _passwordCtrl.text,
            displayName: _displayNameCtrl.text.trim(),
            birthdate: _birthdateCtrl.text.trim(),
          );
      if (!mounted) return;
      context.goNamed('home');
    } on AuthException catch (e) {
      if (!mounted) return;
      setState(() {
        switch (e.kind) {
          case AuthFailureKind.under13:
            _birthdateError = e.message ?? 'Echo is for ages 13 and up.';
          case AuthFailureKind.validation:
            switch (e.field) {
              case 'traits.email':
                _emailError = e.message ?? 'Please enter a valid email.';
              case 'password':
                _passwordError =
                    e.message ?? 'Please use a longer, harder-to-guess password.';
              case 'traits.birthdate':
                _birthdateError = e.message ?? 'Please enter a valid date.';
              default:
                _topError = e.message ?? 'Something didn\'t look right.';
            }
          case AuthFailureKind.invalidCredentials:
            _topError = 'An account with that email already exists.';
          case AuthFailureKind.unauthorised:
          case AuthFailureKind.other:
            _topError = 'Sign-up failed. Please try again.';
        }
      });
    } catch (_) {
      if (!mounted) return;
      setState(
          () => _topError = 'Echo is having a moment. Please try again.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Create your Echo account')),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 480),
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Form(
                key: _formKey,
                child: ListView(
                  shrinkWrap: true,
                  children: <Widget>[
                    if (_topError != null) ...<Widget>[
                      _ErrorBanner(message: _topError!),
                      const SizedBox(height: 12),
                    ],
                    TextFormField(
                      key: const Key('signup.email'),
                      controller: _emailCtrl,
                      keyboardType: TextInputType.emailAddress,
                      autocorrect: false,
                      decoration: InputDecoration(
                        labelText: 'Email',
                        errorText: _emailError,
                      ),
                      validator: (v) {
                        final s = (v ?? '').trim();
                        if (s.isEmpty) return 'Please enter your email.';
                        if (!s.contains('@') || !s.contains('.')) {
                          return 'That doesn\'t look like an email.';
                        }
                        return null;
                      },
                      onChanged: (_) => setState(() => _emailError = null),
                    ),
                    const SizedBox(height: 12),
                    TextFormField(
                      key: const Key('signup.displayName'),
                      controller: _displayNameCtrl,
                      decoration: const InputDecoration(
                        labelText: 'Display name',
                        helperText: 'How Echo addresses you.',
                      ),
                      validator: (v) {
                        final s = (v ?? '').trim();
                        if (s.isEmpty) return 'Please enter a display name.';
                        if (s.length > 50) return 'Keep it under 50 characters.';
                        return null;
                      },
                    ),
                    const SizedBox(height: 12),
                    TextFormField(
                      key: const Key('signup.password'),
                      controller: _passwordCtrl,
                      obscureText: true,
                      decoration: InputDecoration(
                        labelText: 'Password',
                        helperText: 'At least 8 characters.',
                        errorText: _passwordError,
                      ),
                      validator: (v) {
                        if ((v ?? '').length < 8) {
                          return 'Use at least 8 characters.';
                        }
                        return null;
                      },
                      onChanged: (_) =>
                          setState(() => _passwordError = null),
                    ),
                    const SizedBox(height: 12),
                    TextFormField(
                      key: const Key('signup.birthdate'),
                      controller: _birthdateCtrl,
                      keyboardType: TextInputType.datetime,
                      decoration: InputDecoration(
                        labelText: 'Birthdate (YYYY-MM-DD)',
                        helperText:
                            'Echo is for ages 13+ and tailors its tone for 13–17.',
                        errorText: _birthdateError,
                      ),
                      validator: (v) {
                        final s = (v ?? '').trim();
                        if (s.isEmpty) return 'Please enter your birthdate.';
                        if (!RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(s)) {
                          return 'Use YYYY-MM-DD.';
                        }
                        return null;
                      },
                      onChanged: (_) =>
                          setState(() => _birthdateError = null),
                      onEditingComplete: _onBirthdateBlur,
                      onTapOutside: (_) => _onBirthdateBlur(),
                    ),
                    const SizedBox(height: 24),
                    FilledButton(
                      key: const Key('signup.submit'),
                      onPressed: _busy ? null : _onSubmit,
                      child: Text(_busy ? 'Creating…' : 'Create account'),
                    ),
                    const SizedBox(height: 12),
                    TextButton(
                      key: const Key('signup.toLogin'),
                      onPressed: _busy
                          ? null
                          : () => context.goNamed('login'),
                      child: const Text('Already have an account? Sign in.'),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _ErrorBanner extends StatelessWidget {
  const _ErrorBanner({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const Key('auth.topError'),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.errorContainer,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        message,
        style: TextStyle(
          color: Theme.of(context).colorScheme.onErrorContainer,
        ),
      ),
    );
  }
}
