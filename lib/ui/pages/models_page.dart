import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/model_router.dart';
import '../../models/model_info.dart';
import '../../state/controllers.dart';
import '../widgets/common.dart';

class ModelsPage extends ConsumerStatefulWidget {
  const ModelsPage({super.key});

  @override
  ConsumerState<ModelsPage> createState() => _ModelsPageState();
}

class _ModelsPageState extends ConsumerState<ModelsPage> {
  final _searchCtrl = TextEditingController();
  String _search = '';
  String? _providerFilter;

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final all = ref.watch(modelsStreamProvider).value ?? const <ModelInfo>[];
    final settings = ref.watch(settingsNotifierProvider);
    final syncing = ref.watch(syncControllerProvider).syncing;
    final providers = ref.watch(providersProvider);
    final theme = Theme.of(context);

    var models = all;
    if (_providerFilter != null) {
      models = models.where((m) => m.providerId == _providerFilter).toList();
    }
    if (_search.isNotEmpty) {
      final q = _search.toLowerCase();
      models = models
          .where((m) =>
              m.id.toLowerCase().contains(q) ||
              (m.displayName?.toLowerCase().contains(q) ?? false))
          .toList();
    }
    var scoped = models;
    if (settings.showFreeOnly) {
      // Free-flagged models, plus anything you declared by hand, plus **every
      // model of a custom provider** — your own gateway may be paid (daily
      // credit) and you still want to see it. Known providers (OpenRouter, …)
      // only ever contribute free models, since missing pricing metadata is
      // never guessed to be free.
      final customIds = {for (final p in providers) if (p.isCustom) p.id};
      models = models
          .where((m) => m.visibleInFreeView || customIds.contains(m.providerId))
          .toList();
    }
    final hidden = scoped.length - models.length;
    models = [...models]..sort((a, b) {
        final t = ModelCapability.tier(b).rank.compareTo(
            ModelCapability.tier(a).rank);
        if (t != 0) return t;
        final f = (b.isFree ? 1 : 0) - (a.isFree ? 1 : 0);
        if (f != 0) return f;
        return a.id.compareTo(b.id);
      });

    // One block per provider, so the list stays readable when the dropdown is
    // on "All providers".
    final grouped = <String, List<ModelInfo>>{};
    for (final m in models) {
      grouped.putIfAbsent(m.providerId, () => []).add(m);
    }
    String nameOf(String providerId) {
      for (final p in providers) {
        if (p.id == providerId) return p.name;
      }
      final first = models.where((m) => m.providerId == providerId).firstOrNull;
      return first?.providerName.isNotEmpty == true
          ? first!.providerName
          : providerId;
    }

    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(children: [
            Expanded(
              child: TextField(
                controller: _searchCtrl,
                onChanged: (v) => setState(() => _search = v),
                decoration: InputDecoration(
                  isDense: true,
                  prefixIcon: const Icon(Icons.search, size: 18),
                  hintText: 'Search models…',
                  border: const OutlineInputBorder(),
                ),
              ),
            ),
            const SizedBox(width: 10),
            SizedBox(
              width: 190,
              child: DropdownButtonFormField<String?>(
                initialValue: _providerFilter,
                isDense: true,
                decoration: const InputDecoration(
                  labelText: 'Provider',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
                items: [
                  DropdownMenuItem(
                      value: null,
                      child: Text('All providers (${all.length})')),
                  // Providers with zero cached models are still listed — they
                  // are then visible as "0" instead of silently missing.
                  for (final p in providers)
                    DropdownMenuItem(
                      value: p.id,
                      child: Row(children: [
                        Flexible(
                            child: Text(p.name, overflow: TextOverflow.ellipsis)),
                        const SizedBox(width: 6),
                        Text(
                          '(${all.where((m) => m.providerId == p.id).length})',
                          style: TextStyle(
                            color: p.id == _providerFilter
                                ? null
                                : (all.where((m) => m.providerId == p.id).isEmpty
                                    ? theme.colorScheme.error
                                    : theme.colorScheme.outline),
                          ),
                        ),
                      ]),
                    ),
                ],
                onChanged: (v) => setState(() => _providerFilter = v),
              ),
            ),
            const SizedBox(width: 10),
            FilterChip(
              label: const Text('Show Free Only'),
              selected: settings.showFreeOnly,
              onSelected: (v) => ref
                  .read(settingsNotifierProvider.notifier)
                  .update(settings.copyWith(showFreeOnly: v)),
            ),
            const Spacer(),
            Text('${models.length} / ${all.length}',
                style: Theme.of(context).textTheme.labelMedium),
            const SizedBox(width: 8),
            IconButton(
              tooltip: 'Sync now',
              onPressed:
                  syncing ? null : () => ref.read(syncControllerProvider.notifier).syncNow(),
              icon: syncing
                  ? const SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.refresh, size: 18),
            ),
          ]),
          const SizedBox(height: 12),
          Expanded(
            child: models.isEmpty
                ? Center(
                    child: Text(
                      all.isEmpty
                          ? 'No models cached yet — enable a provider and press Sync.'
                          : hidden > 0
                              ? '$hidden model(s) here are hidden by “Show Free Only” — '
                                  'turn the filter off to see them.'
                              : 'No models match the current filters.',
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.bodyMedium,
                    ),
                  )
                : ListView(
                    padding: EdgeInsets.zero,
                    children: _sectionRows(grouped, nameOf),
                  ),
          ),
        ],
      ),
    );
  }

  /// Model rows grouped per provider, each group introduced by a labelled
  /// separator line (visible whenever more than one provider is on screen).
  List<Widget> _sectionRows(
      Map<String, List<ModelInfo>> grouped, String Function(String) nameOf) {
    final showHeaders = grouped.length > 1;
    final rows = <Widget>[];
    var first = true;
    for (final entry in grouped.entries) {
      if (!first) rows.add(const SizedBox(height: 6));
      first = false;
      if (showHeaders) {
        rows.add(_ProviderGroupHeader(
          name: nameOf(entry.key),
          count: entry.value.length,
          freeCount: entry.value.where((m) => m.isFree).length,
        ));
      }
      rows.addAll(entry.value.map((m) => _ModelTile(model: m)));
    }
    return rows;
  }
}

/// `── coarena · 23 models ───────────────` separator row.
class _ProviderGroupHeader extends StatelessWidget {
  final String name;
  final int count;
  final int freeCount;

  const _ProviderGroupHeader({
    required this.name,
    required this.count,
    required this.freeCount,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final line = Divider(
      height: 1,
      thickness: 0.7,
      color: theme.colorScheme.outlineVariant.withValues(alpha: 0.6),
    );
    return Padding(
      padding: const EdgeInsets.only(top: 10, bottom: 4, right: 4),
      child: Row(
        children: [
          Icon(Icons.dns_outlined, size: 14, color: theme.colorScheme.primary),
          const SizedBox(width: 6),
          Text(
            name.toUpperCase(),
            style: theme.textTheme.labelSmall?.copyWith(
              letterSpacing: 1.0,
              fontWeight: FontWeight.w800,
              color: theme.colorScheme.primary,
            ),
          ),
          const SizedBox(width: 8),
          Text(
            '$count model(s)${freeCount > 0 ? ' · $freeCount free' : ''}',
            style: theme.textTheme.labelSmall
                ?.copyWith(color: theme.colorScheme.outline),
          ),
          const SizedBox(width: 10),
          Expanded(child: line),
        ],
      ),
    );
  }
}

class _ModelTile extends ConsumerWidget {
  final ModelInfo model;

  const _ModelTile({required this.model});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    return ListTile(
      dense: true,
      leading: Icon(
        model.isFree ? Icons.bolt : Icons.circle_outlined,
        size: 18,
        color: model.isFree ? Colors.green : theme.colorScheme.outline,
      ),
      title: Text(model.id,
          style: theme.textTheme.bodyMedium
              ?.copyWith(fontFamily: 'monospace', fontWeight: FontWeight.w600)),
      subtitle: Text(
        '${model.providerName}'
        ' · ${ModelCapability.tier(model).label} tier'
        '${model.contextLength != null ? ' · ${_fmtContext(model.contextLength!)} ctx' : ''}'
        '${model.manuallyAdded ? ' · manual' : ''}'
        '${model.displayName != null && model.displayName != model.id ? ' · ${model.displayName}' : ''}',
        style: theme.textTheme.bodySmall,
      ),
      trailing: Row(mainAxisSize: MainAxisSize.min, children: [
        if (model.isFree) const FreeBadge(),
        PopupMenuButton<String>(
          icon: const Icon(Icons.more_vert, size: 18),
          onSelected: (v) {
            switch (v) {
              case 'copy':
                copyToClipboard(context, model.id, 'Model ID');
                break;
              case 'default':
                ref.read(settingsNotifierProvider.notifier).update(
                    ref.read(settingsNotifierProvider).copyWith(defaultModel: model.id));
                showSnack(context, 'Default failover model → ${model.id}');
                break;
            }
          },
          itemBuilder: (ctx) => const [
            PopupMenuItem(value: 'copy', child: Text('Copy model ID')),
            PopupMenuItem(value: 'default', child: Text('Set as default failover model')),
          ],
        ),
      ]),
    );
  }

  String _fmtContext(int tokens) {
    if (tokens >= 1000000) return '${(tokens / 1000000).toStringAsFixed(1)}M';
    if (tokens >= 1000) return '${(tokens / 1000).round()}K';
    return '$tokens';
  }
}
