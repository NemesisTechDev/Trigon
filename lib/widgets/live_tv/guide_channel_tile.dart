import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../../services/jellyfin_services/media_service.dart';
import '../common/pressable.dart';
import '../../services/cache/nemesis_image_cache.dart';

class GuideChannelTile extends StatelessWidget {
  const GuideChannelTile({
    super.key,
    required this.channel,
    this.isPlaying = false,
    this.onTap,
  });

  final Map<String, dynamic> channel;
  final bool isPlaying;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final number = channel['Number']?.toString();

    return Pressable(
      onTap: onTap,
      child: Container(
      width: 130,
      height: 108,
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
      decoration: BoxDecoration(
        color: isPlaying ? const Color(0x22D4AF37) : null,
        border: const Border(bottom: BorderSide(color: Colors.white10)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          if (number != null && number.isNotEmpty) ...[
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 46),
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 6,
                  vertical: 3,
                ),
                decoration: BoxDecoration(
                  color: const Color(0xff2A2A2A),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text(
                  number,
                  textAlign: TextAlign.center,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  softWrap: false,
                  style: const TextStyle(
                    color: Colors.white70,
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ),
            const SizedBox(width: 6),
          ],
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                SizedBox(
                  width: 52,
                  height: 52,
                  child: CachedNetworkImage(
                    cacheManager: NemesisImageCache.instance,
                    imageUrl: MediaService.getPrimaryImage(channel['Id'], size: 150),
                    fit: BoxFit.contain,
                    memCacheWidth: 120,
                    fadeInDuration: const Duration(milliseconds: 250),
                    placeholder: (_, __) => Container(
                      decoration: BoxDecoration(
                        color: const Color(0xff2a2a2a),
                        borderRadius: BorderRadius.circular(6),
                      ),
                    ),
                    errorWidget: (_, __, ___) => const Icon(
                      Icons.live_tv,
                      color: Colors.white38,
                      size: 26,
                    ),
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  channel['Name']?.toString() ?? '',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 13,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
      ),
    );
  }
}
