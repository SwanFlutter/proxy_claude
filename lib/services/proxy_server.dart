import 'dart:convert';
import 'dart:io';
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:shelf_router/shelf_router.dart';
import '../models/log_entry.dart';
import 'anthropic_gateway.dart';
import 'chat_proxy_core.dart';
import 'log_service.dart';
import 'model_registry.dart';
import 'settings_service.dart';

/// Embedded local REST proxy exposing an OpenAI-compatible API:
///
///   GET  /health
///   GET  /v1/models[?free=true]
///   POST /v1/chat/completions      (also /chat/completions)
///
/// Auth: `Authorization: Bearer <localKey>` or `X-API-Key: <localKey>`.
/// Requests are only served with valid credentials even when exposed
/// through a Cloudflare Tunnel.
class ProxyServer {
  ProxyServer({
    required this.logs,
    required this.core,
    required this.settings,
    required this.registry,
  });

  final LogService logs;
  final ChatProxyCore core;
  final SettingsService settings;
  final ModelRegistry registry;

  HttpServer? _server;

  bool get isRunning => _server != null;
  int? get boundPort => _server?.port;

  Future<void> start({required String host, required int port}) async {
    await stop();

    final router = Router()
      ..get('/', _info)
      ..get('/health', _health)
      ..get('/v1/models', _models)
      ..get('/models', _models)
      ..post('/v1/chat/completions', _chat)
      ..post('/chat/completions', _chat)
      // Anthropic Messages API — spoken by Claude Code (ANTHROPIC_BASE_URL).
      ..post('/v1/messages/count_tokens', _countTokens)
      ..post('/v1/messages', _messages)
      ..post('/messages', _messages);

    final handler = Pipeline()
        .addMiddleware(_cors)
        .addMiddleware(_auth)
        .addHandler(router.call);

    _server = await shelf_io.serve(handler, host, port, poweredByHeader: null);
    final shownHost = host == '0.0.0.0' ? '127.0.0.1' : host;
    logs.info(LogCategory.system,
        'Proxy listening on http://$shownHost:$port/v1 (auth: ${settings.appSettings.requireAuth ? 'on' : 'off'})');
  }

  Future<void> stop() async {
    final s = _server;
    _server = null;
    await s?.close(force: true);
  }

  // ── Middleware ────────────────────────────────────────────────────────────

  Middleware get _cors => (inner) => (req) async {
        if (req.method == 'OPTIONS') return _withCors(Response.ok(''));
        final r = await inner(req);
        return _withCors(r);
      };

  Response _withCors(Response r) => r.change(headers: {
        'access-control-allow-origin': '*',
        'access-control-allow-methods': 'GET, POST, OPTIONS',
        'access-control-allow-headers':
            'authorization, x-api-key, content-type',
        'access-control-max-age': '86400',
      });

  Middleware get _auth => (inner) => (req) async {
        // /health stays open so tunnel/monitoring probes work.
        if (req.url.path == 'health') return inner(req);
        final s = settings.appSettings;
        if (!s.requireAuth) return inner(req);

        final expected = settings.localApiKey;
        final authHeader = req.headers['authorization'];
        String? bearer;
        if (authHeader != null &&
            authHeader.length > 7 &&
            authHeader.toLowerCase().startsWith('bearer ')) {
          bearer = authHeader.substring(7).trim();
        }
        final apiKeyHeader = req.headers['x-api-key'];
        if ((bearer != null && bearer == expected) ||
            (apiKeyHeader != null && apiKeyHeader == expected)) {
          return inner(req);
        }
        logs.warn(LogCategory.request,
            'Unauthorized ${req.method} /${req.url.path} (no/invalid key)');
        return _jsonResponse(401, {
          'error': {
            'message':
                'Invalid or missing API key. Use Authorization: Bearer <key> or X-API-Key.',
            'type': 'proxy_auth_error',
          }
        });
      };

  // ── Handlers ──────────────────────────────────────────────────────────────

  Response _jsonResponse(int status, Object? payload,
          {Map<String, String> extra = const {}}) =>
      Response(status,
          body: jsonEncode(payload),
          headers: {'content-type': 'application/json; charset=utf-8', ...extra});

  Future<Response> _info(Request req) async => _jsonResponse(200, {
        'name': 'LLM Proxy Hub',
        'version': '1.0.0',
        'endpoints': ['/health', '/v1/models', '/v1/chat/completions'],
        'models': registry.count,
      });

  Future<Response> _health(Request req) async => _jsonResponse(200, {
        'status': 'ok',
        'models': registry.count,
        'time': DateTime.now().toIso8601String(),
      });

  Future<Response> _models(Request req) async {
    var models = registry.snapshot;
    final q = req.url.queryParameters;
    // Show only free models by default when the user enabled "free only",
    // so Claude Code's model discovery surfaces the usable free catalog
    // (e.g. Gemma 4) instead of hundreds of paid/deprecated entries.
    // Override with ?all=true to see everything, or ?free=true to force free.
    final wantAll = q['all'] == 'true' || q['all'] == '1';
    final wantFree = q['free'] == 'true' || q['free'] == '1';
    if (wantFree || (settings.appSettings.showFreeOnly && !wantAll)) {
      models = models.where((m) => m.isFree).toList();
    }
    final nowSec = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    return _jsonResponse(200, {
      'object': 'list',
      'data': [
        for (final m in models)
          {
            'id': m.id,
            'object': 'model',
            'created': nowSec,
            'owned_by': m.providerName,
            // Claude Code's gateway model discovery only accepts a model when
            // it maps to an Anthropic family tier. Tagging every served model
            // with a tier makes non-Claude models (Gemma, Nemotron, …) usable
            // and selectable in Claude Code instead of "no usable models".
            'anthropic_family_tier': _familyTier(m.id),
            'display_name': m.displayName ?? m.id,
            if (m.contextLength != null) 'max_input_tokens': m.contextLength,
            'llm_proxy': {
              'provider_id': m.providerId,
              'free': m.isFree,
              'context_length': m.contextLength,
            },
          }
      ],
    });
  }

  /// Maps an arbitrary upstream model id to an Anthropic family tier so Claude
  /// Code's discovery treats it as usable. Heuristic only — the tier groups
  /// models for Auto mode; explicit selection uses the real model id.
  String _familyTier(String id) {
    final x = id.toLowerCase();
    if (x.contains('ultra') || x.contains('super') || x.contains('550b') ||
        x.contains('opus') || x.contains('pro-max')) {
      return 'opus';
    }
    if (x.contains('nano') || x.contains('1.7b') || x.contains('particle') ||
        x.contains('flash') || x.contains('haiku') || x.contains('26b') ||
        x.contains('mini') || x.contains('lightning')) {
      return 'haiku';
    }
    return 'sonnet';
  }

  Future<Response> _chat(Request req) async {
    Map<String, dynamic> body;
    try {
      final raw = await req.readAsString();
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) {
        throw const FormatException('body must be a JSON object');
      }
      body = decoded;
    } catch (e) {
      return _jsonResponse(400, {
        'error': {'message': 'Invalid JSON body: $e', 'type': 'proxy_bad_request'}
      });
    }

    final s = settings.appSettings;
    final outcome = await core.chat(
      body,
      connectTimeout: Duration(seconds: s.upstreamTimeoutSeconds),
      bodyTimeout: Duration(seconds: s.upstreamTimeoutSeconds * 2),
    );

    final headers = {...outcome.headers};
    if (outcome.stream != null) {
      return Response(
        outcome.statusCode,
        body: outcome.stream,
        headers: {
          'content-type': outcome.contentType ?? 'text/event-stream',
          'cache-control': 'no-cache',
          ...headers,
        },
      );
    }
    final bytes = outcome.bytes ??
        utf8.encode(jsonEncode({
          'error': {'message': outcome.error ?? 'Unknown proxy error'}
        }));
    return Response(
      outcome.statusCode,
      body: bytes,
      headers: {
        'content-type': outcome.contentType ?? 'application/json; charset=utf-8',
        ...headers,
      },
    );
  }

  // ── Anthropic Messages API (Claude Code compatibility) ────────────────────

  Future<Response> _anthropicError(int status, List<int> bytes) async {
    // Re-wrap an OpenAI-style upstream error body into Anthropic's envelope.
    dynamic decoded;
    try {
      decoded = jsonDecode(utf8.decode(bytes));
    } catch (_) {}
    final upstreamMsg = decoded is Map
        ? ((decoded['error'] is Map
                ? (decoded['error'] as Map)['message']
                : decoded['message']) ??
            '')
        : '';
    final type = status >= 500 ? 'api_error' : 'invalid_request_error';
    final message = upstreamMsg.toString().isEmpty
        ? 'Upstream returned HTTP $status'
        : upstreamMsg.toString();
    return _jsonResponse(status, {
      'type': 'error',
      'error': {'type': type, 'message': message},
    });
  }

  Future<Response> _messages(Request req) async {
    Map<String, dynamic> body;
    try {
      final raw = await req.readAsString();
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) {
        throw const FormatException('body must be a JSON object');
      }
      body = decoded;
    } catch (e) {
      return _jsonResponse(400, {
        'type': 'error',
        'error': {
          'type': 'invalid_request_error',
          'message': 'Invalid JSON body: $e',
        },
      });
    }

    final requested = (body['model'] ?? '').toString();
    final oaiBody = anthropicToOpenAi(body);

    final s = settings.appSettings;
    final outcome = await core.chat(
      oaiBody,
      connectTimeout: Duration(seconds: s.upstreamTimeoutSeconds),
      bodyTimeout: Duration(seconds: s.upstreamTimeoutSeconds * 2),
    );

    final headers = {...outcome.headers};
    if (outcome.stream != null) {
      final sse = openAiSseToAnthropicSse(outcome.stream!, requested);
      return Response(
        outcome.statusCode,
        body: sse,
        headers: {
          'content-type': 'text/event-stream',
          'cache-control': 'no-cache',
          ...headers,
        },
      );
    }

    Map<String, dynamic>? oaiResp;
    if (outcome.bytes != null) {
      try {
        final decoded = jsonDecode(utf8.decode(outcome.bytes!));
        if (decoded is Map<String, dynamic>) oaiResp = decoded;
      } catch (_) {}
    }
    final ok = outcome.statusCode >= 200 && outcome.statusCode < 300;
    if (ok && oaiResp != null) {
      return _jsonResponse(200, openAiToAnthropicResponse(oaiResp, requested));
    }
    // Error envelope in Anthropic format (keeps upstream message detail).
    final bytes = outcome.bytes ??
        utf8.encode(jsonEncode({
          'error': {'message': outcome.error ?? 'Unknown proxy error'}
        }));
    return _anthropicError(outcome.statusCode, bytes);
  }

  Future<Response> _countTokens(Request req) async {
    Map<String, dynamic> body;
    try {
      body = jsonDecode(await req.readAsString()) as Map<String, dynamic>;
    } catch (_) {
      body = const {};
    }
    return _jsonResponse(200, {'input_tokens': estimateTokens(body)});
  }
}
