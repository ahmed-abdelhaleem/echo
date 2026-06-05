// Subscription service (T-MONEY-001 / F-MONEY-001).
//
// Handles Echo+ subscription state across three payment stores:
//   - Apple StoreKit2  (iOS/macOS App Store)
//   - Google Play Billing (Android)
//   - Stripe Checkout   (Windows/macOS direct download)
//
// ⚠️  HUMAN REVIEW REQUIRED — this file contains billing logic.
//     Per AGENTS.md escalation rule #10, do not merge without explicit
//     human review and approval.
//
// Architecture:
//   - On iOS and Android, [in_app_purchase] handles the StoreKit2 /
//     Google Play Billing flow. Successful purchases are acknowledged
//     via the server so the webhook table stays consistent.
//   - On Windows and macOS (non-App-Store builds), the user is redirected
//     to a Stripe Checkout URL in their browser.
//   - [subscriptionStatusProvider] always reads the authoritative state
//     from the server so the paywall reflects the correct tier even after
//     a cross-device subscription change.

import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:in_app_purchase/in_app_purchase.dart';

import 'api_client.dart';

// ─── Product ID constants ─────────────────────────────────────────────────────

/// Apple App Store / Google Play product IDs for the two Echo+ plans.
/// These must match the product IDs configured in App Store Connect and
/// the Google Play Console.
const String kEchoPlusMonthlyProductId = 'echo_plus_monthly';
const String kEchoPlusYearlyProductId = 'echo_plus_yearly';

const Set<String> _productIds = {
  kEchoPlusMonthlyProductId,
  kEchoPlusYearlyProductId,
};

// ─── Providers ───────────────────────────────────────────────────────────────

/// The authoritative subscription status from the server.
/// Refreshes on first read. Call [SubscriptionNotifier.refresh()] after a
/// purchase to pick up the new state.
final AutoDisposeAsyncNotifierProvider<SubscriptionNotifier, SubscriptionStatus>
    subscriptionStatusProvider =
    AsyncNotifierProvider.autoDispose(() => SubscriptionNotifier());

/// The IAP products loaded from the store. Used to display pricing on the
/// paywall screen. Only meaningful on iOS and Android.
final FutureProvider<List<ProductDetails>> iapProductsProvider =
    FutureProvider((ref) async {
  if (!Platform.isIOS && !Platform.isAndroid) {
    return const <ProductDetails>[];
  }
  final iap = InAppPurchase.instance;
  final available = await iap.isAvailable();
  if (!available) {
    return const <ProductDetails>[];
  }
  final response = await iap.queryProductDetails(_productIds);
  return response.productDetails;
});

// ─── SubscriptionNotifier ─────────────────────────────────────────────────────

/// Notifier that exposes the current server-side [SubscriptionStatus] and
/// coordinates the purchase flow on iOS / Android.
class SubscriptionNotifier
    extends AutoDisposeAsyncNotifier<SubscriptionStatus> {
  StreamSubscription<List<PurchaseDetails>>? _purchaseSub;

  @override
  Future<SubscriptionStatus> build() async {
    // Listen to IAP purchase updates on mobile platforms.
    if (Platform.isIOS || Platform.isAndroid) {
      final iap = InAppPurchase.instance;
      unawaited(_purchaseSub?.cancel() ?? Future<void>.value());
      _purchaseSub = iap.purchaseStream.listen(
        _handlePurchaseUpdates,
        onError: (Object err) {
          // Log and swallow — the purchase stream should never error
          // in normal operation; if it does, the paywall will show a
          // retry option.
        },
      );
      ref.onDispose(() => _purchaseSub?.cancel());
    }

    return _fetchFromServer();
  }

  /// Re-fetches subscription status from the server.
  /// Call this after a purchase, restore, or from a pull-to-refresh.
  Future<void> refresh() async {
    state = const AsyncLoading();
    state = await AsyncValue.guard(_fetchFromServer);
  }

  /// Initiates a purchase of [productId] via the platform store.
  /// On desktop (non-mobile), opens a Stripe Checkout URL instead and
  /// returns [PurchaseResultDesktop] as the caller should handle the redirect.
  Future<PurchaseResult> purchase(String productId) async {
    if (!Platform.isIOS && !Platform.isAndroid) {
      return _initiateStripeCheckout();
    }
    return _initiateIAP(productId);
  }

  /// Opens the store's subscription management surface.
  /// On desktop, opens the Stripe Billing Portal.
  Future<ManageSubscriptionResult> manageSubscription() async {
    if (!Platform.isIOS && !Platform.isAndroid) {
      return _openStripePortal();
    }
    // Delegate to the platform store's native subscription management.
    // InAppPurchase does not have a direct API for this; the user opens
    // Settings → Apple ID → Subscriptions (iOS) or Play Store → Subscriptions.
    return const ManageSubscriptionResultPlatformDelegated();
  }

  // ─── private ───────────────────────────────────────────────────────────────

  Future<SubscriptionStatus> _fetchFromServer() {
    final api = ref.read(apiClientProvider);
    return api.getSubscription();
  }

  Future<PurchaseResult> _initiateIAP(String productId) async {
    final iap = InAppPurchase.instance;
    final available = await iap.isAvailable();
    if (!available) {
      return const PurchaseResultStoreUnavailable();
    }

    final response = await iap.queryProductDetails({productId});
    if (response.productDetails.isEmpty) {
      return const PurchaseResultProductNotFound();
    }

    final purchaseParam = PurchaseParam(
      productDetails: response.productDetails.first,
    );
    try {
      await iap.buyNonConsumable(purchaseParam: purchaseParam);
      // The actual outcome arrives via purchaseStream → _handlePurchaseUpdates.
      return const PurchaseResultPending();
    } catch (e) {
      return PurchaseResultError(e.toString());
    }
  }

  Future<PurchaseResult> _initiateStripeCheckout() async {
    try {
      final api = ref.read(apiClientProvider);
      final session = await api.createStripeCheckout();
      return PurchaseResultDesktop(checkoutUrl: session.url);
    } catch (e) {
      return PurchaseResultError(e.toString());
    }
  }

  Future<ManageSubscriptionResult> _openStripePortal() async {
    try {
      final api = ref.read(apiClientProvider);
      final session = await api.createStripePortal();
      return ManageSubscriptionResultDesktop(portalUrl: session.url);
    } catch (e) {
      return ManageSubscriptionResultError(e.toString());
    }
  }

  void _handlePurchaseUpdates(List<PurchaseDetails> purchases) {
    for (final purchase in purchases) {
      switch (purchase.status) {
        case PurchaseStatus.purchased:
        case PurchaseStatus.restored:
          _completePurchase(purchase);
        case PurchaseStatus.error:
          // Surface the error via the subscription state so the paywall
          // can show a "purchase failed" message.
          state = AsyncError(
            purchase.error ?? 'Purchase failed',
            StackTrace.current,
          );
        case PurchaseStatus.canceled:
        case PurchaseStatus.pending:
          break;
      }
    }
  }

  Future<void> _completePurchase(PurchaseDetails purchase) async {
    final iap = InAppPurchase.instance;
    // Acknowledge the purchase with the server before completing with the store.
    // This creates the billing.subscriptions row so Pub/Sub webhooks can
    // match subsequent renewal events to this user.
    if (purchase.productID == kEchoPlusMonthlyProductId ||
        purchase.productID == kEchoPlusYearlyProductId) {
      if (Platform.isAndroid) {
        final token = purchase.verificationData.serverVerificationData;
        try {
          final api = ref.read(apiClientProvider);
          await api.acknowledgeGooglePurchase(
            purchaseToken: token,
            subscriptionId: purchase.productID,
          );
        } catch (_) {
          // Log but do not block completing the purchase — the server will
          // eventually catch up via the Pub/Sub webhook.
        }
      }
      // For Apple, the server receives the SUBSCRIBED notification via the
      // App Store Server Notifications webhook.
    }

    if (purchase.pendingCompletePurchase) {
      await iap.completePurchase(purchase);
    }

    // Re-fetch authoritative state from the server.
    await refresh();
  }
}

// ─── Result types ─────────────────────────────────────────────────────────────

/// Result of initiating a purchase.
sealed class PurchaseResult {
  const PurchaseResult();
}

/// Purchase was submitted to the store; outcome will arrive via purchaseStream.
class PurchaseResultPending extends PurchaseResult {
  const PurchaseResultPending();
}

/// Desktop: caller should open [checkoutUrl] in a browser.
class PurchaseResultDesktop extends PurchaseResult {
  const PurchaseResultDesktop({required this.checkoutUrl});
  final String checkoutUrl;
}

/// Store is not available on this device.
class PurchaseResultStoreUnavailable extends PurchaseResult {
  const PurchaseResultStoreUnavailable();
}

/// Product not found in the store catalog.
class PurchaseResultProductNotFound extends PurchaseResult {
  const PurchaseResultProductNotFound();
}

/// Purchase failed with an error message.
class PurchaseResultError extends PurchaseResult {
  const PurchaseResultError(this.message);
  final String message;
}

/// Result of opening subscription management.
sealed class ManageSubscriptionResult {
  const ManageSubscriptionResult();
}

/// Desktop: caller should open [portalUrl] in a browser.
class ManageSubscriptionResultDesktop extends ManageSubscriptionResult {
  const ManageSubscriptionResultDesktop({required this.portalUrl});
  final String portalUrl;
}

/// Mobile: the platform delegates to its own native subscription management UI.
class ManageSubscriptionResultPlatformDelegated
    extends ManageSubscriptionResult {
  const ManageSubscriptionResultPlatformDelegated();
}

/// Management portal failed with an error message.
class ManageSubscriptionResultError extends ManageSubscriptionResult {
  const ManageSubscriptionResultError(this.message);
  final String message;
}
