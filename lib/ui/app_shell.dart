import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../state/controllers.dart';
import 'pages/dashboard_page.dart';
import 'pages/logs_page.dart';
import 'pages/models_page.dart';
import 'pages/providers_page.dart';
import 'pages/settings_page.dart';
import 'widgets/common.dart';

class AppShell extends ConsumerStatefulWidget {
  const AppShell({super.key});

  @override
  ConsumerState<AppShell> createState() => _AppShellState();
}

class _AppShellState extends ConsumerState<AppShell> {
  int _index = 0;

  static const _destinations = [
    (icon: Icons.speed_outlined, selected: Icons.speed, label: 'Dashboard'),
    (icon: Icons.dns_outlined, selected: Icons.dns, label: 'Providers'),
    (icon: Icons.memory_outlined, selected: Icons.memory, label: 'Models'),
    (icon: Icons.receipt_long_outlined, selected: Icons.receipt_long, label: 'Logs'),
    (icon: Icons.tune_outlined, selected: Icons.tune, label: 'Settings'),
  ];

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(settingsNotifierProvider);
    final proxy = ref.watch(proxyControllerProvider);

    return Scaffold(
      appBar: AppBar(
        titleSpacing: 16,
        title: Row(
          children: [
            Text('LLM Proxy Hub',
                style: Theme.of(context)
                    .textTheme
                    .titleMedium
                    ?.copyWith(fontWeight: FontWeight.w700)),
            const SizedBox(width: 10),
            StatusDot(
              color: switch (proxy.status) {
                ProxyStatus.running => Colors.green,
                ProxyStatus.starting => Colors.orange,
                ProxyStatus.error => Theme.of(context).colorScheme.error,
                ProxyStatus.stopped => Colors.grey,
              },
            ),
          ],
        ),
        actions: [
          IconButton(
            tooltip: 'Toggle theme',
            icon: Icon(switch (settings.themeMode) {
              ThemeMode.system => Icons.brightness_auto_outlined,
              ThemeMode.light => Icons.light_mode_outlined,
              ThemeMode.dark => Icons.dark_mode_outlined,
            }),
            onPressed: () {
              final next = switch (settings.themeMode) {
                ThemeMode.system => ThemeMode.light,
                ThemeMode.light => ThemeMode.dark,
                ThemeMode.dark => ThemeMode.system,
              };
              ref.read(settingsNotifierProvider.notifier).update(
                  settings.copyWith(themeMode: next));
            },
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: Row(
        children: [
          NavigationRail(
            selectedIndex: _index,
            onDestinationSelected: (i) => setState(() => _index = i),
            labelType: NavigationRailLabelType.all,
            minWidth: 72,
            destinations: [
              for (final d in _destinations)
                NavigationRailDestination(
                  icon: Icon(d.icon),
                  selectedIcon: Icon(d.selected),
                  label: Text(d.label),
                ),
            ],
          ),
          const VerticalDivider(width: 1),
          Expanded(
            child: IndexedStack(
              index: _index,
              children: const [
                DashboardPage(),
                ProvidersPage(),
                ModelsPage(),
                LogsPage(),
                SettingsPage(),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
