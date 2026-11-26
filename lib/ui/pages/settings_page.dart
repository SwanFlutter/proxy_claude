import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/model_router.dart';
import '../../models/settings.dart';
import '../../services/claude_code_config.dart';
import '../../services/tunnel_manager.dart' show TunnelStatus;
import '../../state/controllers.dart';
import '../widgets/common.dart';

class SettingsPage extends ConsumerStatefulWidget {
  const SettingsPage({super.key});

  @override
  ConsumerState<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends ConsumerState<SettingsPage> {
  late TextEditingController _portCtrl;
  late TextEditingController _intervalCtrl;
  late TextEditingController _timeoutCtrl;
  late TextEditingController _tokenCtrl;
  late TextEditingController _hostnameCtrl;
  late TextEditingController _cloudflaredPathCtrl;
  bool _obscureToken = true;
  bool _obscureKey = true;
  bool _checkingVersion = false;

  @override
  void initState() {
    super.initState();
    final s = ref.read(settingsNotifierProvider);
    _portCtrl = TextEditingController(text: '${s.port}');
    _intervalCtrl = TextEditingController(text: '${s.syncIntervalMinutes}');
    _timeoutCtrl = TextEditingController(text: '${s.upstreamTimeoutSeconds}');
    _tokenCtrl = TextEditingController(
      text: ref.read(settingsServiceProvider).tunnelToken,
    );
    _hostnameCtrl = TextEditingController(text: s.publicHostname);
    _cloudflaredPathCtrl = TextEditingController(text: s.cloudflaredPath);
  }

  @override
  void dispose() {
    _portCtrl.dispose();
    _intervalCtrl.dispose();
    _timeoutCtrl.dispose();
    _tokenCtrl.dispose();
    _hostnameCtrl.dispose();
    _cloudflaredPathCtrl.dispose();
    super.dispose();
  }

  AppSettings _buildSettings(AppSettings current) {
    return current.copyWith(
      port: int.tryParse(_portCtrl.text.trim()) ?? current.port,
      syncIntervalMinutes:
          int.tryParse(_intervalCtrl.text.trim()) ??
          current.syncIntervalMinutes,
      upstreamTimeoutSeconds:
          int.tryParse(_timeoutCtrl.text.trim()) ??
          current.upstreamTimeoutSeconds,
      cloudflaredPath: _cloudflaredPathCtrl.text.trim(),
      publicHostname: _hostnameCtrl.text.trim(),
    );
  }

  Future<void> _saveProxy() async {
    final notifier = ref.read(settingsNotifierProvider.notifier);
    final updated = _buildSettings(ref.read(settingsNotifierProvider)).copyWith(
      bindLan: ref.read(settingsNotifierProvider).bindLan,
      requireAuth: ref.read(settingsNotifierProvider).requireAuth,
      startProxyOnLaunch: ref.read(settingsNotifierProvider).startProxyOnLaunch,
    );
    notifier.update(updated);
    final proxy = ref.read(proxyControllerProvider);
    if (proxy.status == ProxyStatus.running) {
      await ref.read(proxyControllerProvider.notifier).restart();
    }
    if (!mounted) return;
    showSnack(context, 'Proxy settings saved.');
  }

  Future<void> _saveSync() async {
    final s = ref.read(settingsNotifierProvider);
    final updated = _buildSettings(s).copyWith(autoSync: s.autoSync);
    ref.read(settingsNotifierProvider.notifier).update(updated);
    ref.read(syncControllerProvider.notifier).startAuto();
    if (!mounted) return;
    showSnack(context, 'Sync settings saved.');
  }

  Future<void> _saveTunnel() async {
    final svc = ref.read(settingsServiceProvider);
    final s = ref.read(settingsNotifierProvider);
    final updated = _buildSettings(s);
    ref.read(settingsNotifierProvider.notifier).update(updated);
    await svc.setTunnelToken(_tokenCtrl.text.trim());
    if (!mounted) return;
    showSnack(context, 'Tunnel settings saved.');
  }

  @override
  Widget build(BuildContext context) {
    final s = ref.watch(settingsNotifierProvider);
    final svc = ref.watch(settingsServiceProvider);
    final models = ref.watch(modelsStreamProvider).value ?? const [];
    final tunnel = ref.watch(tunnelControllerProvider);

    // Build the default-model dropdown items defensively: dedupe by id and
    // make sure the currently-selected default is always present exactly once.
    // Otherwise DropdownButton asserts when the model list is still loading
    // (empty) or contains duplicate ids ("exactly one item with value …").
    final seenIds = <String>{};
    final defaultModelItems = <DropdownMenuItem<String?>>[
      const DropdownMenuItem(value: null, child: Text('None')),
    ];
    for (final m in models) {
      if (seenIds.add(m.id)) {
        defaultModelItems.add(DropdownMenuItem(value: m.id, child: Text(m.id)));
      }
    }
    final dm = s.defaultModel;
    if (dm != null && dm.isNotEmpty && !seenIds.contains(dm)) {
      defaultModelItems.add(DropdownMenuItem(value: dm, child: Text(dm)));
    }

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        // ── Proxy & security ────────────────────────────────────────────────
        SectionCard(
          icon: Icons.dns_outlined,
          title: 'Proxy & Security',
          child: Column(
            children: [
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _portCtrl,
                      decoration: const InputDecoration(
                        labelText: 'Port',
                        border: OutlineInputBorder(),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('Bind 0.0.0.0 (LAN access)'),
                      value: s.bindLan,
                      onChanged: (v) => setState(
                        () => ref
                            .read(settingsNotifierProvider.notifier)
                            .update(
                              ref
                                  .read(settingsNotifierProvider)
                                  .copyWith(bindLan: v),
                            ),
                      ),
                    ),
                  ),
                ],
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text(
                  'Require API key (Authorization / X-API-Key)',
                ),
                value: s.requireAuth,
                onChanged: (v) => setState(
                  () => ref
                      .read(settingsNotifierProvider.notifier)
                      .update(
                        ref
                            .read(settingsNotifierProvider)
                            .copyWith(requireAuth: v),
                      ),
                ),
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Start proxy automatically on launch'),
                value: s.startProxyOnLaunch,
                onChanged: (v) => setState(
                  () => ref
                      .read(settingsNotifierProvider.notifier)
                      .update(
                        ref
                            .read(settingsNotifierProvider)
                            .copyWith(startProxyOnLaunch: v),
                      ),
                ),
              ),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      readOnly: true,
                      obscureText: _obscureKey,
                      controller: TextEditingController(text: svc.localApiKey),
                      decoration: const InputDecoration(
                        labelText: 'Local proxy API key (secure storage)',
                        border: OutlineInputBorder(),
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: _obscureKey ? 'Reveal' : 'Hide',
                    icon: Icon(
                      _obscureKey ? Icons.visibility : Icons.visibility_off,
                      size: 18,
                    ),
                    onPressed: () => setState(() => _obscureKey = !_obscureKey),
                  ),
                  IconButton(
                    tooltip: 'Copy',
                    icon: const Icon(Icons.copy, size: 18),
                    onPressed: () =>
                        copyToClipboard(context, svc.localApiKey, 'API key'),
                  ),
                  IconButton(
                    tooltip: 'Regenerate',
                    icon: const Icon(Icons.refresh, size: 18),
                    onPressed: () async {
                      await svc.regenerateLocalKey();
                      if (!context.mounted) return;
                      setState(() {});
                      showSnack(context, 'New API key generated.');
                    },
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Align(
                alignment: Alignment.centerRight,
                child: FilledButton(
                  onPressed: _saveProxy,
                  child: const Text('Save Proxy Settings'),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),

        // ── Auto-sync ───────────────────────────────────────────────────────
        SectionCard(
          icon: Icons.sync,
          title: 'Auto-Sync',
          child: Column(
            children: [
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Re-fetch model lists periodically'),
                subtitle: const Text(
                  'New free models are added and deleted models are removed automatically.',
                ),
                value: s.autoSync,
                onChanged: (v) => setState(
                  () => ref
                      .read(settingsNotifierProvider.notifier)
                      .update(
                        ref
                            .read(settingsNotifierProvider)
                            .copyWith(autoSync: v),
                      ),
                ),
              ),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _intervalCtrl,
                      decoration: const InputDecoration(
                        labelText: 'Interval (minutes)',
                        border: OutlineInputBorder(),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: TextField(
                      controller: _timeoutCtrl,
                      decoration: const InputDecoration(
                        labelText: 'Upstream timeout (seconds)',
                        border: OutlineInputBorder(),
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Align(
                alignment: Alignment.centerRight,
                child: FilledButton(
                  onPressed: _saveSync,
                  child: const Text('Save Sync Settings'),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),

        // ── Model routing / auto model ──────────────────────────────────────
        SectionCard(
          icon: Icons.auto_awesome,
          title: 'Model Routing',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Serve the virtual "auto" model'),
                subtitle: Text(
                  'One model id (${AutoModel.canonical}) backed by every model of every '
                  'connected provider — nothing to pick in the client. '
                  '${models.length} model(s) currently in the pool.',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                value: s.exposeAutoModel,
                onChanged: (v) => setState(
                  () => ref
                      .read(settingsNotifierProvider.notifier)
                      .update(
                        ref
                            .read(settingsNotifierProvider)
                            .copyWith(exposeAutoModel: v),
                      ),
                ),
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Smart task routing'),
                subtitle: Text(
                  s.smartTaskRouting
                      ? 'auto reads the request: trivial/simple prompts start on a light model, '
                            'complex work starts on the strongest one. Failover always escalates.'
                      : 'auto always starts at the strongest tier.',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                value: s.smartTaskRouting,
                onChanged: (v) => setState(
                  () => ref
                      .read(settingsNotifierProvider.notifier)
                      .update(
                        ref
                            .read(settingsNotifierProvider)
                            .copyWith(smartTaskRouting: v),
                      ),
                ),
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Advertise only "auto" in /v1/models'),
                subtitle: Text(
                  'Hides upstream model ids from model discovery, so clients can only '
                  'select the proxy model. Real ids keep working when sent explicitly.',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                value: s.autoModelOnly,
                onChanged: (v) => setState(
                  () => ref
                      .read(settingsNotifierProvider.notifier)
                      .update(
                        ref
                            .read(settingsNotifierProvider)
                            .copyWith(autoModelOnly: v),
                      ),
                ),
              ),
              const SizedBox(height: 6),
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.surfaceContainerHighest
                      .withValues(alpha: 0.5),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Claude Code / any OpenAI client',
                      style: Theme.of(context).textTheme.labelLarge,
                    ),
                    const SizedBox(height: 4),
                    SelectableText(
                      'ANTHROPIC_DEFAULT_OPUS_MODEL=${AutoModel.canonical}\n'
                      'ANTHROPIC_DEFAULT_SONNET_MODEL=${AutoModel.canonical}\n'
                      'ANTHROPIC_DEFAULT_HAIKU_MODEL=${AutoModel.canonical}\n'
                      '# or force a strategy: ${AutoModel.strongVariant} · ${AutoModel.fastVariant}',
                      style: Theme.of(context).textTheme.bodySmall
                          ?.copyWith(fontFamily: 'monospace'),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),

        // ── Claude Code ─────────────────────────────────────────────────────
        const ClaudeCodeCard(),
        const SizedBox(height: 12),

        // ── Cloudflare Tunnel ───────────────────────────────────────────────
        SectionCard(
          icon: Icons.cloud_outlined,
          title: 'Cloudflare Tunnel',
          trailing: tunnel.status == TunnelStatus.connected
              ? Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const StatusDot(color: Colors.green, size: 8),
                    const SizedBox(width: 5),
                    Text(
                      'Connected',
                      style: Theme.of(context).textTheme.labelSmall,
                    ),
                  ],
                )
              : null,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SegmentedButton<TunnelMode>(
                segments: const [
                  ButtonSegment(
                    value: TunnelMode.quick,
                    icon: Icon(Icons.flash_on, size: 16),
                    label: Text('Quick (trycloudflare)'),
                  ),
                  ButtonSegment(
                    value: TunnelMode.token,
                    icon: Icon(Icons.key, size: 16),
                    label: Text('Token (your domain)'),
                  ),
                ],
                selected: {s.tunnelMode},
                onSelectionChanged: (sel) => setState(
                  () => ref
                      .read(settingsNotifierProvider.notifier)
                      .update(
                        ref
                            .read(settingsNotifierProvider)
                            .copyWith(tunnelMode: sel.first),
                      ),
                ),
              ),
              const SizedBox(height: 10),
              if (s.tunnelMode == TunnelMode.token) ...[
                TextField(
                  controller: _tokenCtrl,
                  obscureText: _obscureToken,
                  decoration: InputDecoration(
                    labelText: 'Tunnel token (cloudflared token)',
                    border: const OutlineInputBorder(),
                    suffixIcon: IconButton(
                      icon: Icon(
                        _obscureToken ? Icons.visibility_off : Icons.visibility,
                        size: 18,
                      ),
                      onPressed: () =>
                          setState(() => _obscureToken = !_obscureToken),
                    ),
                  ),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: _hostnameCtrl,
                  decoration: const InputDecoration(
                    labelText: 'Public hostname (configured in Cloudflare DNS)',
                    border: OutlineInputBorder(),
                    hintText: 'llm-proxy.yourdomain.com',
                  ),
                ),
                const SizedBox(height: 10),
              ],
              TextField(
                controller: _cloudflaredPathCtrl,
                decoration: const InputDecoration(
                  labelText:
                      'cloudflared.exe path (leave empty for auto-detect)',
                  border: OutlineInputBorder(),
                  hintText: 'C:\\\\tools\\\\cloudflared.exe',
                ),
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  TextButton.icon(
                    onPressed: _checkingVersion
                        ? null
                        : () async {
                            setState(() => _checkingVersion = true);
                            final v = await ref
                                .read(tunnelManagerProvider)
                                .version();
                            if (!context.mounted) return;
                            setState(() => _checkingVersion = false);
                            showSnack(
                              context,
                              v == null
                                  ? 'cloudflared not found.'
                                  : 'Found: $v',
                            );
                          },
                    icon: const Icon(Icons.search, size: 16),
                    label: const Text('Detect'),
                  ),
                  const SizedBox(width: 8),
                  TextButton.icon(
                    onPressed: () async {
                      await ref
                          .read(tunnelControllerProvider.notifier)
                          .downloadBinary();
                      if (context.mounted)
                        showSnack(context, 'cloudflared download finished.');
                    },
                    icon: const Icon(Icons.download, size: 16),
                    label: const Text('Download cloudflared'),
                  ),
                  if (tunnel.status == TunnelStatus.downloading)
                    SizedBox(
                      width: 140,
                      child: LinearProgressIndicator(
                        value: tunnel.downloadProgress,
                      ),
                    ),
                  const Spacer(),
                  if (tunnel.status == TunnelStatus.connected ||
                      tunnel.status == TunnelStatus.starting)
                    FilledButton.tonalIcon(
                      onPressed: () => ref
                          .read(tunnelControllerProvider.notifier)
                          .disconnect(),
                      icon: const Icon(Icons.link_off, size: 16),
                      label: const Text('Disconnect'),
                    )
                  else
                    FilledButton.tonalIcon(
                      onPressed: () =>
                          ref.read(tunnelControllerProvider.notifier).connect(),
                      icon: const Icon(Icons.link, size: 16),
                      label: const Text('Connect Tunnel'),
                    ),
                ],
              ),
              if (tunnel.publicUrl != null)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Row(
                    children: [
                      Text(
                        'URL: ${tunnel.publicUrl}',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                      IconButton(
                        icon: const Icon(Icons.copy, size: 14),
                        onPressed: () => copyToClipboard(
                          context,
                          tunnel.publicUrl!,
                          'Public URL',
                        ),
                      ),
                    ],
                  ),
                ),
              Align(
                alignment: Alignment.centerRight,
                child: FilledButton(
                  onPressed: _saveTunnel,
                  child: const Text('Save Tunnel Settings'),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),

        // ── Appearance & defaults ───────────────────────────────────────────
        SectionCard(
          icon: Icons.palette_outlined,
          title: 'Appearance & Defaults',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Text('Theme'),
                  const SizedBox(width: 12),
                  SegmentedButton<ThemeMode>(
                    segments: const [
                      ButtonSegment(
                        value: ThemeMode.system,
                        label: Text('System'),
                      ),
                      ButtonSegment(
                        value: ThemeMode.light,
                        label: Text('Light'),
                      ),
                      ButtonSegment(value: ThemeMode.dark, label: Text('Dark')),
                    ],
                    selected: {s.themeMode},
                    onSelectionChanged: (sel) => ref
                        .read(settingsNotifierProvider.notifier)
                        .update(
                          ref
                              .read(settingsNotifierProvider)
                              .copyWith(themeMode: sel.first),
                        ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<String?>(
                initialValue: s.defaultModel,
                decoration: const InputDecoration(
                  labelText: 'Default failover model (last resort)',
                  border: OutlineInputBorder(),
                ),
                items: defaultModelItems,
                onChanged: (v) => ref
                    .read(settingsNotifierProvider.notifier)
                    .update(
                      ref
                          .read(settingsNotifierProvider)
                          .copyWith(defaultModel: v),
                    ),
              ),
              const SizedBox(height: 8),
              Text(
                'Failover order: requested model → same-provider alternates → '
                'other enabled providers (free first) → default model.',
                style: Theme.of(context).textTheme.bodySmall
                    ?.copyWith(color: Theme.of(context).colorScheme.outline),
              ),
            ],
          ),
        ),
        const SizedBox(height: 24),
      ],
    );
  }
}

/// Writes Claude Code's own `settings.json` (URL + proxy key + model names)
/// from inside the app, and keeps it aligned with the live tunnel URL.
class ClaudeCodeCard extends ConsumerStatefulWidget {
  const ClaudeCodeCard({super.key});

  @override
  ConsumerState<ClaudeCodeCard> createState() => _ClaudeCodeCardState();
}

class _ClaudeCodeCardState extends ConsumerState<ClaudeCodeCard> {
  late final TextEditingController _pathCtrl;
  bool _pathInitialised = false;
  bool _showJson = false;

  @override
  void dispose() {
    if (_pathInitialised) _pathCtrl.dispose();
    super.dispose();
  }

  void _initPath(String current) {
    if (_pathInitialised) return;
    _pathInitialised = true;
    _pathCtrl = TextEditingController(text: current);
  }

  Future<void> _act(
    Future<ClaudeWriteResult?> Function() action,
    String okPrefix,
  ) async {
    final result = await action();
    if (!mounted) return;
    showSnack(
      context,
      result == null
          ? '$okPrefix — nothing to change.'
          : '$okPrefix (${result.changes.length} key(s) written)\n'
                '${result.path}'
                '${result.backupPath == null ? '' : '\nbackup: ${result.backupPath}'}',
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final s = ref.watch(settingsNotifierProvider);
    final cc = ref.watch(claudeCodeControllerProvider);
    final tunnel = ref.watch(tunnelControllerProvider);
    _initPath(cc.path);
    if (_pathCtrl.text.isEmpty && cc.path.isNotEmpty) _pathCtrl.text = cc.path;

    final preview = ClaudeCodeConfig.encode({
      'env': ClaudeCodeConfig.envFor(
        baseUrl: cc.baseUrl,
        authToken: ref.read(settingsServiceProvider).localApiKey,
        autoModels: s.claudeCodeAutoModels,
      ),
    });

    return SectionCard(
      icon: Icons.terminal_outlined,
      title: 'Claude Code',
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          StatusDot(
            color: cc.install.upToDate
                ? Colors.green
                : (cc.install.installed ? Colors.orange : Colors.grey),
            size: 8,
          ),
          const SizedBox(width: 5),
          Text(
            cc.install.summary,
            style: theme.textTheme.labelSmall?.copyWith(
              color: theme.colorScheme.outline,
            ),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Claude Code (Windows: %USERPROFILE%\\.claude\\settings.json) reads its '
            'gateway from an env block. This writes the URL, the proxy key and the '
            'model names for you — no hand-editing, and it repairs itself when the '
            'tunnel URL changes.',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.outline,
              height: 1.5,
            ),
          ),
          const SizedBox(height: 14),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Use the tunnel URL (works from other machines)'),
            subtitle: Text(
              tunnel.publicUrl == null
                  ? 'Tunnel is not connected — it will be started on write'
                  : 'Currently ${tunnel.publicUrl}',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.outline,
              ),
            ),
            value: s.claudeCodeUseTunnel,
            onChanged: (v) => ref
                .read(settingsNotifierProvider.notifier)
                .update(s.copyWith(claudeCodeUseTunnel: v)),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Keep settings.json in sync'),
            subtitle: Text(
              'Rewrites the file whenever the URL or the key changes. A quick '
              'tunnel gets a brand new host on every start, so without this '
              'Claude Code breaks after a restart.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.outline,
              ),
            ),
            value: s.claudeCodeKeepInSync,
            onChanged: (v) => ref
                .read(settingsNotifierProvider.notifier)
                .update(s.copyWith(claudeCodeKeepInSync: v)),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Route through the auto model'),
            subtitle: Text(
              'ANTHROPIC_MODEL=auto, opus=auto:strong, haiku=auto:fast. Turn this '
              'off to leave the model keys untouched and pick them yourself.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.outline,
              ),
            ),
            value: s.claudeCodeAutoModels,
            onChanged: (v) => ref
                .read(settingsNotifierProvider.notifier)
                .update(s.copyWith(claudeCodeAutoModels: v)),
          ),
          const SizedBox(height: 6),
          TextField(
            controller: _pathCtrl,
            style: theme.textTheme.bodySmall?.copyWith(fontFamily: 'Consolas'),
            decoration: InputDecoration(
              labelText: 'Settings file',
              helperText: 'empty = ${ClaudeCodeConfig.defaultPath()}',
              helperMaxLines: 2,
              suffixIcon: s.claudeCodePath.isEmpty
                  ? null
                  : IconButton(
                      tooltip: 'Use the default location',
                      icon: const Icon(Icons.restore),
                      onPressed: () {
                        _pathCtrl.clear();
                        ref
                            .read(settingsNotifierProvider.notifier)
                            .update(s.copyWith(claudeCodePath: ''));
                      },
                    ),
            ),
            onSubmitted: (v) => ref
                .read(settingsNotifierProvider.notifier)
                .update(s.copyWith(claudeCodePath: v.trim())),
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              FilledButton.icon(
                onPressed: cc.busy
                    ? null
                    : () => _act(
                        () => ref
                            .read(claudeCodeControllerProvider.notifier)
                            .install(),
                        'Claude Code configured',
                      ),
                icon: const Icon(Icons.upload_outlined, size: 18),
                label: Text(
                  cc.install.installed && !cc.install.upToDate
                      ? 'Update settings.json'
                      : 'Write settings.json',
                ),
              ),
              if (s.claudeCodeUseTunnel && !cc.tunnelReady)
                OutlinedButton.icon(
                  onPressed: cc.busy
                      ? null
                      : () => ref
                            .read(claudeCodeControllerProvider.notifier)
                            .ensureTunnel(),
                  icon: const Icon(Icons.cloud_outlined, size: 18),
                  label: const Text('Start tunnel'),
                ),
              OutlinedButton.icon(
                onPressed: cc.busy
                    ? null
                    : () => _act(
                        () => ref
                            .read(claudeCodeControllerProvider.notifier)
                            .remove(),
                        'Removed proxy keys',
                      ),
                icon: const Icon(Icons.delete_outline, size: 18),
                label: const Text('Remove proxy keys'),
              ),
              OutlinedButton.icon(
                onPressed: () => setState(() => _showJson = !_showJson),
                icon: const Icon(Icons.data_object_outlined, size: 18),
                label: Text(_showJson ? 'Hide JSON' : 'Preview JSON'),
              ),
              OutlinedButton.icon(
                onPressed: () =>
                    copyToClipboard(context, preview, 'settings.json'),
                icon: const Icon(Icons.copy_all_outlined, size: 18),
                label: const Text('Copy'),
              ),
            ],
          ),
          if (cc.error != null) ...[
            const SizedBox(height: 10),
            SelectableText(
              cc.error!,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.error,
              ),
            ),
          ],
          if (cc.lastChanges.isNotEmpty) ...[
            const SizedBox(height: 8),
            SelectableText(
              cc.lastChanges.join('\n'),
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.outline,
                fontFamily: 'Consolas',
              ),
            ),
          ],
          if (_showJson) ...[
            const SizedBox(height: 12),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: theme.colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(10),
              ),
              child: SelectableText(
                preview,
                style: theme.textTheme.bodySmall?.copyWith(
                  fontFamily: 'Consolas',
                  height: 1.5,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
