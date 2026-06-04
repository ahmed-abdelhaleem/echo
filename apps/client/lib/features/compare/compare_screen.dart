import 'package:dio/dio.dart';
import 'package:echo_client/features/auth/auth_controller.dart';
import 'package:echo_client/services/api_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

class CompareScreen extends ConsumerStatefulWidget {
  const CompareScreen({required this.token, super.key});

  final String token;

  @override
  ConsumerState<CompareScreen> createState() => _CompareScreenState();
}

class _CompareScreenState extends ConsumerState<CompareScreen> {
  ComparisonPublicPayload? _payload;
  ComparisonSharePayload? _share;
  String? _error;
  bool _loading = true;
  bool _enablingShare = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });

    final api = ref.read(apiClientProvider);
    try {
      final payload = await api.getComparisonPublic(token: widget.token);
      if (!mounted) {
        return;
      }
      setState(() {
        _payload = payload;
        _loading = false;
      });
    } on CompareNotFound {
      if (!mounted) {
        return;
      }
      setState(() {
        _error = 'Comparison not found or revoked.';
        _loading = false;
      });
    } on CompareExpired {
      if (!mounted) {
        return;
      }
      setState(() {
        _error = 'Comparison link has expired.';
        _loading = false;
      });
    } on DioException catch (e) {
      if (!mounted) {
        return;
      }
      setState(() {
        _error = 'Could not load comparison: ${e.message ?? 'network error'}';
        _loading = false;
      });
    } catch (e) {
      if (!mounted) {
        return;
      }
      setState(() {
        _error = 'Unexpected error: $e';
        _loading = false;
      });
    }
  }

  Future<void> _enableShare() async {
    setState(() {
      _enablingShare = true;
      _error = null;
    });
    final api = ref.read(apiClientProvider);
    try {
      final share = await api.enableComparisonShare(token: widget.token);
      if (!mounted) {
        return;
      }
      setState(() {
        _share = share;
        _enablingShare = false;
      });
    } on CompareUnauthorised {
      if (!mounted) {
        return;
      }
      setState(() {
        _error = 'Sign in required to publish a share link.';
        _enablingShare = false;
      });
    } on CompareForbidden {
      if (!mounted) {
        return;
      }
      setState(() {
        _error = 'Your account is not allowed to publish this comparison.';
        _enablingShare = false;
      });
    } on CompareConflict {
      if (!mounted) {
        return;
      }
      setState(() {
        _error = 'Comparison must be accepted before publishing.';
        _enablingShare = false;
      });
    } on CompareNotFound {
      if (!mounted) {
        return;
      }
      setState(() {
        _error = 'Comparison not found.';
        _enablingShare = false;
      });
    } on DioException catch (e) {
      if (!mounted) {
        return;
      }
      setState(() {
        _error =
            'Could not publish share link: ${e.message ?? 'network error'}';
        _enablingShare = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final auth = ref.watch(authControllerProvider);
    final signedIn = auth is AuthStateSignedIn;

    return Scaffold(
      appBar: AppBar(title: const Text('Friend comparison')),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: _loading
              ? const Center(child: CircularProgressIndicator())
              : _error != null
                  ? _CompareErrorView(message: _error!)
                  : _CompareBody(
                      payload: _payload!,
                      signedIn: signedIn,
                      share: _share,
                      enablingShare: _enablingShare,
                      onEnableShare: _enableShare,
                    ),
        ),
      ),
    );
  }
}

class _CompareBody extends StatelessWidget {
  const _CompareBody({
    required this.payload,
    required this.signedIn,
    required this.share,
    required this.enablingShare,
    required this.onEnableShare,
  });

  final ComparisonPublicPayload payload;
  final bool signedIn;
  final ComparisonSharePayload? share;
  final bool enablingShare;
  final VoidCallback onEnableShare;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            'Season: ${payload.seasonId}',
            style: theme.textTheme.titleMedium,
          ),
          const SizedBox(height: 12),
          Row(
            children: <Widget>[
              Expanded(
                child: _ComparePortrait(
                  title: 'Inviter',
                  url: payload.inviterPngUrl,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _ComparePortrait(
                  title: 'Invitee',
                  url: payload.inviteePngUrl,
                ),
              ),
            ],
          ),
          const SizedBox(height: 20),
          Text(
            'Divergence moment',
            style: theme.textTheme.titleMedium,
          ),
          const SizedBox(height: 8),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text('Vignette: ${payload.vignetteId}'),
                  const SizedBox(height: 4),
                  Text('Inviter choice: ${payload.inviterChoice}'),
                  Text('Invitee choice: ${payload.inviteeChoice}'),
                ],
              ),
            ),
          ),
          const SizedBox(height: 20),
          if (signedIn && share == null)
            FilledButton(
              onPressed: enablingShare ? null : onEnableShare,
              child: Text(
                  enablingShare ? 'Publishing…' : 'Enable public share link'),
            ),
          if (signedIn && share != null) ...<Widget>[
            const Text('Public share link:'),
            const SizedBox(height: 6),
            SelectableText(share!.shareUrl),
          ],
          if (!signedIn) ...<Widget>[
            const Text('Sign in to enable a public share link.'),
            const SizedBox(height: 8),
            OutlinedButton(
              onPressed: () => context.goNamed('login'),
              child: const Text('Sign in'),
            ),
          ],
        ],
      ),
    );
  }
}

class _ComparePortrait extends StatelessWidget {
  const _ComparePortrait({
    required this.title,
    required this.url,
  });

  final String title;
  final String url;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(title),
        const SizedBox(height: 6),
        AspectRatio(
          aspectRatio: 1,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(12),
            child: Image.network(
              url,
              fit: BoxFit.cover,
              errorBuilder: (_, __, ___) => const ColoredBox(
                color: Color(0x22000000),
                child: Center(child: Text('Image unavailable')),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _CompareErrorView extends StatelessWidget {
  const _CompareErrorView({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Text(
            message,
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 12),
          OutlinedButton(
            onPressed: () => context.goNamed('home'),
            child: const Text('Back to home'),
          ),
        ],
      ),
    );
  }
}

class CompareAcceptScreen extends ConsumerStatefulWidget {
  const CompareAcceptScreen({required this.token, super.key});

  final String token;

  @override
  ConsumerState<CompareAcceptScreen> createState() =>
      _CompareAcceptScreenState();
}

class _CompareAcceptScreenState extends ConsumerState<CompareAcceptScreen> {
  final TextEditingController _playthroughIdController =
      TextEditingController();
  bool _submitting = false;
  String? _message;

  @override
  void dispose() {
    _playthroughIdController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final playthroughId = _playthroughIdController.text.trim();
    if (playthroughId.isEmpty) {
      setState(() {
        _message = 'Playthrough ID is required.';
      });
      return;
    }

    setState(() {
      _submitting = true;
      _message = null;
    });

    final api = ref.read(apiClientProvider);
    try {
      await api.acceptComparisonInvite(
        token: widget.token,
        playthroughId: playthroughId,
      );
      if (!mounted) {
        return;
      }
      context.go('/compare/${widget.token}');
    } on CompareForbidden {
      setState(() {
        _message = 'Your account is not eligible to accept this invite.';
        _submitting = false;
      });
    } on CompareNotFound {
      setState(() {
        _message = 'Comparison invite not found.';
        _submitting = false;
      });
    } on CompareExpired {
      setState(() {
        _message = 'Comparison invite expired.';
        _submitting = false;
      });
    } on CompareConflict {
      setState(() {
        _message = 'Comparison invite is no longer pending.';
        _submitting = false;
      });
    } on DioException catch (e) {
      setState(() {
        _message = 'Could not accept invite: ${e.message ?? 'network error'}';
        _submitting = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final auth = ref.watch(authControllerProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('Accept comparison invite')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: auth is AuthStateSignedIn
            ? Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  const Text('Paste your completed remote playthrough ID:'),
                  const SizedBox(height: 8),
                  TextField(
                    key: const Key('compare.accept.playthroughId'),
                    controller: _playthroughIdController,
                    decoration: const InputDecoration(
                      hintText: 'xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx',
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 12),
                  FilledButton(
                    onPressed: _submitting ? null : _submit,
                    child: Text(_submitting ? 'Accepting…' : 'Accept invite'),
                  ),
                  if (_message != null) ...<Widget>[
                    const SizedBox(height: 8),
                    Text(_message!),
                  ],
                ],
              )
            : Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  const Text('Sign in to accept this comparison invite.'),
                  const SizedBox(height: 8),
                  OutlinedButton(
                    onPressed: () => context.goNamed('login'),
                    child: const Text('Sign in'),
                  ),
                ],
              ),
      ),
    );
  }
}
