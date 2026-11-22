import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import '../../services/jellyfin_services/media_service.dart';
import '../common/pressable.dart';
import '../../services/cache/nemesis_image_cache.dart';

class ArtistCard extends StatelessWidget {
  final Map artist;
  final VoidCallback? onTap;

  const ArtistCard({
    super.key,
    required this.artist,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final image = MediaService.getMusicImage(
      artist["Id"],
      size: 400,
    );

    return Pressable(
      onTap: onTap,
      borderRadius: BorderRadius.circular(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(16),
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final dpr = MediaQuery.devicePixelRatioOf(context);
                  return CachedNetworkImage(
                    cacheManager: NemesisImageCache.instance,
                    imageUrl: image,
                    width: double.infinity,
                    fit: BoxFit.cover,
                    memCacheWidth: constraints.maxWidth.isFinite
                        ? (constraints.maxWidth * dpr).round()
                        : null,
                    memCacheHeight: constraints.maxHeight.isFinite
                        ? (constraints.maxHeight * dpr).round()
                        : null,
                    fadeInDuration: const Duration(milliseconds: 250),
                    placeholder: (_, __) => Container(
                      color: const Color(0xff252525),
                    ),
                    errorWidget: (_, __, ___) => Container(
                      color: const Color(0xff252525),
                      child: const Center(
                        child: Icon(
                          Icons.person,
                          color: Colors.white38,
                          size: 40,
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
          ),

          const SizedBox(height: 8),

          Text(
            artist["Name"] ?? "",
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              color: Colors.white,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}