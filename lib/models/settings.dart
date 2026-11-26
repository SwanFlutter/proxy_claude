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
  final ThemeMode themeMode;
  final bool startProxyOnLaunch;
  final bool minimizeToTray;
  final TunnelMode tunnelMode;
  final String publicHostname;
  final String cloudflaredPath;

  const AppSettings({
    this.port = 8080,
    this.bindLan = false,
    this.requireAuth = true,
    this.autoSync = true,
    this.syncIntervalMinutes = 30,
    this.upstreamTimeoutSeconds = 90,
    this.defaultModel,
    this.showFreeOnly = true,
    this.themeMode = ThemeMode.system,
    this.startProxyOnLaunch = true,
    this.minimizeToTray = true,
    this.tunnelMode = TunnelMode.quick,
    this.publicHostname = '',
    this.cloudflaredPath = '',
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
    ThemeMode? themeMode,
    bool? startProxyOnLaunch,
    bool? minimizeToTray,
    TunnelMode? tunnelMode,
    String? publicHostname,
    String? cloudflaredPath,
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
        themeMode: themeMode ?? this.themeMode,
        startProxyOnLaunch: startProxyOnLaunch ?? this.startProxyOnLaunch,
        minimizeToTray: minimizeToTray ?? this.minimizeToTray,
        tunnelMode: tunnelMode ?? this.tunnelMode,
        publicHostname: publicHostname ?? this.publicHostname,
        cloudflaredPath: cloudflaredPath ?? this.cloudflaredPath,
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
        'themeMode': themeMode.index,
        'startProxyOnLaunch': startProxyOnLaunch,
        'minimizeToTray': minimizeToTray,
        'tunnelMode': tunnelMode.index,
        'publicHostname': publicHostname,
        'cloudflaredPath': cloudflaredPath,
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
        themeMode:
            ThemeMode.values[((j['themeMode'] as num?)?.toInt() ?? 0).clamp(0, 2)],
        startProxyOnLaunch: (j['startProxyOnLaunch'] ?? true) as bool,
        minimizeToTray: (j['minimizeToTray'] ?? true) as bool,
        tunnelMode: TunnelMode
            .values[((j['tunnelMode'] as num?)?.toInt() ?? 1).clamp(0, 1)],
        publicHostname: (j['publicHostname'] ?? '') as String,
        cloudflaredPath: (j['cloudflaredPath'] ?? '') as String,
      );
}

const _sentinel = Object();
