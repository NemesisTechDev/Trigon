import 'package:flutter/material.dart';

import '../../utils/app_fonts.dart';
import '../../utils/responsive.dart';
import '../common/collapsing_screen_label.dart';
import '../common/pressable.dart';

class LiveTvHeader extends StatelessWidget {
  final VoidCallback onGuidePressed;
  final VoidCallback onAllChannels;
  final VoidCallback onFavorites;
  final VoidCallback onRecent;

  const LiveTvHeader({
    super.key,
    required this.onGuidePressed,
    required this.onAllChannels,
    required this.onFavorites,
    required this.onRecent,
  });

  @override
  Widget build(BuildContext context) {
    // Horizontal padding adds a TV overscan-safe margin on top of the
    // usual 20 (see Responsive.contentPadding) — phone/tablet get the
    // exact same 20 they always have.
    final horizontalPadding = Responsive.contentPadding(context);

    // Row-to-content gap below: 5 portrait, 8 landscape — matching
    // Movies/Music/All Channels/TV Guide.
    final bottomGap = Responsive.isLandscape(context) ? 8.0 : 5.0;

    return Padding(
      // Top is 8 (kCollapsedLabelTopGap) rather than the 15 shared with
      // Movies/Music/Downloads: the other 7 sit inside the collapsing
      // label below, so the expanded layout is unchanged while the
      // collapsed label leaves 8 above the chips.
      padding: EdgeInsets.fromLTRB(
        horizontalPadding,
        kCollapsedLabelTopGap,
        horizontalPadding,
        bottomGap,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [

          // Slides away on scroll down / returns on scroll up (see
          // collapsing_screen_label.dart). 10 below the label, matching
          // Movies/Music/TagItemsScreen/All Channels/TV Guide.
          CollapsibleLabel(
            topPadding: 7,
            bottomPadding: 10,
            child: Text(
              "Live TV",
              style: AppFonts.dosis(fontSize: 30, fontWeight: FontWeight.bold),
            ),
          ),

          // Chips + guide icon share one row now (the icon used to sit
          // up on the title row instead) so the icon reads as part of
          // this control group rather than floating above it, while
          // staying pinned to the right edge like before.
          //
          // The chip row is wrapped in Expanded + a horizontal
          // SingleChildScrollView rather than laid out as a plain Row:
          // that lets the chips shrink the room they claim (or scroll,
          // once there's truly no room left) whenever the row is
          // squeezed — a small display, or normal display size but a
          // large font/display-scale setting inflating the chip text —
          // instead of that squeeze pushing into the guide icon itself.
          // The icon, outside the Expanded, always keeps its own space
          // and is never the thing that gets clipped or scrolled away,
          // so all three (All Channels, Favorites, guide) stay visible
          // no matter how tight the row gets.
          Row(
            children: [

              Expanded(
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,

                  child: Row(
                    children: [

                      _chip(
                        icon: Icons.grid_view_rounded,
                        label: "All Channels",
                        onTap: onAllChannels,
                      ),

                      _chip(
                        icon: Icons.favorite,
                        label: "Favorites",
                        onTap: onFavorites,
                      ),
                    ],
                  ),
                ),
              ),

              IconButton(
                onPressed: onGuidePressed,
                icon: const Icon(
                  Icons.view_timeline_rounded,
                  color: Colors.white,
                ),
              ),
            ],
          ),

        ],
      ),
    );
  }

  // Matches the LibraryChips (Movies) / tab chips (Music) pill: same
  // gold/dark-grey palette, 30px radius, and Pressable ripple, so Live
  // TV's chip row looks and feels consistent with the rest of the app.
  // These chips don't carry a persistent "selected" state of their own
  // (each tap navigates away to another screen), so they render in the
  // unselected dark-grey treatment used elsewhere for non-active chips.
  Widget _chip({
    required IconData icon,
    required String label,
    required VoidCallback onTap,
  }) {
    return Padding(
      padding: const EdgeInsets.only(right: 8),

      child: Pressable(
        borderRadius: BorderRadius.circular(30),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(
            horizontal: 18,
            vertical: 10,
          ),
          decoration: BoxDecoration(
            color: const Color(0xff2A2A2A),
            borderRadius: BorderRadius.circular(30),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                icon,
                size: 16,
                color: Colors.white70,
              ),

              const SizedBox(width: 6),

              Text(
                label,
                style: const TextStyle(
                  color: Colors.white70,
                  fontWeight: FontWeight.w600,
                  fontSize: 13,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}