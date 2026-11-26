// tray_manager 0.8.x deprecated its classic API (see import below) — the
// deprecation infos are expected here until a native-API migration.
// ignore_for_file: deprecated_member_use

import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
// The classic API used here is provided by the documented legacy bridge.
import 'package:tray_manager/legacy.dart';
import 'package:window_manager/window_manager.dart';
import 'core/utils.dart';
import 'models/log_entry.dart';
import 'state/controllers.dart';
import 'ui/app_shell.dart';
import 'ui/theme.dart';

class ProxyHubApp extends ConsumerStatefulWidget {
  const ProxyHubApp({super.key});

  @override
  ConsumerState<ProxyHubApp> createState() => _ProxyHubAppState();
}

class _ProxyHubAppState extends ConsumerState<ProxyHubApp>
    with WindowListener, TrayListener {
  bool _bootstrapped = false;

  @override
  void initState() {
    super.initState();
    windowManager.addListener(this);
    trayManager.addListener(this);
    _initWindow();
    // Bootstrap AFTER the first frame. Notifier methods (start/syncNow) write
    // state synchronously — running them from initState would mutate provider
    // state mid-build and trip ProviderScope's '!_dirty' assertion.
    WidgetsBinding.instance.addPostFrameCallback((_) => _bootstrap());
  }

  Future<void> _initWindow() async {
    await windowManager.waitUntilReadyToShow(
      const WindowOptions(
        size: Size(1180, 760),
        minimumSize: Size(980, 620),
        center: true,
        title: 'LLM Proxy Hub',
        titleBarStyle: TitleBarStyle.normal,
      ),
      () async {
        await windowManager.show();
        await windowManager.focus();
        await windowManager.setPreventClose(true);
      },
    );
  }

  @override
  void dispose() {
    windowManager.removeListener(this);
    trayManager.removeListener(this);
    super.dispose();
  }

  Future<void> _bootstrap() async {
    if (_bootstrapped || !mounted) return;
    _bootstrapped = true;

    // Capture the container once. `ref`/context ancestor lookups are unsafe
    // across asynchronous gaps (deactivated-element assertion), while a
    // container handle stays valid independently of the element tree.
    final container = ProviderScope.containerOf(context, listen: false);
    final svc = container.read(settingsServiceProvider);
    final settings = svc.appSettings;

    if (settings.startProxyOnLaunch) {
      await container.read(proxyControllerProvider.notifier).start();
      if (!mounted) return;
    }
    container.read(syncControllerProvider.notifier).startAuto();
    await container.read(syncControllerProvider.notifier).syncNow();
    if (!mounted) return;

    if (settings.minimizeToTray) {
      await _setupTray(container);
    }
  }

  Future<void> _setupTray(ProviderContainer container) async {
    try {
      final iconPath = bundledAssetPath(p.join('assets', 'icon', 'icon.ico'));
      if (File(iconPath).existsSync()) {
        await trayManager.setIcon(iconPath);
      }
      await trayManager.setToolTip('LLM Proxy Hub');
      await trayManager.setContextMenu(Menu(items: [
        MenuItem(key: 'show', label: 'Show window'),
        MenuItem(key: 'exit', label: 'Exit'),
      ]));
    } catch (e) {
      container.read(logServiceProvider).warn(
          LogCategory.system, 'Tray unavailable: $e');
    }
  }

  // ── Window events ──────────────────────────────────────────────────────────

  @override
  void onWindowClose() async {
    final minimize = ref.read(settingsNotifierProvider).minimizeToTray;
    if (minimize) {
      await windowManager.hide();
    } else {
      await windowManager.setPreventClose(false);
      await windowManager.destroy();
    }
  }

  // ── Tray events ────────────────────────────────────────────────────────────

  @override
  void onTrayIconMouseDown() {
    windowManager.show();
    windowManager.focus();
  }

  @override
  void onTrayIconRightMouseDown() {
    trayManager.popUpContextMenu();
  }

  @override
  void onTrayMenuItemClick(MenuItem item) {
    switch (item.key) {
      case 'show':
        windowManager.show();
        windowManager.focus();
        break;
      case 'exit':
        windowManager.setPreventClose(false).then((_) => windowManager.destroy());
        break;
    }
  }

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(settingsNotifierProvider);
    return MaterialApp(
      title: 'LLM Proxy Hub',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light,
      darkTheme: AppTheme.dark,
      themeMode: settings.themeMode,
      home: const AppShell(),
    );
  }
}
