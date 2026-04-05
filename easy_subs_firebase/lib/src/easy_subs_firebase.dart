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

  bool _isEntitledStatus(String? status) => status == 'active' || status == 'trialing';

  String _buildVerificationMessage({required String source, required Map<String, dynamic> details, required String fallback}) {
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
  });

  /// Creates or updates the user's subscription document in the 'subscriptions' collection.
  Future<void> saveUserSubscription(String planId) async {
    final user = auth.currentUser;
    if (user == null) {
      debugPrint('[easy_subs_firebase] saveUserSubscription skipped: no authenticated user');
      return;
    }

    debugPrint('[easy_subs_firebase] saveUserSubscription start uid=${user.uid} planId=$planId');

    await firestore.collection('subscriptions').doc(user.uid).set({
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

    final doc = await firestore.collection('subscriptions').doc(user.uid).get();
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
    return firestore.collection('subscriptions').doc(user.uid).snapshots().map((snapshot) {
      final data = snapshot.exists ? snapshot.data() : null;
      debugPrint(
        '[easy_subs_firebase] userSubscriptionStream event uid=${user.uid} exists=${snapshot.exists} keys=${data?.keys.toList()} status=${data?['status']} planId=${data?['planId']}',
      );
      return data;
    });
  }

  /// Verifies the purchase receipt with your Firebase Function (Zero Trust).
  Future<bool> verifyPurchase({required String source, required String productId, required String verificationData}) async {
    try {
      final uid = auth.currentUser?.uid;
      debugPrint(
        '[easy_subs_firebase] verifyPurchase call start uid=$uid source=$source productId=$productId tokenLength=${verificationData.length} tokenPrefix=${verificationData.isNotEmpty ? verificationData.substring(0, verificationData.length > 20 ? 20 : verificationData.length) : ''}',
      );
      final callable = functions.httpsCallable(verifyPurchaseFunctionName);
      final result = await callable.call({'source': source, 'productId': productId, 'verificationData': verificationData});

      debugPrint('[easy_subs_firebase] verifyPurchase callable response type=${result.data.runtimeType} data=$result');

      final response = result.data is Map ? Map<String, dynamic>.from(result.data as Map) : <String, dynamic>{};
      final details = response['details'] is Map ? Map<String, dynamic>.from(response['details'] as Map) : <String, dynamic>{};
      final status = details['status']?.toString().toLowerCase();

      if (response['success'] == true) {
        // Defensive fallback in case backend returns success for a non-entitled status.
        if (status != null && status.isNotEmpty && !_isEntitledStatus(status)) {
          final message = _buildVerificationMessage(
            source: source,
            details: details,
            fallback: response['message']?.toString() ?? 'Receipt validation returned a non-entitled status.',
          );
          debugPrint('[easy_subs_firebase] verifyPurchase inconsistent success status=$status message=$message details=$details');
          throw Exception(message);
        }

        debugPrint('[easy_subs_firebase] verifyPurchase success source=$source productId=$productId');
        return true;
      }

      final message = _buildVerificationMessage(
        source: source,
        details: details,
        fallback: response['message']?.toString() ?? 'Receipt validation failed remotely.',
      );
      debugPrint('[easy_subs_firebase] verifyPurchase remote failure message=$message details=${response['details']}');
      throw Exception(message);
    } on FirebaseFunctionsException catch (e) {
      debugPrint('EasySubsFirebase - Function Error: ${e.code} - ${e.message}');
      throw Exception(e.message ?? 'Unknown Firebase Error');
    } catch (e) {
      debugPrint('EasySubsFirebase - Unknown Error interpreting receipt: $e');
      if (e is Exception) {
        rethrow;
      }
      throw Exception(e.toString());
    }
  }
}
