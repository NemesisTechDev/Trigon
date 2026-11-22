import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../../services/cache/nemesis_image_cache.dart';

/// Puts a small centred spinner over a detail page while it is still waiting
/// for its first real content, and takes it away as soon as SOME of it is
/// there: the page's data has arrived AND at least one of its pictures
/// (backdrop, poster, logo, photo...) has loaded.
///
/// Built so that it is never noticed when it is not needed:
///  - The spinner only appears after [delay]. A fast network, or a page whose
///    pictures are already cached, is ready well inside that time, so the
///    spinner never shows at all.
///  - It fades in and out instead of popping.
///  - It never blocks touches (back, scrolling and taps all keep working), and
///    it does not cover the page, which keeps drawing underneath.
///  - It can only ever go away once: after the first picture is ready it stays
///    away, even if more pictures (or a refresh) come later.
///  - It cannot get stuck: it also goes away when every picture failed to load
///    (offline, missing artwork), or after [timeout] whatever happens.
///
/// While [dataReady] is false (the page has nothing to show yet) the spinner
/// is shown after [delay] too; pass an empty plain page as [child] then.
///
/// Pictures are loaded with the same cache manager the pages use, so the
/// loading done here is not wasted: the page's own images come straight from
/// the cache.
class ArtworkReadySpinner extends StatefulWidget {
  const ArtworkReadySpinner({
    super.key,
    required this.urls,
    required this.child,
    this.dataReady = true,
    this.delay = const Duration(milliseconds: 250),
    this.timeout = const Duration(seconds: 6),
  });

  /// Candidate pictures. Any ONE of them being ready is enough. Addresses
  /// that cannot load (empty, not http(s), the app's own `/no-image/`
  /// placeholder address) are ignored.
  final List<String> urls;

  /// False while the page has no data to draw yet.
  final bool dataReady;

  final Widget child;

  /// How long to wait before the spinner is allowed to appear.
  final Duration delay;

  /// The longest the spinner can ever stay (counted from when the page opens).
  final Duration timeout;

  @override
  State<ArtworkReadySpinner> createState() => _ArtworkReadySpinnerState();
}

class _ArtworkReadySpinnerState extends State<ArtworkReadySpinner> {
  static const Color _gold = Color(0xffD4AF37);

  /// Latched: once true it never goes back to false.
  bool _ready = false;
  bool _delayPassed = false;

  final Set<String> _started = <String>{};
  int _pending = 0;

  Timer? _delayTimer;
  Timer? _timeoutTimer;

  @override
  void initState() {
    super.initState();
    _delayTimer = Timer(widget.delay, () {
      if (mounted && !_ready) setState(() => _delayPassed = true);
    });
    _timeoutTimer = Timer(widget.timeout, () => _finish());
  }

  // Needs a BuildContext that can already be read (image configuration), so
  // it starts here rather than in initState. Runs once at the start and again
  // if an inherited value changes; already started pictures are not repeated.
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _startProbes();
  }

  @override
  void didUpdateWidget(covariant ArtworkReadySpinner oldWidget) {
    super.didUpdateWidget(oldWidget);
    _startProbes();
  }

  @override
  void dispose() {
    _delayTimer?.cancel();
    _timeoutTimer?.cancel();
    super.dispose();
  }

  static bool _usable(String url) {
    if (url.isEmpty || url.contains('/no-image/')) return false;
    final uri = Uri.tryParse(url);
    return uri != null && (uri.scheme == 'http' || uri.scheme == 'https');
  }

  void _startProbes() {
    if (_ready) return;
    if (widget.dataReady) {
      for (final url in widget.urls) {
        if (!_usable(url) || !_started.add(url)) continue;
        unawaited(_probe(url));
      }
    }
    // Called from lifecycle methods, which are always followed by a build,
    // so no extra setState is needed (or wanted) here.
    _checkDone(notify: false);
  }

  Future<void> _probe(String url) async {
    _pending++;
    var ok = true;
    try {
      await precacheImage(
        CachedNetworkImageProvider(url, cacheManager: NemesisImageCache.instance),
        context,
        onError: (Object _, StackTrace? __) => ok = false,
      );
    } catch (_) {
      ok = false;
    }
    _pending--;
    if (!mounted) return;
    if (ok) {
      _finish();
    } else {
      _checkDone();
    }
  }

  /// Nothing left to wait for: the data is there and every picture has been
  /// tried (or the page has none).
  void _checkDone({bool notify = true}) {
    if (!_ready && widget.dataReady && _pending == 0) _finish(notify: notify);
  }

  void _finish({bool notify = true}) {
    if (_ready) return;
    _delayTimer?.cancel();
    _timeoutTimer?.cancel();
    if (notify && mounted) {
      setState(() => _ready = true);
    } else {
      _ready = true;
    }
  }

  @override
  Widget build(BuildContext context) {
    final showSpinner = !_ready && _delayPassed;
    return Stack(
      fit: StackFit.expand,
      children: [
        widget.child,
        Positioned.fill(
          child: IgnorePointer(
            child: AnimatedOpacity(
              opacity: showSpinner ? 1 : 0,
              duration: const Duration(milliseconds: 200),
              curve: Curves.easeOut,
              child: const Center(
                child: SizedBox(
                  width: 36,
                  height: 36,
                  child: CircularProgressIndicator(
                    color: _gold,
                    strokeWidth: 2.5,
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}
