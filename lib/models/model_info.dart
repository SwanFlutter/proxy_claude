/// A single model tracked in the local routing cache.
///
/// [id] is the *upstream* model identifier used in API requests
/// (e.g. `deepseek/deepseek-r1:free` or `gemini-2.0-flash`).
class ModelInfo {
  final String id;
  final String providerId;
  final String providerName;
  final String? displayName;
  final double? promptPrice;
  final double? completionPrice;
  final int? contextLength;
  final bool isFree;
  final String? ownedBy;

  /// True when the model was declared by hand (provider without a `/models`
  /// endpoint, or a curated list) instead of fetched from the provider.
  final bool manuallyAdded;
  final DateTime lastSeen;

  const ModelInfo({
    required this.id,
    required this.providerId,
    required this.providerName,
    this.displayName,
    this.promptPrice,
    this.completionPrice,
    this.contextLength,
    required this.isFree,
    this.ownedBy,
    this.manuallyAdded = false,
    required this.lastSeen,
  });

  /// Stable unique key: `providerId|modelId`.
  String get key => '$providerId|$id';

  /// Pricing metadata explicitly says the model costs money. Models without any
  /// pricing metadata (manual entries, private gateways such as proxy-style
  /// providers) are **not** considered paid — they stay routable and visible.
  bool get isKnownPaid =>
      !isFree && ((promptPrice ?? 0) > 0 || (completionPrice ?? 0) > 0);

  /// Baseline for the "free only" views (Models page, `/v1/models`).
  ///
  /// Free-flagged models pass. Manually declared models always pass — the user
  /// typed them on purpose. Callers additionally pass **every model of a custom
  /// provider** (their own gateway may be paid, e.g. a daily-credit key), which
  /// only the caller can know — see `ProxyServer._models` and the Models page.
  ///
  /// Missing pricing metadata is never guessed to be free: OpenRouter simply
  /// omits pricing for most of its paid catalogue.
  bool get visibleInFreeView => isFree || manuallyAdded;

  Map<String, dynamic> toJson() => {
        'id': id,
        'providerId': providerId,
        'providerName': providerName,
        'displayName': displayName,
        'promptPrice': promptPrice,
        'completionPrice': completionPrice,
        'contextLength': contextLength,
        'isFree': isFree,
        'ownedBy': ownedBy,
        'manuallyAdded': manuallyAdded,
        'lastSeen': lastSeen.toIso8601String(),
      };

  factory ModelInfo.fromJson(Map<String, dynamic> json) => ModelInfo(
        id: json['id'] as String,
        providerId: json['providerId'] as String,
        providerName: (json['providerName'] ?? '') as String,
        displayName: json['displayName'] as String?,
        promptPrice: (json['promptPrice'] as num?)?.toDouble(),
        completionPrice: (json['completionPrice'] as num?)?.toDouble(),
        contextLength: (json['contextLength'] as num?)?.toInt(),
        isFree: (json['isFree'] ?? false) as bool,
        ownedBy: json['ownedBy'] as String?,
        manuallyAdded: (json['manuallyAdded'] ?? false) as bool,
        lastSeen:
            DateTime.tryParse((json['lastSeen'] ?? '') as String) ??
                DateTime.now(),
      );
}
