import 'dart:async';
import '../models/google_play_subscription_change.dart';
import '../models/subscription_plan.dart';
import '../models/purchase_result.dart';

abstract class SubscriptionRepository {
  /// Returns the current connection status with the store (StoreKit / Google Play Billing)
  Future<bool> get isStoreAvailable;

  /// Global stream of purchase events. This stream MUST be listened to
  /// as soon as the app starts to handle pending transactions.
  Stream<PurchaseResult> get purchaseStream;

  /// Fetches and returns the list of plans defined in your configuration
  Future<List<SubscriptionPlan>> getAvailablePlans(Set<String> productIds);

  /// Starts the purchase process for a plan.
  ///
  /// On Android, [googlePlayChange] can be supplied to upgrade or downgrade
  /// an existing subscription using a specific replacement/proration mode.
  Future<void> buyPlan(SubscriptionPlan plan, {GooglePlaySubscriptionChange? googlePlayChange});

  /// Restores previous purchases (vital for accounts reconnecting or changing devices)
  Future<void> restorePurchases();

  /// Reloads the latest verification token for a product from the store when supported.
  ///
  /// On Google Play this queries current purchases directly, which is useful when
  /// the app needs a fresh purchase token for long-lived subscriptions.
  Future<PurchaseResult?> refreshPurchaseVerificationData(String productId);

  /// Completes (acknowledges) the transaction. Mandatory to call this
  /// after your backend successfully validates the `verificationToken`.
  Future<void> completePurchase(PurchaseResult purchase);

  /// Opens the platform's subscription management screen so users can cancel
  /// or update their subscription directly in the store.
  Future<void> openManageSubscription();

  /// Presents the store's code redemption sheet (iOS) or redirects to Play Store (Android)
  Future<void> presentCodeRedemptionSheet({String? code});
}
