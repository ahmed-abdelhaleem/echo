// Subscription / paywall screen (T-MONEY-001 / F-MONEY-001).
//
// Shows the Echo+ benefits and lets the user subscribe via:
//   - Apple StoreKit2 (iOS/macOS App Store)
//   - Google Play Billing (Android)
//   - Stripe Checkout  (Windows/macOS direct download)
//
// ⚠️  HUMAN REVIEW REQUIRED — this screen contains billing-adjacent UI.
//     Per AGENTS.md escalation rule #10, do not merge without explicit
//     human review and approval.

import 'dart:io';

import 'package:echo_client/services/api_client.dart';
import 'package:echo_client/services/subscription_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

/// The paywall / subscription management screen.
///
/// - If the user is already subscribed, shows their current plan + a
///   "Manage subscription" button.
/// - If the user is on the free tier, shows the Echo+ benefits and the
///   monthly / annual purchase buttons.
class SubscriptionScreen extends ConsumerWidget {
  const SubscriptionScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final statusAsync = ref.watch(subscriptionStatusProvider);
    final productsAsync = ref.watch(iapProductsProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('Echo+')),
      body: statusAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (err, _) => _ErrorView(
          message: err.toString(),
          onRetry: () => ref.invalidate(subscriptionStatusProvider),
        ),
        data: (status) => status.isPremium
            ? _ActiveView(status: status)
            : _PaywallView(productsAsync: productsAsync),
      ),
    );
  }
}

// ─── Active subscription view ─────────────────────────────────────────────────

class _ActiveView extends ConsumerWidget {
  const _ActiveView({required this.status});

  final SubscriptionStatus status;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32.0),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.star_rounded,
                size: 64, color: theme.colorScheme.primary),
            const SizedBox(height: 16),
            Text('Echo+ Active', style: theme.textTheme.headlineSmall),
            const SizedBox(height: 8),
            Text(
              'Thank you for supporting Echo.',
              style: theme.textTheme.bodyMedium,
              textAlign: TextAlign.center,
            ),
            if (status.currentPeriodEnd != null) ...[
              const SizedBox(height: 8),
              Text(
                'Renews on ${_formatDate(status.currentPeriodEnd!)}',
                style: theme.textTheme.bodySmall,
              ),
            ],
            const SizedBox(height: 32),
            OutlinedButton.icon(
              key: const Key('subscription.manage'),
              onPressed: () => _manageSubscription(context, ref),
              icon: const Icon(Icons.settings_outlined),
              label: const Text('Manage subscription'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _manageSubscription(BuildContext context, WidgetRef ref) async {
    final notifier = ref.read(subscriptionStatusProvider.notifier);
    final result = await notifier.manageSubscription();

    switch (result) {
      case ManageSubscriptionResultDesktop(:final portalUrl):
        final uri = Uri.parse(portalUrl);
        if (await canLaunchUrl(uri)) {
          await launchUrl(uri, mode: LaunchMode.externalApplication);
        }
      case ManageSubscriptionResultPlatformDelegated():
        // Platform handles it natively — nothing to do.
        break;
      case ManageSubscriptionResultError(:final message):
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Error: $message')),
          );
        }
    }
  }

  String _formatDate(String iso) {
    try {
      final dt = DateTime.parse(iso);
      return '${dt.day}/${dt.month}/${dt.year}';
    } catch (_) {
      return iso;
    }
  }
}

// ─── Paywall view ─────────────────────────────────────────────────────────────

class _PaywallView extends ConsumerStatefulWidget {
  const _PaywallView({required this.productsAsync});

  final AsyncValue<List<dynamic>> productsAsync;

  @override
  ConsumerState<_PaywallView> createState() => _PaywallViewState();
}

class _PaywallViewState extends ConsumerState<_PaywallView> {
  bool _purchasing = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return SingleChildScrollView(
      padding: const EdgeInsets.all(24.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Header.
          Center(
            child: Icon(
              Icons.auto_awesome_rounded,
              size: 56,
              color: theme.colorScheme.primary,
            ),
          ),
          const SizedBox(height: 16),
          Text(
            'Echo+',
            textAlign: TextAlign.center,
            style: theme.textTheme.headlineMedium
                ?.copyWith(fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 8),
          Text(
            'Unlock the full Echo experience.',
            textAlign: TextAlign.center,
            style: theme.textTheme.bodyLarge,
          ),
          const SizedBox(height: 32),

          // Benefits list.
          ..._benefits.map(
            (b) => Padding(
              padding: const EdgeInsets.symmetric(vertical: 6.0),
              child: Row(
                children: [
                  Icon(
                    Icons.check_circle_outline,
                    size: 20,
                    color: theme.colorScheme.primary,
                  ),
                  const SizedBox(width: 12),
                  Expanded(child: Text(b, style: theme.textTheme.bodyMedium)),
                ],
              ),
            ),
          ),
          const SizedBox(height: 32),

          // Purchase buttons.
          if (_purchasing)
            const Center(child: CircularProgressIndicator())
          else ...[
            _PurchaseButton(
              key: const Key('subscription.buyYearly'),
              label: 'Echo+ Annual',
              sublabel: '€39.99 / year  ·  Save 33%',
              isPrimary: true,
              onPressed: () => _purchase(kEchoPlusYearlyProductId),
            ),
            const SizedBox(height: 12),
            _PurchaseButton(
              key: const Key('subscription.buyMonthly'),
              label: 'Echo+ Monthly',
              sublabel: '€4.99 / month',
              isPrimary: false,
              onPressed: () => _purchase(kEchoPlusMonthlyProductId),
            ),
          ],
          const SizedBox(height: 16),

          // Legal.
          Text(
            Platform.isIOS || Platform.isAndroid
                ? 'Payment processed by ${Platform.isIOS ? "Apple" : "Google"}.'
                    ' Subscriptions auto-renew. Cancel anytime.'
                : 'Payment processed by Stripe. Cancel anytime.',
            textAlign: TextAlign.center,
            style: theme.textTheme.bodySmall
                ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
        ],
      ),
    );
  }

  static const List<String> _benefits = [
    'Full Season library — current & back catalog',
    'Unlimited friend comparisons',
    'Deeper reflection — extended prose and Portrait breakdown',
    'Early access to new Seasons (1 week before free)',
    'Constellation — archive of all your Portraits',
  ];

  Future<void> _purchase(String productId) async {
    setState(() => _purchasing = true);
    try {
      final notifier = ref.read(subscriptionStatusProvider.notifier);
      final result = await notifier.purchase(productId);

      switch (result) {
        case PurchaseResultDesktop(:final checkoutUrl):
          final uri = Uri.parse(checkoutUrl);
          if (await canLaunchUrl(uri)) {
            await launchUrl(uri, mode: LaunchMode.externalApplication);
          }
        case PurchaseResultPending():
          // Outcome arrives via IAP purchase stream — notifier handles it.
          break;
        case PurchaseResultStoreUnavailable():
          _showError('Store is not available on this device.');
        case PurchaseResultProductNotFound():
          _showError('Product not found. Please try again later.');
        case PurchaseResultError(:final message):
          _showError(message);
      }
    } finally {
      if (mounted) setState(() => _purchasing = false);
    }
  }

  void _showError(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
  }
}

// ─── Purchase button ──────────────────────────────────────────────────────────

class _PurchaseButton extends StatelessWidget {
  const _PurchaseButton({
    super.key,
    required this.label,
    required this.sublabel,
    required this.isPrimary,
    required this.onPressed,
  });

  final String label;
  final String sublabel;
  final bool isPrimary;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final child = Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(label, style: const TextStyle(fontWeight: FontWeight.bold)),
        const SizedBox(height: 2),
        Text(
          sublabel,
          style: theme.textTheme.bodySmall
              ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
        ),
      ],
    );

    if (isPrimary) {
      return ElevatedButton(
        onPressed: onPressed,
        style: ElevatedButton.styleFrom(
          padding: const EdgeInsets.symmetric(vertical: 16),
        ),
        child: child,
      );
    }
    return OutlinedButton(
      onPressed: onPressed,
      style: OutlinedButton.styleFrom(
        padding: const EdgeInsets.symmetric(vertical: 16),
      ),
      child: child,
    );
  }
}

// ─── Error view ───────────────────────────────────────────────────────────────

class _ErrorView extends StatelessWidget {
  const _ErrorView({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32.0),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.error_outline, size: 48),
            const SizedBox(height: 16),
            Text(message, textAlign: TextAlign.center),
            const SizedBox(height: 16),
            ElevatedButton(
              key: const Key('subscription.retry'),
              onPressed: onRetry,
              child: const Text('Retry'),
            ),
          ],
        ),
      ),
    );
  }
}
