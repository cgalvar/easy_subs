import 'package:flutter_test/flutter_test.dart';
import 'package:easy_subs_firebase/easy_subs_firebase.dart';

void main() {
  test('buildVerificationMessage explains expired sandbox renewal history', () {
    final message = EasySubsFirebase.buildVerificationMessage(
      source: 'app_store',
      details: {
        'status': 'expired',
        'appleEnvironment': 'sandbox',
        'transactionReason': 'RENEWAL',
      },
      fallback: 'fallback',
    );

    expect(message, contains('Sandbox'));
    expect(message, contains('fresh Sandbox tester account'));
  });

  test('isEntitledStatus only allows active and trialing', () {
    expect(EasySubsFirebase.isEntitledStatus('active'), isTrue);
    expect(EasySubsFirebase.isEntitledStatus('trialing'), isTrue);
    expect(EasySubsFirebase.isEntitledStatus('expired'), isFalse);
  });
}
