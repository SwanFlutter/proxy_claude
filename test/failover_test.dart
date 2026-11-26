import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:proxy_claude/models/model_info.dart';
import 'package:proxy_claude/models/provider_config.dart';
import 'package:proxy_claude/services/chat_proxy_core.dart';
import 'package:proxy_claude/services/log_service.dart';
import 'package:proxy_claude/services/model_registry.dart';
import 'package:proxy_claude/services/upstream_client.dart';

ModelInfo _m(String id, String pid, String pname, {bool free = true}) =>
    ModelInfo(id: id, providerId: pid, providerName: pname, isFree: free,
        lastSeen: DateTime.now());

http.StreamedResponse _resp(int status, {String body = '', String ct = 'application/json'}) =>
    http.StreamedResponse(
      Stream.value(utf8.encode(body)),
      status,
      headers: {'content-type': ct},
    );

void main() {
  late ProviderConfig p1;
  late ProviderConfig p2;

  setUp(() {
    p1 = ProviderConfig(
      id: 'p1', name: 'P1', preset: ProviderPreset.custom,
      baseUrl: 'http://upstream1/v1', modelsPath: '/models',
      chatPath: '/chat/completions', enabled: true, assumeAllFree: false,
      apiKey: 'k1',
    );
    p2 = ProviderConfig(
      id: 'p2', name: 'P2', preset: ProviderPreset.custom,
      baseUrl: 'http://upstream2/v1', modelsPath: '/models',
      chatPath: '/chat/completions', enabled: true, assumeAllFree: false,
      apiKey: 'k2',
    );
  });

  group('buildFailoverChain', () {
    test('primary → preferred default → same-provider siblings → cross-provider', () {
      final models = [
        _m('m1', 'p1', 'P1'),
        _m('m2', 'p1', 'P1'),
        _m('m3', 'p2', 'P2'),
        _m('default-x', 'p2', 'P2', free: false),
      ];
      final chain = buildFailoverChain(
        models: models,
        providers: [p1, p2],
        requestedModel: 'm1',
        defaultModel: 'default-x',
      );

      // The configured default is a known-good preferred fallback, tried right
      // after the primary (before alphabetical siblings that may be deprecated).
      expect(chain.map((c) => c.model.id).toList(),
          ['m1', 'default-x', 'm2', 'm3']);
    });

    test('provider-prefixed routing (p2/m3) forces provider p2', () {
      final models = [
        _m('m1', 'p1', 'P1'),
        _m('m3', 'p2', 'P2'),
      ];
      final chain = buildFailoverChain(
          models: models, providers: [p1, p2], requestedModel: 'p2/m3');
      expect(chain.first.provider.id, 'p2');
      expect(chain.first.model.id, 'm3');
    });

    test('unknown model falls back to free models of each provider', () {
      final models = [
        _m('paid', 'p1', 'P1', free: false),
        _m('free1', 'p1', 'P1'),
        _m('free2', 'p2', 'P2'),
      ];
      final chain = buildFailoverChain(
          models: models, providers: [p1, p2], requestedModel: 'does-not-exist');
      expect(chain.map((c) => c.model.id), containsAll(['free1', 'free2']));
      expect(chain.first.model.isFree, isTrue);
    });

    test('caps the chain length', () {
      final models = [
        for (var i = 0; i < 10; i++) _m('m$i', 'p1', 'P1'),
        _m('x', 'p2', 'P2'),
      ];
      final chain = buildFailoverChain(
          models: models, providers: [p1, p2], requestedModel: 'm0');
      expect(chain.length, lessThanOrEqualTo(6));
    });
  });

  group('ChatProxyCore failover', () {
    late ModelRegistry registry;
    late LogService logs;
    late List<String> seenModels;
    late List<String> seenAuth;
    var m1Status = 500;
    var m2Status = 429;
    var m3Status = 200;

    ChatProxyCore makeCore({String? defaultModel, required http.Client client}) {
      return ChatProxyCore(
        registry: registry,
        enabledProviders: () => [p1, p2],
        defaultModel: () => defaultModel,
        upstream: UpstreamClient(client),
        logs: logs,
      );
    }

    setUp(() {
      logs = LogService();
      registry = ModelRegistry(logs, cacheDir: Directory.systemTemp.path);
      registry.replaceProviderModels(
          'p1', [_m('m1', 'p1', 'P1'), _m('m2', 'p1', 'P1')]);
      registry.replaceProviderModels('p2', [_m('m3', 'p2', 'P2')]);
      seenModels = [];
      seenAuth = [];
      m1Status = 500;
      m2Status = 429;
      m3Status = 200;
    });

    http.Client mockClient() {
      return MockClient.streaming((req, bodyStream) async {
        final body =
            jsonDecode(await bodyStream.bytesToString()) as Map<String, dynamic>;
        seenModels.add(body['model'] as String);
        seenAuth.add(req.headers['authorization'] ?? '');
        return switch (body['model']) {
          'm1' => _resp(m1Status, body: '{"error":"upstream1 down"}'),
          'm2' => _resp(m2Status, body: '{"error":"rate limited"}'),
          'm3' => _resp(m3Status,
              body: jsonEncode({'id': 'ok', 'model': 'm3', 'choices': []})),
          _ => _resp(404, body: '{"error":"unknown model"}'),
        };
      });
    }

    test('5xx → next sibling → cross-provider success; keys are injected', () async {
      final core = makeCore(client: mockClient());
      final out = await core.chat(
        {'model': 'm1', 'stream': false},
        connectTimeout: const Duration(seconds: 5),
        bodyTimeout: const Duration(seconds: 5),
      );

      expect(out.statusCode, 200);
      expect(out.modelId, 'm3');
      expect(out.providerId, 'p2');
      expect(out.attempts, 3);
      expect(seenModels, ['m1', 'm2', 'm3']);
      // The proxy must inject the *upstream provider* key on each attempt.
      expect(seenAuth[0], 'Bearer k1');
      expect(seenAuth[2], 'Bearer k2');
      expect(out.headers['x-proxy-provider'], 'p2');
    });

    test('429 is retryable and fails over', () async {
      m1Status = 500;
      final core = makeCore(client: mockClient());
      final out = await core.chat(
        {'model': 'm1', 'stream': false},
        connectTimeout: const Duration(seconds: 5),
        bodyTimeout: const Duration(seconds: 5),
      );
      expect(out.statusCode, 200);
      expect(seenModels, ['m1', 'm2', 'm3']);
    });

    test('400 is passed through without failover', () async {
      m1Status = 400;
      final core = makeCore(client: mockClient());
      final out = await core.chat(
        {'model': 'm1', 'stream': false},
        connectTimeout: const Duration(seconds: 5),
        bodyTimeout: const Duration(seconds: 5),
      );
      expect(out.statusCode, 400);
      expect(out.attempts, 1);
      expect(seenModels, ['m1'],
          reason: 'a malformed request must not be retried elsewhere');
    });

    test('all attempts failing → 502 with attempt log', () async {
      m1Status = 500;
      m2Status = 500;
      m3Status = 500;
      final core = makeCore(client: mockClient());
      final out = await core.chat(
        {'model': 'm1', 'stream': false},
        connectTimeout: const Duration(seconds: 5),
        bodyTimeout: const Duration(seconds: 5),
      );
      expect(out.statusCode, 502);
      expect(out.attempts, 3);
      expect(out.error, contains('failover'));
    });

    test('unknown model falls back to first free model', () async {
      final core = makeCore(client: mockClient());
      final out = await core.chat(
        {'model': 'nope', 'stream': false},
        connectTimeout: const Duration(seconds: 5),
        bodyTimeout: const Duration(seconds: 5),
      );
      expect(out.statusCode, 200);
      expect(seenModels.first, 'm1',
          reason: 'fallback should start with the first free model of p1');
    });

    test('default model is used as last resort when requested is unknown', () async {
      final models = [
        _m('m1', 'p1', 'P1'),
        _m('m3', 'p2', 'P2'),
      ];
      registry.replaceProviderModels('p1', [models[0]]);
      registry.replaceProviderModels('p2', [models[1]]);
      final core = makeCore(defaultModel: 'm3', client: mockClient());
      final out = await core.chat(
        {'model': 'does-not-exist', 'stream': false},
        connectTimeout: const Duration(seconds: 5),
        bodyTimeout: const Duration(seconds: 5),
      );
      expect(out.statusCode, 200);
      expect(out.modelId, 'm3');
    });

    test('SSE streaming is piped through without buffering', () async {
      m1Status = 200;
      final client = MockClient.streaming((req, bodyStream) async {
        final body =
            jsonDecode(await bodyStream.bytesToString()) as Map<String, dynamic>;
        seenModels.add(body['model'] as String);
        if (body['model'] == 'm1') {
          return http.StreamedResponse(
            Stream.value(utf8.encode('data: {"choices":[{"delta":{"content":"hi"}}]}\n\n')),
            200,
            headers: {'content-type': 'text/event-stream'},
          );
        }
        return _resp(404);
      });
      final core = makeCore(client: client);
      final out = await core.chat(
        {'model': 'm1', 'stream': true},
        connectTimeout: const Duration(seconds: 5),
        bodyTimeout: const Duration(seconds: 5),
      );

      expect(out.isStream, isTrue);
      expect(out.contentType, contains('text/event-stream'));
      final bytes = await out.stream!.toList();
      final text = utf8.decode(bytes.expand((b) => b).toList());
      expect(text, contains('data:'));
    });

    test('network errors fail over to next candidate', () async {
      final client = MockClient.streaming((req, bodyStream) async {
        final body =
            jsonDecode(await bodyStream.bytesToString()) as Map<String, dynamic>;
        seenModels.add(body['model'] as String);
        if (body['model'] == 'm1') {
          throw const SocketException('connection refused');
        }
        return _resp(200, body: jsonEncode({'id': 'ok', 'choices': []}));
      });
      final core = makeCore(client: client);
      final out = await core.chat(
        {'model': 'm1', 'stream': false},
        connectTimeout: const Duration(seconds: 5),
        bodyTimeout: const Duration(seconds: 5),
      );
      expect(out.statusCode, 200);
      expect(seenModels, ['m1', 'm2']);
    });

    test('no models available → 404 with hint', () async {
      final emptyRegistry = ModelRegistry(logs, cacheDir: Directory.systemTemp.path);
      final core = ChatProxyCore(
        registry: emptyRegistry,
        enabledProviders: () => [p1],
        defaultModel: () => null,
        upstream: UpstreamClient(mockClient()),
        logs: logs,
      );
      final out = await core.chat(
        {'model': 'm1', 'stream': false},
        connectTimeout: const Duration(seconds: 5),
        bodyTimeout: const Duration(seconds: 5),
      );
      expect(out.statusCode, 404);
      expect(out.error, contains('No models'));
    });
  });

  group('ModelRegistry sync diff', () {
    test('diffIds detects additions and deletions', () {
      final diff = ModelRegistry.diffIds({'a', 'b', 'c'}, {'b', 'c', 'd', 'e'});
      expect(diff.added, ['d', 'e']);
      expect(diff.removed, ['a']);
    });

    test('replaceProviderModels removes deleted models and logs them', () {
      final logs = LogService();
      final registry = ModelRegistry(logs, cacheDir: Directory.systemTemp.path);
      registry.replaceProviderModels(
          'p1', [_m('keep', 'p1', 'P1'), _m('gone', 'p1', 'P1')]);
      expect(registry.count, 2);

      registry.replaceProviderModels('p1', [_m('keep', 'p1', 'P1'), _m('new', 'p1', 'P1')]);

      expect(registry.resolveAny('gone'), isNull,
          reason: 'models deleted upstream must leave the cache');
      expect(registry.resolveAny('new'), isNotNull,
          reason: 'new models must enter the cache');
      expect(registry.resolveAny('keep'), isNotNull);

      final messages = logs.entries.map((e) => e.message).join('\n');
      expect(messages, contains('model(s) removed'));
      expect(messages, contains('+1 new model'));
    });
  });
}
