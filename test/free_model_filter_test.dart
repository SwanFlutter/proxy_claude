import 'package:flutter_test/flutter_test.dart';
import 'package:proxy_claude/core/free_model_filter.dart';
import 'package:proxy_claude/models/model_info.dart';
import 'package:proxy_claude/models/provider_config.dart';
import 'package:proxy_claude/services/upstream_client.dart';

void main() {
  group('FreeModelFilter.isFree', () {
    test('OpenRouter ":free" suffix is free', () {
      expect(
        FreeModelFilter.isFree(modelId: 'deepseek/deepseek-r1:free'),
        isTrue,
      );
    });

    test('id with standalone "free" token is free', () {
      expect(FreeModelFilter.isFree(modelId: 'llama-3.1-free-8b'), isTrue);
      expect(FreeModelFilter.isFree(modelId: 'some/model_free'), isTrue);
    });

    test('free-tier substring is free', () {
      expect(FreeModelFilter.isFree(modelId: 'gpt-free-tier-trial'), isTrue);
    });

    test('paid ids are not free', () {
      expect(FreeModelFilter.isFree(modelId: 'openai/gpt-4o'), isFalse);
      expect(FreeModelFilter.isFree(modelId: 'anthropic/claude-3.5-sonnet'), isFalse);
      // "freedom" must NOT trigger the standalone-free word match
      expect(FreeModelFilter.isFree(modelId: 'model/freedom-x'), isFalse);
    });

    test('zero pricing metadata means free', () {
      expect(
        FreeModelFilter.isFree(
            modelId: 'vendor/model', promptPrice: 0, completionPrice: 0),
        isTrue,
      );
    });

    test('non-zero pricing means paid', () {
      expect(
        FreeModelFilter.isFree(
            modelId: 'vendor/model',
            promptPrice: 0.0000015,
            completionPrice: 0.000002),
        isFalse,
      );
    });

    test('provider-level free tier flag overrides everything', () {
      expect(
        FreeModelFilter.isFree(
            modelId: 'gemini-2.0-flash', assumeProviderFree: true),
        isTrue,
      );
      expect(FreeModelFilter.isFree(modelId: 'gemini-2.0-flash'), isFalse);
    });

    test('uppercase ids normalized', () {
      expect(FreeModelFilter.isFree(modelId: 'DeepSeek/DeepSeek-R1:FREE'), isTrue);
    });
  });

  group('UpstreamClient.parseModels', () {
    test('parses OpenAI-style payload with OpenRouter pricing', () {
      final p = ProviderConfig.defaultFor(ProviderPreset.openRouter,
          id: 'openrouter');
      final models = UpstreamClient.parseModels(p, {
        'data': [
          {
            'id': 'deepseek/deepseek-r1:free',
            'name': 'DeepSeek R1 (free)',
            'pricing': {'prompt': '0', 'completion': '0'},
            'context_length': 163840,
            'owned_by': 'deepseek',
          },
          {
            'id': 'openai/gpt-4o',
            'name': 'GPT-4o',
            'pricing': {'prompt': '0.0000025', 'completion': '0.00001'},
            'context_length': 128000,
          },
        ],
      });

      expect(models, hasLength(2));
      expect(models.first.id, 'deepseek/deepseek-r1:free');
      expect(models.first.isFree, isTrue);
      expect(models.first.contextLength, 163840);
      expect(models.first.displayName, 'DeepSeek R1 (free)');
      expect(models.last.isFree, isFalse,
          reason: 'paid pricing must not be marked free');
    });

    test('parses Gemini-native payload and strips models/ prefix', () {
      final p = ProviderConfig.defaultFor(ProviderPreset.googleGemini,
          id: 'gemini');
      final models = UpstreamClient.parseModels(p, {
        'models': [
          {
            'name': 'models/gemini-2.0-flash',
            'input_token_limit': 1048576,
          },
        ],
      });

      expect(models, hasLength(1));
      expect(models.first.id, 'gemini-2.0-flash');
      expect(models.first.isFree, isTrue,
          reason: 'Gemini preset assumes free tier');
      expect(models.first.contextLength, 1048576);
    });
  });

  test('ModelInfo JSON round-trip', () {
    final m = ModelInfo(
      id: 'a/b:free',
      providerId: 'openrouter',
      providerName: 'OpenRouter',
      isFree: true,
      contextLength: 8000,
      lastSeen: DateTime(2026, 1, 1),
    );
    final restored = ModelInfo.fromJson(m.toJson());
    expect(restored.id, m.id);
    expect(restored.providerId, m.providerId);
    expect(restored.isFree, m.isFree);
    expect(restored.contextLength, m.contextLength);
    expect(restored.key, m.key);
  });
}
