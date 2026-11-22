import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import '../../services/jellyfin_services/media_service.dart';
import '../../utils/epg_utils.dart';
import '../../services/cache/nemesis_image_cache.dart';

class LiveChannelCard extends StatefulWidget {
  final Map channel;
  final Map? program;
  final Map? nextProgram;
  final VoidCallback onTap;

  /// Card width. Defaults to the existing 170dp phone/tablet size —
  /// callers (e.g. LiveSection) pass a larger value on TV so the card
  /// doesn't read as tiny at 10-foot viewing distance. Internal layout
  /// (image padding, text sizes) is otherwise untouched.
  final double width;

  const LiveChannelCard({
    super.key,
    required this.channel,
    required this.program,
    required this.nextProgram,
    required this.onTap,
    this.width = 170,
  });

  @override
  State<LiveChannelCard> createState() => _LiveChannelCardState();
}

class _LiveChannelCardState extends State<LiveChannelCard> {
  bool pressed = false;

  bool get isLive {
    if (widget.program == null) return false;

    final now = DateTime.now();
    final start = EpgUtils.parseProgramTime(widget.program!["StartDate"]);
    final end = EpgUtils.parseProgramTime(widget.program!["EndDate"]);
    if (start == null || end == null) return false;

    return now.isAfter(start) && now.isBefore(end);
  }

  double get progress {
    if (!isLive) return 0;

    final now = DateTime.now();
    final start = EpgUtils.parseProgramTime(widget.program!["StartDate"])!;
    final end = EpgUtils.parseProgramTime(widget.program!["EndDate"])!;

    return now.difference(start).inSeconds /
        end.difference(start).inSeconds;
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedScale(
      duration: const Duration(milliseconds: 120),
      scale: pressed ? 0.96 : 1,
      child: InkWell(
        borderRadius: BorderRadius.circular(18),

        onTap: widget.onTap,

        onTapDown: (_) {
          setState(() => pressed = true);
        },

        onTapUp: (_) {
          setState(() => pressed = false);
        },

        onTapCancel: () {
          setState(() => pressed = false);
        },

        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),

          width: widget.width,

          decoration: BoxDecoration(
            color: const Color(0xff222222),

            borderRadius: BorderRadius.circular(18),

            boxShadow: [
              if (pressed)
                BoxShadow(
                  color: Colors.black.withValues(alpha: .35),
                  blurRadius: 18,
                  offset: const Offset(0, 10),
                ),
            ],
          ),

          child: Column(
            children: [
              Expanded(
                flex: 3,

                child: Stack(
                  children: [
                    Center(
                      child: Padding(
                        padding: const EdgeInsets.all(18),

                        child: CachedNetworkImage(
                          cacheManager: NemesisImageCache.instance,
                          imageUrl: MediaService.getPrimaryImage(
                            widget.channel["Id"],
                          ),

                          fit: BoxFit.contain,

                          filterQuality: FilterQuality.high,

                          memCacheWidth: 300,

                          fadeInDuration: const Duration(milliseconds: 250),

                          placeholder: (_, __) => Container(
                            decoration: BoxDecoration(
                              color: const Color(0xff2a2a2a),
                              borderRadius: BorderRadius.circular(12),
                            ),
                          ),

                          errorWidget: (_, __, ___) {
                            return const Icon(
                              Icons.live_tv,
                              color: Colors.white30,
                              size: 60,
                            );
                          },
                        ),
                      ),
                    ),

                    if (isLive)
                      Positioned(
                        top: 10,
                        right: 10,
                        child: Container(
                          padding:
                          const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 3,
                          ),

                          decoration: BoxDecoration(
                            color: Colors.red,
                            borderRadius:
                            BorderRadius.circular(30),
                          ),

                          child: const Text(
                            "LIVE",
                            style: TextStyle(
                              color: Colors.white,
                              fontSize: 10,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),

              Padding(
                padding:
                const EdgeInsets.symmetric(horizontal: 12),

                child: Text(
                  widget.channel["Name"] ?? "",

                  maxLines: 2,

                  overflow: TextOverflow.ellipsis,

                  textAlign: TextAlign.center,

                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.bold,
                    fontSize: 15,
                  ),
                ),
              ),

              const SizedBox(height: 6),

              if (widget.program != null)
                Padding(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 12),

                  child: Text(
                    widget.program!["Name"] ?? "",

                    maxLines: 2,

                    overflow: TextOverflow.ellipsis,

                    textAlign: TextAlign.center,

                    style: const TextStyle(
                      color: Colors.white70,
                      fontSize: 12,
                    ),
                  ),
                ),

              if (widget.nextProgram != null) ...[
                const SizedBox(height: 6),

                Text(
                  "Next",
                  style: TextStyle(
                    color: Colors.grey[500],
                    fontSize: 10,
                    fontWeight: FontWeight.bold,
                  ),
                ),

                const SizedBox(height: 2),

                Padding(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 12),

                  child: Text(
                    widget.nextProgram!["Name"] ?? "",

                    maxLines: 1,

                    overflow: TextOverflow.ellipsis,

                    textAlign: TextAlign.center,

                    style: const TextStyle(
                      color: Colors.white54,
                      fontSize: 11,
                    ),
                  ),
                ),
              ],

              if (isLive) ...[
                const SizedBox(height: 8),

                Padding(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 12),

                  child: ClipRRect(
                    borderRadius:
                    BorderRadius.circular(10),

                    child: LinearProgressIndicator(
                      value: progress,
                      minHeight: 5,
                      backgroundColor: Colors.white12,
                      valueColor:
                      const AlwaysStoppedAnimation(
                        Color(0xffD4AF37),
                      ),
                    ),
                  ),
                ),
              ],

              const SizedBox(height: 12),
            ],
          ),
        ),
      ),
    );
  }
}