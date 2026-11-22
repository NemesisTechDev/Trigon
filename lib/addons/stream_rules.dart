import 'addon_models.dart';

/// What the auto link selector knows about the title being played, so a link
/// can be judged against it (see [StreamRules.exclusionReason]).
class LinkContext {
  const LinkContext({this.originalLanguage, this.titleName = ''});

  /// TMDB's `original_language` for the title (`en`, `ja`, ...); null when
  /// it is not known (saved history/watchlist snapshots do not keep it).
  final String? originalLanguage;

  /// The title's own name. A language word that is part of the title
  /// ("The French Connection") is not read as the link's audio language, and
  /// a film really called "Cam" is not mistaken for a CAM recording.
  final String titleName;

  static const LinkContext none = LinkContext();
}

/// How closely a link's release name matches the kinds of file the person
/// prefers. Lower [rank] is better.
///
///  - [a]  H.264 / H.265 (dotted spelling) from a BluRay, or in an MP4
///  - [b]  x264 / x265 from a BluRay, or in an MP4
///  - [c]  HEVC from a BluRay
///  - [d]  WEB-DL in HEVC (H.265 / x265 / HEVC), MKV or MP4
///  - [codecOnly] a modern codec was named, but none of the combinations
///    above
///  - [unrated] nothing recognisable (direct links often say nothing at all)
enum PreferredTier {
  a(0),
  b(1),
  c(2),
  d(3),
  codecOnly(4),
  unrated(5);

  const PreferredTier(this.rank);
  final int rank;
}

/// Hard rules for the auto link selector: links that must never be picked,
/// and how the rest are ranked by file type.
///
/// Pure and synchronous (no UI, no network).
class StreamRules {
  StreamRules._();

  // A "word" boundary that treats '.', '_' and '-' as separators (release
  // names are full of them), which `\b` does not.
  static const String _pre = r'(?<![A-Za-z0-9])';
  static const String _post = r'(?![A-Za-z0-9])';

  static RegExp _tok(String body, {bool caseSensitive = false}) =>
      RegExp('$_pre(?:$body)$_post', caseSensitive: caseSensitive);

  static String _text(AddonStream s) =>
      '${s.name}\n${s.description}\n${s.fileName ?? ''}';

  // ------------------------------------------------------------------
  // Never-select rules
  // ------------------------------------------------------------------

  /// Why [s] must never be auto-selected, or null when it may be.
  static String? exclusionReason(AddonStream s, LinkContext ctx) {
    if (_isHls(s)) return 'HLS stream';
    if (_isVidlink(s)) return 'vidlink source';
    if (_isCam(s, ctx)) return 'CAM recording';
    final language = _languageReason(s, ctx);
    if (language != null) return language;
    return null;
  }

  static bool isExcluded(AddonStream s, LinkContext ctx) =>
      exclusionReason(s, ctx) != null;

  // ---- HLS ----

  static final RegExp _hlsWord = _tok('HLS');
  static final RegExp _hlsUrl = RegExp(
    r'm3u8|(?:^|[/?&=._-])hls(?:$|[/?&=._-])',
    caseSensitive: false,
  );

  static bool _isHls(AddonStream s) {
    if (!s.isTorrent && _hlsUrl.hasMatch(s.url)) return true;
    return _hlsWord.hasMatch('${s.name}\n${s.description}');
  }

  // ---- vidlink ----

  static bool _isVidlink(AddonStream s) {
    final haystack = '${s.addonName}\n${s.name}\n${s.description}\n'
            '${s.isTorrent ? '' : s.url}'
        .toLowerCase();
    return haystack.contains('vidlink');
  }

  // ---- CAM ----

  // Spellings that can only mean a camera recording.
  static final RegExp _camSure = _tok(
    r'(?:HD|HQ)[ ._-]?CAM(?:[ ._-]?RIP)?|CAM[ ._-]?RIP',
  );
  // The bare word. Also a normal word / name, so it is judged more carefully.
  static final RegExp _camBare = _tok('CAM');
  static final RegExp _camWordInTitle = RegExp(
    r'(?<![A-Za-z0-9])cam(?![A-Za-z0-9])',
    caseSensitive: false,
  );

  static bool _isCam(AddonStream s, LinkContext ctx) {
    final text = _text(s);
    if (_camSure.hasMatch(text)) return true;
    // A title that itself contains the word ("Cam", "Cam Girl") cannot tell
    // the tag from the title, so only the unmistakable spellings count.
    if (_camWordInTitle.hasMatch(ctx.titleName)) return false;
    for (final line in text.split('\n')) {
      for (final m in _camBare.allMatches(line)) {
        // At the very start of a line the word is the title, not a tag.
        if (m.start > 0) return true;
      }
    }
    return false;
  }

  // ---- language ----

  /// Why [s] is excluded on language grounds, or null.
  ///
  /// The rule: a link whose audio is only a foreign-language dub is never
  /// chosen; multi-audio links are chosen only when English is one of the
  /// languages; a single language is fine when it is English or when it is
  /// the title's own original language; a link that names no language is
  /// taken to be English.
  static String? _languageReason(AddonStream s, LinkContext ctx) {
    final found = _audioLanguages(s, ctx);
    if (found.languages.isEmpty) return null; // no indication: English
    if (found.languages.contains(_en)) return null;

    final original = ctx.originalLanguage?.toLowerCase();
    final foreign = found.languages;

    if (found.multi || foreign.length > 1) {
      // Several tracks, English not among them. One listed language next to a
      // multi/dual tag still leaves the original track, which is English when
      // the title is English-language.
      if (foreign.length == 1 && found.multi && original == 'en') return null;
      return 'multi audio without English';
    }

    final only = foreign.first;
    if (original != null && only.matches(original)) return null;
    return 'foreign-language dub (${only.key})';
  }

  /// The audio languages a link's text names, and whether it is tagged as
  /// multi / dual audio. Subtitle mentions are ignored.
  static ({Set<_Lang> languages, bool multi}) _audioLanguages(
    AddonStream s,
    LinkContext ctx,
  ) {
    var text = _text(s);
    text = text.replaceAll(_subtitleList, ' ').replaceAll(_subtitleTag, ' ');
    final title = ctx.titleName.toLowerCase();

    final languages = <_Lang>{};
    for (final lang in _languages) {
      if (_mentions(lang, text, title)) languages.add(lang);
    }
    return (languages: languages, multi: _multiAudio.hasMatch(text));
  }

  static const Map<String, String> _labels = {
    'en': 'English',
    'fr': 'French',
    'de': 'German',
    'es': 'Spanish',
    'it': 'Italian',
    'pt': 'Portuguese',
    'ru': 'Russian',
    'ja': 'Japanese',
    'ko': 'Korean',
    'zh': 'Chinese',
    'hi': 'Hindi',
    'ta': 'Tamil',
    'te': 'Telugu',
    'ml': 'Malayalam',
    'kn': 'Kannada',
    'bn': 'Bengali',
    'pa': 'Punjabi',
    'mr': 'Marathi',
    'gu': 'Gujarati',
    'ur': 'Urdu',
    'indic': 'Indian language',
    'tr': 'Turkish',
    'ar': 'Arabic',
    'pl': 'Polish',
    'nl': 'Dutch',
    'th': 'Thai',
    'vi': 'Vietnamese',
    'uk': 'Ukrainian',
    'cs': 'Czech',
    'el': 'Greek',
    'he': 'Hebrew',
    'hu': 'Hungarian',
    'ro': 'Romanian',
    'sv': 'Swedish',
    'no': 'Norwegian',
    'da': 'Danish',
    'fi': 'Finnish',
    'id': 'Indonesian',
    'fa': 'Persian',
  };

  /// The audio languages [s] names, as display names (English first), and
  /// whether it is tagged multi / dual audio. Empty when the link says
  /// nothing about its language. Subtitle mentions are not counted.
  static ({List<String> labels, bool multi}) audioLanguageLabels(
    AddonStream s,
    LinkContext ctx,
  ) {
    final found = _audioLanguages(s, ctx);
    final keys = found.languages.map((l) => l.key).toSet();
    // The India flag only says "an Indian language": drop it once a specific
    // one is named.
    if (keys.contains('indic') && keys.any((k) => _indicKeys.contains(k))) {
      keys.remove('indic');
    }
    final labels = <String>[
      for (final lang in _languages)
        if (keys.contains(lang.key)) _labels[lang.key] ?? lang.key,
    ];
    return (labels: labels, multi: found.multi);
  }

  static const Set<String> _indicKeys = {
    'hi', 'ta', 'te', 'ml', 'kn', 'bn', 'pa', 'mr', 'gu', 'ur',
  };

  static bool _mentions(_Lang lang, String text, String lowerTitle) {
    for (final flag in lang.flags) {
      if (text.contains(flag)) return true;
    }
    for (final m in lang.names.allMatches(text)) {
      final word = m.group(0)!.toLowerCase();
      // "The French Connection": the word is the title's, not an audio track.
      if (lowerTitle.isNotEmpty && _tok(RegExp.escape(word)).hasMatch(lowerTitle)) {
        continue;
      }
      return true;
    }
    final codes = lang.codes;
    return codes != null && codes.hasMatch(text);
  }

  // "Eng Subs", "French subtitles", "Subs: English, Spanish": not audio.
  static final RegExp _subtitleTag = RegExp(
    r'[A-Za-z]{3,12}[ ._-]?(?:subs?|subtitles?|subbed)(?![A-Za-z])',
    caseSensitive: false,
  );
  static final RegExp _subtitleList = RegExp(
    r'(?:subs?|subtitles?)\s*[:=][^\n]*',
    caseSensitive: false,
  );

  static final RegExp _multiAudio = _tok(
    r'MULTI(?:[ ._-]?(?:AUDIO|LANG(?:UAGE)?S?))?|'
    r'DUAL(?:[ ._-]?(?:AUDIO|LANG(?:UAGE)?S?))?|TRIPLE[ ._-]?AUDIO',
  );

  static final _Lang _en = _Lang(
    'en',
    names: r'English|Eng',
    flags: const ['\u{1F1EC}\u{1F1E7}', '\u{1F1FA}\u{1F1F8}', '\u{1F1E6}\u{1F1FA}', '\u{1F1F3}\u{1F1FF}', '\u{1F1EE}\u{1F1EA}'],
    tmdb: const ['en'],
  );

  static final List<_Lang> _languages = <_Lang>[
    _en,
    _Lang('fr',
        names: r'French|Fran[cç]ais|TrueFrench|VFF|VFQ|VFI|VF2|VF',
        codes: 'FRE|FRA',
        flags: const ['\u{1F1EB}\u{1F1F7}'],
        tmdb: const ['fr']),
    _Lang('de',
        names: r'German|Deutsch',
        codes: 'GER|DEU',
        flags: const ['\u{1F1E9}\u{1F1EA}'],
        tmdb: const ['de']),
    _Lang('es',
        names: r'Spanish|Espa[nñ]ol|Castellano|Castilian|Latino|LATAM',
        codes: 'SPA|ESP',
        flags: const [
          '\u{1F1EA}\u{1F1F8}',
          '\u{1F1F2}\u{1F1FD}',
          '\u{1F1E6}\u{1F1F7}',
          '\u{1F1E8}\u{1F1F4}',
          '\u{1F1E8}\u{1F1F1}',
        ],
        tmdb: const ['es']),
    _Lang('it',
        names: r'Italian|Italiano',
        codes: 'ITA',
        flags: const ['\u{1F1EE}\u{1F1F9}'],
        tmdb: const ['it']),
    _Lang('pt',
        names: r'Portuguese|Portugu[eê]s|Dublado|PT[ ._-]?BR|Brazilian',
        codes: 'POR',
        flags: const ['\u{1F1F5}\u{1F1F9}', '\u{1F1E7}\u{1F1F7}'],
        tmdb: const ['pt']),
    _Lang('ru',
        names: r'Russian|Russkiy',
        codes: 'RUS',
        flags: const ['\u{1F1F7}\u{1F1FA}'],
        tmdb: const ['ru']),
    _Lang('ja',
        names: r'Japanese',
        codes: 'JPN|JAP',
        flags: const ['\u{1F1EF}\u{1F1F5}'],
        tmdb: const ['ja']),
    _Lang('ko',
        names: r'Korean',
        codes: 'KOR',
        flags: const ['\u{1F1F0}\u{1F1F7}'],
        tmdb: const ['ko']),
    _Lang('zh',
        names: r'Chinese|Mandarin|Cantonese',
        codes: 'CHI|CHN|ZHO',
        flags: const ['\u{1F1E8}\u{1F1F3}', '\u{1F1F9}\u{1F1FC}', '\u{1F1ED}\u{1F1F0}'],
        tmdb: const ['zh', 'cn']),
    _Lang('hi', names: r'Hindi', codes: 'HIN', tmdb: const ['hi']),
    _Lang('ta', names: r'Tamil', codes: 'TAM', tmdb: const ['ta']),
    _Lang('te', names: r'Telugu', tmdb: const ['te']),
    _Lang('ml', names: r'Malayalam', tmdb: const ['ml']),
    _Lang('kn', names: r'Kannada', tmdb: const ['kn']),
    _Lang('bn', names: r'Bengali|Bangla', tmdb: const ['bn']),
    _Lang('pa', names: r'Punjabi', tmdb: const ['pa']),
    _Lang('mr', names: r'Marathi', tmdb: const ['mr']),
    _Lang('gu', names: r'Gujarati', tmdb: const ['gu']),
    _Lang('ur', names: r'Urdu', tmdb: const ['ur']),
    // The India flag does not say which Indian language.
    _Lang('indic',
        flags: const ['\u{1F1EE}\u{1F1F3}'],
        tmdb: const ['hi', 'ta', 'te', 'ml', 'kn', 'bn', 'pa', 'mr', 'gu', 'ur', 'bh']),
    _Lang('tr',
        names: r'Turkish|T[uü]rk[cç]e',
        codes: 'TUR',
        flags: const ['\u{1F1F9}\u{1F1F7}'],
        tmdb: const ['tr']),
    _Lang('ar',
        names: r'Arabic',
        codes: 'ARA',
        flags: const ['\u{1F1F8}\u{1F1E6}', '\u{1F1E6}\u{1F1EA}', '\u{1F1EA}\u{1F1EC}'],
        tmdb: const ['ar']),
    _Lang('pl',
        names: r'Polish|Polski',
        codes: 'POL',
        flags: const ['\u{1F1F5}\u{1F1F1}'],
        tmdb: const ['pl']),
    _Lang('nl',
        names: r'Dutch|Nederlands',
        codes: 'NLD|DUT',
        flags: const ['\u{1F1F3}\u{1F1F1}'],
        tmdb: const ['nl']),
    _Lang('th',
        names: r'Thai',
        codes: 'THA',
        flags: const ['\u{1F1F9}\u{1F1ED}'],
        tmdb: const ['th']),
    _Lang('vi',
        names: r'Vietnamese',
        codes: 'VIE',
        flags: const ['\u{1F1FB}\u{1F1F3}'],
        tmdb: const ['vi']),
    _Lang('uk',
        names: r'Ukrainian',
        codes: 'UKR',
        flags: const ['\u{1F1FA}\u{1F1E6}'],
        tmdb: const ['uk']),
    _Lang('cs',
        names: r'Czech',
        codes: 'CZE',
        flags: const ['\u{1F1E8}\u{1F1FF}'],
        tmdb: const ['cs']),
    _Lang('el',
        names: r'Greek',
        codes: 'GRE',
        flags: const ['\u{1F1EC}\u{1F1F7}'],
        tmdb: const ['el']),
    _Lang('he',
        names: r'Hebrew',
        codes: 'HEB',
        flags: const ['\u{1F1EE}\u{1F1F1}'],
        tmdb: const ['he']),
    _Lang('hu',
        names: r'Hungarian',
        codes: 'HUN',
        flags: const ['\u{1F1ED}\u{1F1FA}'],
        tmdb: const ['hu']),
    _Lang('ro',
        names: r'Romanian',
        flags: const ['\u{1F1F7}\u{1F1F4}'],
        tmdb: const ['ro']),
    _Lang('sv',
        names: r'Swedish',
        codes: 'SWE',
        flags: const ['\u{1F1F8}\u{1F1EA}'],
        tmdb: const ['sv']),
    _Lang('no',
        names: r'Norwegian',
        codes: 'NOR',
        flags: const ['\u{1F1F3}\u{1F1F4}'],
        tmdb: const ['no', 'nb', 'nn']),
    _Lang('da',
        names: r'Danish',
        flags: const ['\u{1F1E9}\u{1F1F0}'],
        tmdb: const ['da']),
    _Lang('fi',
        names: r'Finnish',
        flags: const ['\u{1F1EB}\u{1F1EE}'],
        tmdb: const ['fi']),
    _Lang('id',
        names: r'Indonesian',
        flags: const ['\u{1F1EE}\u{1F1E9}'],
        tmdb: const ['id']),
    _Lang('fa', names: r'Persian|Farsi', tmdb: const ['fa']),
  ];

  // ------------------------------------------------------------------
  // Preferred file types
  // ------------------------------------------------------------------

  static final RegExp _dottedCodec = _tok(r'H[ ._-]?26[45]');
  static final RegExp _xCodec = _tok(r'x26[45]');
  static final RegExp _hevcWord = _tok('HEVC');
  static final RegExp _hevcFamily = _tok(r'HEVC|H[ ._-]?265|x265');
  static final RegExp _avcWord = _tok('AVC');
  static final RegExp _bluray = _tok(
    r'Blu[ ._-]?Ray|BDRip|BRRip|BD[ ._-]?Remux|Remux',
  );
  static final RegExp _webDl = _tok(r'WEB[ ._-]?DL');
  static final RegExp _mp4 = _tok('MP4');
  static final RegExp _mkv = _tok('MKV');

  /// Where [s] stands among the preferred file types (see [PreferredTier]).
  static PreferredTier tierOf(AddonStream s) {
    final text = _text(s);
    final path = s.isTorrent ? '' : (Uri.tryParse(s.url)?.path ?? '').toLowerCase();

    final bluray = _bluray.hasMatch(text);
    final webDl = _webDl.hasMatch(text);
    final mp4 = _mp4.hasMatch(text) || path.endsWith('.mp4');
    final mkv = _mkv.hasMatch(text) || path.endsWith('.mkv');

    final dotted = _dottedCodec.hasMatch(text);
    final x = _xCodec.hasMatch(text);
    final hevcWord = _hevcWord.hasMatch(text);
    final hevc = _hevcFamily.hasMatch(text);

    if (dotted && (bluray || mp4)) return PreferredTier.a;
    if (x && (bluray || mp4)) return PreferredTier.b;
    if (hevcWord && bluray) return PreferredTier.c;
    if (webDl && hevc && (mkv || mp4)) return PreferredTier.d;
    if (dotted || x || hevcWord || _avcWord.hasMatch(text)) {
      return PreferredTier.codecOnly;
    }
    return PreferredTier.unrated;
  }
}

/// One language the audio-language check knows.
class _Lang {
  _Lang(
    this.key, {
    String? names,
    String? codes,
    this.flags = const [],
    required this.tmdb,
  })  : names = names == null
            ? _never
            : RegExp(
                '${StreamRules._pre}(?:$names)${StreamRules._post}',
                caseSensitive: false,
              ),
        codes = codes == null
            ? null
            : RegExp(
                '${StreamRules._pre}(?:$codes)${StreamRules._post}',
              );

  static final RegExp _never = RegExp(r'(?!)');

  final String key;

  /// Full names / tags, matched in any letter case.
  final RegExp names;

  /// Three-letter codes (ENG, FRE, HIN...), matched in capitals only so
  /// ordinary words are not mistaken for them.
  final RegExp? codes;

  /// Flag emoji addons put next to the audio languages.
  final List<String> flags;

  /// TMDB `original_language` values this language covers.
  final List<String> tmdb;

  bool matches(String tmdbCode) => tmdb.contains(tmdbCode);

  @override
  String toString() => key;
}
