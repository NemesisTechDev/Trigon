import 'dart:async';

import 'package:flutter/material.dart';

import '../../widgets/common/pressable.dart';

/// "Are you still watching?" idle-safety card, shown by
/// [PlayerOverlayLayer] once [PlayerManager.showStillWatching] flips true
/// — i.e. after four hours with no detected activity on the video player
/// screen. Styled to match [SkipSegmentButton]/[NextEpisodeOverlay] (same
/// dark translucent card, white12 border, drop shadow, 14px radius, gold
/// accent) so it reads as part of the same overlay family rather than a
/// bolted-on system dialog.
///
/// Owns its own two-phase timer internally, the same way
/// [NextEpisodeOverlay] owns its own auto-play countdown rather than
/// PlayerManager driving it:
///  - Grace (first 10s): a plain "Still watching?" prompt with no number
///    attached yet, giving a quiet moment to respond before anything
///    alarming appears.
///  - Countdown (next 30s): escalates to "Playback will stop in Ns",
///    ticking down every second with a matching circular ring.
///
/// Any tap anywhere on the dimming scrim behind the card — not just the
/// "Yes" button itself — counts as activity and calls [onContinue].
/// Letting the countdown reach zero calls [onExpired] instead.
class StillWatchingOverlay extends StatefulWidget {
  final VoidCallback onContinue;
  final VoidCallback onExpired;

  const StillWatchingOverlay({
    super.key,
    required this.onContinue,
    required this.onExpired,
  });

  @override
  State<StillWatchingOverlay> createState() => _StillWatchingOverlayState();
}

class _StillWatchingOverlayState extends State<StillWatchingOverlay> {
  static const _gold = Color(0xffD4AF37);

  static const _gracePeriod = Duration(seconds: 10);
  static const _countdownSeconds = 30;

  // -1 while still in the initial grace period (no number shown yet);
  // counts down from 30 to 0 once escalated.
  int secondsLeft = -1;

  Timer? graceTimer;
  Timer? countdownTimer;

  @override
  void initState() {
    super.initState();

    graceTimer = Timer(_gracePeriod, _startCountdown);
  }

  void _startCountdown() {
    if (!mounted) return;

    setState(() => secondsLeft = _countdownSeconds);

    countdownTimer = Timer.periodic(const Duration(seconds: 1), (t) {
      if (secondsLeft <= 1) {
        t.cancel();
        widget.onExpired();
        return;
      }

      setState(() => secondsLeft--);
    });
  }

  @override
  void dispose() {
    graceTimer?.cancel();
    countdownTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final counting = secondsLeft >= 0;

    return Positioned.fill(
      child: GestureDetector(
        // Any tap on the dimming scrim itself is activity too, not just
        // the "Yes" button — matches "dismissed after sensing any
        // activity on the app".
        behavior: HitTestBehavior.opaque,
        onTap: widget.onContinue,
        child: Container(
          color: Colors.black.withValues(alpha: 0.6),
          alignment: Alignment.center,
          child: GestureDetector(
            // Swallow taps that land on the card itself so they don't
            // fall through to the scrim behind it — the "Yes" button
            // below is the intended tap target here, not the card body.
            onTap: () {},
            child: Container(
              width: 300,
              padding: const EdgeInsets.fromLTRB(20, 24, 20, 20),
              decoration: BoxDecoration(
                color: const Color(0xF0121212),
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: Colors.white12),
                boxShadow: const [
                  BoxShadow(
                    color: Colors.black54,
                    blurRadius: 20,
                    offset: Offset(0, 8),
                  ),
                ],
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  SizedBox(
                    width: 52,
                    height: 52,
                    child: Stack(
                      alignment: Alignment.center,
                      children: [
                        if (counting)
                          CircularProgressIndicator(
                            value: secondsLeft / _countdownSeconds,
                            strokeWidth: 3,
                            backgroundColor: Colors.white24,
                            valueColor: const AlwaysStoppedAnimation(_gold),
                          )
                        else
                          const DecoratedBox(
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: _gold,
                            ),
                          ),

                        Icon(
                          Icons.visibility_rounded,
                          color: counting ? Colors.white : Colors.black,
                          size: 24,
                        ),
                      ],
                    ),
                  ),

                  const SizedBox(height: 16),

                  const Text(
                    "Still watching?",
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 17,
                      fontWeight: FontWeight.w600,
                    ),
                  ),

                  const SizedBox(height: 6),

                  Text(
                    counting
                        ? "Playback will stop in ${secondsLeft}s"
                        : "We haven't seen any activity in a while.",
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: counting ? _gold : Colors.white54,
                      fontSize: 13,
                      fontWeight:
                          counting ? FontWeight.w600 : FontWeight.w500,
                    ),
                  ),

                  const SizedBox(height: 18),

                  SizedBox(
                    width: double.infinity,
                    child: Pressable(
                      onTap: widget.onContinue,
                      borderRadius: BorderRadius.circular(8),
                      child: Container(
                        alignment: Alignment.center,
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        decoration: BoxDecoration(
                          color: _gold,
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: const Text(
                          "Yes, I'm still here",
                          style: TextStyle(
                            color: Colors.black,
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
