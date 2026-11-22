import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../addons/addon_models.dart';

/// Which source the person picked for a title last time.
///
/// Matching is deliberately by *meaning*, not by URL (URLs differ for every
/// episode): same addon and same stream label first, then same addon at the
/// same resolution, then the best stream from the same addon.
class SourcePreference {
  final String addonId;
  final String name;
  final int height;

  const SourcePreference({
    required this.addonId,
    required this.name,
    required this.height,
  });

  factory SourcePreference.of(AddonStream s) => SourcePreference(
        addonId: s.addonId,
        name: s.name,
        height: s.height,
      );

  bool matches(AddonStream s) => s.addonId == addonId && s.name == name;

  /// Only a same-addon, same-name match. Safe to act on while results are
  /// still arriving from slower addons.
  AddonStream? exactFrom(List<AddonStream> streams) {
    for (final s in streams) {
      if (matches(s)) return s;
    }
    return null;
  }

  /// Best available match once all results are in: exact, then same addon at
  /// the same resolution, then the first (highest resolution) from the same
  /// addon. Null if the addon returned nothing.
  AddonStream? pickFrom(List<AddonStream> streams) {
    final exact = exactFrom(streams);
    if (exact != null) return exact;
    final sameAddon = streams.where((s) => s.addonId == addonId).toList();
    if (sameAddon.isEmpty) return null;
    for (final s in sameAddon) {
      if (s.height == height) return s;
    }
    return sameAddon.first;
  }

  Map<String, dynamic> toJson() =>
      {'addonId': addonId, 'name': name, 'height': height};

  static SourcePreference? fromJson(dynamic j) {
    if (j is! Map) return null;
    final id = j['addonId']?.toString();
    final name = j['name']?.toString();
    if (id == null || name == null) return null;
    return SourcePreference(
      addonId: id,
      name: name,
      height: (j['height'] as num?)?.toInt() ?? 0,
    );
  }
}

/// Per-title remembered source, plus the "auto-pick" setting.
class SourcePreferences {
  SourcePreferences._();
  static final SourcePreferences instance = SourcePreferences._();

  static const String _mapKey = 'namesis_source_prefs_v1';
  static const String _autoKey = 'namesis_autopick_v1';
  static const int _maxTitles = 200;

  /// When on, a title with a remembered source plays it immediately instead
  /// of showing the source list.
  final ValueNotifier<bool> autoPick = ValueNotifier(true);

  final Map<String, SourcePreference> _byTitle = {};
  Future<void>? _loading;

  /// Safe to call repeatedly; the work happens once.
  Future<void> load() => _loading ??= _load();

  /// Re-reads the saved choices from disk (account switch / cloud update).
  Future<void> reloadFromStorage() {
    return _loading = _load();
  }

  Future<void> _load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      _byTitle.clear();
      autoPick.value = prefs.getBool(_autoKey) ?? true;
      final raw = prefs.getString(_mapKey);
      if (raw != null && raw.isNotEmpty) {
        final decoded = jsonDecode(raw);
        if (decoded is Map) {
          decoded.forEach((k, v) {
            final p = SourcePreference.fromJson(v);
            if (p != null) _byTitle[k.toString()] = p;
          });
        }
      }
    } catch (e) {
      debugPrint('[SourcePreferences] load failed: $e');
    }
  }

  /// [titleKey] is `movie:603` / `tv:1399` (same as TitleSnapshot.key).
  SourcePreference? forTitle(String titleKey) => _byTitle[titleKey];

  Future<void> remember(String titleKey, AddonStream stream) async {
    await load();
    // Re-insert so the most recently used title is last (cheap LRU).
    _byTitle.remove(titleKey);
    _byTitle[titleKey] = SourcePreference.of(stream);
    while (_byTitle.length > _maxTitles) {
      _byTitle.remove(_byTitle.keys.first);
    }
    await _persist();
  }

  /// Forgets the source remembered for [titleKey], so the next Play of that
  /// title shows the source list again instead of auto-picking the old link.
  /// Used when a title is removed from Continue Watching. A title with
  /// nothing remembered is left alone (nothing is written).
  Future<void> forget(String titleKey) async {
    await load();
    if (_byTitle.remove(titleKey) == null) return;
    await _persist();
  }

  Future<void> _persist() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        _mapKey,
        jsonEncode(_byTitle.map((k, v) => MapEntry(k, v.toJson()))),
      );
    } catch (e) {
      debugPrint('[SourcePreferences] save failed: $e');
    }
  }

  Future<void> setAutoPick(bool value) async {
    autoPick.value = value;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_autoKey, value);
    } catch (e) {
      debugPrint('[SourcePreferences] save failed: $e');
    }
  }
}
