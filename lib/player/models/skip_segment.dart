/// Mirrors Jellyfin's own MediaSegment "Type" enum (Intro, Outro, Recap,
/// Preview, Commercial) — only the two types this app's skip UI actually
/// acts on are kept here. Real segments come from Jellyfin's Media
/// Segments feature (server 10.10+, needs a segment-providing plugin
/// such as "Chapter Segments Provider" installed and its scan task run
/// at least once) via `MediaService.getSkipSegments`.
enum SkipSegmentType {
  intro,
  outro,

  /// The "Previously on…" summary at the start of an episode (button text:
  /// "Skip Recap").
  recap,
}

/// A single skippable window in a video — "Skip Intro" while inside
/// [start, end] for [SkipSegmentType.intro], or "Skip Outro" (which also
/// doubles as the cue to offer the Next Episode overlay) for
/// [SkipSegmentType.outro].
class SkipSegment {

  final Duration start;

  final Duration end;

  final SkipSegmentType type;

  /// A guess, not real data: the "Skip 85s" button offered when nothing is
  /// known about an episode's intro. Pressing it jumps ahead by a fixed
  /// amount instead of to [end].
  final bool manual;

  const SkipSegment({
    required this.start,
    required this.end,
    required this.type,
    this.manual = false,
  });

}