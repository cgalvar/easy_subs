import 'dart:async';
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
  Future<void> buyPlan(SubscriptionPlan plan);

  /// Restores previous purchases (vital for accounts reconnecting or changing devices)
  Future<void> restorePurchases();

  /// Completes (acknowledges) the transaction. Mandatory to call this
  /// after your backend successfully validates the `verificationToken`.
  Future<void> completePurchase(PurchaseResult purchase);

  /// Presents the store's code redemption sheet (iOS) or redirects to Play Store (Android)
  Future<void> presentCodeRedemptionSheet({String? code});
}
