import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:proxy_claude/models/model_info.dart';
import 'package:proxy_claude/models/settings.dart';
import 'package:proxy_claude/services/settings_service.dart';
import 'package:proxy_claude/services/tunnel_manager.dart';
import 'package:proxy_claude/state/controllers.dart';
import 'package:proxy_claude/ui/pages/dashboard_page.dart';

// The stubs below reuse the real notifier classes but override `build()` so no
// service has to be initialized inside widget tests.
class StubSettingsNotifier extends SettingsNotifier {
  @override
  AppSettings build() => const AppSettings();
}

class StubProxyNotifier extends ProxyController {
  StubProxyNotifier(this._state);
  final ProxyState _state;

  @override
  ProxyState build() => _state;
}

class StubTunnelNotifier extends TunnelController {
  StubTunnelNotifier(this._runtime);
  final TunnelRuntime _runtime;

  @override
  TunnelRuntime build() => _runtime;
}

class StubSyncNotifier extends SyncController {
  StubSyncNotifier(this._state);
  final SyncState _state;

  @override
  SyncState build() => _state;
}

Widget makeApp({
  required ProxyState proxy,
  required TunnelRuntime tunnel,
  required SyncState sync,
  List<ModelInfo> models = const [],
}) {
  return ProviderScope(
    overrides: [
      settingsServiceProvider.overrideWithValue(SettingsService()),
      settingsNotifierProvider.overrideWith(() => StubSettingsNotifier()),
      proxyControllerProvider.overrideWith(() => StubProxyNotifier(proxy)),
      tunnelControllerProvider.overrideWith(() => StubTunnelNotifier(tunnel)),
      syncControllerProvider.overrideWith(() => StubSyncNotifier(sync)),
      modelsStreamProvider.overrideWith((ref) => Stream.value(models)),
    ],
    child: const MaterialApp(home: DashboardPage()),
  );
}

void main() {
  testWidgets('dashboard shows stopped/disconnected state initially',
      (tester) async {
    await tester.pumpWidget(makeApp(
      proxy: const ProxyState.idle(),
      tunnel: const TunnelRuntime.idle(),
      sync: const SyncState.initial(),
    ));
    await tester.pump();

    expect(find.text('Stopped'), findsOneWidget);
    expect(find.text('Disconnected'), findsOneWidget);
    expect(find.text('Not synced yet'), findsOneWidget);
    expect(find.text('Start Proxy'), findsOneWidget);
    expect(find.text('Connect Tunnel'), findsOneWidget);
  });

  testWidgets('dashboard reflects running proxy + connected tunnel + healthy sync',
      (tester) async {
    await tester.pumpWidget(makeApp(
      proxy: const ProxyState(status: ProxyStatus.running, port: 8080),
      tunnel: const TunnelRuntime(
        status: TunnelStatus.connected,
        publicUrl: 'https://my-tunnel.trycloudflare.com',
      ),
      sync: const SyncState(
        lastSummary: '2/2 providers OK · 42 models (+3/−1)',
      ),
      models: [
        ModelInfo(
            id: 'a:free',
            providerId: 'openrouter',
            providerName: 'OpenRouter',
            isFree: true,
            lastSeen: DateTime(2026, 1, 1)),
      ],
    ));
    await tester.pump();

    expect(find.text('Running'), findsOneWidget);
    expect(find.text('Connected'), findsOneWidget);
    expect(find.text('Stop Proxy'), findsOneWidget);
    expect(find.text('Disconnect Tunnel'), findsOneWidget);
    expect(find.text('2/2 providers OK · 42 models (+3/−1)'), findsOneWidget);
    // The public URL is shown on both the tunnel status card and endpoints card.
    expect(find.text('https://my-tunnel.trycloudflare.com'), findsWidgets);
  });

  testWidgets('dashboard surfaces proxy errors', (tester) async {
    await tester.pumpWidget(makeApp(
      proxy: const ProxyState(
          status: ProxyStatus.error,
          port: 8080,
          error: 'Port already in use'),
      tunnel: const TunnelRuntime(
          status: TunnelStatus.error, error: 'cloudflared not found'),
      sync: const SyncState.initial(),
    ));
    await tester.pump();

    expect(find.text('Error'), findsNWidgets(2));
    expect(find.textContaining('Port already in use'), findsOneWidget);
    expect(find.textContaining('cloudflared not found'), findsOneWidget);
  });
}
