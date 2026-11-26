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
    required this.lastSeen,
  });

  /// Stable unique key: `providerId|modelId`.
  String get key => '$providerId|$id';

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
        lastSeen:
            DateTime.tryParse((json['lastSeen'] ?? '') as String) ??
                DateTime.now(),
      );
}
