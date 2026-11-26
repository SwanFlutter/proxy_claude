import 'dart:io';
import 'dart:math';
import 'package:path/path.dart' as p;

/// Joins a base URL and a path fragment into a single URL.
/// If [path] is already absolute (`http(s)://...`) it wins over [base].
String joinUrl(String base, String path) {
  final b = base.trim();
  final s = path.trim();
  if (s.isEmpty) return b;
  if (s.startsWith('http://') || s.startsWith('https://')) return s;
  final left = b.endsWith('/') ? b.substring(0, b.length - 1) : b;
  final right = s.startsWith('/') ? s : '/$s';
  return '$left$right';
}

/// Generates a cryptographically random alphanumeric key of [length].
String generateApiKey([int length = 32]) {
  const chars = 'ABCDEFGHJKLMNPQRSTUVWXYZabcdefghjkmnpqrstuvwxyz23456789';
  final rnd = Random.secure();
  return List.generate(length, (_) => chars[rnd.nextInt(chars.length)]).join();
}

/// Runtime path of a bundled Flutter asset on Windows (flutter_assets folder
/// next to the executable).
String bundledAssetPath(String asset) {
  final exeDir = p.dirname(Platform.resolvedExecutable);
  return p.join(exeDir, 'data', 'flutter_assets', asset);
}

String formatLatency(int ms) =>
    ms < 1000 ? '${ms}ms' : '${(ms / 1000).toStringAsFixed(2)}s';

/// Parses a price value that may arrive as `String` or `num`;
/// returns `null` when absent/invalid.
double? parsePrice(Object? value) {
  if (value == null) return null;
  if (value is num) return value.toDouble();
  final s = value.toString().trim();
  if (s.isEmpty) return null;
  return double.tryParse(s);
}

/// Parses `Key: Value` lines (newline or `;` separated) into a header map.
Map<String, String> parseHeaders(String raw) {
  final out = <String, String>{};
  for (final line in raw.split(RegExp(r'[\n;]'))) {
    final idx = line.indexOf(':');
    if (idx <= 0) continue;
    final k = line.substring(0, idx).trim();
    final v = line.substring(idx + 1).trim();
    if (k.isNotEmpty && v.isNotEmpty) out[k] = v;
  }
  return out;
}

String headersToText(Map<String, String> headers) =>
    headers.entries.map((e) => '${e.key}: ${e.value}').join('\n');
