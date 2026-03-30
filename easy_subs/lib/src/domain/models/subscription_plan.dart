class SubscriptionPlan {
  final String id;
  final String title;
  final String description;
  final String price;
  final double rawPrice;
  final String currencyCode;

  const SubscriptionPlan({
    required this.id,
    required this.title,
    required this.description,
    required this.price,
    required this.rawPrice,
    required this.currencyCode,
  });

  @override
  String toString() {
    return 'SubscriptionPlan(id: $id, title: $title, price: $price)';
  }
}
