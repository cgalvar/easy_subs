const crypto = require("node:crypto");
const { google } = require("googleapis");
const jwt = require("jsonwebtoken");

const APPLE_VERIFY_RECEIPT_PRODUCTION_URL = "https://buy.itunes.apple.com/verifyReceipt";
const APPLE_VERIFY_RECEIPT_SANDBOX_URL = "https://sandbox.itunes.apple.com/verifyReceipt";
const APPLE_SERVER_API_PRODUCTION_URL = "https://api.storekit.itunes.apple.com";
const APPLE_SERVER_API_SANDBOX_URL = "https://api.storekit-sandbox.itunes.apple.com";
const DEFAULT_SUBSCRIPTIONS_COLLECTION = "subscriptions";
const SUBSCRIPTION_SOURCES_SUBCOLLECTION = "sources";
const VALID_PURCHASE_SOURCES = new Set(["app_store", "google_play"]);
const GOOGLE_PLAY_RETRY_DELAYS_MS = [0, 1500, 4000];

const fallbackLogger = {
  info(message, metadata = {}) {
    console.log(message, metadata);
  },
  warn(message, metadata = {}) {
    console.warn(message, metadata);
  },
  error(message, metadata = {}) {
    console.error(message, metadata);
  },
};

function getLogger(functionsInstance) {
  const logger = functionsInstance?.logger;
  if (logger && typeof logger.info === "function") {
    return logger;
  }
  return fallbackLogger;
}

function logInfo(functionsInstance, message, metadata = {}) {
  getLogger(functionsInstance).info(message, metadata);
}

function logWarn(functionsInstance, message, metadata = {}) {
  getLogger(functionsInstance).warn(message, metadata);
}

function logError(functionsInstance, message, metadata = {}) {
  getLogger(functionsInstance).error(message, metadata);
}

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

function getSubscriptionsCollectionName(functionsInstance) {
  return getConfigValue(
    functionsInstance,
    "easysubs.subscriptions_collection",
    "EASY_SUBS_SUBSCRIPTIONS_COLLECTION",
  ) || DEFAULT_SUBSCRIPTIONS_COLLECTION;
}

function getSubscriptionDocRef(adminInstance, userId, functionsInstance) {
  return adminInstance.firestore
    .collection(getSubscriptionsCollectionName(functionsInstance))
    .doc(userId);
}

function getSubscriptionSourcesCollectionRef(adminInstance, userId, functionsInstance) {
  return getSubscriptionDocRef(adminInstance, userId, functionsInstance)
    .collection(SUBSCRIPTION_SOURCES_SUBCOLLECTION);
}

function normalizePurchaseSource(source) {
  return typeof source === "string" ? source.trim().toLowerCase() : "";
}

function hashIdentifier(value) {
  return crypto.createHash("sha256").update(String(value)).digest("hex").slice(0, 24);
}

function toComparableMillis(value) {
  if (value == null) return null;
  if (typeof value?.toMillis === "function") {
    return value.toMillis();
  }
  if (value instanceof Date) {
    return value.getTime();
  }
  return toMillis(value);
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

function hasEffectiveEntitlement(sourceData = {}) {
  const status = String(sourceData?.status || "").toLowerCase();
  const expiryDateMs = toComparableMillis(sourceData?.expiryDateMs);

  if (isEntitledStatus(status)) {
    return true;
  }

  return status === "canceled" && typeof expiryDateMs === "number" && expiryDateMs > Date.now();
}

function getSourcePriority(sourceData = {}) {
  const status = String(sourceData?.status || "").toLowerCase();
  if (hasEffectiveEntitlement(sourceData)) {
    return 3;
  }
  if (["paused", "on_hold", "canceled", "expired", "refunded", "revoked"].includes(status)) {
    return 2;
  }
  if (["pending", "unknown", "invalid"].includes(status)) {
    return 0;
  }
  return 1;
}

function buildSubscriptionSourceId({ source, details = {}, productId, verificationData }) {
  const stableIdentifier =
    details.originalTransactionId ||
    details.transactionId ||
    details.purchaseToken ||
    details.linkedPurchaseToken ||
    verificationData ||
    productId ||
    `${source}:${Date.now()}`;

  return `${source}_${hashIdentifier(stableIdentifier)}`;
}

function selectWinningSource(sourceEntries = []) {
  if (sourceEntries.length === 0) {
    return null;
  }

  const sortedEntries = [...sourceEntries].sort((left, right) => {
    const priorityDiff = getSourcePriority(right.data) - getSourcePriority(left.data);
    if (priorityDiff !== 0) {
      return priorityDiff;
    }

    const expiryDiff = (toComparableMillis(right.data?.expiryDateMs) || 0) - (toComparableMillis(left.data?.expiryDateMs) || 0);
    if (expiryDiff !== 0) {
      return expiryDiff;
    }

    const purchaseDiff = (toComparableMillis(right.data?.purchaseDateMs) || 0) - (toComparableMillis(left.data?.purchaseDateMs) || 0);
    if (purchaseDiff !== 0) {
      return purchaseDiff;
    }

    return (toComparableMillis(right.data?.updatedAt) || 0) - (toComparableMillis(left.data?.updatedAt) || 0);
  });

  return sortedEntries[0];
}

function buildSubscriptionAggregate({ userId, selectedSource, sourceCount }) {
  const selectedSourceId = selectedSource?.sourceId || null;
  const data = selectedSource?.data || {};

  return {
    userId,
    selectedSourceId,
    sourceCount,
    hasActiveEntitlement: hasEffectiveEntitlement(data),
    planId: data?.planId || null,
    platform: data?.platform || null,
    status: data?.status || (sourceCount > 0 ? "unknown" : "invalid"),
    reason: data?.reason || null,
    expiryDateMs: toComparableMillis(data?.expiryDateMs),
    purchaseDateMs: toComparableMillis(data?.purchaseDateMs),
    cancellationDateMs: toComparableMillis(data?.cancellationDateMs),
    revocationDateMs: toComparableMillis(data?.revocationDateMs),
    purchaseToken: data?.purchaseToken || null,
    linkedPurchaseToken: data?.linkedPurchaseToken || null,
    originalTransactionId: data?.originalTransactionId || null,
    transactionId: data?.transactionId || null,
    latestOrderId: data?.latestOrderId || null,
    externalAccountIdentifiers: data?.externalAccountIdentifiers || null,
    productIdFromStore: data?.productIdFromStore || null,
    productIdMatches: data?.productIdMatches ?? null,
    rawSubscriptionState: data?.rawSubscriptionState || null,
    autoRenewStatus: data?.autoRenewStatus ?? null,
    acknowledged: data?.acknowledged ?? null,
    acknowledgementRequired: data?.acknowledgementRequired ?? null,
    refreshedUsingStoredToken: data?.refreshedUsingStoredToken ?? null,
    tokenCandidateCount: data?.tokenCandidateCount ?? null,
    appAccountToken: data?.appAccountToken || null,
    storefront: data?.storefront || null,
    transactionReason: data?.transactionReason || null,
    webOrderLineItemId: data?.webOrderLineItemId || null,
    appleEnvironment: data?.appleEnvironment || null,
    appleStatus: data?.appleStatus || null,
    appleVerificationMode: data?.appleVerificationMode || null,
    appleLookupDeferred: data?.appleLookupDeferred ?? null,
    appleLookupErrorCode: data?.appleLookupErrorCode ?? null,
    notificationType: data?.notificationType || null,
    notificationSubtype: data?.notificationSubtype || null,
    rtdnNotificationType: data?.rtdnNotificationType || null,
  };
}

function buildGoogleApiErrorMetadata(error) {
  return {
    code: error?.code || null,
    status: error?.response?.status || error?.status || null,
    message: error?.message || String(error),
    errors: error?.errors || null,
  };
}

function isRetryableGoogleApiError(error) {
  const statusCode = error?.response?.status || error?.status || error?.code;
  return statusCode === 408 || statusCode === 429 || (statusCode >= 500 && statusCode < 600);
}

async function upsertSubscription(adminInstance, userId, data, functionsInstance) {
  const collectionName = getSubscriptionsCollectionName(functionsInstance);

  logInfo(functionsInstance, "[easySubs][subscriptions] upsert start", {
    userId,
    collectionName,
    status: data?.status || null,
    platform: data?.platform || null,
    notificationType: data?.notificationType || null,
    originalTransactionId: data?.originalTransactionId || null,
    transactionId: data?.transactionId || null,
    expiryDateMs: data?.expiryDateMs || null,
  });

  await getSubscriptionDocRef(adminInstance, userId, functionsInstance).set(
    {
      userId,
      ...data,
      updatedAt: adminInstance.FieldValue.serverTimestamp(),
    },
  );

  logInfo(functionsInstance, "[easySubs][subscriptions] upsert done", {
    userId,
    collectionName,
    status: data?.status || null,
    platform: data?.platform || null,
  });
}

async function upsertSubscriptionSource(adminInstance, userId, sourceId, data, functionsInstance) {
  logInfo(functionsInstance, "[easySubs][subscriptionSources] upsert start", {
    userId,
    sourceId,
    platform: data?.platform || null,
    status: data?.status || null,
    planId: data?.planId || null,
  });

  await getSubscriptionSourcesCollectionRef(adminInstance, userId, functionsInstance)
    .doc(sourceId)
    .set(
      {
        sourceId,
        ownerUserId: userId,
        ...data,
        updatedAt: adminInstance.FieldValue.serverTimestamp(),
      },
      { merge: true },
    );

  logInfo(functionsInstance, "[easySubs][subscriptionSources] upsert done", {
    userId,
    sourceId,
    platform: data?.platform || null,
    status: data?.status || null,
  });
}

async function recomputeSubscriptionAggregate(adminInstance, userId, functionsInstance) {
  const sourcesSnapshot = await getSubscriptionSourcesCollectionRef(
    adminInstance,
    userId,
    functionsInstance,
  ).get();

  const sourceEntries = sourcesSnapshot.docs.map((doc) => ({
    sourceId: doc.id,
    data: doc.data() || {},
  }));

  const selectedSource = selectWinningSource(sourceEntries);
  const aggregate = buildSubscriptionAggregate({
    userId,
    selectedSource,
    sourceCount: sourceEntries.length,
  });

  await upsertSubscription(adminInstance, userId, aggregate, functionsInstance);

  logInfo(functionsInstance, "[easySubs][subscriptions] aggregate recomputed", {
    userId,
    selectedSourceId: aggregate.selectedSourceId,
    status: aggregate.status,
    planId: aggregate.planId,
    sourceCount: aggregate.sourceCount,
  });

  return {
    aggregate,
    selectedSource,
  };
}

async function findSubscriptionByField(adminInstance, field, value, functionsInstance) {
  const collectionName = getSubscriptionsCollectionName(functionsInstance);

  if (!value) {
    logWarn(functionsInstance, "[easySubs][subscriptions] find skipped: empty value", { field, collectionName });
    return null;
  }

  logInfo(functionsInstance, "[easySubs][subscriptions] find start", {
    field,
    collectionName,
    valuePreview: String(value).slice(0, 24),
    valueLength: String(value).length,
  });

  const snap = await adminInstance.firestore
    .collection(collectionName)
    .where(field, "==", value)
    .limit(1)
    .get();

  if (snap.empty) {
    logWarn(functionsInstance, "[easySubs][subscriptions] find empty", { field, collectionName });
    return null;
  }

  const doc = snap.docs[0];
  logInfo(functionsInstance, "[easySubs][subscriptions] find hit", {
    field,
    collectionName,
    userId: doc.id,
    docKeys: Object.keys(doc.data() || {}),
  });

  return {
    userId: doc.id,
    data: doc.data(),
  };
}

async function getSubscriptionByUserId(adminInstance, userId, functionsInstance) {
  const collectionName = getSubscriptionsCollectionName(functionsInstance);
  const snapshot = await getSubscriptionDocRef(adminInstance, userId, functionsInstance).get();

  if (!snapshot.exists) {
    logWarn(functionsInstance, "[easySubs][subscriptions] get by user empty", {
      collectionName,
      userId,
    });
    return null;
  }

  return {
    userId: snapshot.id,
    data: snapshot.data() || {},
  };
}

async function findSubscriptionSourceByField(adminInstance, field, value, functionsInstance) {
  if (!value) {
    return null;
  }

  const snapshot = await adminInstance.firestore
    .collectionGroup(SUBSCRIPTION_SOURCES_SUBCOLLECTION)
    .where(field, "==", value)
    .limit(1)
    .get();

  if (snapshot.empty) {
    return null;
  }

  const doc = snapshot.docs[0];
  const parentDoc = doc.ref.parent.parent;
  return {
    userId: parentDoc?.id || null,
    sourceId: doc.id,
    data: doc.data() || {},
  };
}

async function findSubscriptionSourceByGoogleTokens(adminInstance, { purchaseToken, linkedPurchaseToken, functionsInstance }) {
  const candidates = [
    { field: "purchaseToken", value: purchaseToken },
    { field: "linkedPurchaseToken", value: purchaseToken },
    { field: "purchaseToken", value: linkedPurchaseToken },
    { field: "linkedPurchaseToken", value: linkedPurchaseToken },
  ];

  for (const candidate of candidates) {
    if (!candidate.value) {
      continue;
    }

    const source = await findSubscriptionSourceByField(
      adminInstance,
      candidate.field,
      candidate.value,
      functionsInstance,
    );

    if (source) {
      return source;
    }
  }

  return null;
}

async function findSubscriptionSourceByAppleIdentifiers(adminInstance, { originalTransactionId, transactionId, functionsInstance }) {
  const candidates = [
    { field: "originalTransactionId", value: originalTransactionId },
    { field: "transactionId", value: transactionId },
  ];

  for (const candidate of candidates) {
    if (!candidate.value) {
      continue;
    }

    const source = await findSubscriptionSourceByField(
      adminInstance,
      candidate.field,
      candidate.value,
      functionsInstance,
    );

    if (source) {
      return source;
    }
  }

  return null;
}

function collectUniqueStrings(values) {
  const unique = [];
  for (const value of values) {
    if (typeof value !== "string") {
      continue;
    }

    const normalized = value.trim();
    if (!normalized || unique.includes(normalized)) {
      continue;
    }

    unique.push(normalized);
  }
  return unique;
}

async function findSubscriptionByGoogleTokens(adminInstance, { purchaseToken, linkedPurchaseToken, functionsInstance }) {
  const candidates = [
    { field: "purchaseToken", value: purchaseToken },
    { field: "linkedPurchaseToken", value: purchaseToken },
    { field: "purchaseToken", value: linkedPurchaseToken },
    { field: "linkedPurchaseToken", value: linkedPurchaseToken },
  ];

  for (const candidate of candidates) {
    if (!candidate.value) {
      continue;
    }

    const subscription = await findSubscriptionByField(
      adminInstance,
      candidate.field,
      candidate.value,
      functionsInstance,
    );

    if (subscription) {
      return subscription;
    }
  }

  return null;
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

async function fetchGoogleSubscription({ verificationData, packageName, productId, functionsInstance, logContext = {} }) {
  const auth = new google.auth.GoogleAuth({
    scopes: ["https://www.googleapis.com/auth/androidpublisher"],
  });
  const authClient = await auth.getClient();
  const androidpublisher = google.androidpublisher({ version: "v3", auth: authClient });

  let lastError;

  for (const delayMs of GOOGLE_PLAY_RETRY_DELAYS_MS) {
    if (delayMs > 0) {
      await sleep(delayMs);
    }

    try {
      logInfo(functionsInstance, "[easySubs][googlePlay] subscription lookup attempt", {
        ...logContext,
        packageName,
        productId,
        delayMs,
        tokenLength: verificationData ? String(verificationData).length : 0,
      });

      const response = await androidpublisher.purchases.subscriptionsv2.get({
        packageName,
        token: verificationData,
      });

      return response.data || {};
    } catch (error) {
      lastError = error;
      logWarn(functionsInstance, "[easySubs][googlePlay] subscription lookup failed", {
        ...logContext,
        packageName,
        productId,
        delayMs,
        ...buildGoogleApiErrorMetadata(error),
      });

      if (!isRetryableGoogleApiError(error)) {
        break;
      }
    }
  }

  throw lastError;
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
  logInfo(functionsInstance, "[easySubs][verifyAppleServerApi] decoded token metadata", {
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
    logInfo(functionsInstance, "[easySubs][verifyAppleServerApi] lookup attempt", {
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
      logWarn(functionsInstance, "[easySubs][verifyAppleServerApi] production lookup failed", {
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
      logWarn(functionsInstance, "[easySubs][verifyAppleServerApi] sandbox lookup failed", {
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
      logWarn(functionsInstance, "[easySubs][verifyPurchase] Apple transaction not found in Server API", {
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

  const sub = await fetchGoogleSubscription({
    verificationData,
    packageName,
    productId,
    functionsInstance,
    logContext: {
      verificationMode: "verify_purchase",
    },
  });
  const lineItems = Array.isArray(sub.lineItems) ? sub.lineItems : [];
  const line = (productId
    ? lineItems.find((item) => item?.productId === productId)
    : null) || lineItems[0] || {};
  const expiryDateMs = line.expiryTime ? new Date(line.expiryTime).getTime() : null;
  const productIdFromStore = line.productId || null;
  const productIdMatches = !productId || !productIdFromStore || productIdFromStore === productId;
  const acknowledged = sub.acknowledgementState === "ACKNOWLEDGEMENT_STATE_ACKNOWLEDGED";

  const status = mapGoogleSubscriptionState(sub.subscriptionState);
  const isValid = isEntitledStatus(status) && productIdMatches;

  return {
    isValid,
    details: {
      platform: "google_play",
      status,
      reason: productIdMatches ? null : "product_id_mismatch",
      appleLookupDeferred: null,
      appleLookupErrorCode: null,
      purchaseToken: verificationData,
      planId: productId,
      productIdFromStore,
      productIdMatches,
      linkedPurchaseToken: sub.linkedPurchaseToken || null,
      externalAccountIdentifiers: sub.externalAccountIdentifiers || null,
      latestOrderId: line.latestSuccessfulOrderId || null,
      expiryDateMs,
      acknowledged,
      acknowledgementRequired: isEntitledStatus(status) && !acknowledged,
      rawSubscriptionState: sub.subscriptionState || null,
    },
  };
}

async function refreshGooglePurchaseStatus({
  adminInstance,
  userId,
  productId,
  verificationData,
  functionsInstance,
}) {
  const storedSubscription = await getSubscriptionByUserId(
    adminInstance,
    userId,
    functionsInstance,
  );

  const candidateTokens = collectUniqueStrings([
    verificationData,
    storedSubscription?.data?.purchaseToken,
    storedSubscription?.data?.linkedPurchaseToken,
  ]);

  if (candidateTokens.length === 0) {
    return {
      isValid: false,
      details: {
        platform: "google_play",
        status: "invalid",
        reason: "missing_purchase_token",
        appleLookupDeferred: null,
        appleLookupErrorCode: null,
      },
    };
  }

  let lastError;

  for (const token of candidateTokens) {
    try {
      const verification = await verifyGooglePurchase({
        verificationData: token,
        productId,
        functionsInstance,
      });

      return {
        isValid: verification.isValid,
        details: {
          ...verification.details,
          refreshedUsingStoredToken: token !== verificationData,
          tokenCandidateCount: candidateTokens.length,
        },
      };
    } catch (error) {
      lastError = error;
      logWarn(functionsInstance, "[easySubs][refreshPurchaseStatus] google token refresh attempt failed", {
        userId,
        productId,
        usedProvidedToken: token === verificationData,
        ...buildGoogleApiErrorMetadata(error),
      });
    }
  }

  throw lastError;
}

function buildOwnershipConflictError({ userId, ownerUserId, sourceId, source }) {
  const error = new Error(
    `This ${source} purchase is already associated with another account. owner=${ownerUserId} requested=${userId} sourceId=${sourceId}`,
  );
  error.code = "purchase-owner-conflict";
  return error;
}

async function resolveAppleSourceReference({
  adminInstance,
  userId,
  details,
  productId,
  verificationData,
  functionsInstance,
}) {
  const existingSource = await findSubscriptionSourceByAppleIdentifiers(adminInstance, {
    originalTransactionId: details?.originalTransactionId,
    transactionId: details?.transactionId,
    functionsInstance,
  });

  if (existingSource) {
    if (existingSource.userId !== userId) {
      throw buildOwnershipConflictError({
        userId,
        ownerUserId: existingSource.userId,
        sourceId: existingSource.sourceId,
        source: "app_store",
      });
    }

    return {
      userId,
      sourceId: existingSource.sourceId,
      existingData: existingSource.data,
    };
  }

  const legacySubscription =
    await findSubscriptionByField(
      adminInstance,
      "originalTransactionId",
      details?.originalTransactionId,
      functionsInstance,
    ) ||
    await findSubscriptionByField(
      adminInstance,
      "transactionId",
      details?.transactionId,
      functionsInstance,
    );

  if (legacySubscription && legacySubscription.userId !== userId) {
    throw buildOwnershipConflictError({
      userId,
      ownerUserId: legacySubscription.userId,
      sourceId: buildSubscriptionSourceId({
        source: "app_store",
        details: legacySubscription.data,
        productId,
        verificationData,
      }),
      source: "app_store",
    });
  }

  return {
    userId,
    sourceId: buildSubscriptionSourceId({
      source: "app_store",
      details: legacySubscription?.data || details,
      productId,
      verificationData,
    }),
    existingData: legacySubscription?.data || null,
  };
}

async function resolveGoogleSourceReference({
  adminInstance,
  userId,
  details,
  productId,
  verificationData,
  functionsInstance,
}) {
  const existingSource = await findSubscriptionSourceByGoogleTokens(adminInstance, {
    purchaseToken: details?.purchaseToken || verificationData,
    linkedPurchaseToken: details?.linkedPurchaseToken,
    functionsInstance,
  });

  if (existingSource) {
    if (existingSource.userId !== userId) {
      throw buildOwnershipConflictError({
        userId,
        ownerUserId: existingSource.userId,
        sourceId: existingSource.sourceId,
        source: "google_play",
      });
    }

    return {
      userId,
      sourceId: existingSource.sourceId,
      existingData: existingSource.data,
    };
  }

  const legacySubscription = await findSubscriptionByGoogleTokens(adminInstance, {
    purchaseToken: details?.purchaseToken || verificationData,
    linkedPurchaseToken: details?.linkedPurchaseToken,
    functionsInstance,
  });

  if (legacySubscription && legacySubscription.userId !== userId) {
    throw buildOwnershipConflictError({
      userId,
      ownerUserId: legacySubscription.userId,
      sourceId: buildSubscriptionSourceId({
        source: "google_play",
        details: legacySubscription.data,
        productId,
        verificationData,
      }),
      source: "google_play",
    });
  }

  return {
    userId,
    sourceId: buildSubscriptionSourceId({
      source: "google_play",
      details: legacySubscription?.data || details,
      productId,
      verificationData,
    }),
    existingData: legacySubscription?.data || null,
  };
}

async function resolveSourceReferenceForUser({
  adminInstance,
  userId,
  source,
  details,
  productId,
  verificationData,
  functionsInstance,
}) {
  if (source === "app_store") {
    return resolveAppleSourceReference({
      adminInstance,
      userId,
      details,
      productId,
      verificationData,
      functionsInstance,
    });
  }

  if (source === "google_play") {
    return resolveGoogleSourceReference({
      adminInstance,
      userId,
      details,
      productId,
      verificationData,
      functionsInstance,
    });
  }

  return {
    userId,
    sourceId: buildSubscriptionSourceId({ source, details, productId, verificationData }),
    existingData: null,
  };
}

async function persistSubscriptionSourceAndAggregate({
  adminInstance,
  userId,
  sourceId,
  data,
  functionsInstance,
}) {
  await upsertSubscriptionSource(adminInstance, userId, sourceId, data, functionsInstance);
  return recomputeSubscriptionAggregate(adminInstance, userId, functionsInstance);
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
    const source = normalizePurchaseSource(data?.source);
    const productId = typeof data?.productId === "string" ? data.productId.trim() : "";
    const verificationData = typeof data?.verificationData === "string" ? data.verificationData.trim() : "";

    logInfo(functionsInstance, "[easySubs][verifyPurchase] incoming request", {
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
    logInfo(functionsInstance, "[easySubs][verifyPurchase] authenticated", { requestId, userId });

    try {
      if (!VALID_PURCHASE_SOURCES.has(source)) {
        throw new functionsInstance.https.HttpsError("invalid-argument", "Invalid source provided.");
      }

      if (!productId) {
        throw new functionsInstance.https.HttpsError("invalid-argument", "Missing productId.");
      }

      if (!verificationData) {
        throw new functionsInstance.https.HttpsError("invalid-argument", "Missing verificationData.");
      }

      let verification;
      if (source === "app_store") {
        verification = await verifyApplePurchase({ verificationData, productId, functionsInstance });
      } else if (source === "google_play") {
        verification = await verifyGooglePurchase({ verificationData, productId, functionsInstance });
      } else {
        throw new functionsInstance.https.HttpsError("invalid-argument", "Invalid source provided.");
      }

      const resolvedSource = await resolveSourceReferenceForUser({
        adminInstance,
        userId,
        source,
        details: verification.details || {},
        productId,
        verificationData,
        functionsInstance,
      });

      const persistedState = await persistSubscriptionSourceAndAggregate({
        adminInstance,
        userId,
        sourceId: resolvedSource.sourceId,
        data: {
          planId: productId,
          platform: source,
          ...(resolvedSource.existingData || {}),
          ...(verification.details || {}),
        },
        functionsInstance,
      });

      if (verification.isValid) {
        logInfo(functionsInstance, "[easySubs][verifyPurchase] success", {
          requestId,
          userId,
          planId: productId,
          sourceId: resolvedSource.sourceId,
          aggregate: persistedState.aggregate,
        });

        return {
          success: true,
          message: "Purchase verified successfully.",
          details: persistedState.aggregate || {},
        };
      } else {
        logWarn(functionsInstance, "[easySubs][verifyPurchase] remote validation failed", {
          requestId,
          userId,
          source,
          productId,
          details: verification.details || null,
        });
        return {
          success: false,
          message: `Receipt validation failed remotely. details=${JSON.stringify(persistedState.aggregate || {})}`,
          details: persistedState.aggregate || {},
        };
      }

    } catch (error) {
      if (error?.code === "purchase-owner-conflict") {
        throw new functionsInstance.https.HttpsError("failed-precondition", error.message);
      }

      if (error instanceof functionsInstance.https.HttpsError) {
        throw error;
      }

      logError(functionsInstance, "[easySubs][verifyPurchase] unhandled error", {
        requestId,
        message: error?.message || String(error),
        stack: error?.stack || null,
        code: error?.code || null,
      });
      throw new functionsInstance.https.HttpsError("internal", "An error occurred during verification.");
    }
  });

  const refreshPurchaseStatus = functionsInstance.https.onCall(async (data, context) => {
    const requestId = `${Date.now()}-${Math.random().toString(36).slice(2, 8)}`;
    const source = normalizePurchaseSource(data?.source);
    const productId = typeof data?.productId === "string" ? data.productId.trim() : "";
    const verificationData = typeof data?.verificationData === "string" ? data.verificationData.trim() : "";

    logInfo(functionsInstance, "[easySubs][refreshPurchaseStatus] incoming request", {
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
        "The function must be called while authenticated.",
      );
    }

    const userId = context.auth.uid;

    try {
      if (!VALID_PURCHASE_SOURCES.has(source)) {
        throw new functionsInstance.https.HttpsError("invalid-argument", "Invalid source provided.");
      }

      if (!productId) {
        throw new functionsInstance.https.HttpsError("invalid-argument", "Missing productId.");
      }

      let verification;
      if (source === "google_play") {
        verification = await refreshGooglePurchaseStatus({
          adminInstance,
          userId,
          productId,
          verificationData,
          functionsInstance,
        });
      } else {
        if (!verificationData) {
          throw new functionsInstance.https.HttpsError(
            "invalid-argument",
            "Missing verificationData for App Store refresh.",
          );
        }

        verification = await verifyApplePurchase({
          verificationData,
          productId,
          functionsInstance,
        });
      }

      const resolvedSource = await resolveSourceReferenceForUser({
        adminInstance,
        userId,
        source,
        details: verification.details || {},
        productId,
        verificationData,
        functionsInstance,
      });

      const persistedState = await persistSubscriptionSourceAndAggregate({
        adminInstance,
        userId,
        sourceId: resolvedSource.sourceId,
        data: {
          planId: productId,
          platform: source,
          ...(resolvedSource.existingData || {}),
          ...(verification.details || {}),
        },
        functionsInstance,
      });

      if (verification.isValid) {
        logInfo(functionsInstance, "[easySubs][refreshPurchaseStatus] success", {
          requestId,
          userId,
          productId,
          sourceId: resolvedSource.sourceId,
          details: persistedState.aggregate || null,
        });
        return {
          success: true,
          message: "Purchase status refreshed successfully.",
          details: persistedState.aggregate || {},
        };
      }

      logWarn(functionsInstance, "[easySubs][refreshPurchaseStatus] non-entitled status", {
        requestId,
        userId,
        source,
        productId,
        details: persistedState.aggregate || null,
      });
      return {
        success: false,
        message: `Purchase status refresh completed without entitlement. details=${JSON.stringify(persistedState.aggregate || {})}`,
        details: persistedState.aggregate || {},
      };
    } catch (error) {
      if (error?.code === "purchase-owner-conflict") {
        throw new functionsInstance.https.HttpsError("failed-precondition", error.message);
      }

      if (error instanceof functionsInstance.https.HttpsError) {
        throw error;
      }

      logError(functionsInstance, "[easySubs][refreshPurchaseStatus] unhandled error", {
        requestId,
        userId,
        message: error?.message || String(error),
        stack: error?.stack || null,
        code: error?.code || null,
      });
      throw new functionsInstance.https.HttpsError("internal", "An error occurred during purchase refresh.");
    }
  });

  const appleWebhook = functionsInstance.https.onRequest(async (req, res) => {
    const requestId = `${Date.now()}-${Math.random().toString(36).slice(2, 8)}`;
    try {
      logInfo(functionsInstance, "[easySubs][appleWebhook] incoming", {
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
        logWarn(functionsInstance, "[easySubs][appleWebhook] unexpected method", { requestId, method: req.method });
      }

      const signedPayload = req.body?.signedPayload;
      logInfo(functionsInstance, "[easySubs][appleWebhook] signedPayload metadata", {
        requestId,
        hasSignedPayload: Boolean(signedPayload),
        signedPayloadLength: signedPayload ? String(signedPayload).length : 0,
        signedPayloadPrefix: signedPayload ? String(signedPayload).slice(0, 20) : null,
      });

      if (!signedPayload) {
        logWarn(functionsInstance, "[easySubs][appleWebhook] missing signedPayload", { requestId });
        res.status(400).send("Missing signedPayload");
        return;
      }

      const decodedPayload = safeJwtDecode(signedPayload);
      if (!decodedPayload) {
        logWarn(functionsInstance, "[easySubs][appleWebhook] invalid signedPayload", { requestId });
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

      logInfo(functionsInstance, "[easySubs][appleWebhook] parsed", {
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
        logWarn(functionsInstance, "[easySubs][appleWebhook] no originalTransactionId, skipping upsert", { requestId });
        res.status(200).send("OK");
        return;
      }

      logInfo(functionsInstance, "[easySubs][appleWebhook] finding subscription by originalTransactionId", {
        requestId,
        originalTransactionId,
      });
      const sourceMatch = await findSubscriptionSourceByAppleIdentifiers(
        adminInstance,
        {
          originalTransactionId,
          transactionId: transactionInfo.transactionId || null,
          functionsInstance,
        },
      );
      const sub = sourceMatch || await findSubscriptionByField(
        adminInstance,
        "originalTransactionId",
        originalTransactionId,
        functionsInstance,
      );

      if (!sub) {
        logWarn(functionsInstance, "[easySubs][appleWebhook] subscription not found for originalTransactionId", {
          requestId,
          originalTransactionId,
        });
        res.status(200).send("OK");
        return;
      }

      const expiryDateMs = transactionInfo.expiresDate
        ? new Date(transactionInfo.expiresDate).getTime()
        : toMillis(transactionInfo.expiresDateMs);

      const ownerUserId = sub.userId;
      const sourceId = sourceMatch?.sourceId || buildSubscriptionSourceId({
        source: "app_store",
        details: sourceMatch?.data || sub.data || {
          originalTransactionId,
          transactionId: transactionInfo.transactionId || null,
        },
        productId: sub.data?.planId || null,
        verificationData: signedTransactionInfo || originalTransactionId,
      });

      await persistSubscriptionSourceAndAggregate({
        adminInstance,
        userId: ownerUserId,
        sourceId,
        data: {
          ...(sourceMatch?.data || {}),
          platform: "app_store",
          planId: sub.data?.planId || null,
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
        },
        functionsInstance,
      });

      logInfo(functionsInstance, "[easySubs][appleWebhook] updated subscription", {
        requestId,
        userId: ownerUserId,
        sourceId,
        status,
        originalTransactionId,
        transactionId: transactionInfo.transactionId || null,
        expiryDateMs: expiryDateMs || null,
      });

      logInfo(functionsInstance, "[easySubs][appleWebhook] responding 200", { requestId });
      res.status(200).send("OK");
    } catch (error) {
      logError(functionsInstance, "[easySubs][appleWebhook] unhandled error", {
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

        logInfo(functionsInstance, "[easySubs][googlePubSubHandler] incoming", {
          packageName: raw.packageName,
          notificationType,
          subscriptionId,
          hasPurchaseToken: Boolean(purchaseToken),
        });

        if (!purchaseToken) {
          logWarn(functionsInstance, "[easySubs][googlePubSubHandler] missing purchaseToken, skipping");
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

        const payload = await fetchGoogleSubscription({
          verificationData: purchaseToken,
          packageName,
          productId: subscriptionId || null,
          functionsInstance,
          logContext: {
            verificationMode: "rtdn",
            notificationType,
          },
        });

        const lineItems = Array.isArray(payload.lineItems) ? payload.lineItems : [];
        const line = (subscriptionId
          ? lineItems.find((item) => item?.productId === subscriptionId)
          : null) || lineItems[0] || {};
        const status = mapGoogleSubscriptionState(payload.subscriptionState);
        const linkedPurchaseToken = payload.linkedPurchaseToken || null;

        const sourceMatch = await findSubscriptionSourceByGoogleTokens(adminInstance, {
          purchaseToken,
          linkedPurchaseToken,
          functionsInstance,
        });
        const sub = sourceMatch || await findSubscriptionByGoogleTokens(adminInstance, {
          purchaseToken,
          linkedPurchaseToken,
          functionsInstance,
        });

        if (!sub) {
          logWarn(functionsInstance, "[easySubs][googlePubSubHandler] subscription not found for purchase token chain", {
            purchaseToken,
            linkedPurchaseToken,
            subscriptionId,
          });
          return;
        }

        const ownerUserId = sub.userId;
        const sourceId = sourceMatch?.sourceId || buildSubscriptionSourceId({
          source: "google_play",
          details: sourceMatch?.data || sub.data || {
            purchaseToken,
            linkedPurchaseToken,
          },
          productId: subscriptionId || sub.data?.planId || null,
          verificationData: purchaseToken,
        });

        await persistSubscriptionSourceAndAggregate({
          adminInstance,
          userId: ownerUserId,
          sourceId,
          data: {
            ...(sourceMatch?.data || {}),
            planId: subscriptionId || sub.data?.planId || null,
            platform: "google_play",
            status,
            reason: null,
            appleLookupDeferred: null,
            appleLookupErrorCode: null,
            purchaseToken,
            linkedPurchaseToken,
            latestOrderId: line.latestSuccessfulOrderId || null,
            expiryDateMs: line.expiryTime ? new Date(line.expiryTime).getTime() : null,
            rawSubscriptionState: payload.subscriptionState || null,
            rtdnNotificationType: notificationType,
            acknowledged:
              payload.acknowledgementState === "ACKNOWLEDGEMENT_STATE_ACKNOWLEDGED",
            acknowledgementRequired:
              isEntitledStatus(status) &&
              payload.acknowledgementState !== "ACKNOWLEDGEMENT_STATE_ACKNOWLEDGED",
          },
          functionsInstance,
        });

        logInfo(functionsInstance, "[easySubs][googlePubSubHandler] updated subscription", {
          userId: ownerUserId,
          sourceId,
          status,
          notificationType,
        });
      } catch (error) {
          logError(functionsInstance, "[easySubs][googlePubSubHandler] unhandled error", {
            message: error?.message || String(error),
            stack: error?.stack || null,
          });
      }
  });

  return {
    verifyPurchase,
    refreshPurchaseStatus,
    appleWebhook,
    googlePubSubHandler
  };
}

module.exports = { createEasySubsFunctions };
