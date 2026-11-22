import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../../services/jellyfin_services/media_service.dart';
import '../common/pressable.dart';
import '../../services/cache/nemesis_image_cache.dart';

class ChannelLogoCard extends StatelessWidget {
  final Map channel;
  final VoidCallback? onTap;
  final bool showLabel;
  final double iconSize;

  const ChannelLogoCard({
    super.key,
    required this.channel,
    this.onTap,
    this.showLabel = true,
    this.iconSize = 82,
  });

  @override
  Widget build(BuildContext context) {
    return Pressable(
      onTap: onTap,
      borderRadius: BorderRadius.circular(18),
      child: SizedBox(
        width: iconSize + 30,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: iconSize,
              height: iconSize,
              decoration: BoxDecoration(
                color: const Color(0xff232323),
                borderRadius: BorderRadius.circular(18),
              ),
              padding: const EdgeInsets.all(12),
              child: CachedNetworkImage(
                cacheManager: NemesisImageCache.instance,
                imageUrl: MediaService.getPrimaryImage(channel["Id"]),
                fit: BoxFit.contain,
                memCacheWidth: 160,
                fadeInDuration: const Duration(milliseconds: 250),
                placeholder: (_, __) => Container(
                  decoration: BoxDecoration(
                    color: const Color(0xff2a2a2a),
                    borderRadius: BorderRadius.circular(8),
                  ),
                ),
                errorWidget: (_, __, ___) => const Icon(
                  Icons.live_tv,
                  color: Colors.white30,
                  size: 34,
                ),
              ),
            ),

            if (showLabel) ...[
              const SizedBox(height: 8),

              Padding(
                padding: const EdgeInsets.only(left: 4),
                child: Text(
                  channel["Name"] ?? "",
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.left,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}