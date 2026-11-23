/// Data types for the Stremio addon protocol (the subset Namesis Prime uses).
///
/// An addon is just an HTTP server that publishes `manifest.json` and answers
/// `/stream/{type}/{id}.json` (and optionally `/subtitles/...`). Everything
/// here is plain JSON <-> Dart mapping, no behaviour.
library;

/// What an installed addon says about itself.
class AddonManifest {
  final String id;
  final String name;
  final String version;
  final String description;

  /// Base URL with no trailing slash and no `/manifest.json`, e.g.
  /// `http://192.168.1.20:7000`. Every resource URL is built from this.
  final String baseUrl;

  /// Resource names the addon serves: `stream`, `subtitles`, `meta`, ...
  /// Stremio also allows resources to be objects with their own `types` and
  /// `idPrefixes`; [fromJson] flattens those into [resourceTypes]/[resourcePrefixes].
  final List<String> resources;

  /// Content types the addon handles: `movie`, `series`, ...
  final List<String> types;

  /// Id prefixes the addon understands, e.g. `tt` (IMDb) or `tmdb:`.
  /// Empty means "any id".
  final List<String> idPrefixes;

  /// Per-resource overrides (only present when the manifest used the object
  /// form for a resource).
  final Map<String, List<String>> resourceTypes;
  final Map<String, List<String>> resourcePrefixes;

  /// True for an addon the person added themselves (Settings > Addons >
  /// Custom addons). False for the addons that come with the app (the
  /// addresses in `default_addons.dart`).
  final bool isCustom;

  const AddonManifest({
    required this.id,
    required this.name,
    required this.version,
    required this.description,
    required this.baseUrl,
    required this.resources,
    required this.types,
    required this.idPrefixes,
    this.resourceTypes = const {},
    this.resourcePrefixes = const {},
    this.isCustom = false,
  });

  /// Identity of an installed addon. A custom addon may share its [id] with a
  /// default one (the same addon with the person's own settings), so the id
  /// alone is not enough to tell them apart.
  String get key => '${isCustom ? 'c' : 'd'}:$id';

  /// The same addon, marked as custom or default.
  AddonManifest withCustom(bool custom) => AddonManifest(
        id: id,
        name: name,
        version: version,
        description: description,
        baseUrl: baseUrl,
        resources: resources,
        types: types,
        idPrefixes: idPrefixes,
        resourceTypes: resourceTypes,
        resourcePrefixes: resourcePrefixes,
        isCustom: custom,
      );

  /// True if this addon should be asked for [resource] of [type] with [id].
  bool supports(String resource, String type, String id) {
    if (!resources.contains(resource)) return false;
    final t = resourceTypes[resource] ?? types;
    if (t.isNotEmpty && !t.contains(type)) return false;
    final prefixes = resourcePrefixes[resource] ?? idPrefixes;
    if (prefixes.isEmpty) return true;
    return prefixes.any(id.startsWith);
  }

  factory AddonManifest.fromJson(Map<String, dynamic> json, String baseUrl) {
    List<String> strings(dynamic v) =>
        v is List ? v.map((e) => e.toString()).toList() : const [];

    final resources = <String>[];
    final resTypes = <String, List<String>>{};
    final resPrefixes = <String, List<String>>{};
    final rawResources = json['resources'];
    if (rawResources is List) {
      for (final r in rawResources) {
        if (r is String) {
          resources.add(r);
        } else if (r is Map) {
          final name = r['name']?.toString();
          if (name == null) continue;
          resources.add(name);
          final t = strings(r['types']);
          final p = strings(r['idPrefixes']);
          if (t.isNotEmpty) resTypes[name] = t;
          if (p.isNotEmpty) resPrefixes[name] = p;
        }
      }
    }

    return AddonManifest(
      id: (json['id'] ?? baseUrl).toString(),
      name: (json['name'] ?? 'Addon').toString(),
      version: (json['version'] ?? '').toString(),
      description: (json['description'] ?? '').toString(),
      baseUrl: baseUrl,
      resources: resources,
      types: strings(json['types']),
      idPrefixes: strings(json['idPrefixes']),
      resourceTypes: resTypes,
      resourcePrefixes: resPrefixes,
    );
  }

  /// Round-trip form used for on-disk persistence (a copy of the manifest, so
  /// the addon list can be shown offline).
  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'version': version,
        'description': description,
        'baseUrl': baseUrl,
        'resources': resources,
        'types': types,
        'idPrefixes': idPrefixes,
        'resourceTypes': resourceTypes,
        'resourcePrefixes': resourcePrefixes,
        'custom': isCustom,
      };

  /// [isDefaultUrl] is only used for an addon saved before the custom flag
  /// existed: one whose address is not one of the app's default addresses
  /// was added by the person, so it counts as custom.
  factory AddonManifest.fromStored(
    Map<String, dynamic> json, {
    bool Function(String baseUrl)? isDefaultUrl,
  }) {
    Map<String, List<String>> mapOfLists(dynamic v) {
      if (v is! Map) return const {};
      return v.map((k, val) => MapEntry(
            k.toString(),
            val is List ? val.map((e) => e.toString()).toList() : <String>[],
          ));
    }

    List<String> strings(dynamic v) =>
        v is List ? v.map((e) => e.toString()).toList() : const [];

    final baseUrl = json['baseUrl'].toString();
    final bool custom;
    if (json['custom'] is bool) {
      custom = json['custom'] as bool;
    } else {
      custom = isDefaultUrl != null && !isDefaultUrl(baseUrl);
    }

    return AddonManifest(
      id: json['id'].toString(),
      name: json['name'].toString(),
      version: (json['version'] ?? '').toString(),
      description: (json['description'] ?? '').toString(),
      baseUrl: baseUrl,
      resources: strings(json['resources']),
      types: strings(json['types']),
      idPrefixes: strings(json['idPrefixes']),
      resourceTypes: mapOfLists(json['resourceTypes']),
      resourcePrefixes: mapOfLists(json['resourcePrefixes']),
      isCustom: custom,
    );
  }
}

/// A subtitle track offered by an addon (or attached to one of its streams).
class AddonSubtitle {
  final String id;
  final String lang;
  final String url;
  final String addonName;

  const AddonSubtitle({
    required this.id,
    required this.lang,
    required this.url,
    required this.addonName,
  });

  static AddonSubtitle? tryParse(dynamic json, String addonName) {
    if (json is! Map) return null;
    final url = json['url']?.toString();
    if (url == null || url.isEmpty) return null;
    return AddonSubtitle(
      id: (json['id'] ?? url).toString(),
      lang: (json['lang'] ?? 'und').toString(),
      url: url,
      addonName: addonName,
    );
  }
}

/// One playable option returned by an addon for a title.
///
/// Only streams with a direct `url` are usable by the app's player. Entries
/// that describe something else (no `url`) are dropped by [tryParse].
class AddonStream {
  final String addonId;
  final String addonName;

  /// Short label, usually the addon / source name (Stremio's `name`).
  final String name;

  /// Longer, often multi-line description (Stremio's `title`/`description`),
  /// typically carrying quality, size and language text.
  final String description;

  final String url;

  /// Extra HTTP request headers the player must send (from
  /// `behaviorHints.proxyHeaders.request`), if the addon asked for any.
  final Map<String, String> headers;

  final List<AddonSubtitle> subtitles;

  /// Pixel height guessed from the text (2160/1080/720/...), 0 if unknown.
  /// Used for sorting and the quality badge only.
  final int height;

  // ---- torrent sources (Stremio streams with `infoHash` instead of `url`) --

  /// 40-char hex info hash. When set, [url] is a magnet link and the stream
  /// must go through the torrent engine before it can be played.
  final String? infoHash;

  /// Position of the wanted file inside the torrent (Stremio's `fileIdx`).
  final int? fileIdx;

  /// `behaviorHints.filename`, used to find the right file in a pack.
  final String? fileName;

  /// Tracker addresses from the stream's `sources`.
  final List<String> trackers;

  /// True once a torrent stream has been turned into a local http address.
  final bool viaTorrent;

  /// File size, seeders and peers when the addon sent them as proper fields
  /// (`behaviorHints.videoSize`, `seeders`, `peers`). Otherwise they are
  /// read from the description text (see StreamInfo).
  final int? videoSize;
  final int? jsonSeeders;
  final int? jsonPeers;

  bool get isTorrent => infoHash != null;

  /// What kind of link this is, shown in place of the addon's own name:
  /// "Direct link" or "Torrent".
  String get typeLabel => isTorrent ? 'Torrent' : 'Direct link';

  /// Saved with a download so it can continue after the app was closed.
  /// (Subtitles are left out: downloads ask the addons for them again.)
  Map<String, dynamic> toJson() => {
        'addonId': addonId,
        'addonName': addonName,
        'name': name,
        'description': description,
        'url': url,
        'headers': headers,
        'height': height,
        'infoHash': infoHash,
        'fileIdx': fileIdx,
        'fileName': fileName,
        'trackers': trackers,
        'videoSize': videoSize,
        'jsonSeeders': jsonSeeders,
        'jsonPeers': jsonPeers,
      };

  static AddonStream? fromJson(dynamic j) {
    if (j is! Map) return null;
    final url = j['url']?.toString();
    if (url == null || url.isEmpty) return null;
    final h = j['headers'];
    final t = j['trackers'];
    return AddonStream(
      addonId: (j['addonId'] ?? '').toString(),
      addonName: (j['addonName'] ?? '').toString(),
      name: (j['name'] ?? '').toString(),
      description: (j['description'] ?? '').toString(),
      url: url,
      headers: h is Map
          ? {for (final e in h.entries) e.key.toString(): e.value.toString()}
          : const {},
      height: (j['height'] as num?)?.toInt() ?? 0,
      infoHash: j['infoHash'] as String?,
      fileIdx: (j['fileIdx'] as num?)?.toInt(),
      fileName: j['fileName'] as String?,
      trackers:
          t is List ? t.map((e) => e.toString()).toList() : const <String>[],
      videoSize: (j['videoSize'] as num?)?.toInt(),
      jsonSeeders: (j['jsonSeeders'] as num?)?.toInt(),
      jsonPeers: (j['jsonPeers'] as num?)?.toInt(),
    );
  }

  const AddonStream({
    required this.addonId,
    required this.addonName,
    required this.name,
    required this.description,
    required this.url,
    this.headers = const {},
    this.subtitles = const [],
    this.height = 0,
    this.infoHash,
    this.fileIdx,
    this.fileName,
    this.trackers = const [],
    this.viaTorrent = false,
    this.videoSize,
    this.jsonSeeders,
    this.jsonPeers,
  });

  String get qualityLabel {
    if (height >= 2160) return '4K';
    if (height >= 1440) return '1440p';
    if (height > 0) return '${height}p';
    return '';
  }

  static AddonStream? tryParse(
    dynamic json, {
    required String addonId,
    required String addonName,
  }) {
    if (json is! Map) return null;

    final name = (json['name'] ?? addonName).toString();
    final hints = json['behaviorHints'];
    String? fileName;
    if (hints is Map && hints['filename'] != null) {
      fileName = hints['filename'].toString();
    }
    final description = (json['description'] ??
            json['title'] ??
            fileName ??
            '')
        .toString();

    // A direct link wins. Without one, a torrent info hash is playable
    // through the torrent engine.
    String? direct;
    final rawUrl = json['url']?.toString();
    if (rawUrl != null && rawUrl.isNotEmpty) {
      final uri = Uri.tryParse(rawUrl);
      if (uri != null && (uri.scheme == 'http' || uri.scheme == 'https')) {
        direct = rawUrl;
      }
    }
    String? infoHash;
    int? fileIdx;
    var trackers = const <String>[];
    final String url;
    if (direct != null) {
      url = direct;
    } else {
      infoHash = _cleanHash(json['infoHash']);
      if (infoHash == null) return null;
      trackers = _trackersFrom(json['sources']);
      url = _magnet(infoHash, trackers, fileName ?? name);
      final fi = json['fileIdx'];
      if (fi is num) {
        fileIdx = fi.toInt();
      } else if (fi is String) {
        fileIdx = int.tryParse(fi);
      }
    }

    final headers = <String, String>{};
    if (hints is Map) {
      final proxy = hints['proxyHeaders'];
      if (proxy is Map && proxy['request'] is Map) {
        (proxy['request'] as Map).forEach((k, v) {
          headers[k.toString()] = v.toString();
        });
      }
    }

    final subs = <AddonSubtitle>[];
    final rawSubs = json['subtitles'];
    if (rawSubs is List) {
      for (final s in rawSubs) {
        final parsed = AddonSubtitle.tryParse(s, addonName);
        if (parsed != null) subs.add(parsed);
      }
    }

    return AddonStream(
      addonId: addonId,
      addonName: addonName,
      name: name,
      description: description,
      url: url,
      headers: headers,
      subtitles: subs,
      height: guessHeight('$name $description'),
      infoHash: infoHash,
      fileIdx: fileIdx,
      fileName: fileName,
      trackers: trackers,
      videoSize: _num(hints is Map ? hints['videoSize'] : null),
      jsonSeeders: _num(json['seeders'] ?? json['seeds']),
      jsonPeers: _num(json['peers']),
    );
  }

  static int? _num(dynamic v) {
    if (v is num) return v.toInt();
    if (v is String) return int.tryParse(v);
    return null;
  }

  static final RegExp _hexHash = RegExp(r'^[0-9a-f]{40}$');

  static String? _cleanHash(dynamic v) {
    if (v == null) return null;
    final h = v.toString().trim().toLowerCase();
    return _hexHash.hasMatch(h) ? h : null;
  }

  static List<String> _trackersFrom(dynamic sources) {
    if (sources is! List) return const [];
    final out = <String>[];
    for (final s in sources) {
      var t = s.toString().trim();
      if (t.startsWith('tracker:')) t = t.substring(8);
      final ok = t.startsWith('udp://') ||
          t.startsWith('http://') ||
          t.startsWith('https://');
      if (ok && !out.contains(t)) out.add(t);
      if (out.length >= 30) break;
    }
    return out;
  }

  static String _magnet(String hash, List<String> trackers, String name) {
    final b = StringBuffer('magnet:?xt=urn:btih:$hash');
    if (name.isNotEmpty) b.write('&dn=${Uri.encodeQueryComponent(name)}');
    for (final t in trackers) {
      b.write('&tr=${Uri.encodeQueryComponent(t)}');
    }
    return b.toString();
  }

  static final RegExp _heightRe =
      RegExp(r'\b(2160|1440|1080|720|576|480|360)\s*p\b', caseSensitive: false);
  static final RegExp _fourKRe = RegExp(r'\b(4k|uhd)\b', caseSensitive: false);

  static int guessHeight(String text) {
    final m = _heightRe.firstMatch(text);
    if (m != null) return int.parse(m.group(1)!);
    if (_fourKRe.hasMatch(text)) return 2160;
    return 0;
  }
}
