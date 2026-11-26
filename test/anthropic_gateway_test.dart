import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:proxy_claude/services/anthropic_gateway.dart';

Stream<List<int>> sse(List<Map<String, dynamic>> chunks) async* {
  for (final c in chunks) {
    yield utf8.encode('data: ${jsonEncode(c)}\n\n');
  }
  yield utf8.encode('data: [DONE]\n\n');
}

Future<String> collect(Stream<List<int>> s) async =>
    utf8.decode((await s.toList()).expand((b) => b).toList());

void main() {
  group('anthropicToOpenAi', () {
    test('system string, plain messages, max_tokens', () {
      final out = anthropicToOpenAi({
        'model': 'deepseek/deepseek-chat:free',
        'max_tokens': 512,
        'system': 'You are helpful.',
        'messages': [
          {'role': 'user', 'content': 'hi'},
          {'role': 'assistant', 'content': 'hello'},
          {'role': 'user', 'content': [
              {'type': 'text', 'text': 'how are you?'},
            ]},
        ],
      });

      expect(out['model'], 'deepseek/deepseek-chat:free');
      expect(out['max_tokens'], 512);
      expect(out['messages'], [
        {'role': 'system', 'content': 'You are helpful.'},
        {'role': 'user', 'content': 'hi'},
        {'role': 'assistant', 'content': 'hello'},
        {'role': 'user', 'content': 'how are you?'},
      ]);
    });

    test('tool_use / tool_result blocks translate to tool_calls + tool role',
        () {
      final out = anthropicToOpenAi({
        'model': 'm',
        'max_tokens': 100,
        'tools': [
          {
            'name': 'read_file',
            'description': 'Reads a file',
            'input_schema': {
              'type': 'object',
              'properties': {'path': {'type': 'string'}},
            },
          },
        ],
        'messages': [
          {'role': 'user', 'content': 'read the file'},
          {
            'role': 'assistant',
            'content': [
              {'type': 'text', 'text': 'Let me read it.'},
              {
                'type': 'tool_use',
                'id': 'toolu_1',
                'name': 'read_file',
                'input': {'path': 'a.txt'},
              },
            ],
          },
          {
            'role': 'user',
            'content': [
              {
                'type': 'tool_result',
                'tool_use_id': 'toolu_1',
                'content': 'file contents here',
              },
            ],
          },
        ],
        'tool_choice': {'type': 'auto'},
      });

      expect(out['tools'], [
        {
          'type': 'function',
          'function': {
            'name': 'read_file',
            'description': 'Reads a file',
            'parameters': {
              'type': 'object',
              'properties': {'path': {'type': 'string'}},
            },
          },
        },
      ]);
      expect(out['tool_choice'], 'auto');
      expect(out['messages'][1]['tool_calls'], [
        {
          'id': 'toolu_1',
          'type': 'function',
          'function': {
            'name': 'read_file',
            'arguments': '{"path":"a.txt"}',
          },
        },
      ]);
      expect(out['messages'][2], {
        'role': 'tool',
        'tool_call_id': 'toolu_1',
        'content': 'file contents here',
      });
      expect(out['messages'][1]['content'], 'Let me read it.');
    });
  });

  group('openAiToAnthropicResponse', () {
    test('text + tool_calls → text/tool_use blocks, stop_reason mapping', () {
      final resp = openAiToAnthropicResponse({
        'id': 'abc',
        'choices': [
          {
            'finish_reason': 'tool_calls',
            'message': {
              'role': 'assistant',
              'content': 'Working on it.',
              'tool_calls': [
                {
                  'id': 'call_1',
                  'type': 'function',
                  'function': {
                    'name': 'read_file',
                    'arguments': '{"path":"a.txt"}',
                  },
                },
              ],
            },
          },
        ],
        'usage': {'prompt_tokens': 100, 'completion_tokens': 21},
      }, 'claude-sonnet-4');

      expect(resp['type'], 'message');
      expect(resp['role'], 'assistant');
      expect(resp['model'], 'claude-sonnet-4');
      expect(resp['stop_reason'], 'tool_use');
      expect(resp['content'][0], {'type': 'text', 'text': 'Working on it.'});
      expect(resp['content'][1]['type'], 'tool_use');
      expect(resp['content'][1]['id'], 'call_1');
      expect(resp['content'][1]['name'], 'read_file');
      expect(resp['content'][1]['input'], {'path': 'a.txt'});
      expect(resp['usage'], {'input_tokens': 100, 'output_tokens': 21});
    });

    test('empty content gets an empty text block', () {
      final resp = openAiToAnthropicResponse({
        'choices': [
          {'finish_reason': 'stop', 'message': {'role': 'assistant'}}
        ],
      }, 'm');
      expect(resp['content'], [
        {'type': 'text', 'text': ''},
      ]);
      expect(resp['stop_reason'], 'end_turn');
    });
  });

  group('openAiSseToAnthropicSse', () {
    test('text deltas stream as content_block events and close properly',
        () async {
      final out = await collect(openAiSseToAnthropicSse(
        sse([
          {
            'choices': [
              {
                'delta': {'content': 'Hel'},
              },
            ],
          },
          {
            'choices': [
              {
                'delta': {'content': 'lo!'},
                'finish_reason': 'stop',
              },
            ],
          },
        ]),
        'my-model',
      ));

      expect(out, contains('event: message_start'));
      expect(out, contains('event: content_block_start'));
      expect(out, contains('"type":"text_delta","text":"Hel"'));
      expect(out, contains('"type":"text_delta","text":"lo!"'));
      expect(out, contains('event: content_block_stop'));
      expect(out, contains('"stop_reason":"end_turn"'));
      expect(out, contains('event: message_stop'));
      expect(out, contains('"model":"my-model"'));
      // Events appear in order.
      final order = [
        out.indexOf('event: message_start'),
        out.indexOf('event: content_block_start'),
        out.indexOf('event: content_block_delta'),
        out.indexOf('event: content_block_stop'),
        out.indexOf('event: message_delta'),
        out.indexOf('event: message_stop'),
      ];
      expect(order, everyElement(isNonNegative));
      final sorted = [...order]..sort();
      expect(order, sorted);
    });

    test('tool_calls stream as tool_use blocks with input_json_delta', () async {
      final out = await collect(openAiSseToAnthropicSse(
        sse([
          {
            'choices': [
              {
                'delta': {
                  'tool_calls': [
                    {
                      'index': 0,
                      'id': 'call_9',
                      'function': {'name': 'read_file', 'arguments': ''},
                    },
                  ],
                },
              },
            ],
          },
          {
            'choices': [
              {
                'delta': {
                  'tool_calls': [
                    {
                      'index': 0,
                      'function': {'arguments': '{"path":"a.txt"}'},
                    },
                  ],
                },
                'finish_reason': 'tool_calls',
              },
            ],
          },
        ]),
        'my-model',
      ));

      expect(out, contains('"type":"tool_use"'));
      expect(out, contains('"id":"call_9"'));
      expect(out, contains('"name":"read_file"'));
      expect(out, contains('"type":"input_json_delta"'));
      expect(out, contains('"partial_json":"{\\"path\\":\\"a.txt\\"}"'));
      expect(out, contains('"stop_reason":"tool_use"'));
    });
  });

  test('estimateTokens is a rough char/4 count', () {
    expect(
      estimateTokens({
        'system': '12345678',
        'messages': [
          {'role': 'user', 'content': '1234'},
        ],
        'tools': [],
      }),
      3,
    );
  });
}
