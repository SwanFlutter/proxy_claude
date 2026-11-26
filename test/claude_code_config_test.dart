import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:proxy_claude/services/claude_code_config.dart';

void main() {
  late Directory tmp;
  late String path;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync();
    path = '${tmp.path}${Platform.pathSeparator}settings.json';
  });
  tearDown(() => tmp.deleteSync(recursive: true));

  Map<String, String> envFor(String url) => ClaudeCodeConfig.envFor(
        baseUrl: url,
        authToken: 'proxykey123',
        autoModels: true,
      );

  Map<String, dynamic> readDoc() =>
      jsonDecode(File(path).readAsStringSync()) as Map<String, dynamic>;

  group('merge', () {
    test('creates the env block for a new file', () {
      final plan = ClaudeCodeConfig.merge(null, env: envFor('http://127.0.0.1:8080/'));
      final env = plan.doc['env'] as Map;
      expect(plan.changed, isTrue);
      // Trailing slash must be normalised — Claude Code appends /v1/messages.
      expect(env['ANTHROPIC_BASE_URL'], 'http://127.0.0.1:8080');
      expect(env['ANTHROPIC_AUTH_TOKEN'], 'proxykey123');
      expect(env['ANTHROPIC_MODEL'], 'auto');
      expect(env['ANTHROPIC_DEFAULT_OPUS_MODEL'], 'auto:strong');
      expect(env['ANTHROPIC_DEFAULT_HAIKU_MODEL'], 'auto:fast');
    });

    test('keeps unrelated keys and their order', () {
      final existing = jsonEncode({
        'model': 'opus',
        'hasCompletedOnboarding': true,
        'mcpServers': {'ctx7': {'command': 'npx'}},
        'env': {'HTTPS_PROXY': 'http://127.0.0.1:7890'},
        'CLAUDE_CODE_MAX_CONTEXT_TOKENS': 1000000,
      });
      final plan =
          ClaudeCodeConfig.merge(existing, env: envFor('http://127.0.0.1:8080'));
      expect(plan.doc.keys.toList(),
          ['model', 'hasCompletedOnboarding', 'mcpServers', 'env', 'CLAUDE_CODE_MAX_CONTEXT_TOKENS']);
      final env = plan.doc['env'] as Map;
      expect(env['HTTPS_PROXY'], 'http://127.0.0.1:7890');
      expect((plan.doc['mcpServers'] as Map).containsKey('ctx7'), isTrue);
      expect(plan.doc['hasCompletedOnboarding'], isTrue);
    });

    test('drops model ids left over from a previous install', () {
      final existing = jsonEncode({
        'env': {
          'ANTHROPIC_BASE_URL': 'http://127.0.0.1:8080',
          'ANTHROPIC_AUTH_TOKEN': 'proxykey123',
          'ANTHROPIC_MODEL': 'nvidia/nemotron-3.5-lightning:free',
          'ANTHROPIC_DEFAULT_SONNET_MODEL': 'nvidia/nemotron-3.5-lightning:free',
        }
      });
      final plan = ClaudeCodeConfig.merge(existing,
          env: ClaudeCodeConfig.envFor(
              baseUrl: 'http://127.0.0.1:8080',
              authToken: 'proxykey123',
              autoModels: false));
      final env = plan.doc['env'] as Map;
      expect(env.containsKey('ANTHROPIC_MODEL'), isFalse);
      expect(env.containsKey('ANTHROPIC_DEFAULT_SONNET_MODEL'), isFalse);
      expect(env['ANTHROPIC_BASE_URL'], 'http://127.0.0.1:8080');
      expect(plan.changes.any((c) => c.contains('removed')), isTrue);
    });

    test('reports nothing to do when the file is already correct', () {
      final plan =
          ClaudeCodeConfig.merge(null, env: envFor('http://127.0.0.1:8080'));
      final again = ClaudeCodeConfig.merge(
          jsonEncode(plan.doc), env: envFor('http://127.0.0.1:8080'));
      expect(again.changed, isFalse);
      expect(again.changes, isEmpty);
    });
  });

  group('write / inspect / remove', () {
    test('writes, is detected as current, and keeps a backup', () async {
      File(path).writeAsStringSync(jsonEncode({
        'model': 'opus',
        'env': {'HTTPS_PROXY': 'http://127.0.0.1:7890'},
      }));

      final first = await ClaudeCodeConfig.write(path: path, env: envFor('http://127.0.0.1:8080'));
      expect(first.changed, isTrue);
      expect(first.backupPath, isNotNull);
      expect(File(first.backupPath!).existsSync(), isTrue);
      // The backup still holds the original bytes.
      expect(jsonDecode(File(first.backupPath!).readAsStringSync())['model'],
          'opus');

      final state =
          await ClaudeCodeConfig.inspect(path, expected: envFor('http://127.0.0.1:8080'));
      expect(state.upToDate, isTrue);
      expect(state.summary, 'Configured and current');

      // The user's own keys survived the write.
      expect(readDoc()['model'], 'opus');
      expect((readDoc()['env'] as Map)['HTTPS_PROXY'], 'http://127.0.0.1:7890');

      // A second write is a no-op.
      final second =
          await ClaudeCodeConfig.write(path: path, env: envFor('http://127.0.0.1:8080'));
      expect(second.changed, isFalse);
    });

    test('a stale URL or rotated key is detected', () async {
      await ClaudeCodeConfig.write(path: path, env: envFor('http://127.0.0.1:8080'));

      final moved = await ClaudeCodeConfig.inspect(
          path, expected: envFor('https://demo.trycloudflare.com'));
      expect(moved.installed, isTrue);
      expect(moved.upToDate, isFalse);
      expect(moved.baseUrlMatches, isFalse);
      expect(moved.summary, contains('points at'));

      final rotated = await ClaudeCodeConfig.inspect(path, expected: {
        ...envFor('http://127.0.0.1:8080'),
        'ANTHROPIC_AUTH_TOKEN': 'other-key',
      });
      expect(rotated.tokenMatches, isFalse);
      expect(rotated.summary, contains('key differs'));
    });

    test('remove strips only the proxy keys', () async {
      await ClaudeCodeConfig.write(path: path, env: envFor('http://127.0.0.1:8080'));
      final removed = await ClaudeCodeConfig.remove(path: path);
      expect(removed.changed, isTrue);
      final env = readDoc()['env'] as Map;
      expect(env.containsKey('ANTHROPIC_BASE_URL'), isFalse);
      expect(env.containsKey('ANTHROPIC_MODEL'), isFalse);
      expect(removed.changes.length, ClaudeCodeConfig.managedKeys.length);
    });

    test('a missing file is reported as not configured', () async {
      final state =
          await ClaudeCodeConfig.inspect('$path.nope', expected: envFor('x'));
      expect(state.exists, isFalse);
      expect(state.upToDate, isFalse);
      expect(state.summary, 'No settings file yet');
    });

    test('resolvePath falls back to the per-user default', () {
      expect(ClaudeCodeConfig.resolvePath(''), ClaudeCodeConfig.defaultPath());
      expect(ClaudeCodeConfig.resolvePath('  '), ClaudeCodeConfig.defaultPath());
      expect(ClaudeCodeConfig.resolvePath(path), path);
    });
  });
}
