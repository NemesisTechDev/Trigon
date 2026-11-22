import 'package:flutter/material.dart';

const _gold = Color(0xffD4AF37);

/// Cellphone glyph with a small gold tick over it — the "saved to
/// this device" language a lot of premium apps use for a finished
/// download, in place of a plain checkmark.
///
/// Pulled out of active_downloads_section.dart (where it started as a
/// private `_DeviceCheckBadge` used only by that screen's FINISHED
/// cards) so a downloaded show's per-episode list can show the exact
/// same finished-state badge instead of growing its own copy — see
/// DownloadedEpisodeTile.
class DeviceCheckBadge extends StatelessWidget {
  final double size;

  const DeviceCheckBadge({super.key, this.size = 34});

  @override
  Widget build(BuildContext context) {
    // Ratios lifted straight from the original fixed-size version
    // (34 box / 30 phone / 15 tick circle / 11 tick icon, tick
    // positioned bottom: 2, right: 0) so every existing call site
    // renders pixel-identical at the same default size.
    final tickSize = size * (15 / 34);

    return SizedBox(
      width: size,
      height: size,
      child: Stack(
        alignment: Alignment.center,
        children: [
          Icon(
            Icons.smartphone_rounded,
            color: Colors.white,
            size: size * (30 / 34),
          ),
          Positioned(
            bottom: size * (2 / 34),
            right: 0,
            child: Container(
              width: tickSize,
              height: tickSize,
              alignment: Alignment.center,
              decoration: const BoxDecoration(
                color: _gold,
                shape: BoxShape.circle,
              ),
              child: Icon(
                Icons.check_rounded,
                color: Colors.black,
                size: tickSize * (11 / 15),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
