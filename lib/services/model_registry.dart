import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import '../core/free_model_filter.dart';
import '../models/log_entry.dart';
import '../models/model_info.dart';
import '../models/provider_config.dart';
import 'log_service.dart';
import 'upstream_client.dart';

class ProviderSyncEntry {
  final String providerId;
  final String providerName;
  final bool ok;
  final int modelCount;
  final List<String> added;
  final List<String> removed;
  final String? error;

  const ProviderSyncEntry({
    required this.providerId,
    required this.providerName,
    required this.ok,
    required this.modelCount,
    required this.added,
    required this.removed,
    this.error,
  });
}

class SyncReport {
  final List<ProviderSyncEntry> entries;
  const SyncReport({required this.entries});

  int get addedTotal =>
      entries.fold(0, (sum, e) => sum + e.added.length);
  int get removedTotal =>
      entries.fold(0, (sum, e) => sum + e.removed.length);
  bool get allOk => entries.every((e) => e.ok);
}

/// Local routing cache of all models across all providers.
///
/// - Auto-sync replaces each provider's model set and **logs additions and
///   deletions** (deletion detection & addition detection requirement).
/// - The cache is persisted to `<cacheDir>/models.json` so the proxy can
///   serve `/v1/models` immediately after restart.
class ModelRegistry {
  ModelRegistry(this._logs, {required this.cacheDir});

  final LogService _logs;
  final String cacheDir;
  final Map<String, ModelInfo> _byKey = {};
  final StreamController<List<ModelInfo>> _changes =
      StreamController<List<ModelInfo>>.broadcast();

  List<ModelInfo> get snapshot => _byKey.values.toList();
  int get count => _byKey.length;
  List<ModelInfo> get freeModels =>
      snapshot.where((m) => m.isFree).toList();
  Stream<List<ModelInfo>> get changes => _changes.stream;

  ModelInfo? find(String providerId, String id) => _byKey['$providerId|$id'];

  ModelInfo? resolveAny(String id) {
    for (final m in _byKey.values) {
      if (m.id == id) return m;
    }
    return null;
  }

  List<ModelInfo> forProvider(String providerId) =>
      snapshot.where((m) => m.providerId == providerId).toList();

  void _emit() => _changes.add(snapshot);

  /// Used after loading the persisted cache so subscribers get an initial
  /// snapshot.
  void notifyListeners() => _emit();

  /// Pure addition/removal detection between two id sets.
  static ({List<String> added, List<String> removed}) diffIds(
      Set<String> oldIds, Set<String> newIds) {
    return (
      added: newIds.difference(oldIds).toList()..sort(),
      removed: oldIds.difference(newIds).toList()..sort(),
    );
  }

  /// Replaces one provider's model set, logging additions/removals.
  void replaceProviderModels(String providerId, List<ModelInfo> fresh,
      {String? providerLabel}) {
    final existing =
        _byKey.values.where((m) => m.providerId == providerId).toList();
    final newIds = fresh.map((m) => m.id).toSet();
    final diff = diffIds(existing.map((m) => m.id).toSet(), newIds);
    for (final m in existing) {
      if (!newIds.contains(m.id)) _byKey.remove(m.key);
    }
    for (final m in fresh) {
      _byKey[m.key] = m;
    }
    final label = providerLabel ?? providerId;
    if (diff.added.isNotEmpty) {
      _logs.info(LogCategory.sync,
          '$label: +${diff.added.length} new model(s)${_shortList(diff.added)}');
    }
    if (diff.removed.isNotEmpty) {
      _logs.warn(LogCategory.sync,
          '$label: −${diff.removed.length} model(s) removed${_shortList(diff.removed)}');
    }
  }

  /// Converts a provider's manually-declared models into [ModelInfo]s,
  /// skipping ids already present in [excludeIds] (or already cached).
  List<ModelInfo> manualAsModelInfos(ProviderConfig p, {Set<String>? excludeIds}) {
    final now = DateTime.now();
    final out = <ModelInfo>[];
    for (final m in p.manualModels) {
      final id = m.id.trim();
      if (id.isEmpty) continue;
      if (excludeIds?.contains(id) ?? false) continue;
      if (_byKey.containsKey('${p.id}|$id')) continue;
      out.add(ModelInfo(
        id: id,
        providerId: p.id,
        providerName: p.name,
        displayName: m.name.trim().isEmpty ? null : m.name.trim(),
        isFree: FreeModelFilter.isFree(
            modelId: id, assumeProviderFree: p.assumeAllFree),
        lastSeen: now,
      ));
    }
    return out;
  }

  Future<SyncReport> syncAll(
    List<ProviderConfig> providers, {
    required UpstreamClient upstream,
    http.Client? client,
    bool persist = true,
  }) async {
    final entries = <ProviderSyncEntry>[];
    await Future.wait(providers.where((p) => p.enabled).map((p) async {
      final outcome = await upstream.listModels(p, client: client);
      if (outcome.ok) {
        final fetchedIds = outcome.models.map((m) => m.id).toSet();
        final combined = [...outcome.models, ...manualAsModelInfos(p, excludeIds: fetchedIds)];
        replaceProviderModels(p.id, combined, providerLabel: p.name);
        final existing = forProvider(p.id);
        final diff = diffIds(
          existing.map((m) => m.id).toSet(),
          combined.map((m) => m.id).toSet(),
        );
        entries.add(ProviderSyncEntry(
          providerId: p.id,
          providerName: p.name,
          ok: true,
          modelCount: combined.length,
          added: diff.added,
          removed: diff.removed,
        ));
      } else {
        // Keep previously-fetched models, but make sure manually-declared
        // ones are present even when the listing endpoint fails.
        final manual = manualAsModelInfos(p);
        if (manual.isNotEmpty) {
          final combined = [...forProvider(p.id), ...manual];
          replaceProviderModels(p.id, combined, providerLabel: p.name);
        }
        entries.add(ProviderSyncEntry(
          providerId: p.id,
          providerName: p.name,
          ok: false,
          modelCount: forProvider(p.id).length,
          added: const [],
          removed: const [],
          error: outcome.error,
        ));
      }
    }));
    _emit();
    if (persist) await persistCache();
    return SyncReport(entries: entries);
  }

  Future<void> persistCache() async {
    try {
      final f = File(p.join(cacheDir, 'models.json'));
      await f.create(recursive: true);
      await f.writeAsString(jsonEncode(snapshot.map((m) => m.toJson()).toList()));
    } catch (e) {
      _logs.warn(LogCategory.sync, 'Could not persist model cache: $e');
    }
  }

  Future<void> loadCache() async {
    try {
      final f = File(p.join(cacheDir, 'models.json'));
      if (!await f.exists()) return;
      final list =
          (jsonDecode(await f.readAsString()) as List).cast<Map<String, dynamic>>();
      for (final j in list) {
        final m = ModelInfo.fromJson(j);
        _byKey[m.key] = m;
      }
      _logs.info(LogCategory.system, 'Restored ${_byKey.length} cached model(s)');
    } catch (e) {
      _logs.warn(LogCategory.system, 'Could not load model cache: $e');
    }
  }

  static String _shortList(List<String> ids) {
    if (ids.isEmpty) return '';
    final shown = ids.take(4).join(', ');
    return ids.length <= 4 ? ' ($shown)' : ' ($shown, +${ids.length - 4} more)';
  }
}
