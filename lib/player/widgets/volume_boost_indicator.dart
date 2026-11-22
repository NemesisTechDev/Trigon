import 'package:flutter/material.dart';

/// VLC-style volume indicator: the percentage on top, a slim vertical bar,
/// a "Volume" label beside it and a speaker icon underneath, sitting on the
/// left edge of the screen. Used by BOTH the local and the casting video
/// player screens (see VideoPlayerScreen), so the two always match.
///
/// [level] is the combined scale. With [allowBoost] (local playback) it runs
/// 0.0–2.0 (1.0 = 100% = the device's own maximum; 1.0–2.0 is software
/// boost): the bar's lower half is white up to 100%, and anything above
/// 100% fills in gold. Without it (casting — the TV's volume has no boost)
/// it runs 0.0–1.0 and the whole bar is the 0–100% range, with no gold.
class VolumeBoostIndicator extends StatelessWidget {
  const VolumeBoostIndicator({
    super.key,
    required this.visible,
    required this.level,
    this.allowBoost = true,
  });

  final bool visible;

  /// 0.0 – 2.0 (1.0 == 100%) when [allowBoost], else 0.0 – 1.0.
  final double level;

  /// False while casting: no boost range, so the bar spans 0–100% only.
  final bool allowBoost;

  // App-wide gold (same as the rest of the UI), shared by the bar and the hint.
  static const Color boostColor = Color(0xFFD4AF37);

  @override
  Widget build(BuildContext context) {
    final maxLevel = allowBoost ? 2.0 : 1.0;
    final clamped = level.clamp(0.0, maxLevel).toDouble();

    return _SideLevelIndicator(
      visible: visible,
      alignment: Alignment.centerLeft,
      percent: (clamped * 100).round(),
      // Local: the bar's lower half is 0–100%. Casting: the whole bar is.
      whiteFraction: allowBoost
          ? (clamped > 1.0 ? 1.0 : clamped) / 2.0
          : clamped,
      boostFraction: allowBoost && clamped > 1.0 ? (clamped - 1.0) / 2.0 : 0.0,
      label: 'Volume',
      icon: clamped <= 0 ? Icons.volume_off : Icons.volume_up,
    );
  }
}

/// Screen-brightness indicator — the same design as [VolumeBoostIndicator]
/// (percentage, slim vertical bar, label, icon) mirrored onto the RIGHT edge
/// of the screen, with the label to the bar's left. Brightness has no boost
/// range, so the bar spans the full 0–100%.
class BrightnessIndicator extends StatelessWidget {
  const BrightnessIndicator({
    super.key,
    required this.visible,
    required this.level,
  });

  final bool visible;

  /// 0.0 – 1.0.
  final double level;

  @override
  Widget build(BuildContext context) {
    final clamped = level.clamp(0.0, 1.0).toDouble();

    return _SideLevelIndicator(
      visible: visible,
      alignment: Alignment.centerRight,
      percent: (clamped * 100).round(),
      whiteFraction: clamped,
      boostFraction: 0.0,
      label: 'Brightness',
      icon: Icons.brightness_6,
    );
  }
}

/// The shared layout behind [VolumeBoostIndicator] and [BrightnessIndicator]
/// — one implementation so the two can never drift apart. [alignment] picks
/// the screen edge (centerLeft / centerRight); on the right edge the label
/// sits to the bar's left instead of its right.
class _SideLevelIndicator extends StatelessWidget {
  const _SideLevelIndicator({
    required this.visible,
    required this.alignment,
    required this.percent,
    required this.whiteFraction,
    required this.boostFraction,
    required this.label,
    required this.icon,
  });

  final bool visible;
  final Alignment alignment;
  final int percent;

  /// Portion (0–1) of the bar height filled white from the bottom.
  final double whiteFraction;

  /// Portion (0–1) of the bar height filled gold, stacked above the bar's
  /// midpoint (the 100% mark of the boost scale). 0 when there is no boost.
  final double boostFraction;

  final String label;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    if (!visible) return const SizedBox.shrink();

    final media = MediaQuery.of(context);
    final size = media.size;
    final onLeft = alignment == Alignment.centerLeft;

    final barHeight = (size.height * 0.30).clamp(90.0, 170.0).toDouble();
    const barWidth = 6.0;
    const columnWidth = 56.0;
    const percentHeight = 20.0;
    const gap = 14.0;

    const labelStyle = TextStyle(
      color: Colors.white,
      fontSize: 15,
      fontWeight: FontWeight.w400,
      decoration: TextDecoration.none,
      shadows: [Shadow(color: Colors.black54, blurRadius: 4)],
    );

    final labelTop = percentHeight + gap + barHeight / 2 - 10;
    final labelOffset = columnWidth / 2 + 30;

    // Same distance from the screen edge on BOTH sides. In landscape the
    // safe-area insets are usually lopsided (camera cutout / system bar on
    // one side only), so adding each side's own inset made the volume
    // indicator sit much farther from its edge than the brightness one.
    // Using the smaller inset for both keeps them mirror images of each
    // other while still clearing a cutout on either side.
    final edgeInset =
        (media.padding.left < media.padding.right
                ? media.padding.left
                : media.padding.right) +
            size.width * 0.07;

    return IgnorePointer(
      child: Align(
        alignment: alignment,
        child: Padding(
          padding: EdgeInsets.only(
            left: onLeft ? edgeInset : 0,
            right: onLeft ? 0 : edgeInset,
          ),
          child: SizedBox(
            width: columnWidth,
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    SizedBox(
                      height: percentHeight,
                      child: Center(
                        child: Text(
                          '$percent%',
                          maxLines: 1,
                          softWrap: false,
                          style: labelStyle,
                        ),
                      ),
                    ),
                    const SizedBox(height: gap),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(barWidth / 2),
                      child: SizedBox(
                        width: barWidth,
                        height: barHeight,
                        child: Stack(
                          alignment: Alignment.bottomCenter,
                          children: [
                            // Track.
                            const Positioned.fill(
                              child: ColoredBox(color: Color(0x66FFFFFF)),
                            ),
                            // White fill.
                            Positioned(
                              left: 0,
                              right: 0,
                              bottom: 0,
                              height: barHeight * whiteFraction,
                              child: const ColoredBox(color: Colors.white),
                            ),
                            // Above 100% (volume boost only): gold, stacked
                            // on the white.
                            if (boostFraction > 0)
                              Positioned(
                                left: 0,
                                right: 0,
                                bottom: barHeight * 0.5,
                                height: barHeight * boostFraction,
                                child: const ColoredBox(
                                  color: VolumeBoostIndicator.boostColor,
                                ),
                              ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: gap),
                    Icon(
                      icon,
                      color: Colors.white,
                      size: 28,
                      shadows: const [
                        Shadow(color: Colors.black54, blurRadius: 4),
                      ],
                    ),
                  ],
                ),
                // Label, vertically centred on the bar and sitting beside
                // it — to its right on the left edge, to its left on the
                // right edge.
                Positioned(
                  left: onLeft ? labelOffset : null,
                  right: onLeft ? null : labelOffset,
                  top: labelTop,
                  child: Text(
                    label,
                    maxLines: 1,
                    softWrap: false,
                    style: labelStyle,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// The "Slide up again to go beyond 100%" pill shown at the bottom of the
/// screen when a swipe hits 100% (VLC does the same — a single swipe never
/// runs straight through into the boost range).
class VolumeBoostHint extends StatelessWidget {
  const VolumeBoostHint({
    super.key,
    required this.visible,
  });

  final bool visible;

  @override
  Widget build(BuildContext context) {
    if (!visible) return const SizedBox.shrink();

    final media = MediaQuery.of(context);

    return IgnorePointer(
      child: Align(
        alignment: Alignment.bottomCenter,
        child: Padding(
          padding: EdgeInsets.only(
            bottom: media.padding.bottom + media.size.height * 0.1,
          ),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            decoration: BoxDecoration(
              color: const Color(0xFF1F1F26),
              borderRadius: BorderRadius.circular(28),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 26,
                  height: 26,
                  decoration: const BoxDecoration(
                    color: VolumeBoostIndicator.boostColor,
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(
                    Icons.volume_up,
                    color: Colors.black,
                    size: 16,
                  ),
                ),
                const SizedBox(width: 14),
                const Text(
                  'Slide up again to go beyond 100%',
                  maxLines: 1,
                  softWrap: false,
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 15,
                    fontWeight: FontWeight.w400,
                    decoration: TextDecoration.none,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
