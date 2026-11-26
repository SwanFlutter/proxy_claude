import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import '../models/log_entry.dart';
import '../models/settings.dart' show TunnelMode;
import 'log_service.dart';

enum TunnelStatus { idle, downloading, starting, connected, stopped, error }

class TunnelRuntime {
  final TunnelStatus status;
  final TunnelMode mode;
  final String? publicUrl;
  final String? binaryPath;
  final String? error;
  final double? downloadProgress;

  const TunnelRuntime({
    this.status = TunnelStatus.idle,
    this.mode = TunnelMode.quick,
    this.publicUrl,
    this.binaryPath,
    this.error,
    this.downloadProgress,
  });

  const TunnelRuntime.idle() : this();

  TunnelRuntime copyWith({
    TunnelStatus? status,
    TunnelMode? mode,
    String? publicUrl,
    String? binaryPath,
    String? error,
    double? downloadProgress,
  }) =>
      TunnelRuntime(
        status: status ?? this.status,
        mode: mode ?? this.mode,
        publicUrl: publicUrl ?? this.publicUrl,
        binaryPath: binaryPath ?? this.binaryPath,
        error: error ?? this.error,
        downloadProgress: downloadProgress ?? this.downloadProgress,
      );
}

class TunnelException implements Exception {
  final String message;
  const TunnelException(this.message);
  @override
  String toString() => message;
}

/// Manages the `cloudflared` child process:
///
///  - locates the binary (override path → next to app exe → app-support/bin → PATH)
///  - downloads it from GitHub releases when missing
///  - token mode:  `cloudflared tunnel run` with `TUNNEL_TOKEN` env (not argv,
///    so the secret is not visible in the process list)
///  - quick mode:  `cloudflared tunnel --url http://127.0.0.1:<port>` and
///    scrapes the generated trycloudflare.com URL from stdout
///  - health: "Registered tunnel connection" → connected; process exit → error
class TunnelManager {
  TunnelManager(this._logs, {required this.downloadDir, required this.pathOverride});

  final LogService _logs;
  final String downloadDir;
  final String? Function() pathOverride;

  static const downloadUrl =
      'https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-windows-amd64.exe';

  static final RegExp _quickUrl =
      RegExp(r'https://[a-zA-Z0-9-]+\.trycloudflare\.com');

  Process? _proc;
  bool _userStopped = false;
  final StreamController<TunnelRuntime> _states =
      StreamController<TunnelRuntime>.broadcast();
  TunnelRuntime _runtime = const TunnelRuntime.idle();

  TunnelRuntime get runtime => _runtime;
  Stream<TunnelRuntime> get states => _states.stream;
  bool get isRunning => _proc != null;

  void _set(TunnelRuntime rt) {
    _runtime = rt;
    _states.add(rt);
  }

  List<String> candidatePaths() {
    final override = pathOverride()?.trim() ?? '';
    return [
      if (override.isNotEmpty) override,
      p.join(p.dirname(Platform.resolvedExecutable), 'cloudflared.exe'),
      p.join(downloadDir, 'cloudflared.exe'),
    ];
  }

  Future<String?> findBinary() async {
    for (final path in candidatePaths()) {
      if (path.isEmpty) continue;
      final f = File(path);
      if (await f.exists()) return path;
    }
    final pathEnv = Platform.environment['PATH'] ?? '';
    for (final dir in pathEnv.split(';')) {
      if (dir.trim().isEmpty) continue;
      final f = File(p.join(dir.trim(), 'cloudflared.exe'));
      if (await f.exists()) return f.path;
    }
    return null;
  }

  Future<String> download({void Function(double progress)? onProgress}) async {
    await Directory(downloadDir).create(recursive: true);
    final dest = p.join(downloadDir, 'cloudflared.exe');
    final tmp = '$dest.part';
    _logs.info(LogCategory.tunnel, 'Downloading cloudflared from GitHub releases…');
    final client = http.Client();
    try {
      final resp = await client
          .send(http.Request('GET', Uri.parse(downloadUrl)))
          .timeout(const Duration(minutes: 5));
      if (resp.statusCode != 200) {
        throw TunnelException('Download failed: HTTP ${resp.statusCode}');
      }
      final total = resp.contentLength ?? 0;
      final sink = File(tmp).openWrite();
      var received = 0;
      await resp.stream.forEach((chunk) {
        received += chunk.length;
        sink.add(chunk);
        if (total > 0) onProgress?.call(received / total);
      });
      await sink.flush();
      await sink.close();
      await File(tmp).rename(dest);
      _logs.info(LogCategory.tunnel, 'cloudflared downloaded → $dest');
      return dest;
    } finally {
      client.close();
    }
  }

  Future<void> start({
    required TunnelMode mode,
    required String token,
    required int proxyPort,
    required String? publicHostname,
  }) async {
    await stop();
    _userStopped = false;

    var binary = await findBinary();
    if (binary == null) {
      _set(TunnelRuntime(
          status: TunnelStatus.downloading, mode: mode, downloadProgress: 0));
      try {
        binary = await download(
            onProgress: (pr) => _set(_runtime.copyWith(downloadProgress: pr)));
      } catch (e) {
        _set(TunnelRuntime(
            status: TunnelStatus.error,
            mode: mode,
            error: 'cloudflared not found and download failed: $e'));
        rethrow;
      }
    }

    if (mode == TunnelMode.token) {
      if (token.isEmpty) {
        _set(TunnelRuntime(
            status: TunnelStatus.error,
            mode: mode,
            error: 'Tunnel token is empty — paste it in Settings first.'));
        throw const TunnelException('Tunnel token is empty');
      }
    }

    final args = switch (mode) {
      TunnelMode.token => ['tunnel', '--no-autoupdate', 'run'],
      TunnelMode.quick => [
          'tunnel',
          '--no-autoupdate',
          '--url',
          'http://127.0.0.1:$proxyPort'
        ],
    };

    final hostnameUrl = (publicHostname ?? '').trim().isEmpty
        ? null
        : 'https://${publicHostname!.trim()}';
    _set(TunnelRuntime(
      status: TunnelStatus.starting,
      mode: mode,
      binaryPath: binary,
      publicUrl: mode == TunnelMode.token ? hostnameUrl : null,
    ));
    _logs.info(LogCategory.tunnel, 'Starting cloudflared (${mode.name} mode)…');

    try {
      _proc = await Process.start(
        binary,
        args,
        environment: mode == TunnelMode.token ? {'TUNNEL_TOKEN': token} : null,
      );
    } catch (e) {
      _set(TunnelRuntime(
          status: TunnelStatus.error,
          mode: mode,
          error: 'Failed to launch cloudflared: $e'));
      rethrow;
    }

    _proc!.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(_onLine);
    _proc!.stderr
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(_onLine);

    _proc!.exitCode.then((code) {
      _proc = null;
      if (_userStopped) {
        _set(TunnelRuntime(
            status: TunnelStatus.stopped,
            mode: mode,
            binaryPath: binary,
            publicUrl: _runtime.publicUrl));
        _logs.info(LogCategory.tunnel, 'cloudflared stopped');
      } else {
        _set(TunnelRuntime(
            status: TunnelStatus.error,
            mode: mode,
            binaryPath: binary,
            publicUrl: _runtime.publicUrl,
            error: 'cloudflared exited unexpectedly (code $code)'));
        _logs.error(LogCategory.tunnel, 'cloudflared exited with code $code');
      }
    });
  }

  void _onLine(String line) {
    final trimmed = line.trim();
    if (trimmed.isEmpty) return;
    final isError = trimmed.contains('ERR') || trimmed.contains('FATAL');
    _logs.add(isError ? LogLevel.warn : LogLevel.info, LogCategory.tunnel, trimmed);

    final m = _quickUrl.firstMatch(trimmed);
    if (m != null) {
      _runtime = _runtime.copyWith(publicUrl: m.group(0));
      _states.add(_runtime);
    }
    if (trimmed.contains('Registered tunnel connection')) {
      if (_runtime.status != TunnelStatus.connected) {
        _set(TunnelRuntime(
          status: TunnelStatus.connected,
          mode: _runtime.mode,
          publicUrl: _runtime.publicUrl,
          binaryPath: _runtime.binaryPath,
        ));
        _logs.info(
            LogCategory.tunnel, 'Tunnel connected ✓ ${_runtime.publicUrl ?? ''}');
      }
    }
  }

  Future<void> stop() async {
    _userStopped = true;
    final proc = _proc;
    _proc = null;
    if (proc != null) {
      proc.kill();
    }
    if (_runtime.status != TunnelStatus.idle &&
        _runtime.status != TunnelStatus.stopped) {
      _set(TunnelRuntime(
          status: TunnelStatus.stopped,
          mode: _runtime.mode,
          binaryPath: _runtime.binaryPath,
          publicUrl: _runtime.publicUrl));
    }
  }

  Future<String?> version([String? path]) async {
    final binary = path ?? await findBinary();
    if (binary == null) return null;
    try {
      final r = await Process.run(binary, ['--version']);
      return r.stdout.toString().trim();
    } catch (_) {
      return null;
    }
  }

  void dispose() => _states.close();
}
