/// Keyword-based channel genre classification.
///
/// Each list below holds lowercase substrings matched against a channel's
/// name. [classify] is the single source of truth for turning a channel
/// name into a category — every screen that needs to bucket channels
/// (Live TV home, TV Guide, All Channels) should call it instead of
/// re-implementing its own `contains` checks, so the three screens can't
/// drift out of sync with each other again.
class ChannelCategories {
  static const sports = [
    "sport",
    "sports",
    "espn",
    "supersport",
    "bein",
    "sky sports",
    "fox sports",
    "football",
    "nba",
    "tennis",
    "golf",
    "cricket",
    "wwe",
    "motorsport",
    "tnt sports",
    "premier sports",
    "la liga",
    "laliga",
    "tsn",
    "dazn",
    "accn",
    "golazo",
    "cbs sports",
    "sportsnet",
    "acc network",
    "fanduel",
    "deportes",
    "fight network",
    "soccer",
  ];

  // Deliberately specific (e.g. "bbc news", not bare "bbc") so general
  // entertainment channels from the same broadcaster (BBC One/Two/Three,
  // ITV1/2/3, etc.) don't get swept into News.
  static const news = [
    "cnn",
    "bbc news",
    "bbc world news",
    "bbc parliament",
    "sky news",
    "itv news",
    "dw",
    "aljazeera",
    "al jazeera",
    "bloomberg",
    "cnbc",
    "france24",
    "france 24",
    "euronews",
    "ndtv",
    "wion",
    "trt world",
    "newsmax",
    "fox news",
    "weather channel",
    "fox business",
    "cbs news",
    "msnbc",
    "abc news",
  ];

  // Also kept specific — bare tokens like "star", "sony" or "max" used to
  // swallow up general-entertainment siblings (Star Plus, Sony
  // Entertainment Television, ...), which is what caused a lot of the
  // mis-categorization.
  static const movies = [
    "movie",
    "cinema",
    "hbo",
    "cinemax",
    "star movies",
    "star action",
    "sony max",
    "sony pix",
    "zee cinema",
    "colors cineplex",
    "utv movies",
    "showcase",
    "film4",
    "film",
    "paramount channel",
    "sky comedy",
    "lmn",
    "mgm+",
    "showtime",
    "starz",
    "b4u movies",
  ];

  static const kids = [
    "cartoon",
    "nick",
    "nickelodeon",
    "disney",
    "kids",
    "boomerang",
    "cn",
    "baby tv",
    "babytv",
    "cbeebies",
    "baby first",
    "babyfirst",
    "tiny pop",
    "junior",
    "pogo",
    "gulli",
    "cartoonito",
  ];

  static const music = [
    "music",
    "mtv",
    "trace",
    "vh1",
    "9xm",
    "b4u music",
    "kiss",
    "now 70s",
    "now 80s",
    "now rock",
  ];

  static const documentary = [
    "nat geo",
    "national geographic",
    "history",
    "discovery",
    "animal planet",
    "documentary",
    "eden",
    "crime investigation",
    "crime + investigation",
    "food network",
    "really",
    "blaze",
    "curiosity",
    "yesterday",
    "sky nature",
    "sky crime",
    "sky documentaries",
    "true crime",
    "law & crime",
    "love nature",
    "sky witness",
  ];

  // General/lifestyle entertainment — also the catch-all bucket for
  // anything that doesn't match a more specific genre above, since most
  // unmatched channels (BBC One/Two/Three, ITV, E!, TLC, Sony
  // Entertainment Television, etc.) are general entertainment, not movie
  // channels.
  static const entertainment = [
    "entertainment",
    "e! entertainment",
    "e entertainment",
    "tlc",
    "comedy central",
    "bbc one",
    "bbc two",
    "bbc three",
    "bbc four",
    "itv1",
    "itv2",
    "itv3",
    "itv4",
    "channel 4",
    "channel 5",
    "universal tv",
    "amc",
    "paramount network",
    "lifetime",
    "hallmark",
    "5star",
    "dave",
    "gold",
    "w channel",
    "star plus",
    "star world",
    "zee tv",
    "colors",
    "gem",
  ];

  /// Ordered narrowest-first so a channel that could plausibly match more
  /// than one list (e.g. a kids channel with "junior" in its name) lands
  /// in the most specific/correct bucket rather than the broadest one.
  static const List<MapEntry<String, List<String>>> _priority = [
    MapEntry("Kids", kids),
    MapEntry("Sports", sports),
    MapEntry("News", news),
    MapEntry("Music", music),
    MapEntry("Documentaries", documentary),
    MapEntry("Movies", movies),
    MapEntry("Entertainment", entertainment),
  ];

  /// All category labels, in display order, including the catch-all.
  static const List<String> labels = [
    "Sports",
    "Movies",
    "News",
    "Kids",
    "Music",
    "Documentaries",
    "Entertainment",
  ];

  /// Classifies [channelName] into exactly one category. Falls back to
  /// "Entertainment" when nothing matches, rather than leaving the channel
  /// unclassified or dumping it into an unrelated bucket.
  static String classify(String channelName) {
    final name = channelName.toLowerCase();
    for (final entry in _priority) {
      if (entry.value.any((keyword) => _matches(name, keyword))) {
        return entry.key;
      }
    }
    return "Entertainment";
  }

  /// Whether [keyword] appears in [name] as a whole token rather than as
  /// a substring buried inside a longer word.
  ///
  /// Plain `.contains` checks used to misfire badly: the kids keyword
  /// "cn" (short for the Cartoon Network channel) is also a substring of
  /// "CNN" and "CNBC", so both news channels were being swept into Kids
  /// before the News list ever got a chance to match. Requiring a word
  /// boundary on both sides of the keyword means "cn" still matches a
  /// channel literally named "CN" or "CN Kids", but no longer matches
  /// "CNN"/"CNBC", where it's stuck inside a longer run of letters.
  ///
  /// This intentionally does NOT use `\b`. Regex "word" boundaries treat
  /// digits as word characters too, so `\bespn\b` fails to match "ESPN2"
  /// (no boundary between the letter "n" and the following digit "2"),
  /// and `\bsport\b` fails to match "Sports" (no boundary between
  /// "sport" and its trailing "s"). Real channel names are full of
  /// exactly these patterns — numbered feeds ("Sky Sports 1", "TSN1-5",
  /// "ESPN2") and plurals ("Sports") — so that silently dropped a large
  /// number of channels into the Entertainment catch-all. Only letters
  /// count as "part of the same word" here; digits, spaces, and
  /// punctuation all act as boundaries.
  static bool _matches(String name, String keyword) {
    return _patternFor(keyword).hasMatch(name);
  }

  /// [classify] runs for every channel, potentially several times per
  /// screen build (TV Guide's channel/timeline columns, Live TV home,
  /// All Channels). Compiling a fresh [RegExp] per keyword on every one
  /// of those calls — as this used to do — meant every rebuild paid for
  /// recompiling the same ~100 patterns across all categories from
  /// scratch, which is the single biggest reason the TV guide felt heavy
  /// to scroll. Each pattern is now compiled once, lazily, and cached
  /// forever after.
  static final Map<String, RegExp> _patternCache = {};

  static RegExp _patternFor(String keyword) {
    return _patternCache[keyword] ??= RegExp(
      r'(?<![a-z])' + _escapeRegex(keyword) + r'(?![a-z])',
    );
  }

  static String _escapeRegex(String s) {
    return s.replaceAllMapped(
      RegExp(r'[.*+?^${}()|[\]\\]'),
      (m) => '\\${m[0]}',
    );
  }
}
