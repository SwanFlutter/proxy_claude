import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
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
    if (settings.showFreeOnly) {
      models = models.where((m) => m.isFree).toList();
    }
    models = [...models]..sort((a, b) {
        final f = (b.isFree ? 1 : 0) - (a.isFree ? 1 : 0);
        if (f != 0) return f;
        return a.id.compareTo(b.id);
      });

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
                  const DropdownMenuItem(value: null, child: Text('All providers')),
                  for (final p in providers)
                    DropdownMenuItem(value: p.id, child: Text(p.name)),
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
                          : 'No models match the current filters.',
                      style: Theme.of(context).textTheme.bodyMedium,
                    ),
                  )
                : ListView.builder(
                    itemCount: models.length,
                    itemBuilder: (context, i) => _ModelTile(model: models[i]),
                  ),
          ),
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
        '${model.contextLength != null ? ' · ${_fmtContext(model.contextLength!)} ctx' : ''}'
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
