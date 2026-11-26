import 'dart:async';
import 'dart:convert';
import 'package:http/http.dart' as http;
import '../core/free_model_filter.dart';
import '../core/utils.dart';
import '../models/model_info.dart';
import '../models/provider_config.dart';

class ModelsOutcome {
  final List<ModelInfo> models;
  final String? error;
  final int? statusCode;

  const ModelsOutcome({required this.models, this.error, this.statusCode});

  bool get ok => error == null;
}

/// Thin OpenAI-compatible client used for both model listing and chat
/// forwarding. Works for OpenRouter, Groq and Google Gemini's
/// OpenAI-compatibility endpoint, plus any custom provider.
class UpstreamClient {
  UpstreamClient(this._client);

  final http.Client _client;
  static const defaultTimeout = Duration(seconds: 20);

  Map<String, String> _headers(ProviderConfig p, {bool json = false}) {
    final h = <String, String>{...p.extraHeaders};
    if (json) h['content-type'] = 'application/json';
    h['accept'] = 'application/json';
    if (p.apiKey.isNotEmpty) h['authorization'] = 'Bearer ${p.apiKey}';
    return h;
  }

  Future<ModelsOutcome> listModels(
    ProviderConfig p, {
    http.Client? client,
    Duration timeout = defaultTimeout,
  }) async {
    if (p.baseUrl.trim().isEmpty) {
      return const ModelsOutcome(models: [], error: 'Base URL not configured');
    }
    final url = joinUrl(p.baseUrl, p.modelsPath);
    try {
      final req = http.Request('GET', Uri.parse(url))
        ..headers.addAll(_headers(p));
      final resp = await (client ?? _client).send(req).timeout(timeout);
      final text = await resp.stream.bytesToString().timeout(timeout);
      if (resp.statusCode != 200) {
        return ModelsOutcome(
          models: const [],
          statusCode: resp.statusCode,
          error: 'HTTP ${resp.statusCode}: ${snippet(text)}',
        );
      }
      final decoded = jsonDecode(text);
      if (decoded is! Map<String, dynamic>) {
        return const ModelsOutcome(models: [], error: 'Unexpected /models payload');
      }
      return ModelsOutcome(models: parseModels(p, decoded));
    } on TimeoutException {
      return ModelsOutcome(
          models: const [], error: 'Timed out after ${timeout.inSeconds}s');
    } catch (e) {
      return ModelsOutcome(models: const [], error: e.toString());
    }
  }

  /// Parses OpenAI-style (`data: [...]`) or Gemini-native (`models: [...]`)
  /// listing payloads and applies the free-model filter. Pure & unit-tested.
  static List<ModelInfo> parseModels(
      ProviderConfig p, Map<String, dynamic> json) {
    var rawList = (json['data'] as List?) ?? (json['models'] as List?);
    rawList ??= const [];
    final now = DateTime.now();
    final out = <ModelInfo>[];
    for (final item in rawList) {
      if (item is! Map<String, dynamic>) continue;
      var id = (item['id'] ?? item['name'] ?? '').toString().trim();
      if (id.isEmpty) continue;
      // Gemini native listings use `models/gemini-...`.
      id = id.replaceFirst(RegExp(r'^models/', caseSensitive: false), '');
      var displayName = (item['name'] ?? item['display_name'])?.toString();
      if (displayName != null &&
          displayName.replaceFirst(RegExp(r'^models/', caseSensitive: false), '') ==
              id) {
        displayName = null;
      }

      double? promptPrice;
      double? completionPrice;
      final pricing = item['pricing'];
      if (pricing is Map<String, dynamic>) {
        promptPrice = parsePrice(pricing['prompt']);
        completionPrice = parsePrice(pricing['completion']);
      }
      final contextRaw = item['context_length'] ??
          item['context_window'] ??
          item['input_token_limit'] ??
          item['contextWindow'];

      out.add(ModelInfo(
        id: id,
        providerId: p.id,
        providerName: p.name,
        displayName: displayName,
        promptPrice: promptPrice,
        completionPrice: completionPrice,
        contextLength: contextRaw is num ? contextRaw.toInt() : null,
        isFree: FreeModelFilter.isFree(
          modelId: id,
          promptPrice: promptPrice,
          completionPrice: completionPrice,
          assumeProviderFree: p.assumeAllFree,
        ),
        ownedBy: item['owned_by']?.toString(),
        lastSeen: now,
      ));
    }
    out.sort((a, b) => a.id.compareTo(b.id));
    return out;
  }

  /// Sends an OpenAI-compatible chat completion. Returns the raw streamed
  /// response so callers can pipe SSE straight through or buffer JSON.
  /// The `model` field of [body] is overwritten with [model].
  Future<http.StreamedResponse> sendChat(
    ProviderConfig p,
    String model,
    Map<String, dynamic> body, {
    http.Client? client,
    Duration timeout = const Duration(seconds: 90),
  }) async {
    final url = joinUrl(p.baseUrl, p.chatPath);
    final req = http.Request('POST', Uri.parse(url))
      ..headers.addAll(_headers(p, json: true))
      ..body = jsonEncode({...body, 'model': model});
    final resp = await (client ?? _client).send(req).timeout(
          timeout,
          onTimeout: () => throw TimeoutException(
              'Upstream did not respond within ${timeout.inSeconds}s'),
        );
    return resp;
  }

  static String snippet(String s) => s.length > 300 ? '${s.substring(0, 300)}…' : s;
}
