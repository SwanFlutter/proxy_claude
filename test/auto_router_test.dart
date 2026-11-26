import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:proxy_claude/core/model_router.dart';
import 'package:proxy_claude/models/model_info.dart';
import 'package:proxy_claude/models/provider_config.dart';
import 'package:proxy_claude/services/chat_proxy_core.dart';
import 'package:proxy_claude/services/log_service.dart';
import 'package:proxy_claude/services/model_registry.dart';
import 'package:proxy_claude/services/upstream_client.dart';

ModelInfo _m(
  String id,
  String pid, {
  bool free = false,
  int? ctx,
  double? price,
  bool manual = false,
}) =>
    ModelInfo(
      id: id,
      providerId: pid,
      providerName: pid,
      isFree: free,
      contextLength: ctx,
      promptPrice: price,
      completionPrice: price,
      manuallyAdded: manual,
      lastSeen: DateTime.now(),
    );

/// coarena behaves like the user's own gateway (custom preset → paid models are
/// fair game), everything else like a public catalogue (free models only).
ProviderConfig _p(String id) => ProviderConfig(
      id: id,
      name: id.toUpperCase(),
      preset: id == 'coarena' ? ProviderPreset.custom : ProviderPreset.openRouter,
      baseUrl: 'https://$id.invalid/v1',
      modelsPath: '/models',
      chatPath: '/chat/completions',
      enabled: true,
      assumeAllFree: false,
      apiKey: 'key-$id',
    );

/// A prompt that has to classify as `complex`: long, several code blocks,
/// engineering keywords.
final _complexPrompt = '''
Please refactor this module and implement the missing error handling, then
review the architecture and write tests for the failing cases.

```dart
${List.filled(120, 'final value = compute(index) + 1;').join('\n')}
```

```yaml
ci: true
```

```sh
flutter test
```
''';

/// One flagship, one mid-range and one small model per provider, plus a
/// known-paid flagship that must never outrank the usable ones.
final _pool = <ModelInfo>[
  // A curated gateway provider: hand-declared, no pricing metadata.
  _m('gpt-6-max', 'coarena', ctx: 1050000, manual: true),
  _m('gpt-6-flash', 'coarena', ctx: 1050000, manual: true),
  _m('nova-lite', 'coarena', ctx: 128000, manual: true),
  _m('kimi-k3', 'coarena', ctx: 1000000, manual: true),
  _m('deepseek-v4-1-flash-1017', 'coarena', ctx: 1000000, manual: true),
  _m('gemma-4-27b-it:free', 'openrouter', free: true, ctx: 131072),
  _m('north-mini-code:free', 'openrouter', free: true, ctx: 32000),
  _m('gpt-6-max-paid', 'openrouter', ctx: 1000000, price: 0.01),
];

void main() {
  group('capability tiering', () {
    test('flagship names land in the strong tier', () {
      expect(ModelCapability.tier(_m('gpt-6-max', 'x', ctx: 1050000)),
          ModelTier.strong);
      expect(ModelCapability.tier(_m('gpt-6-2-astra', 'x', ctx: 1050000)),
          ModelTier.strong);
      expect(ModelCapability.tier(_m('kimi-k3-1-pro', 'x', ctx: 1000000)),
          ModelTier.strong);
      expect(ModelCapability.tier(_m('claude-sonnet-4-5', 'x')), ModelTier.strong);
    });

    test('small / fast variants land in the light tier', () {
      expect(ModelCapability.tier(_m('nova-lite', 'x', ctx: 300000)),
          ModelTier.light);
      expect(ModelCapability.tier(_m('ministral-3-3b', 'x', ctx: 128000)),
          ModelTier.light);
      expect(
          ModelCapability.tier(_m('north-mini-code:free', 'x', free: true)),
          ModelTier.light);
      expect(
          ModelCapability.tier(
              _m('nvidia/nemotron-3.5-lightning:free', 'x', free: true)),
          ModelTier.light);
    });

    test('"flash" of a new generation stays below the flagship', () {
      final flagship = ModelCapability.score(_m('gpt-6-max', 'x', ctx: 1050000));
      final flash = ModelCapability.score(_m('gpt-6-flash', 'x', ctx: 1050000));
      expect(flagship, greaterThan(flash));
      expect(ModelCapability.tier(_m('gpt-6-flash', 'x', ctx: 1050000)),
          isNot(ModelTier.strong));
    });

    test('cost class: free > trusted manual model > anything else', () {
      expect(ModelCapability.cost(_m('a:free', 'x', free: true)),
          ModelCost.free);
      expect(
          ModelCapability.cost(_m('gate-model', 'x', manual: true)),
          ModelCost.unknown);
      // No pricing metadata alone is NOT evidence of free.
      expect(ModelCapability.cost(_m('silent-catalogue-model', 'x')),
          ModelCost.paid);
      expect(
          ModelCapability.cost(_m('paid-model', 'x', price: 0.002)),
          ModelCost.paid);
    });
  });

  group('AutoChain ordering', () {
    test('strongest usable model first, known-paid only at the very end', () {
      final ordered = AutoChain.order(models: _pool, target: ModelTier.strong);
      expect(ModelCapability.tier(ordered.first), ModelTier.strong);
      expect(ModelCapability.cost(ordered.last), ModelCost.paid);
      expect(ordered.where((m) => m.id == 'gpt-6-max-paid').length, 1);
      // Nothing known-paid may precede a free / unknown model of the same tier.
      final paidIdx = ordered.indexWhere((m) => m.isKnownPaid);
      final freeIdx = ordered.indexWhere((m) => m.isFree);
      expect(freeIdx, lessThan(paidIdx));
    });

    test('target light starts small and escalates upwards on failure', () {
      final ordered = AutoChain.order(models: _pool, target: ModelTier.light);
      expect(ModelCapability.tier(ordered.first), ModelTier.light);
      final tiers = ordered.map((m) => ModelCapability.tier(m).rank).toList();
      // Never worse than the tier before it once we start climbing back up.
      expect(tiers.first, 0);
      expect(tiers.contains(ModelTier.strong.rank), isTrue);
    });

    test('known-paid candidates are capped behind the usable pool', () {
      final paid = [
        for (var i = 0; i < 20; i++) _m('gpt-6-max-v$i', 'x', price: 0.01),
      ];
      // A purely paid account still gets a chain — capped by maxCandidates.
      expect(AutoChain.order(models: paid, target: ModelTier.strong).length, 12);

      final mixed = [...paid, _m('free-one:free', 'y', free: true)];
      final ordered = AutoChain.order(models: mixed, target: ModelTier.strong);
      expect(ordered.first.id, 'free-one:free');
      expect(ordered.where((m) => m.isKnownPaid).length,
          lessThanOrEqualTo(AutoChain.maxPaidCandidates));
    });

    test('consented (custom provider) models ignore the paid cap', () {
      final mine = [
        for (var i = 0; i < 6; i++)
          _m('gpt-6-max-c$i', 'coarena', ctx: 1000000, price: 0.01),
      ];
      final consented = {for (final m in mine) m.key};
      final free = _m('tiny-small:free', 'openrouter', free: true);

      final mineFirst = AutoChain.order(
          models: [...mine, free],
          target: ModelTier.strong,
          consented: consented);
      expect(mineFirst.where((m) => m.providerId == 'coarena').length, 6,
          reason: 'the user paid for these — all of them compete');
      expect(ModelCapability.tier(mineFirst.first), ModelTier.strong);

      final strangers = AutoChain.order(
          models: [...mine, free], target: ModelTier.strong);
      expect(strangers.where((m) => m.isKnownPaid).length,
          AutoChain.maxPaidCandidates);
    });
  });

  group('task complexity', () {
    AutoPlan planOf(String text, {List<Map<String, dynamic>>? extra}) =>
        TaskRouter.assess({
          'model': 'auto',
          'messages': [
            ...?extra,
            {'role': 'user', 'content': text},
          ],
        });

    test('a greeting is trivial and starts on a light model', () {
      for (final greeting in ['hi', 'thanks!', 'OK 👍', 'سلام', 'مرسی', 'بله']) {
        final p = planOf(greeting);
        expect(p.complexity, TaskComplexity.trivial, reason: greeting);
        expect(p.targetTier, ModelTier.light, reason: greeting);
      }
    });

    test('a greeting stays light even with Claude Code baggage', () {
      final p = TaskRouter.assess({
        'model': 'auto',
        'max_tokens': 8192,
        'system': 'x' * 30000,
        'tools': [
          for (var i = 0; i < 15; i++) {'name': 'tool$i'}
        ],
        'messages': [
          {'role': 'system', 'content': 'huge agent prompt ' * 2000},
          {'role': 'user', 'content': 'hi'},
        ],
      });
      expect(p.complexity, TaskComplexity.trivial);
      expect(p.targetTier, ModelTier.light);
    });

    test('multi-file refactoring with code is complex', () {
      final p = planOf(_complexPrompt);
      expect(p.complexity, TaskComplexity.complex);
      expect(p.targetTier, ModelTier.strong);
    });

    test('a short question is not complex', () {
      final p = planOf('What does the shelf package do?');
      expect(p.targetTier.index, lessThan(ModelTier.strong.index));
    });
  });

  group('auto aliases', () {
    test('the virtual model is recognised in every spelling', () {
      for (final name in [
        'auto',
        'AUTO',
        'auto:strong',
        'auto:fast',
        'proxy-auto',
        'llm-hub-auto',
        'smart',
        'auto[1m]',
        'coarena/auto',
        'openrouter/auto:fast',
      ]) {
        expect(AutoModel.matches(name), isTrue, reason: name);
      }
    });

    test('real model names are not auto aliases', () {
      for (final name in ['', 'gpt-6-max', 'deepseek-r1:free', 'auto-coder']) {
        expect(AutoModel.matches(name), isFalse, reason: name);
      }
    });

    test('strategy variants pin the starting tier', () {
      expect(AutoModel.forcedTier('auto:strong'), ModelTier.strong);
      expect(AutoModel.forcedTier('coarena/auto:fast'), ModelTier.light);
      expect(AutoModel.forcedTier('auto'), isNull);
    });
  });

  group('buildChain — auto model', () {
    final providers = [_p('coarena'), _p('openrouter')];

    test('auto spans every enabled provider instead of one', () {
      final res = buildChain(
        models: _pool,
        providers: providers,
        requestedModel: 'auto',
        smartTaskRouting: false,
      );
      expect(res.auto, isNotNull);
      expect(res.chain.map((c) => c.provider.id).toSet(),
          containsAll(['coarena', 'openrouter']));
      expect(ModelCapability.tier(res.chain.first.model), ModelTier.strong);
    });

    test('simple requests start small, complex ones start big', () {
      final simple = buildChain(
        models: _pool,
        providers: providers,
        requestedModel: 'auto',
        requestBody: {
          'messages': [
            {'role': 'user', 'content': 'thanks!'}
          ]
        },
      );
      final complex = buildChain(
        models: _pool,
        providers: providers,
        requestedModel: 'auto',
        requestBody: {
          'messages': [
            {'role': 'user', 'content': _complexPrompt},
          ],
          'tools': [
            {'name': 'edit'}
          ],
        },
      );
      expect(simple.auto!.targetTier, ModelTier.light);
      expect(complex.auto!.targetTier, ModelTier.strong);
      expect(
        ModelCapability.tier(simple.chain.first.model).rank,
        lessThan(ModelCapability.tier(complex.chain.first.model).rank),
      );
    });

    test('auto:strong ignores the classifier', () {
      final res = buildChain(
        models: _pool,
        providers: providers,
        requestedModel: 'auto:strong',
        requestBody: {
          'messages': [
            {'role': 'user', 'content': 'hi'}
          ]
        },
      );
      expect(res.auto!.tierForced, isTrue);
      expect(ModelCapability.tier(res.chain.first.model), ModelTier.strong);
    });

    test('provider/auto stays inside that provider', () {
      final res = buildChain(
        models: _pool,
        providers: providers,
        requestedModel: 'openrouter/auto',
      );
      expect(res.chain, isNotEmpty);
      expect(res.chain.every((c) => c.provider.id == 'openrouter'), isTrue);
    });

    test('unknown model names still reach every provider', () {
      final res = buildChain(
        models: _pool,
        providers: providers,
        requestedModel: 'claude-sonnet-4-5',
      );
      expect(res.auto, isNotNull);
      expect(res.chain.length, greaterThan(2));
    });

    test('an explicitly requested real model keeps the classic chain', () {
      final res = buildChain(
        models: _pool,
        providers: providers,
        requestedModel: 'nova-lite',
      );
      expect(res.auto, isNull);
      expect(res.chain.first.model.id, 'nova-lite');
    });
  });

  group('ChatProxyCore with the virtual model', () {
    late ModelRegistry registry;
    late LogService logs;
    final providers = [_p('coarena'), _p('openrouter')];

    setUp(() {
      logs = LogService();
      registry = ModelRegistry(logs, cacheDir: Directory.systemTemp.path);
      registry.replaceProviderModels('coarena',
          _pool.where((m) => m.providerId == 'coarena').toList());
      registry.replaceProviderModels('openrouter',
          _pool.where((m) => m.providerId == 'openrouter').toList());
    });

    /// Only [answered] replies; every other model returns 429 (retryable).
    http.Client onlyAnswers(String answered, {List<String>? seen}) =>
        MockClient.streaming((req, body) async {
          final sent = jsonDecode(await body.bytesToString())
              as Map<String, dynamic>;
          final id = sent['model'] as String;
          seen?.add(id);
          if (id == answered) {
            return http.StreamedResponse(
              Stream.value(utf8.encode(jsonEncode({'id': 'ok', 'choices': []}))),
              200,
              headers: {'content-type': 'application/json'},
            );
          }
          return http.StreamedResponse(
            Stream.value(utf8.encode('{"error":"rate limited"}')),
            429,
          );
        });

    ChatProxyCore core(http.Client client) => ChatProxyCore(
          registry: registry,
          enabledProviders: () => providers,
          defaultModel: () => null,
          upstream: UpstreamClient(client),
          logs: logs,
        );

    test('routes a complex request onto a strong model and fails over', () async {
      final seen = <String>[];
      final out = await core(onlyAnswers('gemma-4-27b-it:free', seen: seen)).chat(
        {
          'model': 'auto',
          'stream': false,
          'messages': [
            {'role': 'user', 'content': _complexPrompt},
          ],
        },
        connectTimeout: const Duration(seconds: 5),
        bodyTimeout: const Duration(seconds: 5),
      );
      expect(out.statusCode, 200);
      expect(out.modelId, 'gemma-4-27b-it:free');
      expect(seen.length, greaterThan(1),
          reason: '429s must walk the auto chain instead of failing');
      expect(out.headers['x-proxy-auto-tier'], 'strong');
      expect(logs.entries.map((e) => e.message).join('\n'), contains('auto ·'));
    });

    test('a trivial request is served by a light model', () async {
      final out = await core(onlyAnswers('north-mini-code:free')).chat(
        {
          'model': 'auto',
          'stream': false,
          'messages': [
            {'role': 'user', 'content': 'سلام'}
          ],
        },
        connectTimeout: const Duration(seconds: 5),
        bodyTimeout: const Duration(seconds: 5),
      );
      expect(out.statusCode, 200);
      expect(out.headers['x-proxy-auto-tier'], 'light');
      expect(ModelCapability.isSmallVariant(
          registry.resolveAny(out.modelId!)!),
          isTrue);
    });

    test('smart routing off → strongest model serves even a greeting', () async {
      final seen = <String>[];
      final smartOff = ChatProxyCore(
        registry: registry,
        enabledProviders: () => providers,
        defaultModel: () => null,
        upstream: UpstreamClient(onlyAnswers('gpt-6-max', seen: seen)),
        logs: logs,
        smartTaskRouting: () => false,
      );
      final out = await smartOff.chat(
        {
          'model': 'auto',
          'stream': false,
          'messages': [
            {'role': 'user', 'content': 'hi'}
          ],
        },
        connectTimeout: const Duration(seconds: 5),
        bodyTimeout: const Duration(seconds: 5),
      );
      expect(out.statusCode, 200);
      expect(seen.first, 'gpt-6-max');
      expect(out.headers['x-proxy-auto-tier'], 'strong');
    });
  });

  group('provider credentials', () {
    test('a provider without any credential is reported as needing a key', () {
      final keyless = ProviderConfig(
        id: 'groq',
        name: 'Groq',
        preset: ProviderPreset.groq,
        baseUrl: 'https://api.groq.com/openai/v1',
        modelsPath: '/models',
        chatPath: '/chat/completions',
        enabled: true,
        assumeAllFree: true,
      );
      expect(keyless.needsApiKey, isTrue);
      expect(keyless.copyWith(apiKey: 'gsk_x').needsApiKey, isFalse);
      // Header-authenticated gateways are fine without an API key.
      expect(
          keyless
              .copyWith(extraHeaders: const {'X-Access-Token': 'abc'})
              .needsApiKey,
          isFalse);
    });
  });

  group('model visibility', () {
    test('free and manually declared models stay visible in the free view', () {
      // Curated gateway model (typed by hand, no pricing) — visible.
      expect(_m('typed-by-hand', 'x', manual: true).visibleInFreeView, isTrue);
      // Provider marked "all models are free tier" → its models are isFree.
      expect(_m('gpt-6-luna', 'coarena', free: true).visibleInFreeView, isTrue);
      // Catalogue model with no pricing metadata is NOT assumed free.
      expect(_m('silent-catalogue-model', 'x').visibleInFreeView, isFalse);
      expect(_m('a:free', 'x', free: true).visibleInFreeView, isTrue);
    });

    test('models with real pricing stay hidden', () {
      expect(_m('expensive', 'x', price: 0.02).visibleInFreeView, isFalse);
    });
  });
}
