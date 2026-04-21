import 'package:easy_subs/easy_subs.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('GooglePlaySubscriptionChange defaults to withTimeProration', () {
    const purchase = PurchaseResult(
      status: PurchaseStatus.success,
      productId: 'plan_monthly',
      purchaseId: 'purchase_1',
      verificationToken: 'token_1',
    );

    const change = GooglePlaySubscriptionChange(oldPurchase: purchase);

    expect(change.replacementMode, GooglePlayReplacementMode.withTimeProration);
    expect(change.oldPurchase.productId, 'plan_monthly');
  });
}