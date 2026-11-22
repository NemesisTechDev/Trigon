import 'package:flutter/material.dart';

/// The pulse shared by every logo on the loading and buffering screens, so
/// they always beat the same way: one beat every [kLogoPulseDuration], the
/// logo breathing between [kLogoPulseMin] and `kLogoPulseMin + kLogoPulseRange`
/// of its size.
const Duration kLogoPulseDuration = Duration(milliseconds: 1050);
const double kLogoPulseMin = 0.92;
const double kLogoPulseRange = 0.08;

/// A slowly pulsating logo used on the loading and buffering overlays.
///
/// When [fillProgress] is true (used while a title is first loading or
/// resuming), the logo starts dim and desaturated, then its full colours
/// continuously sweep in from left to right to signal that loading is
/// still in progress. When false (used while buffering mid-playback),
/// the logo is shown at full colour throughout and only pulsates.
class PulsingLogo extends StatefulWidget {
  const PulsingLogo({
    super.key,
    required this.logoUrl,
    this.width = 220,
    this.fillProgress = false,
  });

  final String logoUrl;
  final double width;
  final bool fillProgress;

  @override
  State<PulsingLogo> createState() => _PulsingLogoState();
}

class _PulsingLogoState extends State<PulsingLogo>
    with TickerProviderStateMixin {
  late final AnimationController _pulseController;
  late final AnimationController _fillController;
  late final AnimationController _introController;

  static const _desaturate = ColorFilter.matrix(<double>[
    0.2126, 0.7152, 0.0722, 0, 0,
    0.2126, 0.7152, 0.0722, 0, 0,
    0.2126, 0.7152, 0.0722, 0, 0,
    0, 0, 0, 1, 0,
  ]);

  // Shared by both the initial-loading and buffering states so the two
  // always read as the same pulse, just used in different contexts.
  static const _pulseDuration = kLogoPulseDuration;

  @override
  void initState() {
    super.initState();

    _pulseController = AnimationController(
      vsync: this,
      duration: _pulseDuration,
    );

    _fillController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2200),
    );

    // One-shot "fill up" entrance: the logo grows and fades in from
    // small/dim to full size before settling into the continuous
    // pulse below. Only used for the initial-loading state — buffering
    // (fillProgress: false) skips straight to the steady pulse with no
    // dimming or growing, since playback has already started.
    _introController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 550),
    );

    if (widget.fillProgress) {
      _fillController.repeat();
      _introController.forward();
    } else {
      _introController.value = 1;
    }

    // Start the continuous pulse only once the entrance has finished so
    // the two don't visually fight each other; buffering starts it
    // immediately since there's no entrance to wait on.
    _introController.addStatusListener((status) {
      if (status == AnimationStatus.completed) {
        _pulseController.repeat(reverse: true);
      }
    });

    if (!widget.fillProgress) {
      _pulseController.repeat(reverse: true);
    }
  }

  @override
  void dispose() {
    _pulseController.dispose();
    _fillController.dispose();
    _introController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final logo = Image.network(
      widget.logoUrl,
      width: widget.width,
      fit: BoxFit.contain,
      errorBuilder: (_, __, ___) => const SizedBox(),
    );

    return AnimatedBuilder(
      animation: Listenable.merge(
        [_pulseController, _fillController, _introController],
      ),
      builder: (context, _) {
        final pulse = kLogoPulseMin + (_pulseController.value * kLogoPulseRange);

        final introCurved =
            Curves.easeOutBack.transform(_introController.value);

        Widget content = logo;

        if (widget.fillProgress) {
          content = Stack(
            alignment: Alignment.center,
            children: [
              // Dim, desaturated base — represents "not loaded yet".
              Opacity(
                opacity: 0.35,
                child: ColorFiltered(
                  colorFilter: _desaturate,
                  child: logo,
                ),
              ),
              // Full-colour reveal, wiped in from the left as a stand-in
              // for real progress (the player doesn't expose a byte-level
              // loading percentage, so this sweeps continuously to signal
              // "still loading" rather than tracking an exact number).
              ClipRect(
                clipper: _LeftFillClipper(_fillController.value),
                child: logo,
              ),
            ],
          );
        }

        // Entrance: fade/grow from small+dim up to full size — only
        // has any effect while fillProgress is true, since
        // _introController is already at 1 otherwise.
        final scale = (0.55 + (0.45 * introCurved)) * pulse;

        return Opacity(
          opacity: _introController.value,
          child: Transform.scale(
            scale: scale,
            child: content,
          ),
        );
      },
    );
  }
}

class _LeftFillClipper extends CustomClipper<Rect> {
  _LeftFillClipper(this.fraction);

  final double fraction;

  @override
  Rect getClip(Size size) {
    return Rect.fromLTWH(0, 0, size.width * fraction, size.height);
  }

  @override
  bool shouldReclip(covariant _LeftFillClipper oldClipper) {
    return oldClipper.fraction != fraction;
  }
}
