import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/model_router.dart';
import '../../models/log_entry.dart';
import '../../models/settings.dart';
import '../../services/log_service.dart';
import '../../services/tunnel_manager.dart' show TunnelRuntime, TunnelStatus;
import '../../state/controllers.dart';
import '../widgets/common.dart';

class DashboardPage extends ConsumerWidget {
  const DashboardPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final proxy = ref.watch(proxyControllerProvider);
    final tunnel = ref.watch(tunnelControllerProvider);
    final sync = ref.watch(syncControllerProvider);
    final settings = ref.watch(settingsNotifierProvider);
    final models = ref.watch(modelsStreamProvider).value ?? const [];
    final freeCount = models.where((m) => m.isFree).length;
    final logs = ref.watch(logServiceProvider);

    final okProviders = sync.health.values.where((h) => h.ok).length;
    final totalProviders = sync.health.length;

    // What the virtual `auto` model currently has to choose from.
    final providerIds = models.map((m) => m.providerId).toSet();
    final strongCount =
        models.where((m) => ModelCapability.tier(m) == ModelTier.strong).length;
    final balancedCount = models
        .where((m) => ModelCapability.tier(m) == ModelTier.balanced)
        .length;
    final lightCount =
        models.where((m) => ModelCapability.tier(m) == ModelTier.light).length;
    final autoPool = providerIds.isEmpty
        ? 'No models synced yet'
        : '${providerIds.length} provider(s) · $strongCount strong · '
            '$balancedCount balanced · $lightCount light';

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Wrap(
          spacing: 12,
          runSpacing: 12,
          children: [
            _StatusCard(
              width: 258,
              icon: Icons.dns,
              label: 'Proxy',
              value: switch (proxy.status) {
                ProxyStatus.stopped => 'Stopped',
                ProxyStatus.starting => 'Starting…',
                ProxyStatus.running => 'Running',
                ProxyStatus.error => 'Error',
              },
              subline: proxy.status == ProxyStatus.running
                  ? 'http://${proxy.host == '0.0.0.0' ? '127.0.0.1' : proxy.host}:${proxy.port}/v1'
                  : (proxy.error ?? 'Port ${settings.port}'),
              color: switch (proxy.status) {
                ProxyStatus.running => Colors.green,
                ProxyStatus.starting => Colors.orange,
                ProxyStatus.error => Theme.of(context).colorScheme.error,
                ProxyStatus.stopped => Colors.grey,
              },
            ),
            _StatusCard(
              width: 258,
              icon: Icons.cloud_outlined,
              label: 'Tunnel',
              value: switch (tunnel.status) {
                TunnelStatus.idle || TunnelStatus.stopped => 'Disconnected',
                TunnelStatus.downloading => 'Downloading…',
                TunnelStatus.starting => 'Connecting…',
                TunnelStatus.connected => 'Connected',
                TunnelStatus.error => 'Error',
              },
              subline: tunnel.error ??
                  tunnel.publicUrl ??
                  switch (settings.tunnelMode) {
                    TunnelMode.token => settings.publicHostname.isEmpty
                        ? 'Token mode — hostname not set'
                        : settings.publicHostname,
                    TunnelMode.quick => 'Quick tunnel',
                  },
              color: switch (tunnel.status) {
                TunnelStatus.connected => Colors.green,
                TunnelStatus.starting || TunnelStatus.downloading => Colors.orange,
                TunnelStatus.error => Theme.of(context).colorScheme.error,
                TunnelStatus.idle || TunnelStatus.stopped => Colors.grey,
              },
            ),
            _StatusCard(
              width: 258,
              icon: Icons.sync,
              label: 'Model Sync',
              value: sync.syncing
                  ? 'Syncing…'
                  : (sync.lastSummary ?? 'Not synced yet'),
              subline: sync.lastSyncAt == null
                  ? (sync.lastError ?? 'Auto-sync every ${settings.syncIntervalMinutes} min')
                  : 'Last: ${TimeOfDay.fromDateTime(sync.lastSyncAt!).format(context)}'
                    '${sync.nextSyncAt != null ? ' · next ${TimeOfDay.fromDateTime(sync.nextSyncAt!).format(context)}' : ''}',
              color: sync.syncing
                  ? Colors.orange
                  : (sync.lastError != null
                      ? Theme.of(context).colorScheme.error
                      : (sync.lastSyncAt != null ? Colors.green : Colors.grey)),
              busy: sync.syncing,
            ),
            _StatusCard(
              width: 258,
              icon: Icons.category_outlined,
              label: 'Providers',
              value: totalProviders == 0
                  ? '—'
                  : '$okProviders/$totalProviders healthy',
              subline: '${models.length} models cached · $freeCount free',
              color: totalProviders == 0
                  ? Colors.grey
                  : (okProviders == totalProviders
                      ? Colors.green
                      : (okProviders == 0
                          ? Theme.of(context).colorScheme.error
                          : Colors.orange)),
            ),
          ],
        ),
        const SizedBox(height: 12),
        _EndpointsCard(
            proxy: proxy,
            tunnel: tunnel,
            settings: settings,
            autoPool: autoPool),
        const SizedBox(height: 12),
        _QuickActions(proxy: proxy, tunnel: tunnel),
        const SizedBox(height: 12),
        _RecentActivity(logs: logs),
      ],
    );
  }
}

class _StatusCard extends StatelessWidget {
  final double width;
  final IconData icon;
  final String label;
  final String value;
  final String subline;
  final Color color;
  final bool busy;

  const _StatusCard({
    required this.width,
    required this.icon,
    required this.label,
    required this.value,
    required this.subline,
    required this.color,
    this.busy = false,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SizedBox(
      width: width,
      child: Card(
        margin: EdgeInsets.zero,
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(icon, size: 22, color: color),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(children: [
                      Text(label.toUpperCase(),
                          style: theme.textTheme.labelSmall?.copyWith(
                              letterSpacing: 0.8,
                              color: theme.colorScheme.outline)),
                      const Spacer(),
                      if (busy)
                        const SizedBox(
                            width: 12,
                            height: 12,
                            child: CircularProgressIndicator(strokeWidth: 2))
                      else
                        StatusDot(color: color),
                    ]),
                    const SizedBox(height: 6),
                    Text(value,
                        style: theme.textTheme.titleMedium
                            ?.copyWith(fontWeight: FontWeight.w700)),
                    const SizedBox(height: 4),
                    Text(subline,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall
                            ?.copyWith(color: theme.colorScheme.outline)),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _EndpointsCard extends ConsumerWidget {
  final ProxyState proxy;
  final TunnelRuntime tunnel;
  final AppSettings settings;
  final String autoPool;

  const _EndpointsCard(
      {required this.proxy,
      required this.tunnel,
      required this.settings,
      this.autoPool = ''});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final localUrl =
        'http://127.0.0.1:${settings.port}/v1';
    final publicUrl = settings.tunnelMode == TunnelMode.token
        ? (settings.publicHostname.isEmpty
            ? null
            : 'https://${settings.publicHostname}')
        : tunnel.publicUrl;
    final localKey = ref.read(settingsServiceProvider).localApiKey;

    return SectionCard(
      icon: Icons.link,
      title: 'Endpoints',
      child: Column(
        children: [
          _endpointRow(context, 'Local', localUrl, 'OpenAI base URL'),
          if (publicUrl != null)
            _endpointRow(context, 'Public', publicUrl, 'Via Cloudflare Tunnel'),
          _endpointRow(
              context, 'Proxy key', localKey, 'Authorization: Bearer <key> / X-API-Key'),
          if (settings.exposeAutoModel)
            _endpointRow(
                context,
                'Model',
                AutoModel.canonical,
                'One id for every provider — nothing to pick. $autoPool · '
                    'variants: ${AutoModel.strongVariant}, ${AutoModel.fastVariant}'),
        ],
      ),
    );
  }

  Widget _endpointRow(
      BuildContext context, String label, String value, String hint) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: [
          SizedBox(
              width: 76,
              child: Text(label,
                  style: theme.textTheme.labelMedium
                      ?.copyWith(color: theme.colorScheme.outline))),
          Expanded(
            child: Text(value,
                style: theme.textTheme.bodySmall?.copyWith(
                    fontFamily: 'monospace', fontWeight: FontWeight.w600)),
          ),
          IconButton(
            visualDensity: VisualDensity.compact,
            icon: const Icon(Icons.copy, size: 15),
            tooltip: 'Copy $label',
            onPressed: () => copyToClipboard(context, value, label),
          ),
        ],
      ),
    );
  }
}

class _QuickActions extends ConsumerWidget {
  final ProxyState proxy;
  final TunnelRuntime tunnel;

  const _QuickActions({required this.proxy, required this.tunnel});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return SectionCard(
      icon: Icons.bolt,
      title: 'Quick Actions',
      child: Wrap(
        spacing: 10,
        runSpacing: 10,
        children: [
          if (proxy.status == ProxyStatus.running)
            FilledButton.tonalIcon(
              onPressed: () => ref.read(proxyControllerProvider.notifier).stop(),
              icon: const Icon(Icons.stop, size: 16),
              label: const Text('Stop Proxy'),
            )
          else
            FilledButton.icon(
              onPressed: () => ref.read(proxyControllerProvider.notifier).start(),
              icon: const Icon(Icons.play_arrow, size: 16),
              label: const Text('Start Proxy'),
            ),
          if (tunnel.status == TunnelStatus.connected ||
              tunnel.status == TunnelStatus.starting)
            FilledButton.tonalIcon(
              onPressed: () =>
                  ref.read(tunnelControllerProvider.notifier).disconnect(),
              icon: const Icon(Icons.link_off, size: 16),
              label: const Text('Disconnect Tunnel'),
            )
          else
            FilledButton.tonalIcon(
              onPressed: () =>
                  ref.read(tunnelControllerProvider.notifier).connect(),
              icon: const Icon(Icons.link, size: 16),
              label: const Text('Connect Tunnel'),
            ),
          FilledButton.tonalIcon(
            onPressed: () => ref.read(syncControllerProvider.notifier).syncNow(),
            icon: const Icon(Icons.refresh, size: 16),
            label: const Text('Sync Models'),
          ),
        ],
      ),
    );
  }
}

class _RecentActivity extends StatelessWidget {
  final LogService logs;

  const _RecentActivity({required this.logs});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SectionCard(
      icon: Icons.history,
      title: 'Recent Activity',
      child: StreamBuilder<LogEntry>(
        stream: logs.stream,
        builder: (context, _) {
          final entries = logs.entries.take(8).toList();
          if (entries.isEmpty) {
            return Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Text('No activity yet.',
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: theme.colorScheme.outline)),
            );
          }
          return Column(
            children: [
              for (final e in entries)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 2),
                  child: Row(
                    children: [
                      StatusDot(color: logColor(context, e.level), size: 7),
                      const SizedBox(width: 8),
                      SizedBox(
                        width: 56,
                        child: Text(e.timeLabel,
                            style: theme.textTheme.labelSmall
                                ?.copyWith(color: theme.colorScheme.outline)),
                      ),
                      Expanded(
                        child: Text(e.message,
                            maxLines: 1, overflow: TextOverflow.ellipsis),
                      ),
                    ],
                  ),
                ),
            ],
          );
        },
      ),
    );
  }
}
