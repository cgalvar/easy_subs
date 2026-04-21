import 'purchase_result.dart';

enum GooglePlayReplacementMode {
  withTimeProration,
  chargeProratedPrice,
  withoutProration,
  deferred,
  chargeFullPrice,
}

class GooglePlaySubscriptionChange {
  final PurchaseResult oldPurchase;
  final GooglePlayReplacementMode replacementMode;

  const GooglePlaySubscriptionChange({
    required this.oldPurchase,
    this.replacementMode = GooglePlayReplacementMode.withTimeProration,
  });
}