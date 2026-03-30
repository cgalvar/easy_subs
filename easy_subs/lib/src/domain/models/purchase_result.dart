enum PurchaseStatus {
  success,
  pending,
  error,
  canceled,
  restored,
}

class PurchaseResult {
  final PurchaseStatus status;
  final String? purchaseId;
  final String? verificationToken;
  final String? errorMessage;
  final String productId;
  final String? originalTransactionId;

  const PurchaseResult({
    required this.status,
    required this.productId,
    this.purchaseId,
    this.verificationToken,
    this.errorMessage,
    this.originalTransactionId,
  });

  bool get isSuccess => status == PurchaseStatus.success;
  bool get isPending => status == PurchaseStatus.pending;
  bool get hasError => status == PurchaseStatus.error;
}
