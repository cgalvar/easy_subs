# Easy Subs Firebase Backend

This directory contains the ready-to-deploy Firebase Cloud Functions required to validate receipts and handle Server-to-Server (S2S) webhooks for Apple App Store and Google Play Store.

## Philosophy
As part of the **Zero Trust** architecture, the client app never writes successful transactions to the database itself. It delegates validations to these functions.

## Included Functions
1. **`verifyPurchase` (Callable):** The Flutter app sends the encrypted receipt here. It queries Apple/Google APIs securely, validates it, and if authentic, writes/updates the `subscriptions` collection in Firestore.
2. **`appleWebhook` (HTTP POST):** Exposes a public endpoint for Apple's App Store Server Notifications V2. Automatically updates expiration dates in Firestore when renewals happen while the user is offline.
3. **`googlePubSubHandler` (Pub/Sub):** Bound to the Google Play Developer RTDN (Real-Time Developer Notifications) topic to handle android subscription states asynchronously.

## Platform Guides

- [Google Play Setup](GOOGLE_PLAY_SETUP.md)

## Operational Helpers

- `./google_play_test_notification_verifier.sh`: interactive verifier for Google Play RTDN test notifications. It tells you where to send the test notification, waits for confirmation, and then checks whether everything is healthy.

## Deployment Setup

1. Copy the contents of this folder into your main Firebase functions project directory (usually `<project_root>/functions/`), or import them into your existing `index.js`.
2. Add the required dependencies to your main `package.json`:
   - `googleapis`
   - `jsonwebtoken`
3. Set your environment variables (using Firebase secrets or dotenv):
   ```bash
   firebase functions:secrets:set APPLE_IAP_KEY_ID
   firebase functions:secrets:set APPLE_IAP_ISSUER_ID
   firebase functions:secrets:set APPLE_IAP_BUNDLE_ID
   # Google requires the service account JSON for the Google Play Developer API.
   ```
4. Deploy the functions:
   ```bash
   firebase deploy --only functions
   ```

When using the standalone `deploy.sh` in this folder with `gcloud` available, the script can also prepare Google Play RTDN infrastructure by verifying APIs, creating the `play-billing` topic, granting the Google Play publisher principal, and printing the runtime service account to add in Play Console.
