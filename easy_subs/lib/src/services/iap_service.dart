import 'dart:async';
import 'dart:io';
import 'package:in_app_purchase/in_app_purchase.dart';
import '../domain/models/subscription_plan.dart';
import '../domain/models/purchase_result.dart' as easy;
import '../domain/repositories/subscription_repository.dart';

class IAPService implements SubscriptionRepository {
  final InAppPurchase _iap = InAppPurchase.instance;

  // Internal cache to map back to native in_app_purchase objects
  final Map<String, ProductDetails> _cachedProducts = {};
  final Map<String, PurchaseDetails> _cachedPurchases = {};

  bool _looksLikeJws(String value) {
    return value.isNotEmpty && value.split('.').length == 3;
  }

  String _selectVerificationToken(PurchaseDetails purchaseDetails) {
    final localData = purchaseDetails.verificationData.localVerificationData;
    final serverData = purchaseDetails.verificationData.serverVerificationData;

    print(
      '[easy_subs][iap] selectToken platform=${Platform.operatingSystem} productId=${purchaseDetails.productID} purchaseId=${purchaseDetails.purchaseID}',
    );
    print('[easy_subs][iap] tokenMeta localLen=${localData.length} serverLen=${serverData.length} serverLooksJws=${_looksLikeJws(serverData)}');

    if (!Platform.isIOS) {
      print('[easy_subs][iap] selectToken decision=serverData (non-iOS)');
      return serverData;
    }

    if (_looksLikeJws(serverData)) {
      print('[easy_subs][iap] selectToken decision=serverData (iOS JWS)');
      return serverData;
    }

    if (localData.isNotEmpty) {
      print('[easy_subs][iap] selectToken decision=localData (iOS fallback)');
      return localData;
    }

    print('[easy_subs][iap] selectToken decision=serverData (iOS final fallback)');
    return serverData;
  }

  @override
  Future<bool> get isStoreAvailable => _iap.isAvailable();

  @override
  Stream<easy.PurchaseResult> get purchaseStream {
    return _iap.purchaseStream.transform(
      StreamTransformer.fromHandlers(
        handleData: (List<PurchaseDetails> purchaseDetailsList, EventSink<easy.PurchaseResult> sink) {
          print('[easy_subs][iap] purchaseStream batch size=${purchaseDetailsList.length}');
          for (final pd in purchaseDetailsList) {
            // We save this here to be able to call completePurchase(pd) later
            final cacheId = pd.purchaseID ?? pd.productID;
            _cachedPurchases[cacheId] = pd;

            final selectedToken = _selectVerificationToken(pd);
            print(
              '[easy_subs][iap] purchaseDetails productId=${pd.productID} purchaseId=${pd.purchaseID} status=${pd.status} pendingComplete=${pd.pendingCompletePurchase} error=${pd.error?.code}:${pd.error?.message}',
            );
            print(
              '[easy_subs][iap] selectedTokenMeta len=${selectedToken.length} prefix=${selectedToken.isNotEmpty ? selectedToken.substring(0, selectedToken.length > 18 ? 18 : selectedToken.length) : ''}',
            );

            easy.PurchaseStatus status;
            switch (pd.status) {
              case PurchaseStatus.pending:
                status = easy.PurchaseStatus.pending;
                break;
              case PurchaseStatus.purchased:
                status = easy.PurchaseStatus.success;
                break;
              case PurchaseStatus.error:
                status = easy.PurchaseStatus.error;
                break;
              case PurchaseStatus.restored:
                status = easy.PurchaseStatus.restored;
                break;
              case PurchaseStatus.canceled:
                status = easy.PurchaseStatus.canceled;
                break;
            }

            sink.add(
              easy.PurchaseResult(
                status: status,
                productId: pd.productID,
                purchaseId: cacheId,
                verificationToken: selectedToken,
                errorMessage: pd.error?.message,
                originalTransactionId: pd.status == PurchaseStatus.restored ? pd.purchaseID : null,
              ),
            );
            print('[easy_subs][iap] emitted PurchaseResult productId=${pd.productID} mappedStatus=$status cacheId=$cacheId');
          }
        },
      ),
    );
  }

  @override
  Future<List<SubscriptionPlan>> getAvailablePlans(Set<String> productIds) async {
    print('[easy_subs][iap] getAvailablePlans start productIds=${productIds.toList()}');
    final ProductDetailsResponse response = await _iap.queryProductDetails(productIds);

    if (response.error != null) {
      print('[easy_subs][iap] getAvailablePlans error code=${response.error?.code} message=${response.error?.message}');
      throw Exception('Error loading products from store: ${response.error!.message}');
    }

    print('[easy_subs][iap] getAvailablePlans response notFound=${response.notFoundIDs} count=${response.productDetails.length}');

    _cachedProducts.clear();

    return response.productDetails.map((details) {
      _cachedProducts[details.id] = details;
      return SubscriptionPlan(
        id: details.id,
        title: details.title,
        description: details.description,
        price: details.price,
        rawPrice: details.rawPrice,
        currencyCode: details.currencyCode,
      );
    }).toList();
  }

  @override
  Future<void> buyPlan(SubscriptionPlan plan) async {
    print('[easy_subs][iap] buyPlan start planId=${plan.id} title=${plan.title}');
    final productDetails = _cachedProducts[plan.id];
    if (productDetails == null) {
      print('[easy_subs][iap] buyPlan missing cached product for ${plan.id}');
      throw Exception('Product details not found. Call getAvailablePlans first.');
    }

    final purchaseParam = PurchaseParam(productDetails: productDetails);

    // Since these are subscriptions, we use buyNonConsumable from in_app_purchase.
    // For auto-renewable subscriptions on Android/Apple, this is the correct method.
    await _iap.buyNonConsumable(purchaseParam: purchaseParam);
    print('[easy_subs][iap] buyPlan buyNonConsumable called planId=${plan.id}');
  }

  @override
  Future<void> restorePurchases() async {
    print('[easy_subs][iap] restorePurchases start');
    await _iap.restorePurchases();
    print('[easy_subs][iap] restorePurchases called');
  }

  @override
  Future<void> completePurchase(easy.PurchaseResult purchase) async {
    print('[easy_subs][iap] completePurchase start purchaseId=${purchase.purchaseId} productId=${purchase.productId} status=${purchase.status}');
    if (purchase.purchaseId == null) {
      print('[easy_subs][iap] completePurchase skipped: purchaseId is null');
      return;
    }

    final pd = _cachedPurchases[purchase.purchaseId];
    if (pd == null) {
      print('[easy_subs][iap] completePurchase skipped: no cached PurchaseDetails for ${purchase.purchaseId}');
      return;
    }

    if (pd.pendingCompletePurchase) {
      try {
        await _iap.completePurchase(pd);
        print('[easy_subs][iap] completePurchase success purchaseId=${purchase.purchaseId}');
      } catch (e) {
        print('[easy_subs] Error calling completePurchase: $e');
      }
    } else {
      print('[easy_subs][iap] completePurchase skipped pendingComplete=${pd.pendingCompletePurchase} purchaseId=${purchase.purchaseId}');
    }
  }
}
