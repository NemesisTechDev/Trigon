import 'dart:convert';

/// Centre frequencies (Hz) of the 10 equalizer bands — same layout VLC uses.
const List<int> kEqBandFrequencies = [
  31, 63, 125, 250, 500, 1000, 2000, 4000, 8000, 16000,
];

/// Gain range of a single band / the preamp, in dB.
const double kEqBandMaxDb = 12;
const double kEqPreampMaxDb = 20;

String eqFrequencyLabel(int hz) => hz >= 1000 ? '${hz ~/ 1000}kHz' : '${hz}Hz';

/// One equalizer curve: a preamp plus 10 band gains, all in dB.
///
/// Built-in presets ([builtIn] == true) are read-only; editing one clones
/// it into a custom preset (see EqualizerService.beginEdit).
class EqualizerPreset {
  final String id;
  final String name;
  final double preamp;
  final List<double> bands;
  final bool builtIn;

  EqualizerPreset({
    required this.id,
    required this.name,
    required this.preamp,
    required List<double> bands,
    this.builtIn = false,
  }) : bands = List.unmodifiable(_normalize(bands));

  static List<double> _normalize(List<double> raw) {
    final out = List<double>.filled(kEqBandFrequencies.length, 0);
    for (var i = 0; i < out.length && i < raw.length; i++) {
      out[i] = raw[i].clamp(-kEqBandMaxDb, kEqBandMaxDb).toDouble();
    }
    return out;
  }

  EqualizerPreset copyWith({
    String? id,
    String? name,
    double? preamp,
    List<double>? bands,
    bool? builtIn,
  }) =>
      EqualizerPreset(
        id: id ?? this.id,
        name: name ?? this.name,
        preamp: (preamp ?? this.preamp)
            .clamp(-kEqPreampMaxDb, kEqPreampMaxDb)
            .toDouble(),
        bands: bands ?? this.bands,
        builtIn: builtIn ?? this.builtIn,
      );

  bool get isFlat => preamp == 0 && bands.every((b) => b == 0);

  bool sameCurveAs(EqualizerPreset other) {
    if (preamp != other.preamp) return false;
    for (var i = 0; i < bands.length; i++) {
      if (bands[i] != other.bands[i]) return false;
    }
    return true;
  }

  // ---------------------------------------------------------------------
  // JSON (also the import/export file format).
  //
  //   {"nemesisEqualizer": 1, "name": "Rock", "preamp": -6.0,
  //    "bands": [8.0, 4.8, ...10 numbers...]}
  //
  // Export-all wraps several of these: {"nemesisEqualizer": 1,
  // "presets": [ ... ]}.
  // ---------------------------------------------------------------------

  Map<String, dynamic> toJson() => {
        'name': name,
        'preamp': preamp,
        'bands': bands,
      };

  static String exportOne(EqualizerPreset p) =>
      const JsonEncoder.withIndent('  ')
          .convert({'nemesisEqualizer': 1, ...p.toJson()});

  static String exportMany(Iterable<EqualizerPreset> presets) =>
      const JsonEncoder.withIndent('  ').convert({
        'nemesisEqualizer': 1,
        'presets': presets.map((p) => p.toJson()).toList(),
      });

  /// Parses one preset object. Tolerant on purpose so files from other
  /// apps import too: bands may be a list of numbers or a list of
  /// `{value|gain|level: n}` objects; the preamp may be called
  /// `preamp`/`preAmp`/`pre_amp`. Returns null if it doesn't look like a
  /// preset at all.
  static EqualizerPreset? fromJson(Object? json, {required String newId}) {
    if (json is! Map) return null;

    double? asNum(Object? v) {
      if (v is num) return v.toDouble();
      if (v is String) return double.tryParse(v);
      return null;
    }

    final rawBands = json['bands'] ?? json['gains'] ?? json['values'];
    if (rawBands is! List || rawBands.isEmpty) return null;

    final bands = <double>[];
    for (final b in rawBands) {
      double? v;
      if (b is Map) {
        v = asNum(b['value'] ?? b['gain'] ?? b['level']);
      } else {
        v = asNum(b);
      }
      if (v == null) return null;
      bands.add(v);
    }
    // Only accept 10-band curves — resampling other layouts would
    // silently change what the person hears.
    if (bands.length != kEqBandFrequencies.length) return null;

    final preamp =
        asNum(json['preamp'] ?? json['preAmp'] ?? json['pre_amp']) ?? 0;
    final rawName = (json['name'] ?? json['title'])?.toString().trim() ?? '';

    return EqualizerPreset(
      id: newId,
      name: rawName.isEmpty ? 'Imported equalizer' : rawName,
      preamp: preamp.clamp(-kEqPreampMaxDb, kEqPreampMaxDb).toDouble(),
      bands: bands,
    );
  }

  /// Storage form (includes id, unlike the shareable file form).
  Map<String, dynamic> toStorageJson() => {'id': id, ...toJson()};

  static EqualizerPreset? fromStorageJson(Object? json) {
    if (json is! Map) return null;
    final id = json['id']?.toString();
    if (id == null || id.isEmpty) return null;
    return fromJson(json, newId: id);
  }
}

// ---------------------------------------------------------------------------
// Built-in presets — the same 18 curves VLC ships. Band gains follow VLC's
// preset tables; the preamp is set to -(largest boost) (floored at -12 dB)
// so a boosted preset can't clip, and the audio chain also has a limiter.
// ---------------------------------------------------------------------------

EqualizerPreset _builtIn(String name, List<double> bands) {
  final maxBoost = bands.fold<double>(0, (m, b) => b > m ? b : m);
  final preamp = maxBoost <= 0 ? 0.0 : -(maxBoost > 12 ? 12.0 : maxBoost);
  return EqualizerPreset(
    id: 'builtin_${name.toLowerCase().replaceAll(' ', '_')}',
    name: name,
    preamp: preamp,
    bands: bands,
    builtIn: true,
  );
}

final List<EqualizerPreset> kBuiltInEqualizerPresets = List.unmodifiable([
  _builtIn('Flat', [0, 0, 0, 0, 0, 0, 0, 0, 0, 0]),
  _builtIn('Classical', [0, 0, 0, 0, 0, 0, -7.2, -7.2, -7.2, -9.6]),
  _builtIn('Club', [0, 0, 8, 5.6, 5.6, 5.6, 3.2, 0, 0, 0]),
  _builtIn('Dance', [9.6, 7.2, 2.4, 0, 0, -5.6, -7.2, -7.2, 0, 0]),
  _builtIn('Full bass', [-8, 9.6, 9.6, 5.6, 1.6, -4, -8, -10.4, -11.2, -11.2]),
  _builtIn('Full bass and treble', [7.2, 5.6, 0, -7.2, -4.8, 1.6, 8, 11.2, 12, 12]),
  _builtIn('Full treble', [-9.6, -9.6, -9.6, -4, 2.4, 11.2, 12, 12, 12, 12]),
  _builtIn('Headphones', [4.8, 11.2, 5.6, -3.2, -2.4, 1.6, 4.8, 9.6, 12, 12]),
  _builtIn('Large Hall', [10.4, 10.4, 5.6, 5.6, 0, -4.8, -4.8, -4.8, 0, 0]),
  _builtIn('Live', [-4.8, 0, 4, 5.6, 5.6, 5.6, 4, 2.4, 2.4, 2.4]),
  _builtIn('Party', [7.2, 7.2, 0, 0, 0, 0, 0, 0, 7.2, 7.2]),
  _builtIn('Pop', [-1.6, 4.8, 7.2, 8, 5.6, 0, -2.4, -2.4, -1.6, -1.6]),
  _builtIn('Reggae', [0, 0, 0, -5.6, 0, 6.4, 6.4, 0, 0, 0]),
  _builtIn('Rock', [8, 4.8, -5.6, -8, -3.2, 4, 8.8, 11.2, 11.2, 11.2]),
  _builtIn('Ska', [-2.4, -4.8, -4, 0, 4, 5.6, 8.8, 9.6, 11.2, 9.6]),
  _builtIn('Soft', [4.8, 1.6, 0, -2.4, 0, 4, 8, 9.6, 11.2, 12]),
  _builtIn('Soft rock', [4, 4, 2.4, 0, -4, -5.6, -3.2, 0, 2.4, 8.8]),
  _builtIn('Techno', [8, 5.6, 0, -5.6, -4.8, 0, 8, 9.6, 9.6, 8.8]),
]);

const String kFlatPresetId = 'builtin_flat';
