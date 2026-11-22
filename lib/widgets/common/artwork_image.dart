import 'dart:io';

import 'package:flutter/material.dart';

import '../../utils/artwork_source.dart';

/// Renders artwork from [path] — a network URL or a local file path,
/// whichever it turns out to be — filling its parent's bounds with
/// [fit]. Callers still own their own null-check/placeholder for "no
/// artwork at all"; this only handles the "there is a path, resolve it
/// correctly" half.
class ArtworkImage extends StatelessWidget {
  const ArtworkImage({
    super.key,
    required this.path,
    this.fit = BoxFit.cover,
    this.width,
    this.height,
    this.errorBuilder,
  });

  final String path;
  final BoxFit fit;
  final double? width;
  final double? height;
  final Widget Function(BuildContext, Object, StackTrace?)? errorBuilder;

  @override
  Widget build(BuildContext context) {
    if (isRemoteArtwork(path)) {
      return Image.network(
        path,
        fit: fit,
        width: width,
        height: height,
        errorBuilder: errorBuilder == null
            ? null
            : (context, error, stackTrace) =>
                errorBuilder!(context, error, stackTrace),
      );
    }

    return Image.file(
      File(path),
      fit: fit,
      width: width,
      height: height,
      errorBuilder: errorBuilder == null
          ? null
          : (context, error, stackTrace) =>
              errorBuilder!(context, error, stackTrace),
    );
  }
}
