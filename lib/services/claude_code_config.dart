import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

/// Writes Claude Code's own config file so the CLI talks to this proxy without
/// the user editing JSON by hand.
///
/// Claude Code (Windows: `%USERPROFILE%\.claude\settings.json`, macOS/Linux:
/// `~/.claude/settings.json`) reads its gateway from the `env` block:
///
/// ```json
/// { "env": { "ANTHROPIC_BASE_URL": "http://127.0.0.1:8080",
///            "ANTHROPIC_AUTH_TOKEN": "<proxy key>",
///            "ANTHROPIC_MODEL": "auto", … } }
/// ```
///
/// Everything in this file is deliberately boring and reviewable:
///  * unknown keys (`mcpServers`, `permissions`, `model`, …) are preserved,
///  * only [managedKeys] are written or removed,
///  * the original file is backed up next to itself before the first write,
///  * the JSON is decoded/encoded as an ordered map so key order survives.
class ClaudeCodeConfig {
  const ClaudeCodeConfig._();

  /// Env entries this app owns. Anything else in `env` belongs to the user.
  static const List<String> managedKeys = [
    'ANTHROPIC_BASE_URL',
    'ANTHROPIC_AUTH_TOKEN',
    'ANTHROPIC_MODEL',
    'ANTHROPIC_DEFAULT_OPUS_MODEL',
    'ANTHROPIC_DEFAULT_SONNET_MODEL',
    'ANTHROPIC_DEFAULT_HAIKU_MODEL',
  ];

  /// Default location, shown as the hint in the UI.
  static const String defaultRelPath = r'.claude\settings.json';

  /// `%USERPROFILE%\.claude\settings.json` on Windows, `~/.claude/settings.json`
  /// elsewhere.
  static String defaultPath() {
    final home = Platform.environment['USERPROFILE'] ??
        Platform.environment['HOME'] ??
        '';
    return home.isEmpty ? p.join('.claude', 'settings.json') : p.join(home, '.claude', 'settings.json');
  }

  static String resolvePath(String configured) =>
      configured.trim().isEmpty ? defaultPath() : p.normalize(configured.trim());

  /// The env block Claude Code needs for this proxy.
  ///
  /// [baseUrl] must have **no** trailing `/v1` — Claude Code appends the
  /// endpoint itself.
  static Map<String, String> envFor({
    required String baseUrl,
    required String authToken,
    required bool autoModels,
    String mainModel = 'auto',
    String strongModel = 'auto:strong',
    String fastModel = 'auto:fast',
  }) =>
      {
        'ANTHROPIC_BASE_URL': baseUrl.trim().replaceAll(RegExp(r'/+$'), ''),
        'ANTHROPIC_AUTH_TOKEN': authToken,
        if (autoModels) ...{
          'ANTHROPIC_MODEL': mainModel,
          'ANTHROPIC_DEFAULT_OPUS_MODEL': strongModel,
          'ANTHROPIC_DEFAULT_SONNET_MODEL': mainModel,
          'ANTHROPIC_DEFAULT_HAIKU_MODEL': fastModel,
        },
      };

  /// Pure merge: returns the document to write plus a human-readable diff.
  /// [existingRaw] may be empty or `null` (new file).
  static ({Map<String, dynamic> doc, List<String> changes, bool changed})
      merge(
    String? existingRaw, {
    required Map<String, String> env,
  }) {
    Map<String, dynamic> doc = {};
    final text = (existingRaw ?? '').trim();
    if (text.isNotEmpty) {
      final decoded = jsonDecode(text);
      if (decoded is Map<String, dynamic>) {
        doc = decoded;
      } else {
        throw const FormatException('settings.json root is not a JSON object');
      }
    }

    final rawEnv = doc['env'];
    final mergedEnv = <String, dynamic>{
      if (rawEnv is Map) ...rawEnv.cast<String, dynamic>(),
    };
    final changes = <String>[];

    for (final entry in env.entries) {
      final before = mergedEnv[entry.key];
      if (before != entry.value) {
        changes.add('${entry.key}: ${before ?? '—'} → ${entry.value}');
      }
      mergedEnv[entry.key] = entry.value;
    }
    for (final key in managedKeys) {
      if (!env.containsKey(key) && mergedEnv.containsKey(key)) {
        // Never leave a stale managed value behind (e.g. concrete model ids
        // when switching to the auto models).
        mergedEnv.remove(key);
        changes.add('$key: removed');
      }
    }

    doc['env'] = mergedEnv;
    return (doc: doc, changes: changes, changed: changes.isNotEmpty);
  }

  /// Pure removal: strips only [managedKeys] from `env`.
  static ({Map<String, dynamic> doc, List<String> changes, bool changed})
      strip(String? existingRaw) {
    final text = (existingRaw ?? '').trim();
    if (text.isEmpty) {
      return (doc: <String, dynamic>{}, changes: const [], changed: false);
    }
    final decoded = jsonDecode(text);
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('settings.json root is not a JSON object');
    }
    final rawEnv = decoded['env'];
    final env = <String, dynamic>{
      if (rawEnv is Map) ...rawEnv.cast<String, dynamic>(),
    };
    final changes = <String>[];
    for (final key in managedKeys) {
      if (env.remove(key) != null) changes.add('$key: removed');
    }
    decoded['env'] = env;
    return (doc: decoded, changes: changes, changed: changes.isNotEmpty);
  }

  static const JsonEncoder _encoder = JsonEncoder.withIndent('  ');

  static String encode(Map<String, dynamic> doc) => '${_encoder.convert(doc)}\n';

  /// Writes [env] into [path], backing the previous file up once per change.
  static Future<ClaudeWriteResult> write({
    required String path,
    required Map<String, String> env,
    bool backup = true,
  }) async {
    final file = File(path);
    await file.parent.create(recursive: true);
    final existing = await file.exists() ? await file.readAsString() : null;
    final plan = merge(existing, env: env);
    if (!plan.changed && existing != null) {
      return ClaudeWriteResult(
          path: path, changed: false, changes: const [], backupPath: null);
    }
    String? backupPath;
    if (backup && existing != null && existing.trim().isNotEmpty) {
      backupPath = '${file.path}.proxyhub-bak';
      await File(backupPath).writeAsString(existing);
    }
    await file.writeAsString(encode(plan.doc));
    return ClaudeWriteResult(
        path: path,
        changed: true,
        changes: plan.changes,
        backupPath: backupPath);
  }

  static Future<ClaudeWriteResult> remove({required String path}) async {
    final file = File(path);
    if (!await file.exists()) {
      return ClaudeWriteResult(
          path: path, changed: false, changes: const [], backupPath: null);
    }
    final existing = await file.readAsString();
    final plan = strip(existing);
    if (!plan.changed) {
      return ClaudeWriteResult(
          path: path, changed: false, changes: const [], backupPath: null);
    }
    final backupPath = '${file.path}.proxyhub-bak';
    await File(backupPath).writeAsString(existing);
    await file.writeAsString(encode(plan.doc));
    return ClaudeWriteResult(
        path: path,
        changed: true,
        changes: plan.changes,
        backupPath: backupPath);
  }

  /// What the file currently says, compared against the [expected] env block.
  static Future<ClaudeInstallState> inspect(
    String path, {
    required Map<String, String> expected,
  }) async {
    final file = File(path);
    if (!await file.exists()) {
      return ClaudeInstallState(exists: false, installed: false, expected: expected);
    }
    try {
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map<String, dynamic>) {
        return ClaudeInstallState(exists: false, installed: false, expected: expected);
      }
      final env = decoded['env'];
      final map = env is Map ? env.cast<String, dynamic>() : const {};
      final configured = (map['ANTHROPIC_BASE_URL'] ?? '').toString();
      final token = (map['ANTHROPIC_AUTH_TOKEN'] ?? '').toString();
      final present = <String>{
        for (final k in managedKeys)
          if (map.containsKey(k)) k,
      };
      return ClaudeInstallState(
        exists: true,
        installed: configured.isNotEmpty && token.isNotEmpty,
        baseUrl: configured,
        tokenMatches: token == (expected['ANTHROPIC_AUTH_TOKEN'] ?? ''),
        baseUrlMatches: configured.replaceAll(RegExp(r'/+$'), '') ==
            (expected['ANTHROPIC_BASE_URL'] ?? '')
                .replaceAll(RegExp(r'/+$'), ''),
        modelKeys: present,
        modelValues: {
          for (final k in managedKeys)
            if (k != 'ANTHROPIC_AUTH_TOKEN' &&
                k != 'ANTHROPIC_BASE_URL' &&
                map.containsKey(k))
              k: map[k].toString(),
        },
        model: (map['ANTHROPIC_MODEL'] ?? '').toString(),
        expected: expected,
      );
    } catch (_) {
      return ClaudeInstallState(exists: false, installed: false, expected: expected);
    }
  }
}

class ClaudeWriteResult {
  final String path;
  final bool changed;
  final List<String> changes;
  final String? backupPath;

  const ClaudeWriteResult({
    required this.path,
    required this.changed,
    required this.changes,
    required this.backupPath,
  });
}

class ClaudeInstallState {
  final bool exists;
  final bool installed;
  final String baseUrl;
  final bool tokenMatches;
  final bool baseUrlMatches;
  final Set<String> modelKeys;
  final String model;

  /// The env block the app wants to see in the file.
  final Map<String, String> expected;

  /// Current values of the non-secret managed keys (`ANTHROPIC_MODEL`, …).
  final Map<String, String> modelValues;

  const ClaudeInstallState({
    required this.exists,
    required this.installed,
    this.baseUrl = '',
    this.tokenMatches = false,
    this.baseUrlMatches = false,
    this.modelKeys = const {},
    this.model = '',
    this.expected = const {},
    this.modelValues = const {},
  });

  /// Model keys the file has but the app no longer wants (e.g. concrete ids
  /// left over from before the `auto` switch).
  Set<String> get staleKeys => modelKeys.difference(expected.keys.toSet());

  /// Every managed key holds exactly the value this app would write.
  bool get envMatches {
    if (!tokenMatches || !baseUrlMatches) return false;
    for (final entry in expected.entries) {
      // URL and token are already covered by baseUrlMatches / tokenMatches.
      if (entry.key == 'ANTHROPIC_AUTH_TOKEN' ||
          entry.key == 'ANTHROPIC_BASE_URL') {
        continue;
      }
      if (modelValues[entry.key] != entry.value) return false;
    }
    return staleKeys.isEmpty;
  }

  /// Everything the proxy wants is already in the file.
  bool get upToDate => installed && envMatches;

  String get summary {
    if (!exists) return 'No settings file yet';
    if (upToDate) return 'Configured and current';
    if (!installed) return 'Claude settings file found, proxy env missing';
    return baseUrlMatches
        ? 'Configured — proxy key differs'
        : 'Configured — but points at $baseUrl';
  }
}
