import '../player/models/media_item.dart';
import '../player/models/subtitle_track.dart';
import '../player/services/media_stream_parser.dart';

/// `MediaItem.raw` hint: the subtitle stream index to have showing the
/// moment the item loads on a cast receiver (Jellyfin stream index; the
/// shared local-cast ids for Open With/Play With subtitles).
const String kCastActiveSubtitleHint = 'CastActiveSubtitleId';

/// `MediaItem.raw` hint: the person turned subtitles OFF for this item, so
/// nothing may switch one back on by itself.
const String kCastSubtitlesOffHint = 'CastSubtitlesOff';

/// Whether [t] is an English subtitle (ISO code, language name, or an
/// "English" label such as the ones downloaded sidecars carry).
bool isEnglishSubtitle(SubtitleTrack t) {
  final lang = t.language.trim().toLowerCase();
  if (lang == 'en' ||
      lang == 'eng' ||
      lang == 'english' ||
      lang.startsWith('en-') ||
      lang.startsWith('en_') ||
      lang.startsWith('eng.') ||
      lang.startsWith('en.') ||
      lang.startsWith('english')) {
    return true;
  }
  return RegExp(r'\benglish\b').hasMatch(t.displayTitle.toLowerCase());
}

/// The one subtitle that should be switched on by default out of [tracks]
/// (given in display order). English comes first: a full English track
/// (the file's default one when there are several), then any English
/// track. Without English it is the track the file itself flags as
/// default/forced, otherwise simply the first track.
/// With [allowFirstFallback] false only a file-flagged default/forced
/// track qualifies (and, while an English track exists, only an English
/// one, so a non-English default does not pre-empt the English pick that
/// becomes possible once [allowFirstFallback] is true).
///
/// This is the single rule shared by local playback (PlayerManager) and
/// every cast transport, so the same title always starts on the same track.
SubtitleTrack? pickDefaultSubtitle(
  Iterable<SubtitleTrack> tracks, {
  bool allowFirstFallback = true,
}) {
  final list = tracks.toList();
  if (list.isEmpty) return null;

  final english = list.where(isEnglishSubtitle).toList();

  if (allowFirstFallback && english.isNotEmpty) {
    final full = english.where((t) => !t.isForced).toList();
    final pool = full.isNotEmpty ? full : english;
    for (final t in pool) {
      if (t.isDefault) return t;
    }
    return pool.first;
  }

  final flagged = list.where((t) => t.isDefault || t.isForced).toList();
  if (!allowFirstFallback && english.isNotEmpty) {
    // Wait for the English pick rather than settling on a flagged
    // non-English track now.
    final flaggedEnglish = flagged.where(isEnglishSubtitle).toList();
    return flaggedEnglish.isEmpty ? null : flaggedEnglish.first;
  }
  if (flagged.isNotEmpty) return flagged.first;
  return allowFirstFallback ? list.first : null;
}

/// The Jellyfin stream index of the subtitle a cast of [item] should start
/// with, or null when the item has none (or isn't a Jellyfin video).
///
/// [textOnly] limits the choice to tracks that can be fetched as text
/// (Google Cast / DLNA can only render those); Jellyfin Remote and Nemesis
/// Native receivers can show any subtitle stream.
int? defaultCastSubtitleIndex(MediaItem item, {required bool textOnly}) {
  if (item.audioOnly || item.live || item.isLocal) return null;

  List<dynamic>? streams = item.mediaStreams;
  final sources = item.mediaSources;
  if ((streams == null || streams.isEmpty) &&
      sources != null &&
      sources.isNotEmpty &&
      sources.first is Map) {
    final nested = (sources.first as Map)['MediaStreams'];
    if (nested is List) streams = nested;
  }
  if (streams == null || streams.isEmpty) return null;

  final mediaSourceId = (sources != null && sources.isNotEmpty)
      ? (sources.first as Map)['Id'] as String? ?? item.id
      : item.id;

  var subs = MediaStreamParser.subtitles(
    streams,
    itemId: item.id,
    mediaSourceId: mediaSourceId,
  );
  if (textOnly) {
    subs = subs
        .where((s) => s.externalUrl != null && s.externalUrl!.isNotEmpty)
        .toList();
  }
  return pickDefaultSubtitle(subs)?.index;
}

/// The subtitle stream index to ask a remote-controlled receiver
/// (Jellyfin Remote / Nemesis Native) to start [item] with: -1 when the
/// person turned subtitles off, the stamped default otherwise, null when
/// there is nothing to ask for (the receiver keeps its own default).
int? castStartSubtitleIndex(MediaItem item) {
  final raw = item.raw;
  if (raw == null || item.audioOnly || item.live) return null;
  if (raw[kCastSubtitlesOffHint] == true) return -1;
  final hinted = raw[kCastActiveSubtitleHint];
  return hinted is int && hinted >= 0 ? hinted : null;
}

/// Remembers which items a remote-controlled receiver has already been
/// given their default subtitle, so it is applied once per load and a
/// later "Off" (or any other pick) is never overridden.
class AutoSubtitleTracker {
  final Set<String> _handled = <String>{};

  /// Forget everything — call whenever a fresh load/queue is sent.
  void reset() => _handled.clear();

  /// The person picked a subtitle (or Off) for [itemId] themselves — the
  /// default must never be applied over it afterwards.
  void markHandled(String itemId) => _handled.add(itemId);

  /// Returns the subtitle index to command now for the item the receiver
  /// reports as playing, or null when nothing should be sent. Fires at most
  /// once per [playingId] per load.
  int? indexToApply({
    required String? playingId,
    required MediaItem? item,
    required int? reportedSubtitleIndex,
  }) {
    if (playingId == null || item == null || item.id != playingId) return null;
    if (!_handled.add(playingId)) return null;
    if (reportedSubtitleIndex != null && reportedSubtitleIndex >= 0) {
      return null; // receiver already has one showing
    }
    final raw = item.raw;
    if (raw != null && raw[kCastSubtitlesOffHint] == true) return null;
    final hinted = raw?[kCastActiveSubtitleHint];
    if (hinted is int && hinted >= 0) return hinted;
    return defaultCastSubtitleIndex(item, textOnly: false);
  }
}
