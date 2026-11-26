enum LogLevel { debug, info, warn, error }

enum LogCategory { system, request, provider, sync, tunnel }

class LogEntry {
  final DateTime ts;
  final LogLevel level;
  final LogCategory category;
  final String message;
  final Map<String, Object?> meta;

  const LogEntry({
    required this.ts,
    required this.level,
    required this.category,
    required this.message,
    this.meta = const {},
  });

  String get timeLabel {
    final h = ts.hour.toString().padLeft(2, '0');
    final m = ts.minute.toString().padLeft(2, '0');
    final s = ts.second.toString().padLeft(2, '0');
    return '$h:$m:$s';
  }
}
