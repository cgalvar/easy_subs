import 'package:cloud_functions/cloud_functions.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';

/// An adapter that adds Firebase capabilities to the EasySubs flow.
class EasySubsFirebase {
  final FirebaseFunctions functions;
  final FirebaseFirestore firestore;
  final FirebaseAuth auth;
  final String verifyPurchaseFunctionName;
  final String refreshPurchaseFunctionName;
  final String subscriptionCollectionPath;

  @visibleForTesting
  static bool isEntitledStatus(String? status) => status == 'active' || status == 'trialing';

  @visibleForTesting
  static String buildVerificationMessage({required String source, required Map<String, dynamic> details, required String fallback}) {
    final status = details['status']?.toString().toLowerCase();
    final appleEnvironment = details['appleEnvironment']?.toString().toLowerCase();
    final transactionReason = details['transactionReason']?.toString().toUpperCase();

    if (source == 'app_store' && status == 'expired' && appleEnvironment == 'sandbox') {
      if (transactionReason == 'RENEWAL') {
        return 'Sandbox returned an expired renewal transaction from previous test history. Please clear Sandbox purchase history or use a fresh Sandbox tester account and try again.';
      }
      return 'The Sandbox subscription is expired. This can happen quickly in test mode. Try purchasing again.';
    }

    if (status == 'expired') {
      return 'This subscription is expired. Please renew in the store or restore purchases.';
    }

    if (status == 'revoked') {
      return 'This purchase was revoked by the store and is no longer valid.';
    }

    if (status == 'refunded') {
      return 'This purchase was refunded by the store and is no longer valid.';
    }

    return fallback;
  }

  EasySubsFirebase({
    required this.functions,
    required this.firestore,
    required this.auth,
    this.verifyPurchaseFunctionName = 'easySubs-verifyPurchase',
    this.refreshPurchaseFunctionName = 'easySubs-refreshPurchaseStatus',
    this.subscriptionCollectionPath = 'subscriptions',
  }) : assert(subscriptionCollectionPath != '');

  CollectionReference<Map<String, dynamic>> get _subscriptionsCollection => firestore.collection(subscriptionCollectionPath);

  String _normalizeSource(String source) {
    final normalizedSource = source.trim().toLowerCase();
    if (normalizedSource != 'app_store' && normalizedSource != 'google_play') {
      throw Exception('Unsupported purchase source: $source');
    }
    return normalizedSource;
  }

  Future<bool> _callPurchaseFunction({
    required String functionName,
    required String operationName,
    required String source,
    required String productId,
    String? verificationData,
    required bool requireVerificationData,
  }) async {
    try {
      final normalizedSource = _normalizeSource(source);
      final normalizedVerificationData = verificationData?.trim();
      if (requireVerificationData && (normalizedVerificationData == null || normalizedVerificationData.isEmpty)) {
        throw Exception('Missing verificationData for $operationName.');
      }

      final uid = auth.currentUser?.uid;
      debugPrint(
        '[easy_subs_firebase] $operationName call start uid=$uid source=$normalizedSource productId=$productId tokenLength=${normalizedVerificationData?.length ?? 0} tokenPrefix=${normalizedVerificationData != null && normalizedVerificationData.isNotEmpty ? normalizedVerificationData.substring(0, normalizedVerificationData.length > 20 ? 20 : normalizedVerificationData.length) : ''}',
      );

      final callable = functions.httpsCallable(functionName);
      final payload = <String, dynamic>{
        'source': normalizedSource,
        'productId': productId,
      };
      if (normalizedVerificationData != null && normalizedVerificationData.isNotEmpty) {
        payload['verificationData'] = normalizedVerificationData;
      }

      final result = await callable.call(payload);

      debugPrint('[easy_subs_firebase] $operationName callable response type=${result.data.runtimeType} data=$result');

      final response = result.data is Map ? Map<String, dynamic>.from(result.data as Map) : <String, dynamic>{};
      final details = response['details'] is Map ? Map<String, dynamic>.from(response['details'] as Map) : <String, dynamic>{};
      final status = details['status']?.toString().toLowerCase();

      if (response['success'] == true) {
        if (status != null && status.isNotEmpty && !isEntitledStatus(status)) {
          final message = buildVerificationMessage(
            source: normalizedSource,
            details: details,
            fallback: response['message']?.toString() ?? '$operationName returned a non-entitled status.',
          );
          debugPrint('[easy_subs_firebase] $operationName inconsistent success status=$status message=$message details=$details');
          throw Exception(message);
        }

        debugPrint('[easy_subs_firebase] $operationName success source=$normalizedSource productId=$productId');
        return true;
      }

      final message = buildVerificationMessage(
        source: normalizedSource,
        details: details,
        fallback: response['message']?.toString() ?? '$operationName failed remotely.',
      );
      debugPrint('[easy_subs_firebase] $operationName remote failure message=$message details=${response['details']}');
      throw Exception(message);
    } on FirebaseFunctionsException catch (e) {
      debugPrint('EasySubsFirebase - Function Error during $operationName: ${e.code} - ${e.message}');
      throw Exception(e.message ?? 'Unknown Firebase Error');
    } catch (e) {
      debugPrint('EasySubsFirebase - Unknown Error during $operationName: $e');
      if (e is Exception) {
        rethrow;
      }
      throw Exception(e.toString());
    }
  }

  /// Creates or updates the user's subscription document in the 'subscriptions' collection.
  Future<void> saveUserSubscription(String planId) async {
    final user = auth.currentUser;
    if (user == null) {
      debugPrint('[easy_subs_firebase] saveUserSubscription skipped: no authenticated user');
      return;
    }

    debugPrint('[easy_subs_firebase] saveUserSubscription start uid=${user.uid} planId=$planId');

    await _subscriptionsCollection.doc(user.uid).set({
      'userId': user.uid,
      'planId': planId,
      'status': 'active',
      'updatedAt': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));

    debugPrint('[easy_subs_firebase] saveUserSubscription done uid=${user.uid} planId=$planId');
  }

  /// Fetches the currently saved plan from Firestore.
  Future<String?> getUserSubscriptionPlan() async {
    final user = auth.currentUser;
    if (user == null) {
      debugPrint('[easy_subs_firebase] getUserSubscriptionPlan skipped: no authenticated user');
      return null;
    }

    debugPrint('[easy_subs_firebase] getUserSubscriptionPlan start uid=${user.uid}');

    final doc = await _subscriptionsCollection.doc(user.uid).get();
    if (doc.exists && doc.data() != null) {
      final planId = doc.data()!['planId'] as String?;
      debugPrint('[easy_subs_firebase] getUserSubscriptionPlan hit uid=${user.uid} planId=$planId keys=${doc.data()!.keys.toList()}');
      return planId;
    }
    debugPrint('[easy_subs_firebase] getUserSubscriptionPlan empty uid=${user.uid}');
    return null;
  }

  /// Returns a real-time stream of the current user's subscription document.
  Stream<Map<String, dynamic>?> userSubscriptionStream() {
    final user = auth.currentUser;
    if (user == null) {
      debugPrint('[easy_subs_firebase] userSubscriptionStream no user, emitting null once');
      return Stream.value(null);
    }
    debugPrint('[easy_subs_firebase] userSubscriptionStream attached uid=${user.uid}');
    return _subscriptionsCollection.doc(user.uid).snapshots().map((snapshot) {
      final data = snapshot.exists ? snapshot.data() : null;
      debugPrint(
        '[easy_subs_firebase] userSubscriptionStream event uid=${user.uid} exists=${snapshot.exists} keys=${data?.keys.toList()} status=${data?['status']} planId=${data?['planId']}',
      );
      return data;
    });
  }

  /// Verifies the purchase receipt with your Firebase Function (Zero Trust).
  Future<bool> verifyPurchase({required String source, required String productId, required String verificationData}) async {
    return _callPurchaseFunction(
      functionName: verifyPurchaseFunctionName,
      operationName: 'verifyPurchase',
      source: source,
      productId: productId,
      verificationData: verificationData,
      requireVerificationData: true,
    );
  }

  /// Refreshes the subscription status and, for Google Play, can relink a newer purchase token.
  Future<bool> refreshPurchaseStatus({required String source, required String productId, String? verificationData}) {
    return _callPurchaseFunction(
      functionName: refreshPurchaseFunctionName,
      operationName: 'refreshPurchaseStatus',
      source: source,
      productId: productId,
      verificationData: verificationData,
      requireVerificationData: false,
    );
  }
}
