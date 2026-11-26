import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/utils.dart';
import '../../models/provider_config.dart';
import '../../state/controllers.dart';
import '../widgets/common.dart';

/// Catalog metadata for one preset row.
typedef _CatalogEntry = ({
  ProviderPreset preset,
  IconData icon,
  String description,
  String? tag,
  String? keyUrl,
});

const List<_CatalogEntry> _featured = [
  (
    preset: ProviderPreset.openRouter,
    icon: Icons.hub_outlined,
    description: 'Access all supported models from one provider',
    tag: 'FREE MODELS',
    keyUrl: 'openrouter.ai/settings/keys',
  ),
  (
    preset: ProviderPreset.googleGemini,
    icon: Icons.auto_awesome,
    description: 'Gemini models with a generous free tier',
    tag: 'FREE TIER',
    keyUrl: 'aistudio.google.com/apikey',
  ),
  (
    preset: ProviderPreset.groq,
    icon: Icons.bolt,
    description: 'Ultra-fast inference on a free tier',
    tag: 'FREE TIER',
    keyUrl: 'console.groq.com/keys',
  ),
  (
    preset: ProviderPreset.openAI,
    icon: Icons.all_inclusive,
    description: 'GPT models with your API key',
    tag: null,
    keyUrl: 'platform.openai.com/api-keys',
  ),
];

const List<_CatalogEntry> _more = [
  (
    preset: ProviderPreset.deepSeek,
    icon: Icons.waves,
    description: 'DeepSeek models for reasoning and coding tasks',
    tag: null,
    keyUrl: 'platform.deepseek.com/api_keys',
  ),
  (
    preset: ProviderPreset.anthropic,
    icon: Icons.psychology,
    description: 'Claude models via the OpenAI-compatible endpoint',
    tag: null,
    keyUrl: 'console.anthropic.com/settings/keys',
  ),
  (
    preset: ProviderPreset.mistral,
    icon: Icons.air,
    description: 'Mistral and Mixtral models',
    tag: null,
    keyUrl: 'console.mistral.ai/api-keys',
  ),
  (
    preset: ProviderPreset.together,
    icon: Icons.groups,
    description: '200+ open-source models, some free',
    tag: null,
    keyUrl: 'api.together.xyz/settings/api-keys',
  ),
  (
    preset: ProviderPreset.cerebras,
    icon: Icons.grain,
    description: 'Wafer-scale speed with a free tier',
    tag: 'FREE TIER',
    keyUrl: 'cloud.cerebras.ai',
  ),
  (
    preset: ProviderPreset.xai,
    icon: Icons.close,
    description: 'Grok models with your API key',
    tag: null,
    keyUrl: 'console.x.ai',
  ),
  (
    preset: ProviderPreset.huggingface,
    icon: Icons.emoji_emotions_outlined,
    description: 'Inference providers router with one token',
    tag: null,
    keyUrl: 'huggingface.co/settings/tokens',
  ),
  (
    preset: ProviderPreset.custom,
    icon: Icons.tune,
    description: 'Add any OpenAI-compatible base URL',
    tag: 'CUSTOM',
    keyUrl: null,
  ),
];

class ProvidersPage extends ConsumerStatefulWidget {
  const ProvidersPage({super.key});

  @override
  ConsumerState<ProvidersPage> createState() => _ProvidersPageState();
}

class _ProvidersPageState extends ConsumerState<ProvidersPage> {
  final _searchCtrl = TextEditingController();
  String _query = '';
  bool _showMore = false;

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  /// First configured instance for [preset] (prefers one holding a key).
  ProviderConfig? _instanceFor(
      ProviderPreset preset, List<ProviderConfig> providers) {
    final matches = providers.where((p) => p.preset == preset).toList();
    if (matches.isEmpty) return null;
    return matches.firstWhere((p) => p.apiKey.isNotEmpty, orElse: () => matches.first);
  }

  void _openDialog(_CatalogEntry entry, ProviderConfig? existing) {
    // Custom providers always create a fresh instance from the full form.
    if (entry.preset == ProviderPreset.custom) {
      showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (_) => const _CustomProviderDialog(),
      );
      return;
    }
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _ProviderDialog(entry: entry, existing: existing),
    );
  }

  void _openManage(ProviderConfig p) {
    if (p.isCustom) {
      showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (_) => _CustomProviderDialog(existing: p),
      );
      return;
    }
    final entry = [..._featured, ..._more].firstWhere(
      (e) => e.preset == p.preset,
      orElse: () => (
        preset: p.preset,
        icon: Icons.tune,
        description: p.baseUrl,
        tag: 'CUSTOM',
        keyUrl: null,
      ),
    );
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _ProviderDialog(entry: entry, existing: p),
    );
  }

  @override
  Widget build(BuildContext context) {
    final providers = ref.watch(providersProvider);
    final sync = ref.watch(syncControllerProvider);
    final theme = Theme.of(context);

    final query = _query.trim().toLowerCase();
    Iterable<_CatalogEntry> featured = _featured;
    Iterable<_CatalogEntry> more = _more;
    if (query.isNotEmpty) {
      bool matches(_CatalogEntry e) =>
          e.preset.label.toLowerCase().contains(query) ||
          e.description.toLowerCase().contains(query);
      featured = _featured.where(matches);
      more = _more.where(matches);
    }
    final configured = [...providers]..sort((a, b) {
        final f = (a.enabled ? 0 : 1) - (b.enabled ? 0 : 1);
        if (f != 0) return f;
        return a.name.toLowerCase().compareTo(b.name.toLowerCase());
      });

    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 18, 20, 24),
      children: [
        Text('Providers', style: theme.textTheme.titleLarge),
        const SizedBox(height: 4),
        Text(
          'Connect upstream model providers. The proxy merges their model '
          'lists and forwards chat requests automatically.',
          style: theme.textTheme.bodySmall
              ?.copyWith(color: theme.colorScheme.outline),
        ),
        const SizedBox(height: 16),

        // ── Search ────────────────────────────────────────────────────────
        TextField(
          controller: _searchCtrl,
          onChanged: (v) => setState(() => _query = v),
          decoration: InputDecoration(
            isDense: true,
            prefixIcon: const Icon(Icons.search, size: 18),
            hintText: 'Search providers…',
            border: const OutlineInputBorder(),
            suffixIcon: _query.isEmpty
                ? null
                : IconButton(
                    icon: const Icon(Icons.clear, size: 16),
                    onPressed: () {
                      _searchCtrl.clear();
                      setState(() => _query = '');
                    },
                  ),
          ),
        ),
        const SizedBox(height: 20),

        // ── Catalog ───────────────────────────────────────────────────────
        if (featured.isNotEmpty) ...[
          const _SectionHeader('Popular providers'),
          _CatalogCard(
            children: [
              for (final (i, entry) in featured.indexed) ...[
                if (i > 0) const _Hairline(),
                _CatalogRow(
                  entry: entry,
                  instance: _instanceFor(entry.preset, providers),
                  onOpen: () =>
                      _openDialog(entry, _instanceFor(entry.preset, providers)),
                ),
              ],
            ],
          ),
        ],

        // ── Show more ─────────────────────────────────────────────────────
        if (query.isEmpty && !_showMore && more.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: _CatalogCard(
              children: [
                InkWell(
                  borderRadius: BorderRadius.circular(12),
                  onTap: () => setState(() => _showMore = true),
                  child: Padding(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
                    child: Row(
                      children: [
                        Icon(Icons.add_circle_outline,
                            size: 18, color: theme.colorScheme.primary),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Text('Show more providers',
                              style: theme.textTheme.bodyMedium),
                        ),
                        Text('${more.length} more',
                            style: theme.textTheme.labelSmall
                                ?.copyWith(color: theme.colorScheme.outline)),
                        const SizedBox(width: 6),
                        Icon(Icons.chevron_right,
                            size: 18, color: theme.colorScheme.outline),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          )
        else if (more.isNotEmpty) ...[
          const SizedBox(height: 8),
          const _SectionHeader('All providers'),
          _CatalogCard(
            children: [
              for (final (i, entry) in more.indexed) ...[
                if (i > 0) const _Hairline(),
                _CatalogRow(
                  entry: entry,
                  instance: _instanceFor(entry.preset, providers),
                  onOpen: () =>
                      _openDialog(entry, _instanceFor(entry.preset, providers)),
                ),
              ],
            ],
          ),
        ],

        if (featured.isEmpty && more.isEmpty) ...[
          const SizedBox(height: 8),
          _CatalogCard(children: [
            Padding(
              padding: const EdgeInsets.all(16),
              child: Text('No providers match “$_query”.',
                  style: theme.textTheme.bodySmall),
            ),
          ]),
        ],

        const SizedBox(height: 20),

        // ── Configured ────────────────────────────────────────────────────
        const _SectionHeader('Configured'),
        if (configured.isEmpty)
          _CatalogCard(children: [
            Padding(
              padding: const EdgeInsets.all(16),
              child: Row(
                children: [
                  Icon(Icons.info_outline,
                      size: 16, color: theme.colorScheme.outline),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Nothing configured yet — connect a provider above, then '
                      'sync models from the dashboard.',
                      style: theme.textTheme.bodySmall,
                    ),
                  ),
                ],
              ),
            ),
          ])
        else
          _CatalogCard(
            children: [
              for (final (i, p) in configured.indexed) ...[
                if (i > 0) const _Hairline(),
                _ConfiguredRow(
                  provider: p,
                  health: sync.health[p.id],
                  onManage: () => _openManage(p),
                  onToggle: (v) => ref
                      .read(providersProvider.notifier)
                      .setEnabled(p.id, v),
                  onRemove: () => _confirmRemove(p),
                ),
              ],
            ],
          ),
      ],
    );
  }

  Future<void> _confirmRemove(ProviderConfig p) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Remove ${p.name}?'),
        content: Text(
            'Its cached models stay available until the next sync, but the '
            'proxy will no longer route requests to it.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          FilledButton(
              style: FilledButton.styleFrom(
                  backgroundColor: Theme.of(ctx).colorScheme.error),
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Remove')),
        ],
      ),
    );
    if (ok == true && mounted) {
      await ref.read(providersProvider.notifier).remove(p.id);
      if (!mounted) return;
      showSnack(context, '${p.name} removed.');
    }
  }
}

// ── Section scaffolding ──────────────────────────────────────────────────────

class _SectionHeader extends StatelessWidget {
  final String text;

  const _SectionHeader(this.text);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(left: 4, bottom: 8),
      child: Text(
        text.toUpperCase(),
        style: theme.textTheme.labelSmall?.copyWith(
          letterSpacing: 1.1,
          fontWeight: FontWeight.w700,
          color: theme.colorScheme.outline,
        ),
      ),
    );
  }
}

class _CatalogCard extends StatelessWidget {
  final List<Widget> children;

  const _CatalogCard({required this.children});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      margin: EdgeInsets.zero,
      clipBehavior: Clip.antiAlias,
      shape:
          RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      elevation: 0,
      color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.35),
      child: Column(children: children),
    );
  }
}

class _Hairline extends StatelessWidget {
  const _Hairline();

  @override
  Widget build(BuildContext context) {
    return Divider(
      height: 1,
      thickness: 0.6,
      indent: 58,
      color: Theme.of(context).colorScheme.outlineVariant.withValues(alpha: 0.45),
    );
  }
}

class _IconBox extends StatelessWidget {
  final IconData icon;
  final double size;

  const _IconBox({required this.icon, this.size = 20});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      width: 36,
      height: 36,
      decoration: BoxDecoration(
        color: theme.colorScheme.primary.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(9),
      ),
      child: Icon(icon, size: size, color: theme.colorScheme.primary),
    );
  }
}

/// `Connected` / `Disabled` / `Needs key` chip shown on catalog rows.
class _StatusChip extends StatelessWidget {
  final bool hasInstance;
  final bool hasKey;
  final bool enabled;

  const _StatusChip({
    required this.hasInstance,
    required this.hasKey,
    required this.enabled,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (!hasInstance || !hasKey) return const SizedBox.shrink();

    final (label, color) = enabled
        ? ('Connected', Colors.green)
        : ('Disabled', Colors.orange);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        StatusDot(color: color, size: 6),
        const SizedBox(width: 5),
        Text(label,
            style: theme.textTheme.labelSmall?.copyWith(
                color: color, fontWeight: FontWeight.w600)),
      ]),
    );
  }
}

class _TagChip extends StatelessWidget {
  final String label;

  const _TagChip(this.label);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: theme.colorScheme.primary.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(5),
      ),
      child: Text(
        label,
        style: theme.textTheme.labelSmall?.copyWith(
          fontSize: 9.5,
          letterSpacing: 0.7,
          fontWeight: FontWeight.w800,
          color: theme.colorScheme.primary,
        ),
      ),
    );
  }
}

// ── Catalog row ──────────────────────────────────────────────────────────────

class _CatalogRow extends StatelessWidget {
  final _CatalogEntry entry;
  final ProviderConfig? instance;
  final VoidCallback onOpen;

  const _CatalogRow({
    required this.entry,
    required this.instance,
    required this.onOpen,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hasKey = instance != null && instance!.apiKey.isNotEmpty;
    final isCustom = entry.preset == ProviderPreset.custom;

    return InkWell(
      onTap: onOpen,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
        child: Row(
          children: [
            _IconBox(icon: entry.icon),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(children: [
                    Text(entry.preset.label,
                        style: theme.textTheme.bodyMedium
                            ?.copyWith(fontWeight: FontWeight.w600)),
                    if (entry.tag != null) ...[
                      const SizedBox(width: 8),
                      _TagChip(entry.tag!),
                    ],
                  ]),
                  const SizedBox(height: 2),
                  Text(
                    entry.description,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall
                        ?.copyWith(color: theme.colorScheme.outline),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 12),
            if (!isCustom)
              _StatusChip(
                hasInstance: instance != null,
                hasKey: hasKey,
                enabled: instance?.enabled ?? false,
              ),
            if (!isCustom) const SizedBox(width: 12),
            instance != null && hasKey
                ? OutlinedButton(
                    onPressed: onOpen,
                    style: OutlinedButton.styleFrom(
                      visualDensity: VisualDensity.compact,
                      side: BorderSide(
                          color: theme.colorScheme.outlineVariant),
                    ),
                    child: const Text('Manage'),
                  )
                : FilledButton.tonalIcon(
                    onPressed: onOpen,
                    style: FilledButton.styleFrom(
                      visualDensity: VisualDensity.compact,
                    ),
                    icon: const Icon(Icons.add, size: 15),
                    label: const Text('Connect'),
                  ),
          ],
        ),
      ),
    );
  }
}

// ── Configured row ───────────────────────────────────────────────────────────

class _ConfiguredRow extends StatelessWidget {
  final ProviderConfig provider;
  final ProviderHealth? health;
  final VoidCallback onManage;
  final ValueChanged<bool> onToggle;
  final VoidCallback onRemove;

  const _ConfiguredRow({
    required this.provider,
    required this.health,
    required this.onManage,
    required this.onToggle,
    required this.onRemove,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hasKey = provider.apiKey.isNotEmpty;

    final (Color dot, String status) = switch ((hasKey, provider.enabled, health)) {
      (false, _, _) => (Colors.orange, 'API key required'),
      (_, _, ProviderHealth(ok: false)) => (theme.colorScheme.error, 'Sync error'),
      (_, true, ProviderHealth(ok: true, :final modelCount)) =>
        (Colors.green, '$modelCount models'),
      (_, false, _) => (Colors.grey, 'Disabled'),
      (_, true, null) => (Colors.grey, 'Not synced yet'),
    };

    return InkWell(
      onTap: onManage,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        child: Row(
          children: [
            _IconBox(icon: Icons.dns_outlined, size: 18),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(children: [
                    Text(provider.name,
                        style: theme.textTheme.bodyMedium
                            ?.copyWith(fontWeight: FontWeight.w600)),
                    if (provider.isCustom) ...[
                      const SizedBox(width: 8),
                      _TagChip('CUSTOM'),
                    ],
                  ]),
                  const SizedBox(height: 2),
                  Row(children: [
                    StatusDot(color: dot, size: 7),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        status,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall
                            ?.copyWith(color: theme.colorScheme.outline),
                      ),
                    ),
                  ]),
                ],
              ),
            ),
            const SizedBox(width: 12),
            Text('Enabled', style: theme.textTheme.labelMedium),
            const SizedBox(width: 4),
            Switch(value: provider.enabled, onChanged: onToggle),
            IconButton(
              tooltip: 'Manage',
              icon: const Icon(Icons.settings_outlined, size: 18),
              onPressed: onManage,
            ),
            IconButton(
              tooltip: 'Remove',
              icon: Icon(Icons.delete_outline,
                  size: 18, color: theme.colorScheme.error),
              onPressed: onRemove,
            ),
          ],
        ),
      ),
    );
  }
}

// ── Connect / Manage dialog ──────────────────────────────────────────────────

class _ProviderDialog extends ConsumerStatefulWidget {
  final _CatalogEntry entry;
  final ProviderConfig? existing;

  const _ProviderDialog({required this.entry, required this.existing});

  @override
  ConsumerState<_ProviderDialog> createState() => _ProviderDialogState();
}

class _ProviderDialogState extends ConsumerState<_ProviderDialog> {
  late final TextEditingController _keyCtrl;
  late final TextEditingController _urlCtrl;
  late final TextEditingController _modelsPathCtrl;
  late final TextEditingController _chatPathCtrl;
  late final TextEditingController _headersCtrl;
  late bool _obscure = true;
  bool _assumeFree = false;
  bool _testing = false;
  String? _testError;
  int? _testCount;
  int? _testFree;

  bool get _isManage => widget.existing != null && widget.existing!.apiKey.isNotEmpty;
  bool get _isCustom => widget.entry.preset == ProviderPreset.custom;

  @override
  void initState() {
    super.initState();
    final defaults = ProviderConfig.defaultFor(widget.entry.preset);
    final e = widget.existing;
    _keyCtrl = TextEditingController(text: e?.apiKey ?? '');
    _urlCtrl = TextEditingController(text: e?.baseUrl ?? defaults.baseUrl);
    _modelsPathCtrl =
        TextEditingController(text: e?.modelsPath ?? defaults.modelsPath);
    _chatPathCtrl =
        TextEditingController(text: e?.chatPath ?? defaults.chatPath);
    _headersCtrl = TextEditingController(
        text: headersToText(e?.extraHeaders ?? defaults.extraHeaders));
    _assumeFree = e?.assumeAllFree ?? defaults.assumeAllFree;
  }

  @override
  void dispose() {
    _keyCtrl.dispose();
    _urlCtrl.dispose();
    _modelsPathCtrl.dispose();
    _chatPathCtrl.dispose();
    _headersCtrl.dispose();
    super.dispose();
  }

  ProviderConfig _build({bool? enabledOverride}) {
    final base = widget.existing ??
        ProviderConfig.defaultFor(widget.entry.preset);
    return base.copyWith(
      baseUrl: _urlCtrl.text.trim(),
      modelsPath: _modelsPathCtrl.text.trim(),
      chatPath: _chatPathCtrl.text.trim(),
      extraHeaders: parseHeaders(_headersCtrl.text),
      // Connecting enables the instance; managing keeps its current state.
      enabled: enabledOverride ?? (_isManage ? base.enabled : true),
      assumeAllFree: _assumeFree,
      apiKey: _keyCtrl.text.trim(),
    );
  }

  Future<void> _test() async {
    setState(() {
      _testing = true;
      _testError = null;
      _testCount = null;
      _testFree = null;
    });
    final outcome = await ref
        .read(upstreamClientProvider)
        .listModels(_build(enabledOverride: true),
            timeout: const Duration(seconds: 15));
    if (!mounted) return;
    setState(() {
      _testing = false;
      if (outcome.ok) {
        _testCount = outcome.models.length;
        _testFree = outcome.models.where((m) => m.isFree).length;
      } else {
        _testError = outcome.error;
      }
    });
  }

  Future<void> _save() async {
    final p = _build();
    if (p.baseUrl.trim().isEmpty) {
      showSnack(context, 'Base URL is required.', error: true);
      return;
    }
    if (p.apiKey.isEmpty) {
      showSnack(context, 'API key is required.', error: true);
      return;
    }
    await ref.read(providersProvider.notifier).upsert(p, apiKey: p.apiKey);
    // Refresh the routing cache right away.
    if (!ref.read(syncControllerProvider).syncing) {
      ref.read(syncControllerProvider.notifier).syncNow();
    }
    if (!mounted) return;
    showSnack(context, _isManage ? '${p.name} updated.' : '${p.name} connected — syncing models…');
    Navigator.of(context).pop();
  }

  Future<void> _remove() async {
    final p = widget.existing!;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Remove ${p.name}?'),
        content: const Text(
            'The proxy will no longer route requests to this provider.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          FilledButton(
              style: FilledButton.styleFrom(
                  backgroundColor: Theme.of(ctx).colorScheme.error),
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Remove')),
        ],
      ),
    );
    if (ok == true && mounted) {
      await ref.read(providersProvider.notifier).remove(p.id);
      if (!mounted) return;
      showSnack(context, '${p.name} removed.');
      Navigator.of(context).pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final keyUrl = widget.entry.keyUrl;

    return AlertDialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      insetPadding:
          const EdgeInsets.symmetric(horizontal: 40, vertical: 32),
      titlePadding: const EdgeInsets.fromLTRB(20, 18, 12, 0),
      contentPadding: const EdgeInsets.fromLTRB(20, 14, 20, 6),
      actionsPadding: const EdgeInsets.fromLTRB(16, 6, 16, 14),
      title: Row(children: [
        _IconBox(icon: widget.entry.icon),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(children: [
                Flexible(
                  child: Text(
                    _isManage
                        ? 'Manage ${widget.entry.preset.label}'
                        : 'Connect ${widget.entry.preset.label}',
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.titleMedium,
                  ),
                ),
                if (widget.entry.tag != null) ...[
                  const SizedBox(width: 8),
                  _TagChip(widget.entry.tag!),
                ],
              ]),
            ],
          ),
        ),
      ]),
      content: SizedBox(
        width: 480,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              widget.entry.description,
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.outline),
            ),
            if (keyUrl != null && _keyCtrl.text.isEmpty) ...[
              const SizedBox(height: 4),
              Text('Get your key at $keyUrl',
                  style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.primary,
                      fontWeight: FontWeight.w600)),
            ],
            const SizedBox(height: 14),
            TextField(
              controller: _keyCtrl,
              obscureText: _obscure,
              autofillHints: const [AutofillHints.password],
              decoration: InputDecoration(
                labelText: 'API key',
                border: const OutlineInputBorder(),
                suffixIcon: Row(mainAxisSize: MainAxisSize.min, children: [
                  IconButton(
                    tooltip: _obscure ? 'Reveal' : 'Hide',
                    icon: Icon(
                        _obscure ? Icons.visibility_off : Icons.visibility,
                        size: 18),
                    onPressed: () => setState(() => _obscure = !_obscure),
                  ),
                ]),
              ),
            ),
            const SizedBox(height: 12),
            Theme(
              data: theme.copyWith(dividerColor: Colors.transparent),
              child: ExpansionTile(
                tilePadding: EdgeInsets.zero,
                childrenPadding: const EdgeInsets.only(bottom: 8),
                initiallyExpanded: _isCustom,
                title: Text('Advanced options',
                    style: theme.textTheme.bodyMedium),
                children: [
                  TextField(
                    controller: _urlCtrl,
                    decoration: const InputDecoration(
                      labelText: 'Base URL',
                      border: OutlineInputBorder(),
                      hintText: 'https://…/v1',
                    ),
                  ),
                  const SizedBox(height: 10),
                  Row(children: [
                    Expanded(
                      child: TextField(
                        controller: _modelsPathCtrl,
                        decoration: const InputDecoration(
                          labelText: 'Models path',
                          border: OutlineInputBorder(),
                          hintText: '/models',
                        ),
                      ),
                    ),
                    if (_isCustom) ...[
                      const SizedBox(width: 10),
                      Expanded(
                        child: TextField(
                          controller: _chatPathCtrl,
                          decoration: const InputDecoration(
                            labelText: 'Chat path',
                            border: OutlineInputBorder(),
                            hintText: '/chat/completions',
                          ),
                        ),
                      ),
                    ],
                  ]),
                  if (_isCustom) ...[
                    const SizedBox(height: 10),
                    TextField(
                      controller: _headersCtrl,
                      minLines: 1,
                      maxLines: 3,
                      decoration: const InputDecoration(
                        labelText: 'Custom headers (Key: Value per line)',
                        border: OutlineInputBorder(),
                      ),
                    ),
                  ],
                  SwitchListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Treat all models as free tier'),
                    subtitle: const Text(
                        'Skips per-model pricing detection (Groq / Gemini free tier)'),
                    value: _assumeFree,
                    onChanged: (v) => setState(() => _assumeFree = v),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 8),
            Row(children: [
              OutlinedButton.icon(
                onPressed: _testing ? null : _test,
                icon: _testing
                    ? const SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.wifi_tethering, size: 15),
                label: const Text('Test connection'),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: AnimatedSwitcher(
                  duration: const Duration(milliseconds: 200),
                  child: _buildTestResult(theme),
                ),
              ),
            ]),
          ],
        ),
      ),
      actions: [
        // OverflowBar (AlertDialog actions) has no Flex layout, so the row
        // spacing is handled manually here.
        Row(children: [
          if (_isManage)
            TextButton(
              style: TextButton.styleFrom(
                  foregroundColor: theme.colorScheme.error),
              onPressed: _remove,
              child: const Text('Remove'),
            ),
          const Spacer(),
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton.icon(
            onPressed: _save,
            icon: const Icon(Icons.check, size: 16),
            label: Text(_isManage ? 'Save changes' : 'Connect'),
          ),
        ]),
      ],
    );
  }

  Widget _buildTestResult(ThemeData theme) {
    if (_testing) {
      return Text('Contacting provider…',
          key: ValueKey('t${DateTime.now().millisecondsSinceEpoch}'),
          style: theme.textTheme.bodySmall
              ?.copyWith(color: theme.colorScheme.outline));
    }
    if (_testError != null) {
      return Text(
        '✗ $_testError',
        key: const ValueKey('err'),
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: theme.textTheme.bodySmall
            ?.copyWith(color: theme.colorScheme.error),
      );
    }
    if (_testCount != null) {
      return Text(
        '✓ $_testCount models fetched ($_testFree free)',
        key: const ValueKey('ok'),
        style: theme.textTheme.bodySmall?.copyWith(color: Colors.green),
      );
    }
    return const SizedBox.shrink();
  }
}

// ── Custom provider form (Provider ID / name / API / models table) ───────────

class _ModelRowCtl {
  final TextEditingController id;
  final TextEditingController name;

  _ModelRowCtl(String idText, String nameText)
      : id = TextEditingController(text: idText),
        name = TextEditingController(text: nameText);

  void dispose() {
    id.dispose();
    name.dispose();
  }
}

class _CustomProviderDialog extends ConsumerStatefulWidget {
  final ProviderConfig? existing;

  const _CustomProviderDialog({this.existing});

  @override
  ConsumerState<_CustomProviderDialog> createState() =>
      _CustomProviderDialogState();
}

class _CustomProviderDialogState extends ConsumerState<_CustomProviderDialog> {
  static final _idPattern = RegExp(r'^[a-z0-9_-]+$');
  static const _maxRows = 100;

  late final TextEditingController _idCtrl;
  late final TextEditingController _nameCtrl;
  late final TextEditingController _urlCtrl;
  late final TextEditingController _keyCtrl;
  late final TextEditingController _modelsPathCtrl;
  late final TextEditingController _chatPathCtrl;
  late final TextEditingController _headersCtrl;
  bool _assumeFree = false;
  final List<_ModelRowCtl> _rows = [];

  bool _fetching = false;
  String? _fetchError;
  int? _fetchCount;
  int? _fetchFree;

  bool get _isManage => widget.existing != null;

  @override
  void initState() {
    super.initState();
    final defaults = ProviderConfig.defaultFor(ProviderPreset.custom);
    final e = widget.existing;
    _idCtrl = TextEditingController(text: e?.id ?? '');
    _nameCtrl = TextEditingController(
        text: (e == null || e.name == defaults.name) ? '' : e.name);
    _urlCtrl = TextEditingController(text: e?.baseUrl ?? '');
    _keyCtrl = TextEditingController(text: e?.apiKey ?? '');
    _modelsPathCtrl =
        TextEditingController(text: e?.modelsPath ?? defaults.modelsPath);
    _chatPathCtrl =
        TextEditingController(text: e?.chatPath ?? defaults.chatPath);
    _headersCtrl = TextEditingController(
        text: headersToText(e?.extraHeaders ?? defaults.extraHeaders));
    _assumeFree = e?.assumeAllFree ?? false;
    for (final m in e?.manualModels ?? const <ManualModel>[]) {
      _rows.add(_ModelRowCtl(m.id, m.name));
    }
  }

  @override
  void dispose() {
    _idCtrl.dispose();
    _nameCtrl.dispose();
    _urlCtrl.dispose();
    _keyCtrl.dispose();
    _modelsPathCtrl.dispose();
    _chatPathCtrl.dispose();
    _headersCtrl.dispose();
    for (final r in _rows) {
      r.dispose();
    }
    super.dispose();
  }

  ProviderConfig _build() {
    final base = widget.existing ??
        ProviderConfig.defaultFor(ProviderPreset.custom,
            id: _idCtrl.text.trim());
    final name = _nameCtrl.text.trim();
    return base.copyWith(
      name: name.isEmpty ? base.name : name,
      baseUrl: _urlCtrl.text.trim(),
      modelsPath: _modelsPathCtrl.text.trim(),
      chatPath: _chatPathCtrl.text.trim(),
      extraHeaders: parseHeaders(_headersCtrl.text),
      assumeAllFree: _assumeFree,
      manualModels: _rows
          .map((r) =>
              ManualModel(id: r.id.text.trim(), name: r.name.text.trim()))
          .where((m) => m.id.isNotEmpty)
          .toList(),
      apiKey: _keyCtrl.text.trim(),
    );
  }

  Future<void> _fetchModels() async {
    final url = _urlCtrl.text.trim();
    if (url.isEmpty ||
        !(url.startsWith('http://') || url.startsWith('https://'))) {
      showSnack(context, 'Enter a valid http(s) Base URL first.', error: true);
      return;
    }
    setState(() {
      _fetching = true;
      _fetchError = null;
      _fetchCount = null;
      _fetchFree = null;
    });
    final outcome = await ref
        .read(upstreamClientProvider)
        .listModels(_build(), timeout: const Duration(seconds: 15));
    if (!mounted) return;
    setState(() {
      _fetching = false;
      if (!outcome.ok) {
        _fetchError = outcome.error;
        return;
      }
      _fetchCount = outcome.models.length;
      _fetchFree = outcome.models.where((m) => m.isFree).length;
      final existingIds = _rows.map((r) => r.id.text.trim()).toSet();
      for (final m in outcome.models) {
        if (existingIds.contains(m.id)) continue;
        if (_rows.length >= _maxRows) break;
        _rows.add(_ModelRowCtl(m.id, m.displayName ?? ''));
      }
    });
  }

  /// Derives a valid provider id from a display name ("My AI Provider" →
  /// "my-ai-provider"); empty when nothing usable remains.
  static String _slugify(String raw) => raw
      .toLowerCase()
      .replaceAll(RegExp(r'[^a-z0-9]+'), '-')
      .replaceAll(RegExp(r'^-+|-+$'), '');

  Future<void> _save() async {
    final url = _urlCtrl.text.trim();
    if (widget.existing == null) {
      var id = _idCtrl.text.trim();
      // Empty ID + filled display name → derive the id automatically, so
      // "I only typed the URL" no longer produces an error.
      if (id.isEmpty) {
        final derived = _slugify(_nameCtrl.text.trim());
        if (derived.isNotEmpty) {
          id = derived;
          _idCtrl.text = id;
        }
      }
      if (id.isEmpty || !_idPattern.hasMatch(id)) {
        showSnack(context,
            'Provider ID must use lowercase letters, numbers, hyphens, or underscores.',
            error: true);
        return;
      }
      if (ref.read(providersProvider).any((p) => p.id == id)) {
        showSnack(context, 'Provider ID "$id" is already used.', error: true);
        return;
      }
    }
    if (url.isEmpty ||
        !(url.startsWith('http://') || url.startsWith('https://'))) {
      showSnack(context, 'Enter a valid http(s) Base URL.', error: true);
      return;
    }
    final p = _build();
    await ref.read(providersProvider.notifier).upsert(p, apiKey: p.apiKey);
    if (!ref.read(syncControllerProvider).syncing) {
      ref.read(syncControllerProvider.notifier).syncNow();
    }
    if (!mounted) return;
    showSnack(context,
        _isManage ? '${p.name} updated.' : '${p.name} connected — syncing models…');
    Navigator.of(context).pop();
  }

  Future<void> _remove() async {
    final p = widget.existing!;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Remove ${p.name}?'),
        content:
            const Text('The proxy will no longer route requests to it.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          FilledButton(
              style: FilledButton.styleFrom(
                  backgroundColor: Theme.of(ctx).colorScheme.error),
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Remove')),
        ],
      ),
    );
    if (ok == true && mounted) {
      await ref.read(providersProvider.notifier).remove(p.id);
      if (!mounted) return;
      showSnack(context, '${p.name} removed.');
      Navigator.of(context).pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AlertDialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      insetPadding: const EdgeInsets.symmetric(horizontal: 40, vertical: 24),
      titlePadding: const EdgeInsets.fromLTRB(20, 18, 12, 0),
      contentPadding: const EdgeInsets.fromLTRB(20, 12, 20, 4),
      actionsPadding: const EdgeInsets.fromLTRB(16, 8, 16, 14),
      title: Row(children: [
        const _IconBox(icon: Icons.tune),
        const SizedBox(width: 12),
        Expanded(
          child: Text(
            _isManage ? 'Manage Custom Provider' : 'Custom Provider',
            style: theme.textTheme.titleMedium,
          ),
        ),
        IconButton(
          tooltip: 'Close',
          icon: const Icon(Icons.close, size: 20),
          onPressed: () => Navigator.of(context).pop(),
        ),
      ]),
      content: SizedBox(
        width: 520,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'Configure an OpenAI-compatible provider with its own base '
                'URL, key, and model list.',
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.outline),
              ),
              const SizedBox(height: 14),
              const _FieldLabel('Provider ID'),
              TextField(
                controller: _idCtrl,
                enabled: !_isManage,
                inputFormatters: [
                  FilteringTextInputFormatter.allow(RegExp(r'[a-z0-9_-]')),
                ],
                decoration: const InputDecoration(
                  hintText: 'myprovider',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
              ),
              const _FieldHint(
                  'Lowercase letters, numbers, hyphens, or underscores'),
              const _FieldLabel('Display name'),
              TextField(
                controller: _nameCtrl,
                decoration: const InputDecoration(
                  hintText: 'My AI Provider',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
              ),
              const SizedBox(height: 12),
              const _FieldLabel('Provider API'),
              DropdownButtonFormField<String>(
                initialValue: 'openai',
                items: const [
                  DropdownMenuItem(
                      value: 'openai', child: Text('OpenAI Compatible')),
                ],
                onChanged: (_) {},
                decoration: const InputDecoration(
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
              ),
              const SizedBox(height: 12),
              const _FieldLabel('Base URL'),
              TextField(
                controller: _urlCtrl,
                decoration: const InputDecoration(
                  hintText: 'https://api.myprovider.com/v1',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
              ),
              const SizedBox(height: 12),
              const _FieldLabel('API key'),
              TextField(
                controller: _keyCtrl,
                obscureText: true,
                decoration: const InputDecoration(
                  hintText: 'API key',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
              ),
              const _FieldHint(
                  'Optional. Leave empty if you manage auth via headers.'),
              const SizedBox(height: 14),

              // ── Models ────────────────────────────────────────────────
              Row(children: [
                Text('Models', style: theme.textTheme.labelLarge),
                const SizedBox(width: 12),
                OutlinedButton.icon(
                  onPressed: _fetching ? null : _fetchModels,
                  style: OutlinedButton.styleFrom(
                      visualDensity: VisualDensity.compact),
                  icon: _fetching
                      ? const SizedBox(
                          width: 13,
                          height: 13,
                          child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(Icons.subdirectory_arrow_right, size: 15),
                  label: const Text('Fetch models'),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: AnimatedSwitcher(
                    duration: const Duration(milliseconds: 200),
                    child: _fetchSummary(theme),
                  ),
                ),
              ]),
              const SizedBox(height: 10),
              _ModelTable(
                rows: _rows,
                onAddRow: () => setState(() {
                  if (_rows.length < _maxRows) _rows.add(_ModelRowCtl('', ''));
                }),
                onRemoveRow: (row) {
                  setState(() => _rows.remove(row));
                  row.dispose();
                },
              ),
              const SizedBox(height: 4),
              Theme(
                data: theme.copyWith(dividerColor: Colors.transparent),
                child: ExpansionTile(
                  tilePadding: EdgeInsets.zero,
                  childrenPadding: const EdgeInsets.only(bottom: 8),
                  title: Text('Advanced options',
                      style: theme.textTheme.bodyMedium),
                  children: [
                    Row(children: [
                      Expanded(
                        child: TextField(
                          controller: _modelsPathCtrl,
                          decoration: const InputDecoration(
                            labelText: 'Models path',
                            border: OutlineInputBorder(),
                            hintText: '/models',
                            isDense: true,
                          ),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: TextField(
                          controller: _chatPathCtrl,
                          decoration: const InputDecoration(
                            labelText: 'Chat path',
                            border: OutlineInputBorder(),
                            hintText: '/chat/completions',
                            isDense: true,
                          ),
                        ),
                      ),
                    ]),
                    const SizedBox(height: 10),
                    TextField(
                      controller: _headersCtrl,
                      minLines: 1,
                      maxLines: 3,
                      decoration: const InputDecoration(
                        labelText: 'Custom headers (Key: Value per line)',
                        border: OutlineInputBorder(),
                        isDense: true,
                      ),
                    ),
                    SwitchListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      title: const Text('Treat all models as free tier'),
                      value: _assumeFree,
                      onChanged: (v) => setState(() => _assumeFree = v),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
      actions: [
        // OverflowBar (AlertDialog actions) has no Flex layout — spacing is
        // handled with an inner Row.
        Row(children: [
          if (_isManage)
            TextButton(
              style: TextButton.styleFrom(
                  foregroundColor: theme.colorScheme.error),
              onPressed: _remove,
              child: const Text('Remove'),
            ),
          const Spacer(),
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton.icon(
            onPressed: _save,
            icon: const Icon(Icons.check, size: 16),
            label: Text(_isManage ? 'Save changes' : 'Connect'),
          ),
        ]),
      ],
    );
  }

  Widget _fetchSummary(ThemeData theme) {
    if (_fetching) {
      return Text('Contacting provider…',
          style: theme.textTheme.bodySmall
              ?.copyWith(color: theme.colorScheme.outline));
    }
    if (_fetchError != null) {
      return Text('✗ $_fetchError',
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: theme.textTheme.bodySmall
              ?.copyWith(color: theme.colorScheme.error));
    }
    if (_fetchCount != null) {
      return Text('✓ $_fetchCount models fetched ($_fetchFree free)',
          style: theme.textTheme.bodySmall?.copyWith(color: Colors.green));
    }
    return const SizedBox.shrink();
  }
}

class _FieldLabel extends StatelessWidget {
  final String text;

  const _FieldLabel(this.text);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Text(text, style: Theme.of(context).textTheme.labelLarge),
    );
  }
}

class _FieldHint extends StatelessWidget {
  final String text;

  const _FieldHint(this.text);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 5),
      child: Text(text,
          style: Theme.of(context).textTheme.bodySmall
              ?.copyWith(color: Theme.of(context).colorScheme.outline)),
    );
  }
}

/// Editable ID / Name model table with per-row delete and an "Add model" row.
class _ModelTable extends StatelessWidget {
  final List<_ModelRowCtl> rows;
  final VoidCallback onAddRow;
  final ValueChanged<_ModelRowCtl> onRemoveRow;

  const _ModelTable({
    required this.rows,
    required this.onAddRow,
    required this.onRemoveRow,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      decoration: BoxDecoration(
        border: Border.all(
            color: theme.colorScheme.outlineVariant.withValues(alpha: 0.6)),
        borderRadius: BorderRadius.circular(10),
      ),
      padding: const EdgeInsets.all(10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(children: [
            Expanded(child: Text('ID', style: theme.textTheme.labelMedium)),
            const SizedBox(width: 10),
            Expanded(
                flex: 2,
                child: Text('Name', style: theme.textTheme.labelMedium)),
            const SizedBox(width: 36),
          ]),
          const SizedBox(height: 8),
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 200),
            child: rows.isEmpty
                ? Padding(
                    padding: const EdgeInsets.symmetric(vertical: 10),
                    child: Text(
                      'No models yet — use “Fetch models”, or add rows '
                      'manually for providers without a /models endpoint.',
                      style: theme.textTheme.bodySmall
                          ?.copyWith(color: theme.colorScheme.outline),
                    ),
                  )
                : ListView.separated(
                    shrinkWrap: true,
                    itemCount: rows.length,
                    separatorBuilder: (_, _) => const SizedBox(height: 8),
                    itemBuilder: (context, i) {
                      final row = rows[i];
                      return Row(children: [
                        Expanded(
                          child: TextField(
                            controller: row.id,
                            decoration: const InputDecoration(
                              hintText: 'model-id',
                              border: OutlineInputBorder(),
                              isDense: true,
                            ),
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          flex: 2,
                          child: TextField(
                            controller: row.name,
                            decoration: const InputDecoration(
                              hintText: 'Display Name',
                              border: OutlineInputBorder(),
                              isDense: true,
                            ),
                          ),
                        ),
                        SizedBox(
                          width: 36,
                          child: IconButton(
                            visualDensity: VisualDensity.compact,
                            tooltip: 'Remove model',
                            icon: Icon(Icons.delete_outline,
                                size: 16, color: theme.colorScheme.error),
                            onPressed: () => onRemoveRow(row),
                          ),
                        ),
                      ]);
                    },
                  ),
          ),
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: onAddRow,
              icon: const Icon(Icons.add, size: 15),
              label: const Text('Add model'),
            ),
          ),
        ],
      ),
    );
  }
}
