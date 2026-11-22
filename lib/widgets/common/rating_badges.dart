import 'package:flutter/material.dart';

import '../../services/ratings_service.dart';

/// Small stylized "IMDb" mark — a rounded rectangle in IMDb's signature
/// yellow with bold black lettering. Drawn in code rather than a
/// bundled brand asset, so it stays crisp at any size with no extra
/// image dependency.
class ImdbBadge extends StatelessWidget {
  final double height;

  const ImdbBadge({super.key, this.height = 16});

  @override
  Widget build(BuildContext context) {
    return Container(
      height: height,
      padding: EdgeInsets.symmetric(horizontal: height * 0.28),
      decoration: BoxDecoration(
        color: const Color(0xffF5C518),
        borderRadius: BorderRadius.circular(height * 0.18),
      ),
      alignment: Alignment.center,
      child: Text(
        "IMDb",
        style: TextStyle(
          color: Colors.black,
          fontSize: height * 0.6,
          fontWeight: FontWeight.w900,
          height: 1,
          letterSpacing: -0.2,
        ),
      ),
    );
  }
}

/// Small stylized Rotten Tomatoes *critic* indicator (the Tomatometer)
/// — a red "fresh" tomato for scores ≥60%, or a green "rotten" splat
/// below that, matching RT's own fresh/rotten color convention. Drawn
/// with CustomPaint rather than a bundled brand asset.
class RottenTomatoesBadge extends StatelessWidget {
  final double height;
  final bool fresh;

  const RottenTomatoesBadge({
    super.key,
    this.height = 16,
    this.fresh = true,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: height,
      height: height,
      child: CustomPaint(
        painter: _TomatoPainter(fresh: fresh),
      ),
    );
  }
}

class _TomatoPainter extends CustomPainter {
  final bool fresh;

  const _TomatoPainter({required this.fresh});

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2 + size.height * 0.08);
    final radius = size.width * 0.4;

    final bodyPaint = Paint()
      ..color = fresh ? const Color(0xffFA320A) : const Color(0xff8BC53F);
    canvas.drawCircle(center, radius, bodyPaint);

    final highlightPaint = Paint()..color = Colors.white.withValues(alpha: 0.25);
    canvas.drawCircle(
      Offset(center.dx - radius * 0.35, center.dy - radius * 0.35),
      radius * 0.28,
      highlightPaint,
    );

    final leafPaint = Paint()..color = const Color(0xff2E7D32);
    final leafPath = Path()
      ..moveTo(center.dx - radius * 0.5, center.dy - radius * 0.85)
      ..lineTo(center.dx, center.dy - radius * 1.35)
      ..lineTo(center.dx + radius * 0.5, center.dy - radius * 0.85)
      ..close();
    canvas.drawPath(leafPath, leafPaint);
  }

  @override
  bool shouldRepaint(covariant _TomatoPainter oldDelegate) =>
      oldDelegate.fresh != fresh;
}

/// Small stylized Rotten Tomatoes *audience* indicator (the
/// Popcornmeter) — a striped popcorn bucket with kernels on top,
/// colored gold for an "upright" audience score ≥60% or muted
/// grey/brown for a "spilled" one below that, matching RT's own
/// upright/spilled audience-score convention the same way
/// [RottenTomatoesBadge] matches its fresh/rotten one. Drawn with
/// CustomPaint rather than a bundled brand asset.
class RtAudienceBadge extends StatelessWidget {
  final double height;
  final bool upright;

  const RtAudienceBadge({
    super.key,
    this.height = 16,
    this.upright = true,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: height,
      height: height,
      child: CustomPaint(
        painter: _PopcornPainter(upright: upright),
      ),
    );
  }
}

class _PopcornPainter extends CustomPainter {
  final bool upright;

  const _PopcornPainter({required this.upright});

  @override
  void paint(Canvas canvas, Size size) {
    final kernelColor =
        upright ? const Color(0xffF5C518) : const Color(0xff8A7A66);
    final bucketBase = upright ? Colors.white : const Color(0xffBFBFBF);
    final bucketStripe =
        upright ? const Color(0xffFA320A) : const Color(0xff7A7A7A);

    // Bucket: a trapezoid sitting in the bottom ~60% of the box,
    // narrower at the base than the rim — the classic popcorn-tub
    // silhouette.
    final bucketTop = size.height * 0.42;
    final bucketBottom = size.height * 0.96;
    final rimLeft = size.width * 0.12;
    final rimRight = size.width * 0.88;
    final baseLeft = size.width * 0.22;
    final baseRight = size.width * 0.78;

    final bucketPath = Path()
      ..moveTo(rimLeft, bucketTop)
      ..lineTo(rimRight, bucketTop)
      ..lineTo(baseRight, bucketBottom)
      ..lineTo(baseLeft, bucketBottom)
      ..close();

    canvas.drawPath(bucketPath, Paint()..color = bucketBase);

    // Two vertical stripes over the bucket body — clipped to the
    // trapezoid so they follow its taper instead of overhanging it.
    canvas.save();
    canvas.clipPath(bucketPath);
    final stripeWidth = size.width * 0.16;
    for (final fx in [0.32, 0.68]) {
      final cx = size.width * fx;
      canvas.drawRect(
        Rect.fromLTRB(
          cx - stripeWidth / 2,
          bucketTop,
          cx + stripeWidth / 2,
          bucketBottom,
        ),
        Paint()..color = bucketStripe,
      );
    }
    canvas.restore();

    // Kernels: three small overlapping circles bulging over the rim.
    final kernelPaint = Paint()..color = kernelColor;
    final kernelRadius = size.width * 0.16;
    final kernelY = bucketTop - kernelRadius * 0.55;
    for (final fx in [0.32, 0.5, 0.68]) {
      canvas.drawCircle(
        Offset(size.width * fx, kernelY - (fx == 0.5 ? kernelRadius * 0.35 : 0)),
        kernelRadius,
        kernelPaint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _PopcornPainter oldDelegate) =>
      oldDelegate.upright != upright;
}

/// Drop-in "★ CommunityRating" replacement: resolves and shows IMDb +
/// Rotten Tomatoes critic + Rotten Tomatoes audience ratings for
/// [item] side by side, each with its own badge. Renders nothing while
/// resolving and nothing for any rating that isn't available, so it's
/// always safe to drop into an existing meta row without an extra
/// visibility check at the call site — including for a title with no
/// ratings at all, in which case the whole row renders as nothing.
///
/// All three fields always come from the same RatingsService lookup
/// (MDBList if configured, else OMDb) rather than being mixed from
/// independent sources — see RatingsResult's doc comment for why that
/// matters.
///
/// Paints instantly from whatever's already cached (RatingsService
/// .peek()) on the very first frame when available — callers that know
/// their item list ahead of time (a loaded carousel, an episode list)
/// should call `RatingsService.prefetchAll(items)` as soon as that list
/// is known, the same way HomeScreen already precaches hero backdrops,
/// so this cache is warm by the time each row actually builds instead
/// of every row starting blank and popping in a moment later. When a
/// row does end up waiting on a real network fetch (nothing was
/// prefetched, or the prefetch hadn't finished yet), the badges fade
/// in over 250ms once it resolves rather than snapping into place.
///
/// Pass [seriesImdbId] + [seasonNumber] + [episodeNumber] instead of
/// relying on [item]'s own ProviderIds to rate a specific *episode* —
/// see RatingsService.fetchEpisode for why episodes need this
/// different lookup. When all three are supplied, [item] is only used
/// as the didUpdateWidget change-detection key (its "Id" field) and
/// its own ProviderIds are ignored.
class RatingsRow extends StatefulWidget {
  final Map<String, dynamic> item;
  final double fontSize;
  final Color textColor;
  final double badgeHeight;
  final double gap;
  final String? seriesImdbId;
  final int? seasonNumber;
  final int? episodeNumber;

  const RatingsRow({
    super.key,
    required this.item,
    this.fontSize = 14,
    this.textColor = Colors.white70,
    this.badgeHeight = 15,
    this.gap = 10,
    this.seriesImdbId,
    this.seasonNumber,
    this.episodeNumber,
  });

  bool get _isEpisodeMode =>
      seriesImdbId != null && seasonNumber != null && episodeNumber != null;

  @override
  State<RatingsRow> createState() => _RatingsRowState();
}

class _RatingsRowState extends State<RatingsRow> {
  RatingsResult? _result;

  // True only when _result was just populated by a real network fetch
  // resolving (_resolve()) rather than an already-warm cache hit
  // (_peek()) — used to fade the badges in only for the "genuinely
  // just arrived after a visible wait" case, not the already-instant
  // cache-hit case, which should just render immediately with nothing
  // to soften.
  bool _shouldFade = false;

  String? get _imdbId {
    final providerIds = widget.item["ProviderIds"];
    if (providerIds is! Map) return null;
    final id = providerIds["Imdb"] ?? providerIds["IMDB"] ?? providerIds["imdb"];
    return id?.toString();
  }

  RatingsResult? _peek() => widget._isEpisodeMode
      ? RatingsService.peekEpisode(
          widget.seriesImdbId, widget.seasonNumber, widget.episodeNumber)
      : RatingsService.peek(_imdbId);

  @override
  void initState() {
    super.initState();
    // Paint synchronously from cache on the first frame when it's
    // already warm (see the class doc) instead of always starting
    // blank — this is what actually fixes ratings visibly lagging
    // behind the rest of the row's content.
    final cached = _peek();
    if (cached != null) {
      _result = cached;
    } else {
      _resolve();
    }
  }

  @override
  void didUpdateWidget(covariant RatingsRow oldWidget) {
    super.didUpdateWidget(oldWidget);
    final changed = oldWidget.item["Id"] != widget.item["Id"] ||
        oldWidget.seasonNumber != widget.seasonNumber ||
        oldWidget.episodeNumber != widget.episodeNumber;
    if (changed) {
      final cached = _peek();
      if (cached != null) {
        setState(() {
          _result = cached;
          _shouldFade = false;
        });
      } else {
        _result = null;
        _resolve();
      }
    }
  }

  Future<void> _resolve() async {
    final fetched = widget._isEpisodeMode
        ? await RatingsService.fetchEpisode(
            widget.seriesImdbId, widget.seasonNumber, widget.episodeNumber)
        : await RatingsService.fetch(_imdbId);
    if (!mounted || fetched == null) return;

    setState(() {
      _result = fetched;
      _shouldFade = true;
    });
  }

  @override
  Widget build(BuildContext context) {
    final result = _result;
    if (result == null || result.isEmpty) {
      return const SizedBox.shrink();
    }

    final children = <Widget>[];

    void addGap() {
      if (children.isNotEmpty) children.add(SizedBox(width: widget.gap));
    }

    if (result.imdbRating != null) {
      addGap();
      children.add(_RatingChip(
        badge: ImdbBadge(height: widget.badgeHeight),
        label: result.imdbRating!.toStringAsFixed(1),
        fontSize: widget.fontSize,
        textColor: widget.textColor,
      ));
    }

    if (result.rtCriticScore != null) {
      addGap();
      children.add(_RatingChip(
        badge: RottenTomatoesBadge(
          height: widget.badgeHeight,
          fresh: result.rtCriticScore! >= 60,
        ),
        label: "${result.rtCriticScore}%",
        fontSize: widget.fontSize,
        textColor: widget.textColor,
      ));
    }

    if (result.rtAudienceScore != null) {
      addGap();
      children.add(_RatingChip(
        badge: RtAudienceBadge(
          height: widget.badgeHeight,
          upright: result.rtAudienceScore! >= 60,
        ),
        label: "${result.rtAudienceScore}%",
        fontSize: widget.fontSize,
        textColor: widget.textColor,
      ));
    }

    final row = Row(mainAxisSize: MainAxisSize.min, children: children);

    if (!_shouldFade) return row;

    // Only reached the first time a genuinely-just-completed network
    // fetch populates _result (see _shouldFade's doc) — a brand new
    // subtree each time (the SizedBox.shrink() above never contained
    // one), so this TweenAnimationBuilder always starts its own
    // animation from scratch and plays exactly once per row.
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: const Duration(milliseconds: 250),
      curve: Curves.easeOut,
      builder: (context, opacity, child) =>
          Opacity(opacity: opacity, child: child),
      child: row,
    );
  }
}

class _RatingChip extends StatelessWidget {
  final Widget badge;
  final String label;
  final double fontSize;
  final Color textColor;

  const _RatingChip({
    required this.badge,
    required this.label,
    required this.fontSize,
    required this.textColor,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        badge,
        const SizedBox(width: 4),
        Text(
          label,
          style: TextStyle(
            color: textColor,
            fontSize: fontSize,
            fontWeight: FontWeight.w600,
          ),
        ),
      ],
    );
  }
}
