import 'dart:math';

enum ProviderPreset {
  openRouter,
  groq,
  googleGemini,
  custom,
  openAI,
  anthropic,
  deepSeek,
  mistral,
  together,
  cerebras,
  xai,
  huggingface,
}

extension ProviderPresetX on ProviderPreset {
  String get label => switch (this) {
        ProviderPreset.openRouter => 'OpenRouter',
        ProviderPreset.groq => 'Groq',
        ProviderPreset.googleGemini => 'Google Gemini',
        ProviderPreset.custom => 'Custom Provider',
        ProviderPreset.openAI => 'OpenAI',
        ProviderPreset.anthropic => 'Anthropic',
        ProviderPreset.deepSeek => 'DeepSeek',
        ProviderPreset.mistral => 'Mistral',
        ProviderPreset.together => 'Together AI',
        ProviderPreset.cerebras => 'Cerebras',
        ProviderPreset.xai => 'xAI',
        ProviderPreset.huggingface => 'Hugging Face',
      };
}

/// A manually-declared model for providers that lack a `/models` endpoint
/// (or whose listing should be curated). Stored per provider config.
class ManualModel {
  final String id;
  final String name;

  const ManualModel({required this.id, this.name = ''});

  ManualModel copyWith({String? id, String? name}) =>
      ManualModel(id: id ?? this.id, name: name ?? this.name);

  Map<String, dynamic> toJson() => {'id': id, 'name': name};

  factory ManualModel.fromJson(Map<String, dynamic> json) => ManualModel(
        id: (json['id'] ?? '') as String,
        name: (json['name'] ?? '') as String,
      );
}

/// Configuration of one upstream LLM provider.
///
/// `apiKey` lives only in memory + secure storage — it is never serialized
/// into [toJson] (which is what gets persisted to SharedPreferences).
class ProviderConfig {
  final String id;
  final String name;
  final ProviderPreset preset;
  final String baseUrl;
  final String modelsPath;
  final String chatPath;
  final Map<String, String> extraHeaders;
  final bool enabled;
  final bool assumeAllFree;
  final List<ManualModel> manualModels;
  final String apiKey;

  const ProviderConfig({
    required this.id,
    required this.name,
    required this.preset,
    required this.baseUrl,
    required this.modelsPath,
    required this.chatPath,
    this.extraHeaders = const {},
    required this.enabled,
    required this.assumeAllFree,
    this.manualModels = const [],
    this.apiKey = '',
  });

  bool get isCustom => preset == ProviderPreset.custom;

  ProviderConfig copyWith({
    String? name,
    String? baseUrl,
    String? modelsPath,
    String? chatPath,
    Map<String, String>? extraHeaders,
    bool? enabled,
    bool? assumeAllFree,
    List<ManualModel>? manualModels,
    String? apiKey,
  }) =>
      ProviderConfig(
        id: id,
        name: name ?? this.name,
        preset: preset,
        baseUrl: baseUrl ?? this.baseUrl,
        modelsPath: modelsPath ?? this.modelsPath,
        chatPath: chatPath ?? this.chatPath,
        extraHeaders: extraHeaders ?? this.extraHeaders,
        enabled: enabled ?? this.enabled,
        assumeAllFree: assumeAllFree ?? this.assumeAllFree,
        manualModels: manualModels ?? this.manualModels,
        apiKey: apiKey ?? this.apiKey,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'preset': preset.index,
        'baseUrl': baseUrl,
        'modelsPath': modelsPath,
        'chatPath': chatPath,
        'extraHeaders': extraHeaders,
        'enabled': enabled,
        'assumeAllFree': assumeAllFree,
        'manualModels': manualModels.map((m) => m.toJson()).toList(),
      };

  factory ProviderConfig.fromJson(Map<String, dynamic> json) => ProviderConfig(
        id: json['id'] as String,
        name: (json['name'] ?? 'Provider') as String,
        preset: ProviderPreset
            .values[((json['preset'] as num?)?.toInt() ?? 3)
                .clamp(0, ProviderPreset.values.length - 1)],
        baseUrl: (json['baseUrl'] ?? '') as String,
        modelsPath: (json['modelsPath'] ?? '/models') as String,
        chatPath: (json['chatPath'] ?? '/chat/completions') as String,
        extraHeaders:
            (json['extraHeaders'] as Map?)?.cast<String, String>() ?? const {},
        enabled: (json['enabled'] ?? false) as bool,
        assumeAllFree: (json['assumeAllFree'] ?? false) as bool,
        manualModels: ((json['manualModels'] as List?) ?? const [])
            .whereType<Map>()
            .map((m) => ManualModel.fromJson(m.cast<String, dynamic>()))
            .toList(),
      );

  static ProviderConfig defaultFor(ProviderPreset preset, {String? id}) {
    // Stable ids for named presets so re-connecting a preset reuses its
    // stored instance; `custom` generates a fresh id (multiple instances).
    final stableId = switch (preset) {
      ProviderPreset.openRouter => 'openrouter',
      ProviderPreset.groq => 'groq',
      ProviderPreset.googleGemini => 'gemini',
      ProviderPreset.openAI => 'openai',
      ProviderPreset.anthropic => 'anthropic',
      ProviderPreset.deepSeek => 'deepseek',
      ProviderPreset.mistral => 'mistral',
      ProviderPreset.together => 'together',
      ProviderPreset.cerebras => 'cerebras',
      ProviderPreset.xai => 'xai',
      ProviderPreset.huggingface => 'huggingface',
      ProviderPreset.custom => null,
    };
    final endpoints = switch (preset) {
      ProviderPreset.openRouter => (
          baseUrl: 'https://openrouter.ai/api/v1',
          assumeAllFree: false,
          extraHeaders: {'X-Title': 'LLM Proxy Hub'},
        ),
      ProviderPreset.groq => (
          baseUrl: 'https://api.groq.com/openai/v1',
          assumeAllFree: true,
          extraHeaders: const <String, String>{},
        ),
      ProviderPreset.googleGemini => (
          // Gemini's OpenAI-compatible endpoint (Bearer auth, /models, /chat/completions).
          baseUrl: 'https://generativelanguage.googleapis.com/v1beta/openai',
          assumeAllFree: true,
          extraHeaders: const <String, String>{},
        ),
      ProviderPreset.openAI => (
          baseUrl: 'https://api.openai.com/v1',
          assumeAllFree: false,
          extraHeaders: const <String, String>{},
        ),
      ProviderPreset.anthropic => (
          baseUrl: 'https://api.anthropic.com/v1/openai',
          assumeAllFree: false,
          extraHeaders: const <String, String>{},
        ),
      ProviderPreset.deepSeek => (
          baseUrl: 'https://api.deepseek.com/v1',
          assumeAllFree: false,
          extraHeaders: const <String, String>{},
        ),
      ProviderPreset.mistral => (
          baseUrl: 'https://api.mistral.ai/v1',
          assumeAllFree: false,
          extraHeaders: const <String, String>{},
        ),
      ProviderPreset.together => (
          baseUrl: 'https://api.together.xyz/v1',
          assumeAllFree: false,
          extraHeaders: const <String, String>{},
        ),
      ProviderPreset.cerebras => (
          baseUrl: 'https://api.cerebras.ai/v1',
          assumeAllFree: false,
          extraHeaders: const <String, String>{},
        ),
      ProviderPreset.xai => (
          baseUrl: 'https://api.x.ai/v1',
          assumeAllFree: false,
          extraHeaders: const <String, String>{},
        ),
      ProviderPreset.huggingface => (
          baseUrl: 'https://router.huggingface.co/v1',
          assumeAllFree: false,
          extraHeaders: const <String, String>{},
        ),
      ProviderPreset.custom => (
          baseUrl: '',
          assumeAllFree: false,
          extraHeaders: const <String, String>{},
        ),
    };

    return ProviderConfig(
      id: id ?? stableId ?? _newCustomId(),
      name: preset.label,
      preset: preset,
      baseUrl: endpoints.baseUrl,
      modelsPath: '/models',
      chatPath: '/chat/completions',
      extraHeaders: endpoints.extraHeaders,
      enabled: false,
      assumeAllFree: endpoints.assumeAllFree,
    );
  }

  static String _newCustomId() =>
      'custom-${DateTime.now().millisecondsSinceEpoch.toRadixString(36)}-${Random().nextInt(9999)}';
}
