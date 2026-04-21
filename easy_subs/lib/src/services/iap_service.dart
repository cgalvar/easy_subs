import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:in_app_purchase/in_app_purchase.dart';
import 'package:in_app_purchase_android/billing_client_wrappers.dart';
import 'package:in_app_purchase_android/in_app_purchase_android.dart';
import 'package:in_app_purchase_storekit/in_app_purchase_storekit.dart';
import 'package:url_launcher/url_launcher.dart';
import '../domain/models/google_play_subscription_change.dart';
import '../domain/models/subscription_plan.dart';
import '../domain/models/purchase_result.dart' as easy;
import '../domain/repositories/subscription_repository.dart';

class IAPService implements SubscriptionRepository {
  static const Duration _plansCacheTtl = Duration(minutes: 5);

  final InAppPurchase _iap = InAppPurchase.instance;

  // Internal cache to map back to native in_app_purchase objects
  final Map<String, ProductDetails> _cachedProducts = {};
  final Map<String, PurchaseDetails> _cachedPurchases = {};
  final Map<String, PurchaseDetails> _cachedPurchasesByProductId = {};
  final List<SubscriptionPlan> _cachedPlans = [];

  Set<String>? _lastRequestedProductIds;
  DateTime? _lastPlansFetchedAt;

  void _log(String message) {
    debugPrint(message);
  }

  int _purchaseTimestamp(PurchaseDetails details) {
    return int.tryParse(details.transactionDate ?? '') ?? 0;
  }

  void _cachePurchaseDetails(PurchaseDetails purchaseDetails) {
    final cacheId = purchaseDetails.purchaseID ?? purchaseDetails.productID;
    _cachedPurchases[cacheId] = purchaseDetails;
    _cachedPurchasesByProductId[purchaseDetails.productID] = purchaseDetails;
  }

  easy.PurchaseStatus _mapPurchaseStatus(PurchaseStatus status) {
    switch (status) {
      case PurchaseStatus.pending:
        return easy.PurchaseStatus.pending;
      case PurchaseStatus.purchased:
        return easy.PurchaseStatus.success;
      case PurchaseStatus.error:
        return easy.PurchaseStatus.error;
      case PurchaseStatus.restored:
        return easy.PurchaseStatus.restored;
      case PurchaseStatus.canceled:
        return easy.PurchaseStatus.canceled;
    }
  }

  easy.PurchaseResult _toEasyPurchaseResult(PurchaseDetails purchaseDetails) {
    final selectedToken = _selectVerificationToken(purchaseDetails);
    return easy.PurchaseResult(
      status: _mapPurchaseStatus(purchaseDetails.status),
      productId: purchaseDetails.productID,
      purchaseId: purchaseDetails.purchaseID ?? purchaseDetails.productID,
      verificationToken: selectedToken,
      errorMessage: purchaseDetails.error?.message,
      originalTransactionId: purchaseDetails.status == PurchaseStatus.restored ? purchaseDetails.purchaseID : null,
    );
  }

  PurchaseDetails? _findCachedPurchaseDetails(String productId, {String? purchaseId, String? verificationToken}) {
    if (purchaseId != null && purchaseId.isNotEmpty) {
      final cachedById = _cachedPurchases[purchaseId];
      if (cachedById != null) {
        return cachedById;
      }
    }

    final cachedByProductId = _cachedPurchasesByProductId[productId];
    if (cachedByProductId != null) {
      return cachedByProductId;
    }

    for (final purchaseDetails in _cachedPurchases.values.toList().reversed) {
      if (purchaseDetails.productID != productId) {
        continue;
      }

      if (verificationToken == null || verificationToken.isEmpty) {
        return purchaseDetails;
      }

      if (_selectVerificationToken(purchaseDetails) == verificationToken) {
        return purchaseDetails;
      }
    }

    return null;
  }

  ReplacementMode _mapReplacementMode(GooglePlayReplacementMode mode) {
    switch (mode) {
      case GooglePlayReplacementMode.withTimeProration:
        return ReplacementMode.withTimeProration;
      case GooglePlayReplacementMode.chargeProratedPrice:
        return ReplacementMode.chargeProratedPrice;
      case GooglePlayReplacementMode.withoutProration:
        return ReplacementMode.withoutProration;
      case GooglePlayReplacementMode.deferred:
        return ReplacementMode.deferred;
      case GooglePlayReplacementMode.chargeFullPrice:
        return ReplacementMode.chargeFullPrice;
    }
  }

  Future<GooglePlayPurchaseDetails> _resolveGooglePlayOldPurchaseDetails(
    GooglePlaySubscriptionChange googlePlayChange,
  ) async {
    PurchaseDetails? purchaseDetails = _findCachedPurchaseDetails(
      googlePlayChange.oldPurchase.productId,
      purchaseId: googlePlayChange.oldPurchase.purchaseId,
      verificationToken: googlePlayChange.oldPurchase.verificationToken,
    );

    if (purchaseDetails is! GooglePlayPurchaseDetails) {
      await refreshPurchaseVerificationData(googlePlayChange.oldPurchase.productId);
      purchaseDetails = _findCachedPurchaseDetails(
        googlePlayChange.oldPurchase.productId,
        purchaseId: googlePlayChange.oldPurchase.purchaseId,
        verificationToken: googlePlayChange.oldPurchase.verificationToken,
      );
    }

    if (purchaseDetails is! GooglePlayPurchaseDetails) {
      throw Exception(
        'Google Play purchase details not found for ${googlePlayChange.oldPurchase.productId}. Refresh purchases before attempting a plan change.',
      );
    }

    return purchaseDetails;
  }

  bool _hasFreshPlanCache(Set<String> productIds) {
    final lastRequestedProductIds = _lastRequestedProductIds;
    final lastPlansFetchedAt = _lastPlansFetchedAt;

    if (lastRequestedProductIds == null || lastPlansFetchedAt == null || _cachedPlans.isEmpty) {
      return false;
    }

    if (lastRequestedProductIds.length != productIds.length || !lastRequestedProductIds.containsAll(productIds)) {
      return false;
    }

    return DateTime.now().difference(lastPlansFetchedAt) <= _plansCacheTtl;
  }

  void _cachePlans(Set<String> productIds, List<SubscriptionPlan> plans) {
    _cachedPlans
      ..clear()
      ..addAll(plans);
    _lastRequestedProductIds = Set<String>.from(productIds);
    _lastPlansFetchedAt = DateTime.now();
  }

  void _logAcknowledgementReminder(PurchaseDetails purchaseDetails) {
    if (!Platform.isAndroid || !purchaseDetails.pendingCompletePurchase) {
      return;
    }

    if (purchaseDetails.status == PurchaseStatus.purchased || purchaseDetails.status == PurchaseStatus.restored) {
      _log(
        '[easy_subs][iap] android purchase requires acknowledgement within 3 days productId=${purchaseDetails.productID} purchaseId=${purchaseDetails.purchaseID}',
      );
    }
  }

  bool _isStoreKitNoResponse(Object error) {
    final value = error.toString();
    return value.contains('storekit_no_response') || value.contains('StoreKit: Failed to get response from platform');
  }

  Future<void> _attemptStoreKitRecovery() async {
    if (!Platform.isIOS) return;

    try {
      final InAppPurchaseStoreKitPlatformAddition iosAddition = _iap.getPlatformAddition<InAppPurchaseStoreKitPlatformAddition>();
      await iosAddition.sync();
      await Future<void>.delayed(const Duration(milliseconds: 700));
      _log('[easy_subs][iap] recovery sync completed');
    } catch (e) {
      _log('[easy_subs][iap] recovery sync failed: $e');
    }
  }

  bool _looksLikeJws(String value) {
    return value.isNotEmpty && value.split('.').length == 3;
  }

  String _selectVerificationToken(PurchaseDetails purchaseDetails) {
    final localData = purchaseDetails.verificationData.localVerificationData;
    final serverData = purchaseDetails.verificationData.serverVerificationData;

    _log(
      '[easy_subs][iap] selectToken platform=${Platform.operatingSystem} productId=${purchaseDetails.productID} purchaseId=${purchaseDetails.purchaseID}',
    );
    _log('[easy_subs][iap] tokenMeta localLen=${localData.length} serverLen=${serverData.length} serverLooksJws=${_looksLikeJws(serverData)}');

    if (!Platform.isIOS) {
      _log('[easy_subs][iap] selectToken decision=serverData (non-iOS)');
      return serverData;
    }

    if (_looksLikeJws(serverData)) {
      _log('[easy_subs][iap] selectToken decision=serverData (iOS JWS)');
      return serverData;
    }

    if (localData.isNotEmpty) {
      _log('[easy_subs][iap] selectToken decision=localData (iOS fallback)');
      return localData;
    }

    _log('[easy_subs][iap] selectToken decision=serverData (iOS final fallback)');
    return serverData;
  }

  @override
  Future<bool> get isStoreAvailable => _iap.isAvailable();

  @override
  Stream<easy.PurchaseResult> get purchaseStream {
    return _iap.purchaseStream.transform(
      StreamTransformer.fromHandlers(
        handleData: (List<PurchaseDetails> purchaseDetailsList, EventSink<easy.PurchaseResult> sink) {
          _log('[easy_subs][iap] purchaseStream batch size=${purchaseDetailsList.length}');
          for (final pd in purchaseDetailsList) {
            // We save this here to be able to call completePurchase(pd) later
            _cachePurchaseDetails(pd);

            _log(
              '[easy_subs][iap] purchaseDetails productId=${pd.productID} purchaseId=${pd.purchaseID} status=${pd.status} pendingComplete=${pd.pendingCompletePurchase} error=${pd.error?.code}:${pd.error?.message}',
            );
            final purchaseResult = _toEasyPurchaseResult(pd);
            final selectedToken = purchaseResult.verificationToken ?? '';
            _log('[easy_subs][iap] selectedTokenMeta len=${selectedToken.length} prefix=${selectedToken.isNotEmpty ? selectedToken.substring(0, selectedToken.length > 18 ? 18 : selectedToken.length) : ''}');
            _logAcknowledgementReminder(pd);

            sink.add(purchaseResult);
            _log('[easy_subs][iap] emitted PurchaseResult productId=${pd.productID} mappedStatus=${purchaseResult.status} cacheId=${purchaseResult.purchaseId}');
          }
        },
      ),
    );
  }

  @override
  Future<List<SubscriptionPlan>> getAvailablePlans(Set<String> productIds) async {
    _log('[easy_subs][iap] getAvailablePlans start productIds=${productIds.toList()}');

    if (_hasFreshPlanCache(productIds)) {
      _log('[easy_subs][iap] getAvailablePlans using fresh in-memory cache count=${_cachedPlans.length}');
      return List<SubscriptionPlan>.from(_cachedPlans);
    }

    ProductDetailsResponse response;
    try {
      response = await _iap.queryProductDetails(productIds);
    } catch (e) {
      if (Platform.isIOS && _isStoreKitNoResponse(e)) {
        _log('[easy_subs][iap] getAvailablePlans no_response on first query, attempting sync + retry');
        await _attemptStoreKitRecovery();
        response = await _iap.queryProductDetails(productIds);
      } else {
        rethrow;
      }
    }

    if (response.error != null && Platform.isIOS && _isStoreKitNoResponse(response.error!)) {
      _log('[easy_subs][iap] getAvailablePlans no_response in response payload, attempting sync + retry');
      await _attemptStoreKitRecovery();
      response = await _iap.queryProductDetails(productIds);
    }

    if (response.error != null) {
      _log('[easy_subs][iap] getAvailablePlans error code=${response.error?.code} message=${response.error?.message}');
      throw Exception('Error loading products from store: ${response.error!.message}');
    }

    _log('[easy_subs][iap] getAvailablePlans response notFound=${response.notFoundIDs} count=${response.productDetails.length}');

    _cachedProducts.clear();

    final plans = response.productDetails.map((details) {
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

    _cachePlans(productIds, plans);

    return List<SubscriptionPlan>.from(plans);
  }

  @override
  Future<void> buyPlan(SubscriptionPlan plan, {GooglePlaySubscriptionChange? googlePlayChange}) async {
    _log('[easy_subs][iap] buyPlan start planId=${plan.id} title=${plan.title}');
    final productDetails = _cachedProducts[plan.id];
    if (productDetails == null) {
      _log('[easy_subs][iap] buyPlan missing cached product for ${plan.id}');
      throw Exception('Product details not found. Call getAvailablePlans first.');
    }

    late final PurchaseParam purchaseParam;

    if (Platform.isAndroid) {
      ChangeSubscriptionParam? changeSubscriptionParam;

      if (googlePlayChange != null) {
        final oldPurchaseDetails = await _resolveGooglePlayOldPurchaseDetails(googlePlayChange);
        changeSubscriptionParam = ChangeSubscriptionParam(
          oldPurchaseDetails: oldPurchaseDetails,
          replacementMode: _mapReplacementMode(googlePlayChange.replacementMode),
        );
        _log(
          '[easy_subs][iap] buyPlan android changeSubscription oldProductId=${googlePlayChange.oldPurchase.productId} replacementMode=${googlePlayChange.replacementMode}',
        );
      }

      purchaseParam = GooglePlayPurchaseParam(
        productDetails: productDetails,
        changeSubscriptionParam: changeSubscriptionParam,
      );
    } else {
      if (googlePlayChange != null) {
        throw UnsupportedError('Google Play subscription changes are only supported on Android.');
      }
      purchaseParam = PurchaseParam(productDetails: productDetails);
    }

    // Since these are subscriptions, we use buyNonConsumable from in_app_purchase.
    // For auto-renewable subscriptions on Android/Apple, this is the correct method.
    await _iap.buyNonConsumable(purchaseParam: purchaseParam);
    _log('[easy_subs][iap] buyPlan buyNonConsumable called planId=${plan.id}');
  }

  @override
  Future<void> restorePurchases() async {
    _log('[easy_subs][iap] restorePurchases start');
    await _iap.restorePurchases();
    _log('[easy_subs][iap] restorePurchases called');
  }

  @override
  Future<easy.PurchaseResult?> refreshPurchaseVerificationData(String productId) async {
    _log('[easy_subs][iap] refreshPurchaseVerificationData start productId=$productId platform=${Platform.operatingSystem}');

    if (Platform.isAndroid) {
      final InAppPurchaseAndroidPlatformAddition androidAddition = _iap.getPlatformAddition<InAppPurchaseAndroidPlatformAddition>();
      final response = await androidAddition.queryPastPurchases();

      if (response.error != null) {
        _log(
          '[easy_subs][iap] refreshPurchaseVerificationData android error code=${response.error?.code} message=${response.error?.message}',
        );
        throw Exception('Error refreshing Google Play purchases: ${response.error!.message}');
      }

      for (final purchaseDetails in response.pastPurchases) {
        _cachePurchaseDetails(purchaseDetails);
      }

      final matchingPurchases = response.pastPurchases.where((purchaseDetails) => purchaseDetails.productID == productId).toList()
        ..sort((left, right) => _purchaseTimestamp(right).compareTo(_purchaseTimestamp(left)));

      if (matchingPurchases.isEmpty) {
        _log('[easy_subs][iap] refreshPurchaseVerificationData android no purchase found productId=$productId');
        return null;
      }

      final refreshedPurchase = _toEasyPurchaseResult(matchingPurchases.first);
      _log(
        '[easy_subs][iap] refreshPurchaseVerificationData android success productId=$productId purchaseId=${refreshedPurchase.purchaseId}',
      );
      return refreshedPurchase;
    }

    final cachedPurchaseDetails = _findCachedPurchaseDetails(productId);
    if (cachedPurchaseDetails == null) {
      _log('[easy_subs][iap] refreshPurchaseVerificationData cache miss productId=$productId');
      return null;
    }

    final refreshedPurchase = _toEasyPurchaseResult(cachedPurchaseDetails);
    _log('[easy_subs][iap] refreshPurchaseVerificationData cache hit productId=$productId purchaseId=${refreshedPurchase.purchaseId}');
    return refreshedPurchase;
  }

  @override
  Future<void> completePurchase(easy.PurchaseResult purchase) async {
    _log('[easy_subs][iap] completePurchase start purchaseId=${purchase.purchaseId} productId=${purchase.productId} status=${purchase.status}');
    if (purchase.purchaseId == null) {
      _log('[easy_subs][iap] completePurchase skipped: purchaseId is null');
      return;
    }

    final pd = _cachedPurchases[purchase.purchaseId];
    if (pd == null) {
      _log('[easy_subs][iap] completePurchase skipped: no cached PurchaseDetails for ${purchase.purchaseId}');
      return;
    }

    if (pd.pendingCompletePurchase) {
      try {
        await _iap.completePurchase(pd);
        _log('[easy_subs][iap] completePurchase success purchaseId=${purchase.purchaseId}');
      } catch (e) {
        _log('[easy_subs][iap] error calling completePurchase: $e');
      }
    } else {
      _log('[easy_subs][iap] completePurchase skipped pendingComplete=${pd.pendingCompletePurchase} purchaseId=${purchase.purchaseId}');
    }
  }

  @override
  Future<void> openManageSubscription() async {
    _log('[easy_subs][iap] openManageSubscription start platform=${Platform.operatingSystem}');

    final Uri uri;
    if (Platform.isIOS || Platform.isMacOS) {
      uri = Uri.parse('https://apps.apple.com/account/subscriptions');
    } else if (Platform.isAndroid) {
      uri = Uri.parse('https://play.google.com/store/account/subscriptions');
    } else {
      throw UnsupportedError('Subscription management is only supported on iOS, macOS, and Android.');
    }

    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
      _log('[easy_subs][iap] openManageSubscription launched uri=$uri');
    } else {
      throw Exception('Could not open subscription management.');
    }
  }

  @override
  Future<void> presentCodeRedemptionSheet({String? code}) async {
    _log('[easy_subs][iap] presentCodeRedemptionSheet start code=$code');
    if (Platform.isIOS) {
      final InAppPurchaseStoreKitPlatformAddition iosAddition = _iap.getPlatformAddition<InAppPurchaseStoreKitPlatformAddition>();
      await iosAddition.presentCodeRedemptionSheet();
    } else if (Platform.isAndroid) {
      // In Android, there's no native overlay, so we redirect the user to Play Store
      final urlStr = code != null && code.isNotEmpty ? 'https://play.google.com/redeem?code=$code' : 'https://play.google.com/redeem';
      final uri = Uri.parse(urlStr);
      if (await canLaunchUrl(uri)) {
        await launchUrl(uri, mode: LaunchMode.externalApplication);
      } else {
        throw Exception('Could not launch Android redeem URL.');
      }
    } else {
      throw UnsupportedError('Promo codes are only supported on iOS and Android.');
    }
  }
}
