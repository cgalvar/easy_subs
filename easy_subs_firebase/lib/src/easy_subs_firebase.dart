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

      if (result.data['success'] == true) {
        debugPrint('[easy_subs_firebase] verifyPurchase success source=$source productId=$productId');
        return true;
      }

      final message = result.data['message']?.toString() ?? 'Receipt validation failed remotely.';
      debugPrint('[easy_subs_firebase] verifyPurchase remote failure message=$message details=${result.data['details']}');
      throw Exception(message);
    } on FirebaseFunctionsException catch (e) {
      debugPrint('EasySubsFirebase - Function Error: ${e.code} - ${e.message}');
      throw Exception(e.message ?? 'Unknown Firebase Error');
    } catch (e) {
      debugPrint('EasySubsFirebase - Unknown Error interpreting receipt: $e');
      // Keep the original reason to simplify troubleshooting (e.g. Apple 21002/21004).
      throw Exception(e.toString());
    }
  }
}
