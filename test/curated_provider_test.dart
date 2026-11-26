import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:proxy_claude/models/provider_config.dart';
import 'package:proxy_claude/services/log_service.dart';
import 'package:proxy_claude/services/model_registry.dart';
import 'package:proxy_claude/services/upstream_client.dart';

ProviderConfig _custom({
  bool manualModelsOnly = false,
  bool assumeAllFree = true,
  List<ManualModel> manual = const [],
}) =>
    ProviderConfig(
      id: 'coarena',
      name: 'coarena',
      preset: ProviderPreset.custom,
      baseUrl: 'https://coarena.invalid/v1',
      modelsPath: '/models',
      chatPath: '/chat/completions',
      enabled: true,
      assumeAllFree: assumeAllFree,
      manualModels: manual,
      manualModelsOnly: manualModelsOnly,
      apiKey: 'k',
    );

const _manual3 = [
  ManualModel(id: 'gpt-6-luna', name: 'GPT-6 Luna'),
  ManualModel(id: 'gemini-3-8-flash', name: 'Gemini 3.8 Flash'),
  ManualModel(id: 'deepseek-v4-1-flash-1017', name: 'DeepSeek V4.1 Flash'),
];

/// Client that answers `/models` with a full catalogue and counts the calls.
class _Catalogue {
  int calls = 0;

  http.Client get client => MockClient((req) async {
        if (req.url.path.endsWith('/models')) {
          calls++;
          return http.Response(
            jsonEncode({
              'data': [
                for (var i = 0; i < 20; i++) {'id': 'catalogue-model-$i'},
              ]
            }),
            200,
            headers: {'content-type': 'application/json'},
          );
        }
        return http.Response('{}', 200);
      });
}

void main() {
  LogService logs() => LogService();

  test('curated provider: /models is never called, only manual ids are kept',
      () async {
    final registry = ModelRegistry(logs(), cacheDir: Directory.systemTemp.path);
    final catalogue = _Catalogue();

    final report = await registry.syncAll(
      [_custom(manualModelsOnly: true, manual: _manual3)],
      upstream: UpstreamClient(catalogue.client),
      persist: false,
    );

    expect(catalogue.calls, 0,
        reason: 'a curated list must not touch the listing endpoint');
    expect(report.entries.single.ok, isTrue);
    expect(report.entries.single.modelCount, 3);
    expect(registry.count, 3);
    expect(registry.resolveAny('catalogue-model-0'), isNull);
    expect(registry.find('coarena', 'gpt-6-luna')?.displayName, 'GPT-6 Luna');
    expect(registry.find('coarena', 'gpt-6-luna')?.manuallyAdded, isTrue);
  });

  test('curated provider drops catalogue models cached from an earlier sync',
      () async {
    final registry = ModelRegistry(logs(), cacheDir: Directory.systemTemp.path);
    final catalogue = _Catalogue();
    final provider = _custom(manual: _manual3);

    await registry.syncAll([provider],
        upstream: UpstreamClient(catalogue.client), persist: false);
    expect(registry.count, 23, reason: '20 catalogue + 3 manual');

    final report = await registry.syncAll(
      [provider.copyWith(manualModelsOnly: true)],
      upstream: UpstreamClient(catalogue.client),
      persist: false,
    );

    expect(registry.count, 3);
    expect(report.entries.single.removed.length, 20);
    expect(report.entries.single.added, isEmpty);
    expect(registry.forProvider('coarena').map((m) => m.id),
        containsAll(_manual3.map((m) => m.id)));
  });

  test('curated sync is stable across repeated runs', () async {
    final registry = ModelRegistry(logs(), cacheDir: Directory.systemTemp.path);
    final catalogue = _Catalogue();
    final provider = _custom(manualModelsOnly: true, manual: _manual3);

    for (var i = 0; i < 3; i++) {
      final report = await registry.syncAll([provider],
          upstream: UpstreamClient(catalogue.client), persist: false);
      expect(report.entries.single.modelCount, 3, reason: 'run $i');
      if (i > 0) {
        // Nothing churns once the curated set is in place.
        expect(report.entries.single.added, isEmpty, reason: 'run $i');
        expect(report.entries.single.removed, isEmpty, reason: 'run $i');
      }
    }
    expect(catalogue.calls, 0);
    expect(registry.count, 3);
  });

  test('known provider registers its free models only', () async {
    final registry = ModelRegistry(logs(), cacheDir: Directory.systemTemp.path);
    final client = MockClient((req) async {
      if (req.url.path.endsWith('/models')) {
        return http.Response(
          jsonEncode({
            'data': [
              {'id': 'google/gemma-4-31b-it:free'},
              {'id': 'deepseek/deepseek-v3:free'},
              {'id': 'anthropic/claude-sonnet-4-5'},
              {'id': 'openai/gpt-6', 'pricing': {'prompt': '3', 'completion': '15'}},
            ]
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      }
      return http.Response('{}', 200);
    });
    final openrouter = ProviderConfig(
      id: 'openrouter',
      name: 'OpenRouter',
      preset: ProviderPreset.openRouter,
      baseUrl: 'https://openrouter.invalid/api/v1',
      modelsPath: '/models',
      chatPath: '/chat/completions',
      enabled: true,
      assumeAllFree: false,
      apiKey: 'k',
    );

    final report = await registry.syncAll([openrouter],
        upstream: UpstreamClient(client), persist: false);

    expect(report.entries.single.modelCount, 2,
        reason: 'only the two :free models may enter the pool');
    expect(registry.resolveAny('anthropic/claude-sonnet-4-5'), isNull);
    expect(registry.resolveAny('openai/gpt-6'), isNull);
    expect(registry.resolveAny('google/gemma-4-31b-it:free')?.isFree, isTrue);
  });

  test('the skipped paid models are reported in the sync log', () async {
    final log = LogService();
    final registry = ModelRegistry(log, cacheDir: Directory.systemTemp.path);
    final client = MockClient((req) async => http.Response(
          jsonEncode({
            'data': [
              {'id': 'a:free'},
              {'id': 'paid-1'},
              {'id': 'paid-2'},
            ]
          }),
          200,
          headers: {'content-type': 'application/json'},
        ));
    final known = ProviderConfig(
      id: 'known',
      name: 'Known',
      preset: ProviderPreset.openRouter,
      baseUrl: 'https://known.invalid/api/v1',
      modelsPath: '/models',
      chatPath: '/chat/completions',
      enabled: true,
      assumeAllFree: false,
      apiKey: 'k',
    );

    await registry.syncAll([known], upstream: UpstreamClient(client), persist: false);

    expect(log.entries.map((e) => e.message).join('\n'),
        contains('skipped 2 paid model(s)'));
  });

  test('custom provider keeps its paid models (daily-credit gateway)', () async {
    final registry = ModelRegistry(logs(), cacheDir: Directory.systemTemp.path);
    final client = MockClient((req) async {
      if (req.url.path.endsWith('/models')) {
        return http.Response(
          jsonEncode({
            'data': [
              {
                'id': 'gpt-6-2-astra',
                // Real coarena-style metadata: prices as strings.
                'pricing': {'prompt': '1.2e-6', 'completion': '3.6e-6'}
              },
            ]
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      }
      return http.Response('{}', 200);
    });

    final report = await registry.syncAll(
      [
        _custom(
          assumeAllFree: false,
          manual: const [ManualModel(id: 'gpt-6-luna', name: 'GPT-6 Luna')],
        )
      ],
      upstream: UpstreamClient(client),
      persist: false,
    );

    expect(report.entries.single.modelCount, 2);
    final astra = registry.resolveAny('gpt-6-2-astra');
    expect(astra, isNotNull, reason: 'a custom gateway may be paid');
    expect(astra!.isFree, isFalse);
    expect(astra.isKnownPaid, isTrue);
    // …and it is still served to clients and routable.
    expect(astra.manuallyAdded, isFalse);
    expect(registry.resolveAny('gpt-6-luna')?.manuallyAdded, isTrue);
  });

  test('non-curated provider still imports the whole catalogue', () async {
    final registry = ModelRegistry(logs(), cacheDir: Directory.systemTemp.path);
    final catalogue = _Catalogue();

    final report = await registry.syncAll(
      [_custom(manual: _manual3)],
      upstream: UpstreamClient(catalogue.client),
      persist: false,
    );

    expect(catalogue.calls, 1);
    expect(report.entries.single.modelCount, 23);
  });

  group('manualModelsOnly persistence', () {
    test('legacy records that carry a manual list load as curated', () {
      final legacy = ProviderConfig.fromJson({
        'id': 'coarena',
        'name': 'coarena',
        'preset': ProviderPreset.custom.index,
        'baseUrl': 'https://coarena.invalid/v1',
        'enabled': true,
        'assumeAllFree': false,
        'manualModels': [
          {'id': 'gpt-6-luna', 'name': 'GPT-6 Luna'}
        ],
      });
      expect(legacy.manualModelsOnly, isTrue);
    });

    test('records without manual models load as non-curated', () {
      final auto = ProviderConfig.fromJson({
        'id': 'openrouter',
        'name': 'OpenRouter',
        'preset': ProviderPreset.openRouter.index,
        'baseUrl': 'https://openrouter.ai/api/v1',
        'enabled': true,
        'assumeAllFree': false,
      });
      expect(auto.manualModelsOnly, isFalse);
    });

    test('the flag survives a json round-trip', () {
      final p = _custom(manualModelsOnly: true, manual: _manual3);
      final back = ProviderConfig.fromJson(p.toJson());
      expect(back.manualModelsOnly, isTrue);
      expect(back.manualModels.length, 3);
    });
  });
}
