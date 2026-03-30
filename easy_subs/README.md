# Easy Subs 💳

A fully modular, plug-and-play Flutter package for handling native In-App Purchases (iOS App Store & Google Play Store). Built with a strict separation of concerns, ensuring your IAP logic is 100% agnostic to your app's business domain or database.

## Features ✨

- **Store Agnostic:** Unified API to fetch products and buy plans on both iOS and Android.
- **Zero Trust Ready:** Extracts the raw cryptographic receipt/token from the store and delegates validation to your server. Never writes to the database directly.
- **Self-Contained:** No dependencies on Firebase, Supabase, or your app's user models. 
- **Stream Resiliency:** Handles asynchronous and pending transactions flawlessly, surviving app restarts during a purchase.

## Getting Started 🚀

If you are using this package locally in your workspace, add it to your `pubspec.yaml` via path:

```yaml
dependencies:
  easy_subs:
    path: packages/easy_subs
```

> **Note:** If you use Firebase, check out the companion package/plugin `easy_subs_firebase`, which adds Firestore and Cloud Functions out of the box so you simply pass the credentials.

## Usage 💻

### 1. Initialize & Listen to Purchases
You must listen to the purchase stream as soon as your app starts to process new or pending transactions.

```dart
import 'package:easy_subs/easy_subs.dart';

final iapService = IAPService();

// Listen to the stream in your Bloc or App initialization
iapService.purchaseStream.listen((PurchaseResult purchase) async {
   if (purchase.status == PurchaseStatus.success) {
       // 1. Send `purchase.verificationToken` to your Backend!
       // 2. Wait for Backend response.
       // 3. If Backend says OK, complete the transaction to claim the money:
       await iapService.completePurchase(purchase);
       
       print("User is now premium!");
   }
});
```

### 2. Fetch Available Plans (Paywall)
Retrieve localized prices and details directly from the native stores.

```dart
final productIds = {'com.myapp.premium.monthly', 'com.myapp.premium.yearly'};
List<SubscriptionPlan> plans = await iapService.getAvailablePlans(productIds);

// Render your Paywall UI using the `plans` list.
for (var plan in plans) {
  print("${plan.title} - ${plan.price}");
}
```

### 3. Buy a Plan
Trigger the native bottom sheet from Apple/Google to pay.

```dart
SubscriptionPlan selectedPlan = plans.first;
await iapService.buyPlan(selectedPlan);
// The result will be pushed automatically to your `purchaseStream` listener above.
```

### 4. Restore Purchases
Trigger this when the user taps "Restore Purchases" to retrieve previous active subscriptions.

```dart
await iapService.restorePurchases();
```

## Architecture Philosophy (Zero Trust) 🔐
`easy_subs` acts only as a messenger. It will never dictate state to your database. It gets the official receipt from the platform, hands it over to your frontend, which must send it to your Backend (Server). The server strictly validates the receipt with Apple/Google and writes the premium status in the database.

---

## 🌩️ Optional: Using `easy_subs_firebase`

If your project uses **Firebase** as its backend, we provide a complete plug-and-play extension called `easy_subs_firebase` that handles both the frontend communication and backend validation out of the box.

### 1. Add the extension
```yaml
dependencies:
  easy_subs:
    path: packages/easy_subs
  easy_subs_firebase:
    path: packages/easy_subs_firebase
```

### 2. Frontend Integration
Instead of writing your own backend HTTP calls, wrap `EasySubsFirebase` around your data layer. It handles both Firestore reads and Cloud Functions calls automatically:

```dart
import 'package:easy_subs_firebase/easy_subs_firebase.dart';

final firebaseSubs = EasySubsFirebase(
  functions: FirebaseFunctions.instance,
  firestore: FirebaseFirestore.instance,
  auth: FirebaseAuth.instance,
);

// To verify a purchase through Cloud Functions:
bool isValid = await firebaseSubs.verifyPurchase(
  source: 'app_store', 
  productId: purchase.productId, 
  verificationData: purchase.verificationToken,
);

// To read the active plan directly from Firestore (subscriptions collection):
String? activePlan = await firebaseSubs.getUserSubscriptionPlan();
```

### 3. Backend Deployment (Node.js)
The extension includes the ready-to-deploy Node.js Cloud Functions inside its `backend/` folder. 
Simply copy the contents of `packages/easy_subs_firebase/backend/` to your Firebase project, run `npm install`, and deploy. It includes `verifyPurchase` and the Webhooks (`appleWebhook` & `googlePubSubHandler`) required to handle silent background renewals.

#### Where to set up the Webhooks:
Once you deploy your Firebase Functions, Google will generate a public URL for your webhooks:

- **Apple App Store:**
  1. Go to App Store Connect -> Your App -> App Information -> **App Store Server Notifications**.
  2. Paste your Firebase Function URL for the `appleWebhook` (e.g. `https://us-central1-YOURPROJECT.cloudfunctions.net/appleWebhook`).
  3. Ensure you select **Version 2**.

- **Google Play Store:**
  1. This plugin uses Pub/Sub. Go to Google Cloud Console and create a topic named `play-billing`.
  2. Go to Google Play Console -> App -> Monetization setup -> **Real-time developer notifications**.
  3. Paste the Pub/Sub topic name: `projects/YOURPROJECT/topics/play-billing`. The deployed `googlePubSubHandler` function will automatically intercept events from this topic.
