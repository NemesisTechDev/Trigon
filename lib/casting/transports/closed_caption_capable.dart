import '../models/cast_session.dart';

/// A transport that can switch a live channel's in-stream closed captions
/// (CEA-608/708) on the connected TV.
///
/// Broadcast captions are not a Jellyfin subtitle file that can be
/// declared at load time: they travel inside the video, and Jellyfin can
/// neither burn them in nor extract them for live TV. They can therefore
/// only be shown on a TV by the TV's own player, and only be switched from
/// here when the transport has a real command for it. A transport that
/// does not implement this interface (or answers false) is reported to the
/// person as unable, never faked.
abstract interface class ClosedCaptionCapableTransport {
  /// Whether captions can be switched for what [session] is playing now.
  bool supportsClosedCaptions(CastSession session);

  /// Shows ([on] true) or hides the captions on the TV. Throws when the
  /// command does not reach the TV.
  Future<void> setClosedCaptions(CastSession session, bool on);
}
