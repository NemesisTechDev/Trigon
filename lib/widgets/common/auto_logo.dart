import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../../services/cache/nemesis_image_cache.dart';
import '../../services/jellyfin_services/media_service.dart';
import '../../virtual/virtual_catalog.dart';

/// A title's logo that always tries to appear.
///
/// If the logo is not known yet it is looked up (TMDB) and shown as soon as
/// it arrives; if the picture fails to load it is retried a couple of times
/// before [fallback] (usually the title as text) is shown.
class AutoLogo extends StatefulWidget {
  final String itemId;
  final int maxWidth;
  final BoxFit fit;
  final Alignment alignment;
  final Widget Function() fallback;

  const AutoLogo({
    super.key,
    required this.itemId,
    required this.fallback,
    this.maxWidth = 600,
    this.fit = BoxFit.contain,
    this.alignment = Alignment.center,
  });

  @override
  State<AutoLogo> createState() => _AutoLogoState();
}

class _AutoLogoState extends State<AutoLogo> {
  int _attempt = 0;
  bool _lookingUp = false;
  bool _gaveUp = false;
  Timer? _retry;

  String get _url => MediaService.getImageUrl(widget.itemId,
      type: 'Logo', maxWidth: widget.maxWidth);

  bool get _known => !_url.contains('/no-image/');

  @override
  void initState() {
    super.initState();
    _lookupIfNeeded();
  }

  @override
  void didUpdateWidget(covariant AutoLogo old) {
    super.didUpdateWidget(old);
    if (old.itemId != widget.itemId) {
      _retry?.cancel();
      _attempt = 0;
      _gaveUp = false;
      _lookupIfNeeded();
    }
  }

  @override
  void dispose() {
    _retry?.cancel();
    super.dispose();
  }

  void _lookupIfNeeded() {
    if (_known || _lookingUp) return;
    _lookingUp = true;
    final id = widget.itemId;
    VirtualCatalog.ensureLogo(id).then((url) {
      _lookingUp = false;
      if (!mounted || id != widget.itemId) return;
      setState(() => _gaveUp = url == null);
    });
  }

  void _scheduleRetry() {
    if (_retry != null && _retry!.isActive) return;
    if (_attempt >= 3) return;
    _retry = Timer(Duration(seconds: 2 + _attempt * 2), () {
      if (!mounted) return;
      setState(() => _attempt++);
    });
  }

  @override
  Widget build(BuildContext context) {
    if (!_known) {
      // Blank while the lookup runs (no flash of plain text), the fallback
      // once we know there is no logo at all.
      return _gaveUp ? widget.fallback() : const SizedBox.shrink();
    }
    final url = _attempt == 0 ? _url : '$_url?r=$_attempt';
    return CachedNetworkImage(
      key: ValueKey(url),
      cacheManager: NemesisImageCache.instance,
      imageUrl: url,
      fit: widget.fit,
      alignment: widget.alignment,
      placeholder: (context, url) => const SizedBox.shrink(),
      errorWidget: (context, url, error) {
        _scheduleRetry();
        return _attempt >= 3 ? widget.fallback() : const SizedBox.shrink();
      },
    );
  }
}
