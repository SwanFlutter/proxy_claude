import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:window_manager/window_manager.dart';
import 'app.dart';
import 'services/log_service.dart';
import 'services/model_registry.dart';
import 'services/settings_service.dart';
import 'services/tunnel_manager.dart';
import 'state/controllers.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await windowManager.ensureInitialized();

  final supportDir = await getApplicationSupportDirectory();

  // Load persisted settings + provider configs (+ secrets from secure storage).
  final settingsService = SettingsService();
  await settingsService.load();

  final logs = LogService();
  logs.system('LLM Proxy Hub starting…');

  // Restore the persisted routing cache so /v1/models works immediately.
  final registry = ModelRegistry(
    logs,
    cacheDir: p.join(supportDir.path, 'model_cache'),
  );
  await registry.loadCache();
  registry.notifyListeners();

  final tunnelManager = TunnelManager(
    logs,
    downloadDir: p.join(supportDir.path, 'bin'),
    pathOverride: () => settingsService.appSettings.cloudflaredPath,
  );

  runApp(ProviderScope(
    overrides: [
      logServiceProvider.overrideWithValue(logs),
      settingsServiceProvider.overrideWithValue(settingsService),
      registryProvider.overrideWithValue(registry),
      tunnelManagerProvider.overrideWithValue(tunnelManager),
    ],
    child: const ProxyHubApp(),
  ));
}
