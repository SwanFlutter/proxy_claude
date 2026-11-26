import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import '../core/utils.dart';
import '../models/provider_config.dart';
import '../models/settings.dart';

/// Persists non-secret config and secrets.
///
/// Secrets (provider API keys, tunnel token, local proxy key) are stored in
/// SharedPreferences with base64 obfuscation. The project constraint allows
/// "SharedPreferences or flutter_secure_storage"; flutter_secure_storage was
/// dropped because its Windows plugin requires the VS C++ ATL component.
/// To harden later: swap [SettingsService]'s secret storage for
/// flutter_secure_storage (install "C++ ATL for v143" in VS Installer first).
class SettingsService {
  static const _settingsKey = 'proxy_hub.settings';
  static const _providersKey = 'proxy_hub.providers';
  static const _localKeyEntry = 'proxy_hub.local_api_key';
  static const _tunnelTokenEntry = 'proxy_hub.tunnel_token';
  static String _providerKeyEntry(String id) => 'proxy_hub.provider_key.$id';

  AppSettings appSettings = AppSettings.defaults();
  List<ProviderConfig> providers = [];
  String localApiKey = '';
  String tunnelToken = '';

  late SharedPreferences _prefs;

  /// Base64 obfuscation so keys are not plainly readable in prefs files.
  /// NOTE: this is not encryption — see class docs.
  static String _obfuscate(String value) =>
      base64Encode(utf8.encode(value));
  static String _deobfuscate(String stored) {
    try {
      return utf8.decode(base64Decode(stored));
    } catch (_) {
      // Written by an older/plain-text version — return as-is.
      return stored;
    }
  }

  Future<void> load() async {
    _prefs = await SharedPreferences.getInstance();

    final raw = _prefs.getString(_settingsKey);
    if (raw != null) {
      try {
        appSettings =
            AppSettings.fromJson(jsonDecode(raw) as Map<String, dynamic>);
      } catch (_) {
        appSettings = AppSettings.defaults();
      }
    }

    final provRaw = _prefs.getString(_providersKey);
    if (provRaw != null) {
      try {
        final list = (jsonDecode(provRaw) as List).cast<Map<String, dynamic>>();
        providers = list.map(ProviderConfig.fromJson).toList();
      } catch (_) {
        providers = [];
      }
    }
    // No auto-seeding: fresh installs start with an empty configured list and
    // connect providers from the catalog UI instead.

    // Merge per-provider API keys.
    final merged = <ProviderConfig>[];
    for (final p in providers) {
      final stored = _prefs.getString(_providerKeyEntry(p.id));
      final key =
          (stored != null && stored.isNotEmpty) ? _deobfuscate(stored) : p.apiKey;
      merged.add(p.copyWith(apiKey: key));
    }
    providers = merged;

    final storedLocal = _prefs.getString(_localKeyEntry);
    if (storedLocal != null && storedLocal.isNotEmpty) {
      localApiKey = _deobfuscate(storedLocal);
    } else {
      localApiKey = generateApiKey();
      await _prefs.setString(_localKeyEntry, _obfuscate(localApiKey));
    }

    final storedToken = _prefs.getString(_tunnelTokenEntry);
    tunnelToken =
        (storedToken != null && storedToken.isNotEmpty) ? _deobfuscate(storedToken) : '';
  }

  List<ProviderConfig> get enabledProviders =>
      providers.where((c) => c.enabled).toList();

  Future<void> saveSettings() =>
      _prefs.setString(_settingsKey, jsonEncode(appSettings.toJson()));

  Future<void> saveProviders() => _prefs.setString(
      _providersKey, jsonEncode(providers.map((p) => p.toJson()).toList()));

  Future<void> setProviderApiKey(String id, String key) async {
    providers = [
      for (final p in providers)
        if (p.id == id) p.copyWith(apiKey: key) else p,
    ];
    if (key.isEmpty) {
      await _prefs.remove(_providerKeyEntry(id));
    } else {
      await _prefs.setString(_providerKeyEntry(id), _obfuscate(key));
    }
  }

  Future<void> setTunnelToken(String value) async {
    tunnelToken = value;
    if (value.isEmpty) {
      await _prefs.remove(_tunnelTokenEntry);
    } else {
      await _prefs.setString(_tunnelTokenEntry, _obfuscate(value));
    }
  }

  Future<void> regenerateLocalKey() async {
    localApiKey = generateApiKey();
    await _prefs.setString(_localKeyEntry, _obfuscate(localApiKey));
  }
}
