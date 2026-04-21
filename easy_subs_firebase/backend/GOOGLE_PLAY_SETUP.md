# Google Play Setup for Easy Subs Firebase

This guide explains how to configure Google Play so `easy_subs` and `easy_subs_firebase` can validate Android subscriptions end to end.

It is intentionally project-agnostic. Replace placeholder values such as `com.example.app` and `<YOUR_PROJECT_ID>` with your own.

## What This Setup Covers

For Google Play subscriptions to work correctly with `easy_subs_firebase`, all of these pieces must be configured:

- a subscription product in Google Play Console
- a Play testing or production build installed from Google Play
- backend access to the Google Play Developer API
- backend environment configuration for the Android package name
- Real-time Developer Notifications (RTDN) through Cloud Pub/Sub

## 1. Create the Subscription in Google Play Console

In Google Play Console:

1. Open your app.
2. Go to `Monetization` > `Products` > `Subscriptions`.
3. Create the subscription product.
4. Create at least one base plan.
5. Activate the base plan.
6. Configure pricing for the countries where you want to test or sell the subscription.
7. If you use a free trial or intro offer, activate that offer too.

Checklist:

- [ ] Subscription exists
- [ ] Base plan exists
- [ ] Base plan is active
- [ ] Pricing is configured
- [ ] Offer is active if applicable

## 2. Upload a Build to a Google Play Track

Google Billing purchase tests should be done with an app installed from Google Play, not only from a local debug install.

Recommended flow:

1. Build a release or testing build.
2. Upload it to Internal Testing or Closed Testing.
3. Add your tester account to the track.
4. Accept the tester invitation.
5. Install the app from Google Play Store.

Important:

- A local install from `flutter run` or a sideloaded APK may still load product details but fail to purchase with `BillingResponse.itemUnavailable`.

Checklist:

- [ ] Build uploaded to a track
- [ ] Tester enrolled
- [ ] App installed from Play Store

## 3. Configure Backend Access to Google Play Developer API

`easy_subs_firebase` verifies Android purchases by calling the Google Play Developer API with:

- `androidpublisher.purchases.subscriptionsv2.get`

This means the service account used by your deployed Firebase functions must be allowed to access your Google Play app.

### 3.1 Enable the API in Google Cloud

In Google Cloud Console:

1. Open `APIs & Services`.
2. Enable `Google Play Android Developer API`.

Checklist:

- [ ] Google Play Android Developer API enabled

### 3.2 Identify the Service Account Used by Your Functions

The backend uses Google Application Default Credentials through `google.auth.GoogleAuth`, so the runtime identity of the function is what matters.

If `gcloud` is available when you run `./deploy.sh`, the deploy script will try to print the runtime service account automatically after deploy. You can still verify it manually using the steps below.

In Cloud Functions:

1. Open one of the deployed `easySubs` functions.
2. Check the configured runtime service account.
3. Copy the service account email.

Where this email comes from:

- It is the service account attached to the deployed Cloud Function runtime.
- It is not your personal Google account.
- It is not automatically any random service account from IAM.
- It must be the exact identity that executes the function in production.

How to find it in the console:

1. Open Google Cloud Console.
2. Open `Cloud Functions` or `Cloud Run`, depending on how your functions are shown.
3. Open one of the deployed functions, such as `easySubs-verifyPurchase`.
4. Look for `Service account` or `Runtime service account` in the function details.
5. Copy that email address.

How to find it with the CLI:

For 2nd gen functions:

```bash
gcloud functions describe easySubs-verifyPurchase \
	--region=<YOUR_REGION> \
	--gen2 \
	--project=<YOUR_PROJECT_ID> \
	--format="value(serviceConfig.serviceAccountEmail)"
```

For 1st gen functions:

```bash
gcloud functions describe easySubs-verifyPurchase \
	--region=<YOUR_REGION> \
	--project=<YOUR_PROJECT_ID> \
	--format="value(serviceAccountEmail)"
```

Typical examples:

- `PROJECT_NUMBER-compute@developer.gserviceaccount.com`
- `firebase-adminsdk-xxxxx@YOUR_PROJECT_ID.iam.gserviceaccount.com`
- a custom runtime service account if you explicitly configured one

Record it here:

- Runtime service account email: `____________________________`

Checklist:

- [ ] Runtime service account identified

### 3.3 Grant Play Console Access to That Service Account

In Google Play Console:

1. Open `Users and permissions` or `API access`, depending on the current console layout.
2. Add the runtime service account email.
3. Restrict access to the target app.
4. Grant permissions required for subscription verification.

Recommended permissions:

- `View app information and download bulk reports (read only)`
- `View financial data, orders, and cancellation survey responses`
- `Manage orders and subscriptions`

Checklist:

- [ ] Service account added in Play Console
- [ ] App access restricted correctly
- [ ] Subscription-related permissions granted

## 4. Configure the Backend Environment

The backend must know the Android package name used in Google Play.

Set this environment variable during deploy:

```text
GOOGLE_PLAY_PACKAGE_NAME=com.example.app
```

This must exactly match the package name registered in Google Play Console.

Checklist:

- [ ] `GOOGLE_PLAY_PACKAGE_NAME` configured
- [ ] Package name matches Play Console exactly

## 5. Deploy the Easy Subs Firebase Backend

From the backend directory, run:

```bash
./deploy.sh
```

This deploy publishes the following functions:

- `easySubs-verifyPurchase`
- `easySubs-refreshPurchaseStatus`
- `easySubs-appleWebhook`
- `googlePubSubHandler`

Notes:

- The Flutter app calls `verifyPurchase` and `refreshPurchaseStatus` by callable function name. You do not manually paste those URLs into the app.
- The deploy script also prints the Apple webhook URL and the Google Play RTDN topic name.
- If `gcloud` is installed and authenticated, the deploy script also attempts to:
	- enable `pubsub.googleapis.com`
	- enable `androidpublisher.googleapis.com`
	- create the `play-billing` topic if it does not exist
	- grant `roles/pubsub.publisher` to `google-play-developer-notifications@system.gserviceaccount.com`
	- print the runtime service account of `easySubs-verifyPurchase`

Checklist:

- [ ] Package backend deployed
- [ ] Callable functions visible in Firebase

## 6. Configure Real-time Developer Notifications (RTDN)

RTDN is how Google Play notifies your backend about renewals, cancellations, pauses, on-hold status, and other async subscription changes.

In this backend, the expected Pub/Sub topic is:

```text
play-billing
```

Google Play Console expects the full topic name in this format:

```text
projects/<YOUR_PROJECT_ID>/topics/play-billing
```

### 6.1 Enable Pub/Sub

In Google Cloud Console:

1. Enable the Pub/Sub API.

Checklist:

- [ ] Pub/Sub API enabled

### 6.2 Create the Topic

In Google Cloud Console:

1. Open Pub/Sub.
2. Create a topic named `play-billing`.

Checklist:

- [ ] Topic `play-billing` created

### 6.3 Allow Google Play to Publish to the Topic

Grant this principal on the topic:

```text
google-play-developer-notifications@system.gserviceaccount.com
```

Grant this role:

```text
Pub/Sub Publisher
```

Checklist:

- [ ] Google Play system account granted `Pub/Sub Publisher`

### 6.4 Connect the Topic in Play Console

In Google Play Console:

1. Open `Monetization setup`.
2. Open `Real-time developer notifications`.
3. Set the topic to `play-billing`.
4. Save.
5. Send a test notification.

Checklist:

- [ ] RTDN topic connected in Play Console
- [ ] Test notification sent successfully

## 7. App Integration Expectations

The app needs:

- Firebase configured for the same project where the callables are deployed
- the package name used in Play Console
- a Play-installed build for real purchase tests

The app does not need:

- a manual URL for `easySubs-verifyPurchase`
- a manual URL for `easySubs-refreshPurchaseStatus`
- a Google webhook URL

Google Play uses Pub/Sub for RTDN in this setup, not an HTTP webhook URL pasted into the app.

## 8. End-to-End Smoke Test

Once configuration is complete:

1. Install the app from a Play testing track.
2. Log in with a tester account.
3. Load the subscription product.
4. Buy the subscription.
5. Confirm a purchase token is generated.
6. Confirm `easySubs-verifyPurchase` succeeds.
7. Confirm your backend updates the subscription document.
8. Confirm the app reflects premium access.

Optional follow-up:

9. Send an RTDN test notification and confirm `googlePubSubHandler` receives it.

Checklist:

- [ ] Product loads
- [ ] Purchase launches
- [ ] Purchase completes
- [ ] Verification succeeds
- [ ] Subscription state updates
- [ ] RTDN path is reachable

## 9. Quick Troubleshooting Map

### `BillingResponse.itemUnavailable`

Most common causes:

- app installed locally instead of from Google Play
- tester not enrolled in the track
- wrong Google account in Play Store
- product not purchasable in the current install context

### Google verification fails in backend

Most common causes:

- runtime service account not added in Play Console
- missing Play Console permissions
- Google Play Android Developer API not enabled
- wrong `GOOGLE_PLAY_PACKAGE_NAME`

### RTDN does not arrive

Most common causes:

- topic not created
- Play Console not connected to the topic
- missing `Pub/Sub Publisher` permission for `google-play-developer-notifications@system.gserviceaccount.com`

## 10. Final Checklist

- [ ] Subscription exists
- [ ] Base plan is active
- [ ] Pricing configured
- [ ] Build uploaded to Play
- [ ] Tester enrolled
- [ ] App installed from Play
- [ ] Google Play Android Developer API enabled
- [ ] Runtime service account identified
- [ ] Service account added in Play Console
- [ ] Required Play Console permissions granted
- [ ] `GOOGLE_PLAY_PACKAGE_NAME` configured
- [ ] Backend deployed
- [ ] Pub/Sub API enabled
- [ ] Topic `play-billing` created
- [ ] Google Play system account granted `Pub/Sub Publisher`
- [ ] RTDN connected in Play Console
- [ ] Real purchase smoke test passed