import 'dart:async';
import '../core/utils.dart';
import '../models/log_entry.dart';

/// In-memory ring buffer (2000 entries) + broadcast stream for the live UI.
class LogService {
  static const int maxEntries = 2000;

  final List<LogEntry> _buffer = [];
  final StreamController<LogEntry> _ctrl =
      StreamController<LogEntry>.broadcast();

  /// Newest-first snapshot of the buffer.
  List<LogEntry> get entries =>
      List.unmodifiable(_buffer.reversed);

  Stream<LogEntry> get stream => _ctrl.stream;

  void add(LogLevel level, LogCategory category, String message,
      [Map<String, Object?> meta = const {}]) {
    final entry = LogEntry(
      ts: DateTime.now(),
      level: level,
      category: category,
      message: message,
      meta: meta,
    );
    _buffer.add(entry);
    if (_buffer.length > maxEntries) {
      _buffer.removeRange(0, _buffer.length - maxEntries);
    }
    _ctrl.add(entry);
  }

  void debug(LogCategory c, String m) => add(LogLevel.debug, c, m);
  void info(LogCategory c, String m) => add(LogLevel.info, c, m);
  void warn(LogCategory c, String m) => add(LogLevel.warn, c, m);
  void error(LogCategory c, String m) => add(LogLevel.error, c, m);
  void system(String m) => add(LogLevel.info, LogCategory.system, m);

  void requestLog({
    required String provider,
    required String model,
    required int status,
    required int latencyMs,
    int attempt = 1,
    int total = 1,
    bool streaming = false,
  }) {
    final ok = status >= 200 && status < 400;
    add(
      ok ? LogLevel.info : LogLevel.warn,
      LogCategory.request,
      'POST ${streaming ? '/v1/chat/completions (SSE)' : '/v1/chat/completions'}'
      ' · $model · $provider · HTTP $status · ${formatLatency(latencyMs)}'
      ' · attempt $attempt/$total',
      {
        'status': status,
        'model': model,
        'provider': provider,
        'latencyMs': latencyMs,
      },
    );
  }

  void clear() {
    _buffer.clear();
    _ctrl.add(LogEntry(
      ts: DateTime.now(),
      level: LogLevel.debug,
      category: LogCategory.system,
      message: '— log buffer cleared —',
    ));
  }
}
