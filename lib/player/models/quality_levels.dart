/// One rung of the video Quality selector's resolution ladder.
///
/// [videoBitrateKbps] is only used when Jellyfin is actually asked to
/// transcode down to [height] (see `MediaService.getVideoStreamUrl`) —
/// it's a conservative, broadly-compatible H.264 bitrate for that
/// resolution, loosely matching the presets Jellyfin Web's own quality
/// dropdown offers. Retune per your server's transcoding hardware/
/// library bitrates if these ever look too aggressive or too lax.
class VideoQualityLevel {
  final String label;
  final int height;
  final int videoBitrateKbps;

  const VideoQualityLevel(this.label, this.height, this.videoBitrateKbps);

  @override
  String toString() => 'VideoQualityLevel($label)';
}

/// Ascending order is load-bearing: Data Saver mode is defined as
/// "the second-lowest rung", i.e. index 1 — see
/// `PlayerManager._autoVideoTarget`.
const List<VideoQualityLevel> kVideoQualityLadder = [
  VideoQualityLevel("360p", 360, 800),
  VideoQualityLevel("480p", 480, 1500),
  VideoQualityLevel("720p", 720, 4000),
  VideoQualityLevel("1080p", 1080, 8000),
];

/// The audio equivalent of [VideoQualityLevel] — there's no manual
/// selector for these (music always runs on automatic adaptive
/// switching, per the person's own listening-quality settings). Data
/// Saver always resolves to a fixed rung of this ladder; Default mode
/// resolves to one of these only when the network is actually
/// constrained. Max Quality, and Default mode on a strong connection,
/// both resolve to `null` instead — i.e. "don't touch it" — rather than
/// this ladder's top rung, since `MediaService.getAudioStreamUrl`
/// already direct-streams lossless sources (FLAC) at their real
/// bitrate when unconstrained; forcing a fixed 320kbps cap there would
/// downgrade lossless files through a lossy transcode instead of
/// leaving them alone. See `PlayerManager._autoAudioTarget`.
class AudioQualityLevel {
  final String label;
  final int bitrateKbps;

  const AudioQualityLevel(this.label, this.bitrateKbps);

  @override
  String toString() => 'AudioQualityLevel($label)';
}

/// Also ascending — Data Saver is index 1 here too.
const List<AudioQualityLevel> kAudioQualityLadder = [
  AudioQualityLevel("Low", 64),
  AudioQualityLevel("Medium", 128),
  AudioQualityLevel("High", 192),
  AudioQualityLevel("Max", 320),
];
