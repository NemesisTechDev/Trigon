import '../../player/models/subtitle_appearance.dart';
import '../models/cast_session.dart';

/// Optional capability a [CastTransport] can also implement when its
/// receiver can restyle subtitles remotely (Google Cast's
/// `TextTrackStyle`, the Nemesis Native `subtitleStyle` message).
/// Deliberately a separate interface instead of a new method on
/// `CastTransport`, so Jellyfin Remote (whose protocol has no such
/// command) and any test fakes stay untouched.
abstract interface class SubtitleStyleCapableTransport {
  /// Pushes [appearance] to the receiver for [session]. Safe to call
  /// repeatedly (live updates while the user drags a slider).
  Future<void> applySubtitleStyle(
    CastSession session,
    SubtitleAppearance appearance,
  );
}
