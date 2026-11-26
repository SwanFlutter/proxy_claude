import 'package:flutter/material.dart';

enum TunnelMode { token, quick }

extension TunnelModeX on TunnelMode {
  String get label => switch (this) {
        TunnelMode.token => 'Tunnel Token (Cloudflare-managed)',
        TunnelMode.quick => 'Quick Tunnel (trycloudflare.com, no account)',
      };
}

/// Non-secret application settings, persisted to SharedPreferences as JSON.
/// Secrets (provider API keys, tunnel token, local proxy key) live in
/// flutter_secure_storage — see [SettingsService].
class AppSettings {
  final int port;
  final bool bindLan;
  final bool requireAuth;
  final bool autoSync;
  final int syncIntervalMinutes;
  final int upstreamTimeoutSeconds;
  final String? defaultModel;
  final bool showFreeOnly;

  /// Serve the virtual `auto` model (smart routing over every provider).
  final bool exposeAutoModel;

  /// Hide upstream model ids from `/v1/models`: clients then only ever see
  /// `auto`, so nothing has to be selected in the client at all.
  final bool autoModelOnly;

  /// Let `auto` inspect the request and start small for trivial/simple tasks
  /// instead of always using the strongest model first.
  final bool smartTaskRouting;

  final ThemeMode themeMode;
  final bool startProxyOnLaunch;
  final bool minimizeToTray;
  final TunnelMode tunnelMode;
  final String publicHostname;
  final String cloudflaredPath;

  // ── Claude Code integration ────────────────────────────────────────────────
  /// Write the tunnel's public URL into Claude Code's settings.json instead of
  /// `http://127.0.0.1:<port>`.
  final bool claudeCodeUseTunnel;

  /// Rewrite Claude Code's settings.json whenever the URL or key changes
  /// (a quick tunnel gets a new `trycloudflare.com` host on every start).
  final bool claudeCodeKeepInSync;

  /// Use the virtual `auto` models (`auto`, `auto:strong`, `auto:fast`) instead
  /// of concrete upstream model ids.
  final bool claudeCodeAutoModels;

  /// Empty = `%USERPROFILE%\.claude\settings.json`.
  final String claudeCodePath;

  const AppSettings({
    this.port = 8080,
    this.bindLan = false,
    this.requireAuth = true,
    this.autoSync = true,
    this.syncIntervalMinutes = 30,
    this.upstreamTimeoutSeconds = 90,
    this.defaultModel,
    this.showFreeOnly = true,
    this.exposeAutoModel = true,
    this.autoModelOnly = false,
    this.smartTaskRouting = true,
    this.themeMode = ThemeMode.system,
    this.startProxyOnLaunch = true,
    this.minimizeToTray = true,
    this.tunnelMode = TunnelMode.quick,
    this.publicHostname = '',
    this.cloudflaredPath = '',
    this.claudeCodeUseTunnel = false,
    this.claudeCodeKeepInSync = true,
    this.claudeCodeAutoModels = true,
    this.claudeCodePath = '',
  });

  factory AppSettings.defaults() => const AppSettings();

  AppSettings copyWith({
    int? port,
    bool? bindLan,
    bool? requireAuth,
    bool? autoSync,
    int? syncIntervalMinutes,
    int? upstreamTimeoutSeconds,
    Object? defaultModel = _sentinel,
    bool? showFreeOnly,
    bool? exposeAutoModel,
    bool? autoModelOnly,
    bool? smartTaskRouting,
    ThemeMode? themeMode,
    bool? startProxyOnLaunch,
    bool? minimizeToTray,
    TunnelMode? tunnelMode,
    String? publicHostname,
    String? cloudflaredPath,
    bool? claudeCodeUseTunnel,
    bool? claudeCodeKeepInSync,
    bool? claudeCodeAutoModels,
    String? claudeCodePath,
  }) =>
      AppSettings(
        port: port ?? this.port,
        bindLan: bindLan ?? this.bindLan,
        requireAuth: requireAuth ?? this.requireAuth,
        autoSync: autoSync ?? this.autoSync,
        syncIntervalMinutes: syncIntervalMinutes ?? this.syncIntervalMinutes,
        upstreamTimeoutSeconds:
            upstreamTimeoutSeconds ?? this.upstreamTimeoutSeconds,
        defaultModel: defaultModel == _sentinel
            ? this.defaultModel
            : defaultModel as String?,
        showFreeOnly: showFreeOnly ?? this.showFreeOnly,
        exposeAutoModel: exposeAutoModel ?? this.exposeAutoModel,
        autoModelOnly: autoModelOnly ?? this.autoModelOnly,
        smartTaskRouting: smartTaskRouting ?? this.smartTaskRouting,
        themeMode: themeMode ?? this.themeMode,
        startProxyOnLaunch: startProxyOnLaunch ?? this.startProxyOnLaunch,
        minimizeToTray: minimizeToTray ?? this.minimizeToTray,
        tunnelMode: tunnelMode ?? this.tunnelMode,
        publicHostname: publicHostname ?? this.publicHostname,
        cloudflaredPath: cloudflaredPath ?? this.cloudflaredPath,
        claudeCodeUseTunnel: claudeCodeUseTunnel ?? this.claudeCodeUseTunnel,
        claudeCodeKeepInSync: claudeCodeKeepInSync ?? this.claudeCodeKeepInSync,
        claudeCodeAutoModels:
            claudeCodeAutoModels ?? this.claudeCodeAutoModels,
        claudeCodePath: claudeCodePath ?? this.claudeCodePath,
      );

  Map<String, dynamic> toJson() => {
        'port': port,
        'bindLan': bindLan,
        'requireAuth': requireAuth,
        'autoSync': autoSync,
        'syncIntervalMinutes': syncIntervalMinutes,
        'upstreamTimeoutSeconds': upstreamTimeoutSeconds,
        'defaultModel': defaultModel,
        'showFreeOnly': showFreeOnly,
        'exposeAutoModel': exposeAutoModel,
        'autoModelOnly': autoModelOnly,
        'smartTaskRouting': smartTaskRouting,
        'themeMode': themeMode.index,
        'startProxyOnLaunch': startProxyOnLaunch,
        'minimizeToTray': minimizeToTray,
        'tunnelMode': tunnelMode.index,
        'publicHostname': publicHostname,
        'cloudflaredPath': cloudflaredPath,
        'claudeCodeUseTunnel': claudeCodeUseTunnel,
        'claudeCodeKeepInSync': claudeCodeKeepInSync,
        'claudeCodeAutoModels': claudeCodeAutoModels,
        'claudeCodePath': claudeCodePath,
      };

  factory AppSettings.fromJson(Map<String, dynamic> j) => AppSettings(
        port: (j['port'] as num?)?.toInt() ?? 8080,
        bindLan: (j['bindLan'] ?? false) as bool,
        requireAuth: (j['requireAuth'] ?? true) as bool,
        autoSync: (j['autoSync'] ?? true) as bool,
        syncIntervalMinutes: (j['syncIntervalMinutes'] as num?)?.toInt() ?? 30,
        upstreamTimeoutSeconds:
            (j['upstreamTimeoutSeconds'] as num?)?.toInt() ?? 90,
        defaultModel: j['defaultModel'] as String?,
        showFreeOnly: (j['showFreeOnly'] ?? true) as bool,
        exposeAutoModel: (j['exposeAutoModel'] ?? true) as bool,
        autoModelOnly: (j['autoModelOnly'] ?? false) as bool,
        smartTaskRouting: (j['smartTaskRouting'] ?? true) as bool,
        themeMode:
            ThemeMode.values[((j['themeMode'] as num?)?.toInt() ?? 0).clamp(0, 2)],
        startProxyOnLaunch: (j['startProxyOnLaunch'] ?? true) as bool,
        minimizeToTray: (j['minimizeToTray'] ?? true) as bool,
        tunnelMode: TunnelMode
            .values[((j['tunnelMode'] as num?)?.toInt() ?? 1).clamp(0, 1)],
        publicHostname: (j['publicHostname'] ?? '') as String,
        cloudflaredPath: (j['cloudflaredPath'] ?? '') as String,
        claudeCodeUseTunnel: (j['claudeCodeUseTunnel'] ?? false) as bool,
        claudeCodeKeepInSync: (j['claudeCodeKeepInSync'] ?? true) as bool,
        claudeCodeAutoModels: (j['claudeCodeAutoModels'] ?? true) as bool,
        claudeCodePath: (j['claudeCodePath'] ?? '') as String,
      );
}

const _sentinel = Object();
