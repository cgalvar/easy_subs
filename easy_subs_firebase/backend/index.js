const { google } = require("googleapis");
const jwt = require("jsonwebtoken");

const APPLE_VERIFY_RECEIPT_PRODUCTION_URL = "https://buy.itunes.apple.com/verifyReceipt";
const APPLE_VERIFY_RECEIPT_SANDBOX_URL = "https://sandbox.itunes.apple.com/verifyReceipt";
const APPLE_SERVER_API_PRODUCTION_URL = "https://api.storekit.itunes.apple.com";
const APPLE_SERVER_API_SANDBOX_URL = "https://api.storekit-sandbox.itunes.apple.com";

function toMillis(value) {
  if (!value) return null;
  const n = Number(value);
  if (Number.isNaN(n)) return null;
  return n;
}

function safeJwtDecode(token) {
  if (!token || typeof token !== "string") return null;
  try {
    return jwt.decode(token);
  } catch {
    return null;
  }
}

function isLikelyJws(token) {
  if (!token || typeof token !== "string") return false;
  return token.split(".").length === 3;
}

function getConfigValue(functionsInstance, path, envKey) {
  return process.env[envKey];
}

function mapGoogleSubscriptionState(state) {
  switch (state) {
    case "SUBSCRIPTION_STATE_ACTIVE":
      return "active";
    case "SUBSCRIPTION_STATE_IN_GRACE_PERIOD":
      return "trialing";
    case "SUBSCRIPTION_STATE_PAUSED":
      return "paused";
    case "SUBSCRIPTION_STATE_ON_HOLD":
      return "on_hold";
    case "SUBSCRIPTION_STATE_CANCELED":
      return "canceled";
    case "SUBSCRIPTION_STATE_EXPIRED":
      return "expired";
    case "SUBSCRIPTION_STATE_PENDING":
      return "pending";
    default:
      return "unknown";
  }
}

function mapAppleWebhookStatus(notificationType, subtype) {
  switch (notificationType) {
    case "SUBSCRIBED":
    case "DID_RENEW":
    case "OFFER_REDEEMED":
      return "active";
    case "DID_FAIL_TO_RENEW":
      return subtype === "GRACE_PERIOD" ? "trialing" : "on_hold";
    case "DID_CHANGE_RENEWAL_STATUS":
      return subtype === "AUTO_RENEW_DISABLED" ? "active" : "active";
    case "EXPIRED":
    case "GRACE_PERIOD_EXPIRED":
      return "expired";
    case "REFUND":
      return "refunded";
    case "REVOKE":
      return "revoked";
    default:
      return "active";
  }
}

function isEntitledStatus(status) {
  return status === "active" || status === "trialing";
}

async function upsertSubscription(adminInstance, userId, data) {
  console.log("[easySubs][subscriptions] upsert start", {
    userId,
    status: data?.status || null,
    platform: data?.platform || null,
    notificationType: data?.notificationType || null,
    originalTransactionId: data?.originalTransactionId || null,
    transactionId: data?.transactionId || null,
    expiryDateMs: data?.expiryDateMs || null,
  });

  await adminInstance.firestore.collection("subscriptions").doc(userId).set(
    {
      userId,
      ...data,
      updatedAt: adminInstance.FieldValue.serverTimestamp(),
    },
    { merge: true },
  );

  console.log("[easySubs][subscriptions] upsert done", {
    userId,
    status: data?.status || null,
    platform: data?.platform || null,
  });
}

async function findSubscriptionByField(adminInstance, field, value) {
  if (!value) {
    console.warn("[easySubs][subscriptions] find skipped: empty value", { field });
    return null;
  }

  console.log("[easySubs][subscriptions] find start", {
    field,
    valuePreview: String(value).slice(0, 24),
    valueLength: String(value).length,
  });

  const snap = await adminInstance.firestore
    .collection("subscriptions")
    .where(field, "==", value)
    .limit(1)
    .get();

  if (snap.empty) {
    console.warn("[easySubs][subscriptions] find empty", { field });
    return null;
  }

  const doc = snap.docs[0];
  console.log("[easySubs][subscriptions] find hit", {
    field,
    userId: doc.id,
    docKeys: Object.keys(doc.data() || {}),
  });

  return {
    userId: doc.id,
    data: doc.data(),
  };
}

async function verifyAppleReceiptWithEndpoint(url, receiptData, sharedSecret) {
  const response = await fetch(url, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({
      "receipt-data": receiptData,
      password: sharedSecret,
      "exclude-old-transactions": true,
    }),
  });

  if (!response.ok) {
    throw new Error(`Apple verifyReceipt HTTP ${response.status}`);
  }

  return response.json();
}

function normalizeApplePrivateKey(raw) {
  if (!raw) return raw;
  let normalized = String(raw).trim();

  if (
    (normalized.startsWith('"') && normalized.endsWith('"')) ||
    (normalized.startsWith("'") && normalized.endsWith("'"))
  ) {
    normalized = normalized.slice(1, -1);
  }

  normalized = normalized.replace(/\\r/g, "").replace(/\r/g, "");
  normalized = normalized.replace(/\\\\n/g, "\n");
  normalized = normalized.replace(/\\n/g, "\n");

  return normalized;
}

function buildAppleServerApiJwt({ issuerId, keyId, privateKey, bundleId }) {
  const now = Math.floor(Date.now() / 1000);
  const payload = {
    iss: issuerId,
    iat: now,
    exp: now + 300,
    aud: "appstoreconnect-v1",
  };
  if (bundleId) payload.bid = bundleId;

  return jwt.sign(payload, privateKey, {
    algorithm: "ES256",
    header: {
      alg: "ES256",
      kid: keyId,
      typ: "JWT",
    },
  });
}

async function fetchAppleTransactionById({ transactionId, bearerToken, baseUrl }) {
  const response = await fetch(`${baseUrl}/inApps/v1/transactions/${transactionId}`, {
    method: "GET",
    headers: {
      Authorization: `Bearer ${bearerToken}`,
      Accept: "application/json",
    },
  });

  if (!response.ok) {
    const body = await response.text();
    const error = new Error(`Apple Server API HTTP ${response.status} body=${body}`);
    error.statusCode = response.status;
    error.responseBody = body;

    try {
      const parsedBody = JSON.parse(body);
      error.appleErrorCode = parsedBody?.errorCode;
      error.appleErrorMessage = parsedBody?.errorMessage;
    } catch {
      // Ignore parse failures and keep the raw response body attached.
    }

    throw error;
  }

  return response.json();
}

function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

function isAppleTransactionNotFoundError(error) {
  return error?.statusCode === 404 && error?.appleErrorCode === 4040010;
}

function parseAppleSignedTransactionInfo(signedTransactionInfo) {
  const tx = safeJwtDecode(signedTransactionInfo) || {};
  const expiryDateMs = toMillis(tx.expiresDate);
  const now = Date.now();
  const isExpired = expiryDateMs ? expiryDateMs <= now : false;
  const hasTransaction = Boolean(tx.transactionId || tx.originalTransactionId);
  const status = !hasTransaction
    ? "unknown"
    : tx.revocationDate
      ? "revoked"
      : (expiryDateMs && isExpired ? "expired" : "active");

  return {
    hasTransaction,
    isValid: hasTransaction && isEntitledStatus(status),
    status,
    originalTransactionId: tx.originalTransactionId || null,
    transactionId: tx.transactionId || null,
    purchaseDateMs: toMillis(tx.purchaseDate),
    expiryDateMs,
    revocationDateMs: toMillis(tx.revocationDate),
    appAccountToken: tx.appAccountToken || null,
    productId: tx.productId || null,
    storefront: tx.storefront || null,
    transactionReason: tx.transactionReason || null,
  };
}

async function verifyApplePurchaseByServerApi({ verificationData, productId, functionsInstance }) {
  const issuerId = getConfigValue(functionsInstance, "easysubs.apple_issuer_id", "APPLE_ISSUER_ID");
  const keyId = getConfigValue(functionsInstance, "easysubs.apple_key_id", "APPLE_KEY_ID");
  const privateKeyRaw = getConfigValue(functionsInstance, "easysubs.apple_private_key", "APPLE_PRIVATE_KEY");
  const bundleId = getConfigValue(functionsInstance, "easysubs.apple_bundle_id", "APPLE_BUNDLE_ID");
  const privateKey = normalizeApplePrivateKey(privateKeyRaw);
  const parsedFromSignedTransaction = parseAppleSignedTransactionInfo(verificationData);

  if (!issuerId || !keyId || !privateKey) {
    return {
      isValid: false,
      details: {
        status: "invalid",
        reason: "missing_apple_server_api_credentials",
      },
    };
  }

  const decodedToken = safeJwtDecode(verificationData) || {};
  console.log("[easySubs][verifyAppleServerApi] decoded token metadata", {
    tokenLength: verificationData ? String(verificationData).length : 0,
    tokenPrefix: verificationData ? String(verificationData).slice(0, 24) : null,
    decodedKeys: Object.keys(decodedToken || {}),
    decodedProductId: decodedToken.productId || null,
    decodedBundleId: decodedToken.bundleId || null,
    decodedEnvironment: decodedToken.environment || null,
    decodedTransactionId: decodedToken.transactionId || null,
    decodedOriginalTransactionId: decodedToken.originalTransactionId || null,
  });
  const transactionId = decodedToken.transactionId || decodedToken.originalTransactionId;
  if (!transactionId) {
    return {
      isValid: false,
      details: {
        status: "invalid",
        reason: "missing_transaction_id_in_jws",
      },
    };
  }

  const bearerToken = buildAppleServerApiJwt({ issuerId, keyId, privateKey, bundleId });

  let payload;
  let environment;
  let lastError;
  const retryDelaysMs = [0, 1500, 4000];

  for (const delayMs of retryDelaysMs) {
    console.log("[easySubs][verifyAppleServerApi] lookup attempt", {
      transactionId,
      delayMs,
      productId,
    });
    if (delayMs > 0) {
      await sleep(delayMs);
    }

    try {
      payload = await fetchAppleTransactionById({
        transactionId,
        bearerToken,
        baseUrl: APPLE_SERVER_API_PRODUCTION_URL,
      });
      environment = "Production";
      break;
    } catch (error) {
      console.warn("[easySubs][verifyAppleServerApi] production lookup failed", {
        transactionId,
        statusCode: error?.statusCode || null,
        appleErrorCode: error?.appleErrorCode || null,
        message: error?.message || String(error),
      });
      lastError = error;
    }

    try {
      payload = await fetchAppleTransactionById({
        transactionId,
        bearerToken,
        baseUrl: APPLE_SERVER_API_SANDBOX_URL,
      });
      environment = "Sandbox";
      break;
    } catch (error) {
      console.warn("[easySubs][verifyAppleServerApi] sandbox lookup failed", {
        transactionId,
        statusCode: error?.statusCode || null,
        appleErrorCode: error?.appleErrorCode || null,
        message: error?.message || String(error),
      });
      lastError = error;
    }
  }

  if (!payload) {
    const productMatches = !productId || !parsedFromSignedTransaction.productId || parsedFromSignedTransaction.productId === productId;

    if (isAppleTransactionNotFoundError(lastError) && parsedFromSignedTransaction.hasTransaction && productMatches) {
      console.warn("[easySubs][verifyPurchase] Apple transaction not found in Server API", {
        transactionId,
        productId,
        productIdFromStore: parsedFromSignedTransaction.productId,
        appleErrorCode: lastError.appleErrorCode,
        appleStatusCode: lastError.statusCode || null,
        appleMessage: lastError.message || null,
      });

      return {
        isValid: false,
        details: {
          status: "invalid",
          reason: "apple_transaction_not_found",
          appleLookupDeferred: false,
          appleLookupErrorCode: lastError.appleErrorCode || null,
        },
      };
    }

    throw lastError;
  }

  const parsed = parseAppleSignedTransactionInfo(payload?.signedTransactionInfo);
  return {
    isValid: parsed.isValid,
    details: {
      platform: "app_store",
      status: parsed.status,
      reason: null,
      appleLookupDeferred: null,
      appleLookupErrorCode: null,
      originalTransactionId: parsed.originalTransactionId,
      transactionId: parsed.transactionId,
      purchaseDateMs: parsed.purchaseDateMs,
      expiryDateMs: parsed.expiryDateMs,
      revocationDateMs: parsed.revocationDateMs,
      appAccountToken: parsed.appAccountToken,
      productIdFromStore: parsed.productId,
      storefront: parsed.storefront,
      transactionReason: parsed.transactionReason,
      appleEnvironment: environment,
      appleVerificationMode: "server_api",
    },
  };
}

function parseAppleReceiptResult(payload) {
  const latest = Array.isArray(payload?.latest_receipt_info)
    ? payload.latest_receipt_info
    : [];
  const pendingRenewal = Array.isArray(payload?.pending_renewal_info)
    ? payload.pending_renewal_info
    : [];

  const sorted = [...latest].sort((a, b) => {
    const aExp = Number(a?.expires_date_ms || 0);
    const bExp = Number(b?.expires_date_ms || 0);
    return bExp - aExp;
  });

  const tx = sorted[0] || null;
  const renewal = pendingRenewal[0] || null;

  const expiryDateMs = toMillis(tx?.expires_date_ms);
  const now = Date.now();
  const isExpired = expiryDateMs ? expiryDateMs <= now : false;
  const hasTransaction = Boolean(tx);
  const status = hasTransaction ? (isExpired ? "expired" : "active") : "unknown";

  return {
    hasTransaction,
    isValid: hasTransaction && isEntitledStatus(status),
    status,
    originalTransactionId: tx?.original_transaction_id || null,
    transactionId: tx?.transaction_id || null,
    purchaseDateMs: toMillis(tx?.purchase_date_ms),
    expiryDateMs,
    cancellationDateMs: toMillis(tx?.cancellation_date_ms),
    autoRenewStatus:
      renewal?.auto_renew_status != null
        ? String(renewal.auto_renew_status) === "1"
        : null,
  };
}

async function verifyApplePurchase({ verificationData, productId, functionsInstance }) {
  const jwsLike = isLikelyJws(verificationData);
  if (jwsLike) {
    return verifyApplePurchaseByServerApi({ verificationData, productId, functionsInstance });
  }

  const sharedSecret = getConfigValue(
    functionsInstance,
    "easysubs.apple_shared_secret",
    "APPLE_SHARED_SECRET",
  );
  if (!sharedSecret) {
    throw new Error("Missing APPLE_SHARED_SECRET environment variable");
  }

  const production = await verifyAppleReceiptWithEndpoint(
    APPLE_VERIFY_RECEIPT_PRODUCTION_URL,
    verificationData,
    sharedSecret,
  );

  // 21007 => receipt is from sandbox, retry in sandbox endpoint.
  const finalPayload = production?.status === 21007
    ? await verifyAppleReceiptWithEndpoint(
        APPLE_VERIFY_RECEIPT_SANDBOX_URL,
        verificationData,
        sharedSecret,
      )
    : production;

  if (finalPayload?.status !== 0) {
    return {
      isValid: false,
      details: {
        status: "invalid",
        appleStatus: finalPayload?.status,
        appleEnvironment: finalPayload?.environment || null,
        appleVerificationMode: "verify_receipt",
      },
    };
  }

  const parsed = parseAppleReceiptResult(finalPayload);
  return {
    isValid: parsed.isValid,
    details: {
      platform: "app_store",
      status: parsed.status,
      reason: null,
      appleLookupDeferred: null,
      appleLookupErrorCode: null,
      originalTransactionId: parsed.originalTransactionId,
      transactionId: parsed.transactionId,
      purchaseDateMs: parsed.purchaseDateMs,
      expiryDateMs: parsed.expiryDateMs,
      cancellationDateMs: parsed.cancellationDateMs,
      autoRenewStatus: parsed.autoRenewStatus,
      appleEnvironment: finalPayload?.environment || null,
      appleStatus: finalPayload?.status,
      appleVerificationMode: "verify_receipt",
    },
  };
}

async function verifyGooglePurchase({ verificationData, productId, functionsInstance }) {
  const packageName = getConfigValue(
    functionsInstance,
    "easysubs.google_play_package_name",
    "GOOGLE_PLAY_PACKAGE_NAME",
  );
  if (!packageName) {
    throw new Error("Missing GOOGLE_PLAY_PACKAGE_NAME environment variable");
  }

  const auth = new google.auth.GoogleAuth({
    scopes: ["https://www.googleapis.com/auth/androidpublisher"],
  });
  const authClient = await auth.getClient();
  const androidpublisher = google.androidpublisher({ version: "v3", auth: authClient });

  const response = await androidpublisher.purchases.subscriptionsv2.get({
    packageName,
    token: verificationData,
  });

  const sub = response.data || {};
  const lineItems = Array.isArray(sub.lineItems) ? sub.lineItems : [];
  const line = lineItems[0] || {};
  const expiryDateMs = line.expiryTime ? new Date(line.expiryTime).getTime() : null;

  const status = mapGoogleSubscriptionState(sub.subscriptionState);
  const isValid = ["active", "trialing"].includes(status);

  return {
    isValid,
    details: {
      platform: "google_play",
      status,
      reason: null,
      appleLookupDeferred: null,
      appleLookupErrorCode: null,
      purchaseToken: verificationData,
      planId: productId,
      linkedPurchaseToken: sub.linkedPurchaseToken || null,
      externalAccountIdentifiers: sub.externalAccountIdentifiers || null,
      latestOrderId: line.latestSuccessfulOrderId || null,
      expiryDateMs,
      acknowledged:
        sub.acknowledgementState === "ACKNOWLEDGEMENT_STATE_ACKNOWLEDGED",
      rawSubscriptionState: sub.subscriptionState || null,
    },
  };
}

/**
 * Generates the easy_subs_firebase backend plugin functions dynamically.
 * 
 * @param {Object} adminInstance - The initialized `firebase-admin` instance.
 * @param {Object} functionsInstance - The `firebase-functions` instance.
 * @returns {Object} An object containing the highly coupled functions ready to export.
 */
function createEasySubsFunctions(adminInstance, functionsInstance) {

  const verifyPurchase = functionsInstance.https.onCall(async (data, context) => {
    const requestId = `${Date.now()}-${Math.random().toString(36).slice(2, 8)}`;
    const { source, productId, verificationData } = data;
    console.log("[easySubs][verifyPurchase] incoming request", {
      requestId,
      hasAuth: Boolean(context.auth),
      uid: context.auth?.uid || null,
      source,
      productId,
      verificationDataLength: verificationData ? String(verificationData).length : 0,
      verificationDataIsJws: isLikelyJws(verificationData),
      verificationDataPrefix: verificationData ? String(verificationData).slice(0, 24) : null,
    });
    
    if (!context.auth) {
      throw new functionsInstance.https.HttpsError(
        "unauthenticated",
        "The function must be called while authenticated."
      );
    }

    const userId = context.auth.uid;
    console.log("[easySubs][verifyPurchase] authenticated", { requestId, userId });

    try {
      let verification;
      if (source === "app_store") {
        verification = await verifyApplePurchase({ verificationData, productId, functionsInstance });
      } else if (source === "google_play") {
        verification = await verifyGooglePurchase({ verificationData, productId, functionsInstance });
      } else {
        throw new functionsInstance.https.HttpsError("invalid-argument", "Invalid source provided.");
      }

      if (verification.isValid) {
        console.log("[easySubs][verifyPurchase] writing subscriptions doc", { requestId, userId, planId: productId, verificationDetails: verification.details || null });
        await upsertSubscription(adminInstance, userId, {
          planId: productId,
          ...verification.details,
        });

        console.log("[easySubs][verifyPurchase] success", { requestId, userId, planId: productId });

        return {
          success: true,
          message: "Purchase verified successfully.",
          details: verification.details || {},
        };
      } else {
        console.warn("[easySubs][verifyPurchase] remote validation failed", {
          requestId,
          userId,
          source,
          productId,
          details: verification.details || null,
        });
        await upsertSubscription(adminInstance, userId, {
          planId: productId,
          platform: source,
          status: verification.details?.status || "invalid",
          ...verification.details,
        });
        return {
          success: false,
          message: `Receipt validation failed remotely. details=${JSON.stringify(verification.details || {})}`,
          details: verification.details || {},
        };
      }

    } catch (error) {
      console.error("[easySubs][verifyPurchase] unhandled error", {
        requestId,
        message: error?.message || String(error),
        stack: error?.stack || null,
        code: error?.code || null,
      });
      throw new functionsInstance.https.HttpsError("internal", "An error occurred during verification.");
    }
  });

  const appleWebhook = functionsInstance.https.onRequest(async (req, res) => {
    const requestId = `${Date.now()}-${Math.random().toString(36).slice(2, 8)}`;
    try {
      console.log("[easySubs][appleWebhook] incoming", {
        requestId,
        method: req.method,
        path: req.path,
        contentType: req.get("content-type") || null,
        userAgent: req.get("user-agent") || null,
        ip: req.ip,
        forwardedFor: req.get("x-forwarded-for") || null,
        hasBody: Boolean(req.body),
        bodyKeys: req.body && typeof req.body === "object" ? Object.keys(req.body) : [],
        rawBodyLength: req.rawBody ? req.rawBody.length : 0,
      });

      if (req.method !== "POST") {
        console.warn("[easySubs][appleWebhook] unexpected method", { requestId, method: req.method });
      }

      const signedPayload = req.body?.signedPayload;
      console.log("[easySubs][appleWebhook] signedPayload metadata", {
        requestId,
        hasSignedPayload: Boolean(signedPayload),
        signedPayloadLength: signedPayload ? String(signedPayload).length : 0,
        signedPayloadPrefix: signedPayload ? String(signedPayload).slice(0, 20) : null,
      });

      if (!signedPayload) {
        console.warn("[easySubs][appleWebhook] missing signedPayload", { requestId });
        res.status(400).send("Missing signedPayload");
        return;
      }

      const decodedPayload = safeJwtDecode(signedPayload);
      if (!decodedPayload) {
        console.warn("[easySubs][appleWebhook] invalid signedPayload", { requestId });
        res.status(400).send("Invalid signedPayload");
        return;
      }

      const notificationType = decodedPayload.notificationType || null;
      const subtype = decodedPayload.subtype || null;
      const data = decodedPayload.data || {};

      const signedTransactionInfo = data.signedTransactionInfo;
      const signedRenewalInfo = data.signedRenewalInfo;

      const transactionInfo = safeJwtDecode(signedTransactionInfo) || {};
      const renewalInfo = safeJwtDecode(signedRenewalInfo) || {};

      const originalTransactionId =
        transactionInfo.originalTransactionId ||
        renewalInfo.originalTransactionId ||
        null;

      const status = mapAppleWebhookStatus(notificationType, subtype);

      console.log("[easySubs][appleWebhook] parsed", {
        requestId,
        notificationType,
        subtype,
        originalTransactionId,
        status,
        hasSignedTransactionInfo: Boolean(signedTransactionInfo),
        hasSignedRenewalInfo: Boolean(signedRenewalInfo),
        transactionId: transactionInfo.transactionId || null,
        renewalOriginalTransactionId: renewalInfo.originalTransactionId || null,
      });

      if (!originalTransactionId) {
        console.warn("[easySubs][appleWebhook] no originalTransactionId, skipping upsert", { requestId });
        res.status(200).send("OK");
        return;
      }

      console.log("[easySubs][appleWebhook] finding subscription by originalTransactionId", {
        requestId,
        originalTransactionId,
      });
      const sub = await findSubscriptionByField(
        adminInstance,
        "originalTransactionId",
        originalTransactionId,
      );

      if (!sub) {
        console.warn("[easySubs][appleWebhook] subscription not found for originalTransactionId", {
          requestId,
          originalTransactionId,
        });
        res.status(200).send("OK");
        return;
      }

      const expiryDateMs = transactionInfo.expiresDate
        ? new Date(transactionInfo.expiresDate).getTime()
        : toMillis(transactionInfo.expiresDateMs);

      await upsertSubscription(adminInstance, sub.userId, {
        platform: "app_store",
        status,
        reason: null,
        appleLookupDeferred: null,
        appleLookupErrorCode: null,
        notificationType,
        notificationSubtype: subtype,
        originalTransactionId,
        transactionId: transactionInfo.transactionId || null,
        webOrderLineItemId: transactionInfo.webOrderLineItemId || null,
        autoRenewStatus:
          renewalInfo.autoRenewStatus != null
            ? String(renewalInfo.autoRenewStatus) === "1"
            : null,
        expiryDateMs: expiryDateMs || null,
        revocationDateMs: transactionInfo.revocationDate
          ? new Date(transactionInfo.revocationDate).getTime()
          : null,
      });

      console.log("[easySubs][appleWebhook] updated subscription", {
        requestId,
        userId: sub.userId,
        status,
        originalTransactionId,
        transactionId: transactionInfo.transactionId || null,
        expiryDateMs: expiryDateMs || null,
      });

      console.log("[easySubs][appleWebhook] responding 200", { requestId });
      res.status(200).send("OK");
    } catch (error) {
      console.error("[easySubs][appleWebhook] unhandled error", {
        requestId,
        message: error?.message || String(error),
        stack: error?.stack || null,
      });
      res.status(500).send("Internal Server Error");
    }
  });

  const googlePubSubHandler = functionsInstance.pubsub.topic("play-billing").onPublish(async (message) => {
      try {
        const raw = message.data
          ? JSON.parse(Buffer.from(message.data, "base64").toString("utf8"))
          : {};

        const subscriptionNotification = raw.subscriptionNotification || {};
        const purchaseToken = subscriptionNotification.purchaseToken;
        const notificationType = subscriptionNotification.notificationType;
        const subscriptionId = subscriptionNotification.subscriptionId;

        console.log("[easySubs][googlePubSubHandler] incoming", {
          packageName: raw.packageName,
          notificationType,
          subscriptionId,
          hasPurchaseToken: Boolean(purchaseToken),
        });

        if (!purchaseToken) {
          console.warn("[easySubs][googlePubSubHandler] missing purchaseToken, skipping");
          return;
        }

        const sub = await findSubscriptionByField(
          adminInstance,
          "purchaseToken",
          purchaseToken,
        );

        if (!sub) {
          console.warn("[easySubs][googlePubSubHandler] subscription not found for purchaseToken");
          return;
        }

        const packageName = getConfigValue(
          functionsInstance,
          "easysubs.google_play_package_name",
          "GOOGLE_PLAY_PACKAGE_NAME",
        );
        if (!packageName) {
          throw new Error("Missing GOOGLE_PLAY_PACKAGE_NAME environment variable");
        }

        const auth = new google.auth.GoogleAuth({
          scopes: ["https://www.googleapis.com/auth/androidpublisher"],
        });
        const authClient = await auth.getClient();
        const androidpublisher = google.androidpublisher({ version: "v3", auth: authClient });

        const response = await androidpublisher.purchases.subscriptionsv2.get({
          packageName,
          token: purchaseToken,
        });

        const payload = response.data || {};
        const lineItems = Array.isArray(payload.lineItems) ? payload.lineItems : [];
        const line = lineItems[0] || {};
        const status = mapGoogleSubscriptionState(payload.subscriptionState);

        await upsertSubscription(adminInstance, sub.userId, {
          planId: subscriptionId || sub.data?.planId || null,
          platform: "google_play",
          status,
          reason: null,
          appleLookupDeferred: null,
          appleLookupErrorCode: null,
          purchaseToken,
          latestOrderId: line.latestSuccessfulOrderId || null,
          expiryDateMs: line.expiryTime ? new Date(line.expiryTime).getTime() : null,
          rawSubscriptionState: payload.subscriptionState || null,
          rtdnNotificationType: notificationType,
        });

        console.log("[easySubs][googlePubSubHandler] updated subscription", {
          userId: sub.userId,
          status,
          notificationType,
        });
      } catch (error) {
          console.error("Google RTDN Error:", error);
      }
  });

  return {
    verifyPurchase,
    appleWebhook,
    googlePubSubHandler
  };
}

module.exports = { createEasySubsFunctions };
