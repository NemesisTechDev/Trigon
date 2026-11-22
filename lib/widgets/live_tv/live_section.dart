import 'package:flutter/material.dart';

import '../../utils/responsive.dart';
import '../common/see_all_controls.dart';
import 'live_channel_card.dart';

class LiveSection extends StatelessWidget {
  final String title;
  final List channels;
  final Map<String, dynamic> programs;
  final Function(Map channel) onTap;

  /// When set, shows a gold chevron disc beside the title, and — once the
  /// row is full ([maxItems]) — a "View all" item after the last card.
  final VoidCallback? onSeeAll;

  /// Rows show at most this many channels.
  static const int maxItems = 20;

  const LiveSection({
    super.key,
    required this.title,
    required this.channels,
    required this.programs,
    required this.onTap,
    this.onSeeAll,
  });

  @override
  Widget build(BuildContext context) {
    // TV alone gets a larger card — a 170dp-wide card meant for arm's-
    // length phone/tablet viewing reads as tiny at 10-foot TV viewing
    // distance on a 1080p/4K screen. Phone/tablet (isTV false) keep the
    // exact same 170/230 they've always had. Same isTV-branched sizing
    // Home's horizontal rows already use (see home_screen.dart).
    final cardWidth = Responsive.isTV ? 230.0 : 170.0;
    final rowHeight = Responsive.isTV ? 300.0 : 230.0;
    final horizontalPadding = Responsive.contentPadding(context);
    // Only rows with a "See all" are capped — rows without one (e.g.
    // Favorites, Recently Watched) still show every channel they hold.
    final shown = (onSeeAll != null && channels.length > maxItems)
        ? maxItems
        : channels.length;
    final hasSeeAllTile = onSeeAll != null && channels.length >= maxItems;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,

      children: [
        Padding(
          padding: EdgeInsets.symmetric(horizontal: horizontalPadding),

          child: Row(
            children: [
              Expanded(
                child: Text(
                  title,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 24,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
              if (onSeeAll != null)
                Padding(
                  padding: const EdgeInsets.only(left: 8),
                  child: SeeAllChevronButton(onTap: onSeeAll!),
                ),
            ],
          ),
        ),

        const SizedBox(height: 16),

        SizedBox(
          height: rowHeight,

          child: ListView.separated(
            padding: EdgeInsets.symmetric(horizontal: horizontalPadding),
            scrollDirection: Axis.horizontal,
            itemCount: shown + (hasSeeAllTile ? 1 : 0),
            separatorBuilder: (context, index) =>
            const SizedBox(width: 14),
            itemBuilder: (context, index) {

              if (hasSeeAllTile && index == shown) {
                return ViewAllRowTile(
                  height: rowHeight,
                  onTap: onSeeAll!,
                );
              }

              final channel = channels[index];

              final guide =
                  (programs[channel["Id"]] as List?) ?? [];

              final currentProgram =
              guide.isNotEmpty ? guide.first : null;

              final nextProgram =
              guide.length > 1 ? guide[1] : null;

              return LiveChannelCard(
                channel: channel,
                program: currentProgram,
                nextProgram: nextProgram,
                onTap: () => onTap(channel),
                width: cardWidth,
              );

            },
          ),
        ),
      ],
    );
  }
}