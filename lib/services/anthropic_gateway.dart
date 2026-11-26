import 'dart:async';
import 'dart:convert';

/// Translates between the **Anthropic Messages API** (spoken by Claude Code)
/// and the OpenAI-compatible format used by our upstream providers.
///
/// This is what lets Claude Code (ANTHROPIC_BASE_URL → our proxy) work
/// against OpenRouter / Groq / Gemini / custom providers, including tool
/// calling (tool_use ⇄ tool_calls).
///
/// Request  (Anthropic → OpenAI): [anthropicToOpenAi]
/// Response (OpenAI → Anthropic): [openAiToAnthropicResponse]
/// Streaming: [openAiSseToAnthropicSse] rewrites the upstream SSE event stream
/// into Anthropic-style SSE events (message_start / content_block_* /
/// message_delta / message_stop).

/// Translates an Anthropic `/v1/messages` request body into an
/// OpenAI-compatible chat completion body. The `model` field is preserved so
/// the failover core can resolve it (Claude model names fall back to the
/// free-first chain when unknown).
Map<String, dynamic> anthropicToOpenAi(Map<String, dynamic> a) {
  final messages = <Map<String, dynamic>>[];

  // System prompt: string or list of text blocks.
  final system = a['system'];
  final systemBuf = StringBuffer();
  if (system is String) {
    systemBuf.write(system);
  } else if (system is List) {
    for (final block in system) {
      if (block is Map && block['type'] == 'text') {
        systemBuf.write('${block['text'] ?? ''}\n');
      }
    }
  }
  if (systemBuf.toString().trim().isNotEmpty) {
    messages.add({'role': 'system', 'content': systemBuf.toString().trim()});
  }

  String stringifyToolResult(Object? content) {
    if (content is String) return content;
    if (content is List) {
      final parts = <String>[];
      for (final block in content) {
        if (block is Map && block['type'] == 'text') {
          parts.add('${block['text'] ?? ''}');
        }
      }
      return parts.join('\n');
    }
    return jsonEncode(content);
  }

  for (final m in (a['messages'] as List? ?? const [])) {
    if (m is! Map) continue;
    final isAssistant = m['role'] == 'assistant';
    final content = m['content'];

    if (content is String) {
      messages.add({'role': isAssistant ? 'assistant' : 'user', 'content': content});
      continue;
    }
    if (content is! List) continue;

    if (isAssistant) {
      // Assistant turn: text blocks + tool_use blocks → one message with
      // optional tool_calls.
      final text = StringBuffer();
      final toolCalls = <Map<String, dynamic>>[];
      for (final block in content) {
        if (block is! Map) continue;
        switch (block['type']) {
          case 'text':
            text.write('${block['text'] ?? ''}');
            break;
          case 'tool_use':
            toolCalls.add({
              'id': (block['id'] ?? 'toolu_${toolCalls.length}') as String,
              'type': 'function',
              'function': {
                'name': block['name'] ?? '',
                'arguments': jsonEncode(block['input'] ?? const {}),
              },
            });
            break;
        }
      }
      final msg = <String, dynamic>{
        'role': 'assistant',
        // Many upstreams reject null content — always send a string.
        'content': text.toString(),
      };
      if (toolCalls.isNotEmpty) msg['tool_calls'] = toolCalls;
      messages.add(msg);
    } else {
      // User turn: text blocks become a user message; tool_result blocks
      // become OpenAI `tool` messages in block order.
      final text = StringBuffer();
      for (final block in content) {
        if (block is! Map) continue;
        switch (block['type']) {
          case 'text':
            text.write('${block['text'] ?? ''}');
            break;
          case 'tool_result':
            final body = stringifyToolResult(block['content']);
            messages.add({
              'role': 'tool',
              'tool_call_id': (block['tool_use_id'] ?? '') as String,
              'content': body,
            });
            break;
        }
      }
      if (text.toString().trim().isNotEmpty) {
        messages.add({'role': 'user', 'content': text.toString()});
      }
    }
  }

  final out = <String, dynamic>{
    'model': a['model'] ?? '',
    'messages': messages,
    'max_tokens': (a['max_tokens'] as num?)?.toInt() ?? 4096,
  };
  // Claude Code always streams — pass the flag through so the core returns
  // the upstream SSE stream for re-framing.
  if (a['stream'] == true) out['stream'] = true;
  if (a['temperature'] != null) out['temperature'] = a['temperature'];
  if (a['top_p'] != null) out['top_p'] = a['top_p'];
  if (a['stop_sequences'] is List && (a['stop_sequences'] as List).isNotEmpty) {
    out['stop'] = a['stop_sequences'];
  }

  final tools = a['tools'];
  if (tools is List && tools.isNotEmpty) {
    out['tools'] = [
      for (final t in tools)
        if (t is Map)
          {
            'type': 'function',
            'function': {
              'name': t['name'] ?? '',
              'description': t['description'] ?? '',
              'parameters': t['input_schema'] ??
                  {'type': 'object', 'properties': const {}},
            },
          },
    ];
  }
  final tc = a['tool_choice'];
  if (tc is Map) {
    switch (tc['type']) {
      case 'auto':
        out['tool_choice'] = 'auto';
        break;
      case 'any':
        out['tool_choice'] = 'required';
        break;
      case 'tool':
        out['tool_choice'] = {
          'type': 'function',
          'function': {'name': tc['name'] ?? ''},
        };
        break;
    }
  }
  return out;
}

/// Translates a non-streaming OpenAI chat completion into an Anthropic
/// `/v1/messages` response. [requestedModel] is echoed back so the client
/// sees the model it asked for.
Map<String, dynamic> openAiToAnthropicResponse(
    Map<String, dynamic> oai, String requestedModel) {
  final choices = oai['choices'] as List?;
  final choice = (choices != null && choices.isNotEmpty)
      ? (choices.first as Map).cast<String, dynamic>()
      : const <String, dynamic>{};
  final msg = (choice['message'] as Map?)?.cast<String, dynamic>() ??
      const <String, dynamic>{};

  final content = <Map<String, dynamic>>[];
  final text = msg['content'];
  if (text is String && text.isNotEmpty) {
    content.add({'type': 'text', 'text': text});
  }
  for (final tc in (msg['tool_calls'] as List? ?? const [])) {
    if (tc is! Map) continue;
    final fn = (tc['function'] ?? const {}) as Map<String, dynamic>;
    dynamic input;
    try {
      input = jsonDecode((fn['arguments'] ?? '{}') as String);
    } catch (_) {
      input = const {};
    }
    content.add({
      'type': 'tool_use',
      'id': (tc['id'] ?? 'toolu_${DateTime.now().microsecondsSinceEpoch}')
          as String,
      'name': fn['name'] ?? '',
      'input': input,
    });
  }
  if (content.isEmpty) content.add({'type': 'text', 'text': ''});

  final fr = choice['finish_reason'];
  final stopReason = switch (fr) {
    'tool_calls' => 'tool_use',
    'length' => 'max_tokens',
    'stop_sequence' => 'stop_sequence',
    _ => 'end_turn',
  };

  final usage = (oai['usage'] as Map?)?.cast<String, dynamic>() ??
      const <String, dynamic>{};
  return {
    'id': (oai['id'] ?? 'msg_${DateTime.now().microsecondsSinceEpoch}') as String,
    'type': 'message',
    'role': 'assistant',
    'model': requestedModel,
    'content': content,
    'stop_reason': stopReason,
    'stop_sequence': null,
    'usage': {
      'input_tokens': (usage['prompt_tokens'] as num?)?.toInt() ?? 0,
      'output_tokens': (usage['completion_tokens'] as num?)?.toInt() ?? 0,
    },
  };
}

/// Transforms an upstream OpenAI SSE byte stream into Anthropic SSE frames.
Stream<List<int>> openAiSseToAnthropicSse(
    Stream<List<int>> upstream, String requestedModel) async* {
  final id = 'msg_${DateTime.now().microsecondsSinceEpoch}';

  String frame(String event, Map<String, dynamic> data) =>
      'event: $event\ndata: ${jsonEncode(data)}\n\n';

  yield utf8.encode(frame('message_start', {
    'type': 'message_start',
    'message': {
      'id': id,
      'type': 'message',
      'role': 'assistant',
      'model': requestedModel,
      'content': [],
      'stop_reason': null,
      'stop_sequence': null,
      'usage': {'input_tokens': 0, 'output_tokens': 0},
    },
  }));

  var nextBlockIndex = 0;
  int? textBlockIndex;
  final toolBlockIndex = <int, int>{};
  var outputChars = 0;
  var stopReason = 'end_turn';

  await for (final line in upstream
      .transform(utf8.decoder)
      .transform(const LineSplitter())) {
    final l = line.trim();
    if (l.isEmpty || !l.startsWith('data:')) continue;
    final payload = l.substring(5).trim();
    if (payload == '[DONE]') break;
    Map<String, dynamic> chunk;
    try {
      final decoded = jsonDecode(payload);
      if (decoded is! Map<String, dynamic>) continue;
      chunk = decoded;
    } catch (_) {
      continue;
    }
    final choices = chunk['choices'] as List?;
    if (choices == null || choices.isEmpty) continue;
    final choice = choices.first;
    if (choice is! Map<String, dynamic>) continue;
    final delta = (choice['delta'] ?? const {}) as Map<String, dynamic>;

    final text = delta['content'];
    if (text is String && text.isNotEmpty) {
      if (textBlockIndex == null) {
        textBlockIndex = nextBlockIndex++;
        yield utf8.encode(frame('content_block_start', {
          'type': 'content_block_start',
          'index': textBlockIndex,
          'content_block': {'type': 'text', 'text': ''},
        }));
      }
      outputChars += text.length;
      yield utf8.encode(frame('content_block_delta', {
        'type': 'content_block_delta',
        'index': textBlockIndex,
        'delta': {'type': 'text_delta', 'text': text},
      }));
    }

    final toolDeltas = delta['tool_calls'] as List?;
    if (toolDeltas != null) {
      for (final t in toolDeltas) {
        if (t is! Map) continue;
        final idx = (t['index'] as num?)?.toInt() ?? 0;
        if (!toolBlockIndex.containsKey(idx)) {
          final fn = (t['function'] ?? const {}) as Map<String, dynamic>;
          final bi = nextBlockIndex++;
          toolBlockIndex[idx] = bi;
          yield utf8.encode(frame('content_block_start', {
            'type': 'content_block_start',
            'index': bi,
            'content_block': {
              'type': 'tool_use',
              'id': (t['id'] ?? 'toolu_$bi') as String,
              'name': (fn['name'] ?? '') as String,
              'input': const {},
            },
          }));
        }
        final fn = (t['function'] ?? const {}) as Map<String, dynamic>;
        final args = fn['arguments'];
        if (args is String && args.isNotEmpty) {
          yield utf8.encode(frame('content_block_delta', {
            'type': 'content_block_delta',
            'index': toolBlockIndex[idx]!,
            'delta': {'type': 'input_json_delta', 'partial_json': args},
          }));
        }
      }
    }

    final fr = choice['finish_reason'];
    if (fr != null) {
      stopReason = switch (fr) {
        'tool_calls' => 'tool_use',
        'length' => 'max_tokens',
        'stop_sequence' => 'stop_sequence',
        _ => 'end_turn',
      };
    }
  }

  for (var i = 0; i < nextBlockIndex; i++) {
    yield utf8.encode(frame('content_block_stop', {
      'type': 'content_block_stop',
      'index': i,
    }));
  }
  yield utf8.encode(frame('message_delta', {
    'type': 'message_delta',
    'delta': {'stop_reason': stopReason, 'stop_sequence': null},
    'usage': {'output_tokens': (outputChars / 4).ceil()},
  }));
  yield utf8.encode(frame('message_stop', {'type': 'message_stop'}));
}

/// Rough token estimate used by the `/v1/messages/count_tokens` stub.
int estimateTokens(Object? body) {
  var chars = 0;
  if (body is Map) {
    chars += (body['system'] ?? '').toString().length;
    for (final m in (body['messages'] as List? ?? const [])) {
      if (m is Map) chars += (m['content'] ?? '').toString().length;
    }
    for (final t in (body['tools'] as List? ?? const [])) {
      if (t is Map) chars += jsonEncode(t).length;
    }
  }
  return (chars / 4).ceil();
}
