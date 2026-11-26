import 'dart:async';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import '../models/log_entry.dart';
import '../models/model_info.dart';
import '../models/provider_config.dart';
import '../models/settings.dart';
import '../services/chat_proxy_core.dart';
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
    if (idx >= 0) {
      svc.providers[idx] = p;
    } else {
      svc.providers.add(p);
    }
    if (apiKey != null) await svc.setProviderApiKey(p.id, apiKey);
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
    final providers =
        ref.read(providersProvider).where((p) => p.enabled).toList();

    state = SyncState(
      syncing: true,
      lastSyncAt: state.lastSyncAt,
      nextSyncAt: state.nextSyncAt,
      health: state.health,
      lastSummary: state.lastSummary,
    );

    if (providers.isEmpty) {
      state = state.copyWith(syncing: false, lastSummary: 'No providers enabled');
      return;
    }

    logs.info(LogCategory.sync, 'Syncing models from ${providers.length} provider(s)…');
    try {
      final report = await registry.syncAll(providers, upstream: upstream);
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
      final okCount = report.entries.where((e) => e.ok).length;
      final summary = '$okCount/${report.entries.length} providers OK · '
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
