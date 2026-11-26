import 'dart:async';
import 'dart:convert';
import 'package:http/http.dart' as http;
import '../core/utils.dart';
import '../models/log_entry.dart';
import '../models/model_info.dart';
import '../models/provider_config.dart';
import 'log_service.dart';
import 'model_registry.dart';
import 'upstream_client.dart';

/// One (provider, model) hop in the failover chain.
class FailoverCandidate {
  final ProviderConfig provider;
  final ModelInfo model;
  const FailoverCandidate(this.provider, this.model);
}

/// Pure, unit-testable routing/failover chain builder.
///
/// Order of candidates:
///  1. primary — the requested model (optionally `providerId/modelId`)
///  2. up to 2 same-provider siblings (free models first)
///  3. one fallback model per remaining enabled provider (free first)
///  4. the configured default model as a last resort
List<FailoverCandidate> buildFailoverChain({
  required List<ModelInfo> models,
  required List<ProviderConfig> providers,
  required String requestedModel,
  String? defaultModel,
  int maxCandidates = 6,
}) {
  final chain = <FailoverCandidate>[];
  final seen = <String>{};

  ProviderConfig? providerById(String id) {
    for (final p in providers) {
      if (p.id == id) return p;
    }
    return null;
  }

  void push(ProviderConfig p, ModelInfo m) {
    if (seen.contains(m.key)) return;
    if (chain.length >= maxCandidates) return;
    seen.add(m.key);
    chain.add(FailoverCandidate(p, m));
  }

  int freeFirst(ModelInfo a, ModelInfo b) {
    final f = (b.isFree ? 1 : 0) - (a.isFree ? 1 : 0);
    if (f != 0) return f;
    return a.id.compareTo(b.id);
  }

  var bare = requestedModel.trim();
  // Claude Code appends a `[1m]` context-window suffix to model names
  // (e.g. "model:free[1m]") — strip it for exact registry matching.
  bare = bare.replaceFirst(RegExp(r'\[\d+m\]$'), '');
  ProviderConfig? forced;
  final slash = bare.indexOf('/');
  if (slash > 0) {
    final maybeProvider = providerById(bare.substring(0, slash));
    if (maybeProvider != null) {
      forced = maybeProvider;
      bare = bare.substring(slash + 1);
    }
  }

  ModelInfo? primary;
  if (bare.isNotEmpty) {
    for (final m in models) {
      if (m.id == bare) {
        primary = m;
        break;
      }
    }
    if (primary == null && forced != null) {
      for (final m in models) {
        if (m.providerId == forced.id && m.id == bare) {
          primary = m;
          break;
        }
      }
    }
  }

  // Resolve the configured default model once. It is treated as a known-good
  // preferred fallback and tried immediately after the primary (or first when
  // the requested model is unknown), BEFORE alphabetical free siblings — many
  // of which are deprecated on OpenRouter and would otherwise waste attempts.
  ModelInfo? defaultInfo;
  ProviderConfig? defaultProv;
  if (defaultModel != null && defaultModel.isNotEmpty) {
    for (final m in models) {
      if (m.id == defaultModel) {
        defaultInfo = m;
        defaultProv = providerById(m.providerId);
        break;
      }
    }
  }

  if (primary != null) {
    final prim = primary;
    final pp = providerById(prim.providerId) ?? forced;
    if (pp != null) push(pp, prim);

    // Preferred known-good fallback right after the primary.
    if (defaultInfo != null && defaultProv != null) push(defaultProv, defaultInfo);

    final siblings = models
        .where((m) => m.providerId == prim.providerId && m.id != prim.id)
        .toList()
      ..sort(freeFirst);
    for (final m in siblings.take(2)) {
      final p2 = providerById(m.providerId);
      if (p2 != null) push(p2, m);
    }
  } else if (defaultInfo != null && defaultProv != null) {
    // Unknown requested model: start from the preferred default.
    push(defaultProv, defaultInfo);
  }

  // Cross-provider fallbacks (prefer free models).
  for (final p in providers) {
    if (chain.length >= maxCandidates) break;
    if (primary != null && p.id == primary.providerId) continue;
    final own = models.where((m) => m.providerId == p.id).toList()..sort(freeFirst);
    if (own.isNotEmpty) push(p, own.first);
  }

  return chain;
}

class ChatOutcome {
  final int statusCode;
  final String? contentType;
  final Stream<List<int>>? stream;
  final List<int>? bytes;
  final Map<String, String> headers;
  final String? providerId;
  final String? modelId;
  final int attempts;
  final List<String> attemptLog;
  final String? error;

  const ChatOutcome({
    required this.statusCode,
    this.contentType,
    this.stream,
    this.bytes,
    this.headers = const {},
    this.providerId,
    this.modelId,
    required this.attempts,
    this.attemptLog = const [],
    this.error,
  });

  bool get isStream => stream != null;

  factory ChatOutcome.error(
    int code,
    String message, {
    int attempts = 0,
    List<String> attemptLog = const [],
    String? providerId,
    String? modelId,
    List<int>? bodyBytes,
    String? contentType,
  }) =>
      ChatOutcome(
        statusCode: code,
        error: message,
        attempts: attempts,
        attemptLog: attemptLog,
        providerId: providerId,
        modelId: modelId,
        bytes: bodyBytes,
        contentType: contentType,
      );
}

/// The heart of the proxy: resolves the requested model, injects provider
/// credentials, forwards the request and fails over on
/// 401/403/404/408/429/5xx/timeout/network errors.
class ChatProxyCore {
  ChatProxyCore({
    required this.registry,
    required this.enabledProviders,
    required this.defaultModel,
    required this.upstream,
    required this.logs,
  });

  final ModelRegistry registry;
  final List<ProviderConfig> Function() enabledProviders;
  final String? Function() defaultModel;
  final UpstreamClient upstream;
  final LogService logs;

  Future<ChatOutcome> chat(
    Map<String, dynamic> body, {
    required Duration connectTimeout,
    required Duration bodyTimeout,
  }) async {
    final providers = enabledProviders();
    final requested = (body['model'] ?? '').toString();
    final wantStream = body['stream'] == true;
    final chain = buildFailoverChain(
      models: registry.snapshot,
      providers: providers,
      requestedModel: requested,
      defaultModel: defaultModel(),
    );
    if (chain.isEmpty) {
      return ChatOutcome.error(
        404,
        'No models are currently available. Enable a provider and sync models first.',
      );
    }

    final attemptLines = <String>[];
    var lastStatus = 0;
    String? lastSnippet;

    for (var i = 0; i < chain.length; i++) {
      final cand = chain[i];
      final sw = Stopwatch()..start();
      http.StreamedResponse resp;
      try {
        resp = await upstream.sendChat(
          cand.provider,
          cand.model.id,
          body,
          timeout: connectTimeout,
        );
      } on TimeoutException {
        final line = _attemptLine(i, chain.length, cand, 'timeout', sw.elapsedMilliseconds);
        attemptLines.add(line);
        logs.warn(LogCategory.request, '$line — failing over');
        continue;
      } catch (e) {
        final line = _attemptLine(i, chain.length, cand, 'network error', sw.elapsedMilliseconds);
        attemptLines.add(line);
        logs.warn(LogCategory.request, '$line — $e — failing over');
        continue;
      }

      final ttfbMs = sw.elapsedMilliseconds;
      final status = resp.statusCode;

      if (status >= 200 && status < 300) {
        if (wantStream) {
          final stream = resp.stream
              .transform<List<int>>(StreamTransformer.fromHandlers(
                  handleError: (e, st, sink) {
            logs.error(LogCategory.request,
                'Upstream stream broke after ${sw.elapsedMilliseconds}ms: $e');
            sink.close();
          }));
          logs.requestLog(
            provider: cand.provider.name,
            model: cand.model.id,
            status: status,
            latencyMs: ttfbMs,
            attempt: i + 1,
            total: chain.length,
            streaming: true,
          );
          return ChatOutcome(
            statusCode: status,
            contentType: resp.headers['content-type'] ?? 'text/event-stream',
            stream: stream,
            headers: _proxyHeaders(cand, i + 1),
            providerId: cand.provider.id,
            modelId: cand.model.id,
            attempts: i + 1,
            attemptLog: attemptLines,
          );
        }
        try {
          final bytes = await resp.stream.toBytes().timeout(bodyTimeout);
          logs.requestLog(
            provider: cand.provider.name,
            model: cand.model.id,
            status: status,
            latencyMs: sw.elapsedMilliseconds,
            attempt: i + 1,
            total: chain.length,
          );
          return ChatOutcome(
            statusCode: status,
            contentType: resp.headers['content-type'] ?? 'application/json',
            bytes: bytes,
            headers: _proxyHeaders(cand, i + 1),
            providerId: cand.provider.id,
            modelId: cand.model.id,
            attempts: i + 1,
            attemptLog: attemptLines,
          );
        } on TimeoutException {
          final line =
              _attemptLine(i, chain.length, cand, 'body timeout', sw.elapsedMilliseconds);
          attemptLines.add(line);
          logs.warn(LogCategory.request, '$line — failing over');
          continue;
        }
      }

      // Error status: capture body, decide passthrough vs failover.
      final errText = await _drain(resp);
      lastStatus = status;
      lastSnippet = UpstreamClient.snippet(errText);

      // A 400 that clearly indicates context/token overflow IS model-specific
      // (e.g. Claude Code's huge system prompt vs a small free model) — retry
      // the next candidate. Other 400s are malformed requests → passthrough.
      final looksContextOverflow = status == 400 &&
          RegExp(
              r'context (length|window)|maximum context|too (many|long) (tokens|prompt)|exceed[s]? (the )?(maximum|context|model)|input tokens|prompt is too long',
              caseSensitive: false)
              .hasMatch(errText);
      final retryable = status == 408 ||
          status == 429 ||
          status == 401 ||
          status == 403 ||
          status == 404 ||
          status >= 500 ||
          looksContextOverflow;
      if (!retryable) {
        logs.warn(LogCategory.request, _attemptLine(i, chain.length, cand, 'HTTP $status', ttfbMs));
        return ChatOutcome.error(
          status,
          'Upstream returned HTTP $status: $lastSnippet',
          attempts: i + 1,
          attemptLog: attemptLines,
          providerId: cand.provider.id,
          modelId: cand.model.id,
          bodyBytes: utf8.encode(errText),
          contentType: resp.headers['content-type'] ?? 'application/json',
        );
      }
      final line = _attemptLine(i, chain.length, cand, 'HTTP $status', ttfbMs);
      attemptLines.add(line);
      logs.warn(LogCategory.request, '$line — failing over ($lastSnippet)');
    }

    return ChatOutcome.error(
      502,
      'All ${chain.length} failover attempt(s) failed.'
      ' Last status: HTTP $lastStatus${lastSnippet != null ? ' — $lastSnippet' : ''}',
      attempts: chain.length,
      attemptLog: attemptLines,
    );
  }

  Map<String, String> _proxyHeaders(FailoverCandidate cand, int attempt) => {
        'x-proxy-provider': cand.provider.id,
        'x-proxy-model': cand.model.id,
        'x-proxy-attempt': '$attempt',
      };

  String _attemptLine(
      int attempt, int total, FailoverCandidate c, String result, int ms) {
    return 'attempt ${attempt + 1}/$total · ${c.provider.name} · ${c.model.id}'
        ' · $result · ${formatLatency(ms)}';
  }

  Future<String> _drain(http.StreamedResponse resp) async {
    try {
      return await resp.stream.bytesToString().timeout(const Duration(seconds: 15));
    } catch (_) {
      return '';
    }
  }
}
