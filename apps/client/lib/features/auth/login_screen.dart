// LoginScreen — email + password. Routes to home on success, to
// /recover for password recovery, and to /signup for new accounts.

import 'package:echo_client/features/auth/auth_controller.dart';
import 'package:echo_client/services/auth_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

class LoginScreen extends ConsumerStatefulWidget {
  const LoginScreen({super.key});

  @override
  ConsumerState<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends ConsumerState<LoginScreen> {
  final _formKey = GlobalKey<FormState>();
  final _emailCtrl = TextEditingController();
  final _passwordCtrl = TextEditingController();

  bool _busy = false;
  String? _topError;

  @override
  void dispose() {
    _emailCtrl.dispose();
    _passwordCtrl.dispose();
    super.dispose();
  }

  Future<void> _onSubmit() async {
    setState(() => _topError = null);
    if (!(_formKey.currentState?.validate() ?? false)) return;
    setState(() => _busy = true);
    try {
      await ref.read(authControllerProvider.notifier).login(
            email: _emailCtrl.text.trim(),
            password: _passwordCtrl.text,
          );
      if (!mounted) return;
      context.goNamed('home');
    } on AuthException catch (e) {
      if (!mounted) return;
      setState(() {
        switch (e.kind) {
          case AuthFailureKind.invalidCredentials:
            _topError = 'Email or password is incorrect.';
          case AuthFailureKind.validation:
            _topError = e.message ?? 'Please check your details.';
          case AuthFailureKind.unauthorised:
          case AuthFailureKind.under13:
          case AuthFailureKind.other:
            _topError = 'Sign-in failed. Please try again.';
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
      appBar: AppBar(title: const Text('Sign in to Echo')),
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
                      Container(
                        key: const Key('login.topError'),
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: Theme.of(context).colorScheme.errorContainer,
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Text(
                          _topError!,
                          style: TextStyle(
                            color: Theme.of(context)
                                .colorScheme
                                .onErrorContainer,
                          ),
                        ),
                      ),
                      const SizedBox(height: 12),
                    ],
                    TextFormField(
                      key: const Key('login.email'),
                      controller: _emailCtrl,
                      keyboardType: TextInputType.emailAddress,
                      autocorrect: false,
                      decoration: const InputDecoration(labelText: 'Email'),
                      validator: (v) {
                        final s = (v ?? '').trim();
                        if (s.isEmpty) return 'Please enter your email.';
                        return null;
                      },
                    ),
                    const SizedBox(height: 12),
                    TextFormField(
                      key: const Key('login.password'),
                      controller: _passwordCtrl,
                      obscureText: true,
                      decoration: const InputDecoration(labelText: 'Password'),
                      validator: (v) {
                        if ((v ?? '').isEmpty) {
                          return 'Please enter your password.';
                        }
                        return null;
                      },
                    ),
                    const SizedBox(height: 24),
                    FilledButton(
                      key: const Key('login.submit'),
                      onPressed: _busy ? null : _onSubmit,
                      child: Text(_busy ? 'Signing in…' : 'Sign in'),
                    ),
                    const SizedBox(height: 8),
                    TextButton(
                      key: const Key('login.toRecover'),
                      onPressed: _busy
                          ? null
                          : () => context.goNamed('recover'),
                      child: const Text('Forgot your password?'),
                    ),
                    const SizedBox(height: 4),
                    TextButton(
                      key: const Key('login.toSignUp'),
                      onPressed: _busy
                          ? null
                          : () => context.goNamed('signup'),
                      child: const Text('New here? Create an account.'),
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
