import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../../services/profile_avatar_service.dart';

/// The picture inside a profile circle. Put it as the child of an
/// already-clipped circular container:
///
///  - chose an avatar -> that avatar
///  - Google account  -> the Google photo (the default for Google accounts)
///  - otherwise       -> [fallback] (the default for every other account)
class ProfileAvatarBody extends StatelessWidget {
  const ProfileAvatarBody({super.key, required this.fallback});

  final Widget fallback;

  @override
  Widget build(BuildContext context) {
    final service = ProfileAvatarService.instance;
    return ListenableBuilder(
      listenable: service,
      builder: (context, _) {
        final preset = service.preset;
        if (preset != null) {
          return SizedBox.expand(child: preset.build());
        }
        final photo = service.googlePhotoUrl;
        if (photo != null) {
          return CachedNetworkImage(
            imageUrl: photo,
            fit: BoxFit.cover,
            placeholder: (_, __) => fallback,
            errorWidget: (_, __, ___) => fallback,
          );
        }
        return fallback;
      },
    );
  }
}
