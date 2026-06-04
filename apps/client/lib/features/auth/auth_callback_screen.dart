// Handles the browser return from Google OIDC (Kratos redirects here with
// `?flow=<id>&type=registration|login`).

import 'package:echo_client/features/auth/auth_controller.dart';
import 'package:echo_client/services/auth_client.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

/// Builds the OAuth return URL for the current Flutter web origin.
String buildOidcReturnUrl(String type) {
  // Keep return_to stable for local web dev. Kratos allow-lists this URL.
  if (kIsWeb &&
      (Uri.base.host == 'localhost' || Uri.base.host == '127.0.0.1')) {
    return Uri(
      scheme: Uri.base.scheme,
      host: Uri.base.host,
      port: 8082,
      path: '/auth/callback',
      queryParameters: <String, String>{'type': type},
    ).toString();
  }
  final base = Uri.base;
  return Uri(
    scheme: base.scheme,
    host: base.host,
    port: base.hasPort ? base.port : null,
    path: '/auth/callback',
    queryParameters: <String, String>{'type': type},
  ).toString();
}

class AuthCallbackScreen extends ConsumerStatefulWidget {
  const AuthCallbackScreen({super.key});

  @override
  ConsumerState<AuthCallbackScreen> createState() => _AuthCallbackScreenState();
}

class _AuthCallbackScreenState extends ConsumerState<AuthCallbackScreen> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _complete());
  }

  Future<void> _complete() async {
    final params = GoRouterState.of(context).uri.queryParameters;
    final flowId = params['flow'];
    final type = params['type'] ?? 'login';
    if (flowId == null || flowId.isEmpty) {
      if (!mounted) return;
      context.goNamed('login');
      return;
    }
    try {
      await ref.read(authControllerProvider.notifier).completeOidc(
            flowId: flowId,
            isRegistration: type == 'registration',
          );
      if (!mounted) return;
      context.goNamed('home');
    } on AuthException catch (e) {
      if (!mounted) return;
      final dest = type == 'registration' ? 'signup' : 'login';
      context.goNamed(dest, extra: e.message);
    } catch (_) {
      if (!mounted) return;
      context.goNamed('login');
    }
  }

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      body: Center(child: CircularProgressIndicator()),
    );
  }
}
