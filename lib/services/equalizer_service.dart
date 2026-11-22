import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:media_kit/media_kit.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../player/models/equalizer_preset.dart';
import '../player/player_manager.dart';

/// Result of an import — how many presets were added.
class EqualizerImportResult {
  final int imported;
  final int skipped;
  const EqualizerImportResult(this.imported, this.skipped);
}

/// App-wide 10-band equalizer for local playback (music and video — both
/// run through the one media_kit/mpv `Player` in PlayerManager).
///
/// How it works: the selected curve is turned into an ffmpeg filter chain
/// (one `equalizer` peaking filter per non-zero band) and handed to mpv
/// through its `af` property, so it is applied natively on the audio path
/// — no extra plugin and no audio re-routing. Every local playback path
/// (Jellyfin songs/videos, downloads, On This Device songs, Open With /
/// Play With files) runs through the one shared mpv player, so one filter
/// covers them all. Changing a slider while audio plays re-applies the
/// chain (throttled, see [_scheduleApply]).
///
/// IMPORTANT — why only the `equalizer` filter is used: the libmpv that
/// media_kit ships is built against a slimmed-down FFmpeg
/// (`--disable-filters`, then a handful re-enabled). When ANY filter in a
/// graph is missing, mpv rejects the whole graph and the audio is simply
/// unchanged — which is exactly why the earlier chain (it also used
/// `volume` and `alimiter`) did nothing. The slim build also has no
/// `aresample`, so the graph is fed planar float samples directly via
/// mpv's own `format=floatp`. The preamp therefore does not use an FFmpeg
/// filter at all: it is mpv's built-in `replaygain-fallback` gain (dB),
/// which mpv applies to every file when ReplayGain is off.
///
/// It does not affect casting: a cast receiver plays its own audio, so
/// there is nothing on this device to equalise.
///
/// State model (mirrors VLC):
///  - 18 read-only built-in presets + any number of custom presets.
///  - Editing a built-in clones it first ([cloneForEdit]); only custom
///    presets are ever modified in place.
///  - Custom presets remember their last-saved curve for the editor's
///    undo button ([canRevert] / [revertSelected]).
///  - Built-ins can be hidden from the chip row ([setHidden]) without
///    being deleted.
class EqualizerService extends ChangeNotifier {
  EqualizerService._();
  static final EqualizerService instance = EqualizerService._();

  static const _kEnabled = 'eq_enabled';
  static const _kSelected = 'eq_selected';
  static const _kCustom = 'eq_custom_presets';
  static const _kHidden = 'eq_hidden_presets';
  static const _kSnap = 'eq_snap_bands';

  bool _enabled = false;
  bool _snapBands = true;
  String _selectedId = kFlatPresetId;
  final List<EqualizerPreset> _custom = [];
  final Set<String> _hidden = {};

  // id -> curve as it was when the current editing session began; what
  // the undo button restores.
  final Map<String, EqualizerPreset> _editBaseline = {};

  bool _loaded = false;
  int _idCounter = 0;
  Timer? _applyTimer;
  Timer? _saveTimer;
  String _lastAppliedChain = '';
  double _lastAppliedPreamp = 0;
  // Serialises writes to mpv so rapid slider moves can never interleave.
  Future<void> _applyQueue = Future<void>.value();
  StreamSubscription<PlayerLog>? _logSub;
  DateTime? _lastChainWrite;
  bool _engineRefused = false;
  bool _recovering = false;

  /// True when this device's mpv build rejected the filter chain. The
  /// equalizer is then switched off for audio (so nothing is broken) and
  /// the UI can say so.
  bool get engineRefused => _engineRefused;

  // ------------------------------------------------------------------
  // Read access
  // ------------------------------------------------------------------

  bool get enabled => _enabled;
  bool get snapBands => _snapBands;
  String get selectedId => _selectedId;

  List<EqualizerPreset> get customPresets => List.unmodifiable(_custom);

  /// Custom presets first (newest on top, like VLC's "New equalizer"),
  /// then the built-ins.
  List<EqualizerPreset> get allPresets =>
      [..._custom.reversed, ...kBuiltInEqualizerPresets];

  /// What the chip row shows: everything not hidden, always including
  /// the currently selected preset even if hidden.
  List<EqualizerPreset> get visiblePresets => allPresets
      .where((p) => !_hidden.contains(p.id) || p.id == _selectedId)
      .toList();

  bool isHidden(String id) => _hidden.contains(id);
  bool get hasHidden => _hidden.isNotEmpty;

  EqualizerPreset get selected => allPresets.firstWhere(
        (p) => p.id == _selectedId,
        orElse: () => kBuiltInEqualizerPresets.first,
      );

  /// True when the selected custom preset differs from how it was when
  /// editing began (enables the undo button).
  bool get canRevert {
    final base = _editBaseline[_selectedId];
    final cur = selected;
    if (base == null || cur.builtIn) return false;
    return base.name != cur.name || !base.sameCurveAs(cur);
  }

  // ------------------------------------------------------------------
  // Load / persist
  // ------------------------------------------------------------------

  /// Re-reads the saved settings (account switch / cloud update).
  Future<void> reloadFromStorage() {
    _loaded = false;
    return load();
  }

  Future<void> load() async {
    if (_loaded) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      _enabled = prefs.getBool(_kEnabled) ?? false;
      _snapBands = prefs.getBool(_kSnap) ?? true;
      _selectedId = prefs.getString(_kSelected) ?? kFlatPresetId;
      _hidden
        ..clear()
        ..addAll(prefs.getStringList(_kHidden) ?? const []);

      _custom.clear();
      final raw = prefs.getString(_kCustom);
      if (raw != null) {
        final decoded = jsonDecode(raw);
        if (decoded is List) {
          for (final e in decoded) {
            final p = EqualizerPreset.fromStorageJson(e);
            if (p != null) _custom.add(p);
          }
        }
      }
      if (!allPresets.any((p) => p.id == _selectedId)) {
        _selectedId = kFlatPresetId;
      }
    } catch (e) {
      debugPrint('EqualizerService.load failed: $e');
    }
    _loaded = true;
    _watchEngineLogs();
    notifyListeners();
    await _applyNow();
  }

  /// Watches mpv's own warnings so a rejected filter graph is noticed (and
  /// undone) instead of silently doing nothing — or worse, leaving the
  /// audio track disabled.
  void _watchEngineLogs() {
    _logSub?.cancel();
    try {
      _logSub = PlayerManager.instance.player.stream.log.listen((l) {
        final at = _lastChainWrite;
        if (_lastAppliedChain.isEmpty || at == null) return;
        if (DateTime.now().difference(at) > const Duration(seconds: 4)) return;
        if (l.level != 'error' && l.level != 'fatal') return;
        final t = l.text.toLowerCase();
        final filterRelated = t.contains('filter') ||
            t.contains('lavfi') ||
            l.prefix == 'af' ||
            l.prefix == 'lavfi';
        if (filterRelated) unawaited(_handleEngineRefusal(l.text));
      });
    } catch (e) {
      debugPrint('EqualizerService: log watch failed: $e');
    }
  }

  Future<void> _handleEngineRefusal(String why) async {
    if (_recovering || _engineRefused) return;
    _recovering = true;
    debugPrint('EqualizerService: mpv rejected the filter chain: $why');
    _engineRefused = true;
    try {
      final platform = PlayerManager.instance.player.platform;
      if (platform is NativePlayer) {
        await platform.setProperty('af', '');
        await platform.setProperty('replaygain-fallback', '0');
      }
      _lastAppliedChain = '';
      _lastAppliedPreamp = 0;
      // A failed graph can leave the audio track dropped; re-selecting it
      // makes mpv rebuild the (now empty) chain.
      final p = PlayerManager.instance.player;
      await p.setAudioTrack(p.state.track.audio);
    } catch (e) {
      debugPrint('EqualizerService: recovery failed: $e');
    } finally {
      _recovering = false;
      notifyListeners();
    }
  }

  void _scheduleSave() {
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(milliseconds: 300), _saveNow);
  }

  Future<void> _saveNow() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_kEnabled, _enabled);
      await prefs.setBool(_kSnap, _snapBands);
      await prefs.setString(_kSelected, _selectedId);
      await prefs.setStringList(_kHidden, _hidden.toList());
      await prefs.setString(
        _kCustom,
        jsonEncode(_custom.map((p) => p.toStorageJson()).toList()),
      );
    } catch (e) {
      debugPrint('EqualizerService.save failed: $e');
    }
  }

  void _changed({bool audio = true}) {
    notifyListeners();
    _scheduleSave();
    if (audio) _scheduleApply();
  }

  // ------------------------------------------------------------------
  // Playback hook — builds the mpv `af` chain
  // ------------------------------------------------------------------

  /// Builds the mpv `af` chain for [p], or '' when no band is changed.
  /// Uses ONLY the `equalizer` filter (see the class doc comment).
  @visibleForTesting
  static String buildFilterChain(EqualizerPreset p) {
    final f = <String>[];
    for (var i = 0; i < kEqBandFrequencies.length; i++) {
      final g = p.bands[i];
      if (g == 0) continue;
      f.add('equalizer=f=${kEqBandFrequencies[i]}:t=o:w=1:'
          'g=${g.toStringAsFixed(2)}');
    }
    if (f.isEmpty) return '';
    return 'format=floatp,lavfi=[${f.join(',')}]';
  }

  /// Throttled: dragging a slider fires many changes per second and each
  /// one rebuilds mpv's audio filter graph, so only the latest value in
  /// each ~60 ms window is pushed.
  void _scheduleApply() {
    if (_applyTimer?.isActive ?? false) return;
    _applyTimer = Timer(const Duration(milliseconds: 60), _applyNow);
  }

  Future<void> _applyNow() {
    final next = _applyQueue.then((_) => _applyOnce());
    _applyQueue = next.catchError((_) {});
    return next;
  }

  Future<void> _applyOnce() async {
    if (_engineRefused) return;
    final p = selected;
    final chain = _enabled ? buildFilterChain(p) : '';
    final preamp = _enabled ? p.preamp : 0.0;
    if (chain == _lastAppliedChain && preamp == _lastAppliedPreamp) return;
    try {
      final platform = PlayerManager.instance.player.platform;
      if (platform is! NativePlayer) return;
      if (preamp != _lastAppliedPreamp) {
        // mpv's built-in gain; applied to every file while ReplayGain is
        // off (its default), so it needs no FFmpeg filter.
        await platform.setProperty('replaygain', 'no');
        await platform.setProperty(
            'replaygain-fallback', preamp.toStringAsFixed(2));
        _lastAppliedPreamp = preamp;
      }
      if (chain != _lastAppliedChain) {
        _lastChainWrite = DateTime.now();
        await platform.setProperty('af', chain);
        _lastAppliedChain = chain;
      }
    } catch (e) {
      // Best-effort — a failed filter must never affect playback itself.
      debugPrint('EqualizerService: applying audio filter failed: $e');
    }
  }

  // ------------------------------------------------------------------
  // Actions
  // ------------------------------------------------------------------

  void setEnabled(bool value) {
    if (_enabled == value) return;
    _enabled = value;
    _changed();
  }

  void setSnapBands(bool value) {
    _snapBands = value;
    _changed(audio: false);
  }

  /// Selecting a preset also turns the equalizer on — picking a curve
  /// while it's off and hearing nothing change would read as broken.
  void select(String id) {
    if (!allPresets.any((p) => p.id == id)) return;
    _selectedId = id;
    _enabled = true;
    // Fresh undo baseline for whatever is being opened.
    final p = selected;
    if (!p.builtIn) _editBaseline[p.id] = p;
    _changed();
  }

  String _newId() =>
      'custom_${DateTime.now().microsecondsSinceEpoch}_${_idCounter++}';

  String _uniqueName(String base) {
    final taken = allPresets.map((p) => p.name.toLowerCase()).toSet();
    if (!taken.contains(base.toLowerCase())) return base;
    var n = 2;
    while (taken.contains('$base ($n)'.toLowerCase())) {
      n++;
    }
    return '$base ($n)';
  }

  /// "+" — a fresh flat custom preset, selected and ready to edit.
  void createNew() {
    final p = EqualizerPreset(
      id: _newId(),
      name: _uniqueName('New equalizer'),
      preamp: 0,
      bands: List.filled(kEqBandFrequencies.length, 0),
    );
    _custom.add(p);
    _selectedId = p.id;
    _enabled = true;
    _editBaseline[p.id] = p;
    _changed();
  }

  /// Pencil on a built-in: copies it into an editable custom preset.
  void cloneForEdit(String id) {
    final src = allPresets.firstWhere((p) => p.id == id);
    final p = src.copyWith(
      id: _newId(),
      name: _uniqueName('${src.name} copy'),
      builtIn: false,
    );
    _custom.add(p);
    _selectedId = p.id;
    _enabled = true;
    _editBaseline[p.id] = p;
    _changed();
  }

  /// Edits the selected preset in place. No-op for built-ins.
  void updateSelected({String? name, double? preamp, List<double>? bands}) {
    final i = _custom.indexWhere((p) => p.id == _selectedId);
    if (i < 0) return;
    final cur = _custom[i];
    var newName = name;
    if (newName != null) {
      newName = newName.trim();
      if (newName.isEmpty) newName = null;
    }
    _editBaseline.putIfAbsent(cur.id, () => cur);
    _custom[i] = cur.copyWith(name: newName, preamp: preamp, bands: bands);
    _changed(audio: name == null);
  }

  /// Moves one band; with [snapBands] on, its neighbours follow with a
  /// falloff so dragging one slider bends a smooth curve.
  void setBand(int index, double value) {
    final p = selected;
    if (p.builtIn) return;
    final v = value.clamp(-kEqBandMaxDb, kEqBandMaxDb).toDouble();
    final next = List<double>.of(p.bands);
    final delta = v - next[index];
    next[index] = v;
    if (_snapBands) {
      const falloff = [0.5, 0.25];
      for (var d = 1; d <= falloff.length; d++) {
        for (final j in [index - d, index + d]) {
          if (j < 0 || j >= next.length) continue;
          next[j] = (next[j] + delta * falloff[d - 1])
              .clamp(-kEqBandMaxDb, kEqBandMaxDb)
              .toDouble();
        }
      }
    }
    updateSelected(bands: next);
  }

  void revertSelected() {
    final base = _editBaseline[_selectedId];
    final i = _custom.indexWhere((p) => p.id == _selectedId);
    if (base == null || i < 0) return;
    _custom[i] = base;
    _changed();
  }

  /// Deletes a custom preset (built-ins can only be hidden).
  void deleteCustom(String id) {
    final i = _custom.indexWhere((p) => p.id == id);
    if (i < 0) return;
    _custom.removeAt(i);
    _editBaseline.remove(id);
    _hidden.remove(id);
    if (_selectedId == id) _selectedId = kFlatPresetId;
    _changed();
  }

  void setHidden(String id, bool hidden) {
    if (hidden) {
      _hidden.add(id);
    } else {
      _hidden.remove(id);
    }
    _changed(audio: false);
  }

  void restoreHidden() {
    _hidden.clear();
    _changed(audio: false);
  }

  // ------------------------------------------------------------------
  // Import / export
  // ------------------------------------------------------------------

  String exportJson(EqualizerPreset p) => EqualizerPreset.exportOne(p);

  String exportAllJson() => EqualizerPreset.exportMany(_custom);

  /// Safe file name for an exported preset.
  static String exportFileName(String presetName) {
    final cleaned = presetName
        .replaceAll(RegExp(r'[^\w\- ]+'), '')
        .trim()
        .replaceAll(RegExp(r'\s+'), '_');
    return '${cleaned.isEmpty ? 'equalizer' : cleaned}.json';
  }

  /// Adds every valid preset found in [source] (one preset, a list, or an
  /// export-all file). Throws [FormatException] if nothing usable is in it.
  EqualizerImportResult importJson(String source) {
    final Object? decoded;
    try {
      decoded = jsonDecode(source);
    } catch (_) {
      throw const FormatException('Not a valid equalizer file');
    }

    final List<Object?> candidates;
    if (decoded is List) {
      candidates = decoded;
    } else if (decoded is Map && decoded['presets'] is List) {
      candidates = decoded['presets'] as List;
    } else {
      candidates = [decoded];
    }

    var imported = 0;
    var skipped = 0;
    String? lastId;
    for (final c in candidates) {
      final p = EqualizerPreset.fromJson(c, newId: _newId());
      if (p == null) {
        skipped++;
        continue;
      }
      final named = p.copyWith(name: _uniqueName(p.name));
      _custom.add(named);
      _editBaseline[named.id] = named;
      lastId = named.id;
      imported++;
    }
    if (imported == 0) {
      throw const FormatException('No equalizer presets found in that file');
    }
    _selectedId = lastId!;
    _enabled = true;
    _changed();
    return EqualizerImportResult(imported, skipped);
  }
}
