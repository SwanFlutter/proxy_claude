import 'dart:async';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import '../models/log_entry.dart';
import '../models/model_info.dart';
import '../models/provider_config.dart';
import '../models/settings.dart';
import '../services/chat_proxy_core.dart';
import '../services/claude_code_config.dart';
import '../services/log_service.dart';
import '../services/model_registry.dart';
import '../services/proxy_server.dart';
import '../services/settings_service.dart';
import '../services/tunnel_manager.dart';
import '../services/upstream_client.dart';

// ── Service providers ────────────────────────────────────────────────────────
// Most are overridden with pre-built instances at app bootstrap (main.dart).

final logServiceProvider = Provider<LogService>((ref) => LogService());

final settingsServiceProvider = Provider<SettingsService>(
    (ref) => throw StateError('SettingsService not initialized'));

final registryProvider = Provider<ModelRegistry>(
    (ref) => throw StateError('ModelRegistry not initialized'));

final tunnelManagerProvider = Provider<TunnelManager>(
    (ref) => throw StateError('TunnelManager not initialized'));

final upstreamClientProvider =
    Provider<UpstreamClient>((ref) => UpstreamClient(http.Client()));

final chatCoreProvider = Provider<ChatProxyCore>((ref) {
  final svc = ref.watch(settingsServiceProvider);
  return ChatProxyCore(
    registry: ref.watch(registryProvider),
    logs: ref.watch(logServiceProvider),
    upstream: ref.watch(upstreamClientProvider),
    enabledProviders: () => svc.enabledProviders,
    defaultModel: () => svc.appSettings.defaultModel,
    smartTaskRouting: () => svc.appSettings.smartTaskRouting,
  );
});

final proxyServerProvider = Provider<ProxyServer>((ref) {
  final server = ProxyServer(
    logs: ref.watch(logServiceProvider),
    core: ref.watch(chatCoreProvider),
    settings: ref.watch(settingsServiceProvider),
    registry: ref.watch(registryProvider),
  );
  ref.onDispose(() => server.stop());
  return server;
});

// ── Settings & providers config ──────────────────────────────────────────────

class SettingsNotifier extends Notifier<AppSettings> {
  @override
  AppSettings build() => ref.watch(settingsServiceProvider).appSettings;

  void update(AppSettings next) {
    final svc = ref.read(settingsServiceProvider);
    svc.appSettings = next;
    svc.saveSettings();
    state = next;
  }
}

final settingsNotifierProvider =
    NotifierProvider<SettingsNotifier, AppSettings>(SettingsNotifier.new);

class ProvidersNotifier extends Notifier<List<ProviderConfig>> {
  @override
  List<ProviderConfig> build() => ref.watch(settingsServiceProvider).providers;

  Future<void> upsert(ProviderConfig p, {String? apiKey}) async {
    final svc = ref.read(settingsServiceProvider);
    final idx = svc.providers.indexWhere((e) => e.id == p.id);
    // A freshly connected provider joins routing **immediately** — no separate
    // "enabled" switch to flip. Editing an existing record keeps whatever the
    // user had set it to.
    final record = idx >= 0 ? p : p.copyWith(enabled: true);
    if (idx >= 0) {
      svc.providers[idx] = record;
    } else {
      svc.providers.add(record);
    }
    if (apiKey != null) await svc.setProviderApiKey(p.id, apiKey);
    await svc.saveProviders();
    state = [...svc.providers];
  }

  /// Turns every configured provider on (routing pool = all of them).
  Future<void> setEnabledAll(bool enabled) async {
    final svc = ref.read(settingsServiceProvider);
    if (svc.providers.every((p) => p.enabled == enabled)) return;
    svc.providers = [
      for (final p in svc.providers) p.copyWith(enabled: enabled),
    ];
    await svc.saveProviders();
    state = [...svc.providers];
  }

  Future<void> remove(String id) async {
    final svc = ref.read(settingsServiceProvider);
    svc.providers = svc.providers.where((p) => p.id != id).toList();
    await svc.saveProviders();
    state = [...svc.providers];
  }

  Future<void> setEnabled(String id, bool enabled) async {
    final svc = ref.read(settingsServiceProvider);
    final idx = svc.providers.indexWhere((p) => p.id == id);
    if (idx >= 0) {
      svc.providers[idx] = svc.providers[idx].copyWith(enabled: enabled);
      await svc.saveProviders();
      state = [...svc.providers];
    }
  }
}

final providersProvider =
    NotifierProvider<ProvidersNotifier, List<ProviderConfig>>(
        ProvidersNotifier.new);

// ── Proxy controller ─────────────────────────────────────────────────────────

enum ProxyStatus { stopped, starting, running, error }

class ProxyState {
  final ProxyStatus status;
  final String host;
  final int port;
  final String? error;
  final DateTime? startedAt;

  const ProxyState({
    this.status = ProxyStatus.stopped,
    this.host = '127.0.0.1',
    this.port = 8080,
    this.error,
    this.startedAt,
  });

  const ProxyState.idle() : this();
}

class ProxyController extends Notifier<ProxyState> {
  @override
  ProxyState build() => const ProxyState.idle();

  Future<void> start() async {
    final svc = ref.read(settingsServiceProvider);
    final s = svc.appSettings;
    final host = s.bindLan ? '0.0.0.0' : '127.0.0.1';
    state = ProxyState(status: ProxyStatus.starting, host: host, port: s.port);
    try {
      await ref.read(proxyServerProvider).start(host: host, port: s.port);
      state = ProxyState(
          status: ProxyStatus.running,
          host: host,
          port: s.port,
          startedAt: DateTime.now());
      ref.read(logServiceProvider).info(LogCategory.system,
          'Proxy running → http://${host == '0.0.0.0' ? '127.0.0.1' : host}:${s.port}/v1');
    } catch (e) {
      state = ProxyState(
          status: ProxyStatus.error, host: host, port: s.port, error: '$e');
      ref.read(logServiceProvider).error(LogCategory.system, 'Proxy failed to start: $e');
    }
  }

  Future<void> stop() async {
    await ref.read(proxyServerProvider).stop();
    ref.read(logServiceProvider).info(LogCategory.system, 'Proxy stopped');
    state = const ProxyState.idle();
  }

  Future<void> restart() async {
    await stop();
    await start();
  }
}

final proxyControllerProvider =
    NotifierProvider<ProxyController, ProxyState>(ProxyController.new);

// ── Tunnel controller ────────────────────────────────────────────────────────

class TunnelController extends Notifier<TunnelRuntime> {
  StreamSubscription<TunnelRuntime>? _sub;
  bool _disposed = false;

  @override
  TunnelRuntime build() {
    ref.onDispose(() {
      _disposed = true;
      _sub?.cancel();
    });
    return ref.watch(tunnelManagerProvider).runtime;
  }

  void _listen() {
    _sub ??= ref.read(tunnelManagerProvider).states.listen((rt) {
      if (!_disposed) state = rt;
    });
  }

  Future<void> connect() async {
    _listen();
    final svc = ref.read(settingsServiceProvider);
    final s = svc.appSettings;
    try {
      await ref.read(tunnelManagerProvider).start(
            mode: s.tunnelMode,
            token: svc.tunnelToken,
            proxyPort: s.port,
            publicHostname: s.publicHostname,
          );
    } catch (e) {
      if (!_disposed) {
        ref.read(logServiceProvider).error(LogCategory.tunnel, 'Tunnel start failed: $e');
      }
    }
  }

  Future<void> disconnect() async {
    await ref.read(tunnelManagerProvider).stop();
  }

  Future<void> downloadBinary() async {
    _listen();
    final mgr = ref.read(tunnelManagerProvider);
    state = TunnelRuntime(
        status: TunnelStatus.downloading,
        mode: state.mode,
        downloadProgress: 0);
    try {
      final path = await mgr.download(onProgress: (pr) {
        if (!_disposed) state = state.copyWith(downloadProgress: pr);
      });
      if (!_disposed) {
        state = TunnelRuntime(
            status: TunnelStatus.stopped,
            mode: state.mode,
            binaryPath: path);
      }
    } catch (e) {
      if (!_disposed) {
        state = TunnelRuntime(
            status: TunnelStatus.error, mode: state.mode, error: 'Download failed: $e');
      }
    }
  }
}

final tunnelControllerProvider =
    NotifierProvider<TunnelController, TunnelRuntime>(TunnelController.new);

// ── Sync controller ──────────────────────────────────────────────────────────

class ProviderHealth {
  final bool ok;
  final int modelCount;
  final String? error;
  final int added;
  final int removed;

  const ProviderHealth({
    required this.ok,
    required this.modelCount,
    this.error,
    this.added = 0,
    this.removed = 0,
  });
}

class SyncState {
  final bool syncing;
  final DateTime? lastSyncAt;
  final DateTime? nextSyncAt;
  final Map<String, ProviderHealth> health;
  final String? lastError;
  final String? lastSummary;

  const SyncState({
    this.syncing = false,
    this.lastSyncAt,
    this.nextSyncAt,
    this.health = const {},
    this.lastError,
    this.lastSummary,
  });

  const SyncState.initial() : this();

  SyncState copyWith({
    bool? syncing,
    DateTime? lastSyncAt,
    DateTime? nextSyncAt,
    Map<String, ProviderHealth>? health,
    String? lastError,
    String? lastSummary,
  }) =>
      SyncState(
        syncing: syncing ?? this.syncing,
        lastSyncAt: lastSyncAt ?? this.lastSyncAt,
        nextSyncAt: nextSyncAt ?? this.nextSyncAt,
        health: health ?? this.health,
        lastError: lastError ?? this.lastError,
        lastSummary: lastSummary ?? this.lastSummary,
      );
}

class SyncController extends Notifier<SyncState> {
  Timer? _timer;

  @override
  SyncState build() {
    ref.onDispose(() => _timer?.cancel());
    return const SyncState.initial();
  }

  void startAuto() {
    _timer?.cancel();
    final s = ref.read(settingsNotifierProvider);
    if (!s.autoSync || s.syncIntervalMinutes <= 0) return;
    _timer = Timer.periodic(
        Duration(minutes: s.syncIntervalMinutes), (_) => syncNow());
    state = state.copyWith(
        nextSyncAt: DateTime.now().add(Duration(minutes: s.syncIntervalMinutes)));
  }

  Future<void> syncNow() async {
    if (state.syncing) return;
    final registry = ref.read(registryProvider);
    final upstream = ref.read(upstreamClientProvider);
    final logs = ref.read(logServiceProvider);
    final enabled =
        ref.read(providersProvider).where((p) => p.enabled).toList();
    // Providers without any credential cannot be listed: they are reported with
    // an explicit reason instead of silently showing up as "0 models".
    final providers = enabled.where((p) => !p.needsApiKey).toList();
    final blocked = enabled.where((p) => p.needsApiKey).toList();

    state = SyncState(
      syncing: true,
      lastSyncAt: state.lastSyncAt,
      nextSyncAt: state.nextSyncAt,
      health: state.health,
      lastSummary: state.lastSummary,
    );

    if (enabled.isEmpty) {
      state = state.copyWith(syncing: false, lastSummary: 'No providers enabled');
      return;
    }

    if (providers.isNotEmpty) {
      logs.info(LogCategory.sync, 'Syncing models from ${providers.length} provider(s)…');
    }
    for (final p in blocked) {
      logs.warn(LogCategory.sync,
          '${p.name}: skipped — no API key configured (open Providers and paste the key)');
    }
    try {
      final report = providers.isEmpty
          ? const SyncReport(entries: [])
          : await registry.syncAll(providers, upstream: upstream);
      final health = <String, ProviderHealth>{};
      for (final e in report.entries) {
        health[e.providerId] = ProviderHealth(
          ok: e.ok,
          modelCount: e.modelCount,
          error: e.error,
          added: e.added.length,
          removed: e.removed.length,
        );
      }
      for (final p in blocked) {
        health[p.id] = const ProviderHealth(
          ok: false,
          modelCount: 0,
          error: 'No API key configured',
        );
      }
      final okCount = report.entries.where((e) => e.ok).length;
      final summary = '$okCount/${report.entries.length} providers OK'
          '${blocked.isNotEmpty ? ' · ${blocked.length} need a key' : ''} · '
          '${registry.count} models (+${report.addedTotal}/−${report.removedTotal})';
      final interval = ref.read(settingsNotifierProvider).syncIntervalMinutes;
      state = SyncState(
        syncing: false,
        lastSyncAt: DateTime.now(),
        nextSyncAt: interval > 0
            ? DateTime.now().add(Duration(minutes: interval))
            : null,
        health: health,
        lastSummary: summary,
      );
      logs.info(LogCategory.sync, 'Sync complete: $summary');
      for (final e in report.entries.where((e) => !e.ok)) {
        logs.error(LogCategory.sync, '${e.providerName}: ${e.error}');
      }
    } catch (e) {
      state = SyncState(
        syncing: false,
        lastSyncAt: state.lastSyncAt,
        health: state.health,
        lastError: '$e',
        lastSummary: state.lastSummary,
      );
      logs.error(LogCategory.sync, 'Sync failed: $e');
    }
  }
}

final syncControllerProvider =
    NotifierProvider<SyncController, SyncState>(SyncController.new);

// ── Model stream ─────────────────────────────────────────────────────────────

final modelsStreamProvider =
    StreamProvider<List<ModelInfo>>((ref) => ref.watch(registryProvider).changes);

// ── Claude Code integration ───────────────────────────────────────────────
//
// Everything Claude Code needs (URL + proxy key + model names) is written into
// Claude Code's own settings.json from inside the app, and kept in sync when the
// tunnel URL changes — a quick tunnel gets a brand new host on every start, so
// a hand-edited file breaks on the next restart.

class ClaudeCodeState {
  final String path;
  final String baseUrl;
  final bool usingTunnel;
  final bool tunnelReady;
  final bool busy;
  final ClaudeInstallState install;
  final List<String> lastChanges;
  final String? backupPath;
  final String? error;

  const ClaudeCodeState({
    this.path = '',
    this.baseUrl = '',
    this.usingTunnel = false,
    this.tunnelReady = false,
    this.busy = false,
    this.install = const ClaudeInstallState(exists: false, installed: false),
    this.lastChanges = const [],
    this.backupPath,
    this.error,
  });

  ClaudeCodeState copyWith({
    String? path,
    String? baseUrl,
    bool? usingTunnel,
    bool? tunnelReady,
    bool? busy,
    ClaudeInstallState? install,
    List<String>? lastChanges,
    Object? backupPath = _noValue,
    Object? error = _noValue,
  }) =>
      ClaudeCodeState(
        path: path ?? this.path,
        baseUrl: baseUrl ?? this.baseUrl,
        usingTunnel: usingTunnel ?? this.usingTunnel,
        tunnelReady: tunnelReady ?? this.tunnelReady,
        busy: busy ?? this.busy,
        install: install ?? this.install,
        lastChanges: lastChanges ?? this.lastChanges,
        backupPath: backupPath == _noValue ? this.backupPath : backupPath as String?,
        error: error == _noValue ? this.error : error as String?,
      );

  bool get upToDate => install.upToDate && install.baseUrl == baseUrl;
}

const _noValue = Object();

class ClaudeCodeController extends Notifier<ClaudeCodeState> {
  /// Notifier has no `mounted`; guard the async write paths ourselves.
  bool _alive = true;

  @override
  ClaudeCodeState build() {
    _alive = true;
    ref.onDispose(() => _alive = false);
    // Reactive: rebuilds when the tunnel URL or the settings change.
    final s = ref.watch(settingsNotifierProvider);
    final t = ref.watch(tunnelControllerProvider);
    final plan = _planFor(s, t);
    return ClaudeCodeState(
      path: plan.path,
      baseUrl: plan.baseUrl,
      usingTunnel: plan.useTunnel,
      tunnelReady: plan.tunnelReady,
    );
  }

  /// Where Claude Code should point, and whether that target actually exists.
  ({String path, String baseUrl, bool useTunnel, bool tunnelReady}) _planFor(
      AppSettings s, TunnelRuntime t) {
    final ready = t.publicUrl != null && t.publicUrl!.isNotEmpty;
    final useTunnel = s.claudeCodeUseTunnel;
    return (
      path: ClaudeCodeConfig.resolvePath(s.claudeCodePath),
      baseUrl: useTunnel && ready
          ? t.publicUrl!
          : 'http://127.0.0.1:${s.port}',
      useTunnel: useTunnel,
      tunnelReady: ready,
    );
  }

  /// The exact env block this app would write for [baseUrl].
  /// Non-reactive variant for use inside async methods.
  ({String path, String baseUrl, bool useTunnel, bool tunnelReady}) _plan() =>
      _planFor(ref.read(settingsNotifierProvider),
          ref.read(tunnelControllerProvider));

  Map<String, String> _expected(String baseUrl) {
    final svc = ref.read(settingsServiceProvider);
    return ClaudeCodeConfig.envFor(
      baseUrl: baseUrl,
      authToken: svc.localApiKey,
      autoModels: svc.appSettings.claudeCodeAutoModels,
    );
  }

  Future<void> refresh() async {
    final plan = _plan();
    final current = await ClaudeCodeConfig.inspect(plan.path,
        expected: _expected(plan.baseUrl));
    if (!_alive) return;
    state = state.copyWith(
      path: plan.path,
      baseUrl: plan.baseUrl,
      usingTunnel: plan.useTunnel,
      tunnelReady: plan.tunnelReady,
      install: current,
    );
  }

  /// Writes the config. Returns null when the file was already correct.
  Future<ClaudeWriteResult?> apply({String? reason}) async {
    final plan = _plan();
    if (plan.useTunnel && !plan.tunnelReady) {
      state = state.copyWith(
          error: 'Tunnel is not connected yet — start it below (or switch to '
              'the local URL) before writing the config.');
      return null;
    }
    state = state.copyWith(busy: true, error: null);
    try {
      final env = _expected(plan.baseUrl);
      final result = await ClaudeCodeConfig.write(path: plan.path, env: env);
      final inspect =
          await ClaudeCodeConfig.inspect(plan.path, expected: env);
      if (!_alive) return result;
      state = state.copyWith(
        busy: false,
        path: plan.path,
        baseUrl: plan.baseUrl,
        usingTunnel: plan.useTunnel,
        tunnelReady: plan.tunnelReady,
        install: inspect,
        lastChanges: result.changes,
        backupPath: result.backupPath,
      );
      if (result.changed) {
        ref.read(logServiceProvider).info(
            LogCategory.request,
            'Claude Code config ${reason ?? 'updated'} → ${plan.path}'
                '${result.backupPath == null ? '' : ' (backup: ${result.backupPath})'}\n'
                '${result.changes.join('\n')}');
      }
      return result.changed ? result : null;
    } catch (e) {
      if (_alive) state = state.copyWith(busy: false, error: '$e');
      return null;
    }
  }

  Future<ClaudeWriteResult?> remove() async {
    state = state.copyWith(busy: true, error: null);
    try {
      final plan = _plan();
      final result = await ClaudeCodeConfig.remove(path: plan.path);
      final inspect = await ClaudeCodeConfig.inspect(plan.path,
          expected: _expected(plan.baseUrl));
      if (!_alive) return result;
      state = state.copyWith(
        busy: false,
        install: inspect,
        lastChanges: result.changes,
        backupPath: result.backupPath,
      );
      ref.read(logServiceProvider).info(LogCategory.request,
          'Claude Code config cleaned → ${plan.path} (${result.changes.length} key(s))');
      return result;
    } catch (e) {
      if (_alive) state = state.copyWith(busy: false, error: '$e');
      return null;
    }
  }

  /// Called when the tunnel (re)connects: refresh, and rewrite when it is on.
  Future<void> syncAfterTunnelChange() async {
    await refresh();
    if (!ref.read(settingsNotifierProvider).claudeCodeKeepInSync) return;
    if (state.upToDate) return;
    if (state.usingTunnel && !state.tunnelReady) return;
    await apply(reason: 'auto-synced with the tunnel URL');
  }

  /// Starts the Cloudflare tunnel and waits (max ~25s) for its public URL.
  /// Claude Code over the tunnel is useless without it.
  Future<bool> ensureTunnel() async {
    final tunnel = ref.read(tunnelControllerProvider.notifier);
    if (!state.tunnelReady) await tunnel.connect();
    for (var i = 0; i < 50; i++) {
      await refresh();
      if (state.tunnelReady) return true;
      await Future<void>.delayed(const Duration(milliseconds: 500));
    }
    if (_alive) {
      state = state.copyWith(
          error: 'The tunnel did not report a public URL. Open Settings → '
              'Cloudflare Tunnel and check the logs.');
    }
    return false;
  }

  /// Write Claude Code's config, starting the tunnel first when it is the
  /// selected target.
  Future<ClaudeWriteResult?> install() async {
    if (state.usingTunnel && !state.tunnelReady) {
      if (!await ensureTunnel()) return null;
    }
    return apply(reason: 'installed from the app');
  }
}

final claudeCodeControllerProvider =
    NotifierProvider<ClaudeCodeController, ClaudeCodeState>(
        ClaudeCodeController.new);

/// Watches the tunnel + settings and keeps Claude Code's settings.json aligned
/// while the app runs (also alive when the window is hidden in the tray).
/// Rewrites only when the **target** changed, so a hand-edit is never stomped
/// on every keystroke.
final claudeCodeAutoSyncProvider = Provider<void>((ref) {
  String? lastTarget;
  var queued = false;

  Future<void> check(String reason) async {
    if (queued) return;
    queued = true;
    try {
      final settings = ref.read(settingsNotifierProvider);
      if (!settings.claudeCodeKeepInSync) return;
      final controller = ref.read(claudeCodeControllerProvider.notifier);
      await controller.refresh();
      final st = ref.read(claudeCodeControllerProvider);
      if (st.usingTunnel && !st.tunnelReady) return; // keep the last good URL
      // First observation: adopt whatever is live without writing yet.
      lastTarget ??= st.baseUrl;
      if (st.upToDate || lastTarget == st.baseUrl) return;
      lastTarget = st.baseUrl;
      await controller.apply(reason: reason);
    } finally {
      queued = false;
    }
  }

  ref.listen(tunnelControllerProvider, (prev, next) {
    if (prev?.publicUrl == next.publicUrl && prev?.status == next.status) return;
    check('tunnel ${next.publicUrl == null ? 'stopped' : 'moved'} → auto-sync');
  });
  ref.listen(settingsNotifierProvider, (prev, next) {
    if (prev?.port == next.port &&
        prev?.claudeCodePath == next.claudeCodePath &&
        prev?.claudeCodeUseTunnel == next.claudeCodeUseTunnel &&
        prev?.claudeCodeAutoModels == next.claudeCodeAutoModels) {
      return;
    }
    check('settings changed → auto-sync');
  });
  check('startup');
});
