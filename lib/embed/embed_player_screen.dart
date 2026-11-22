import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_android/webview_flutter_android.dart';

import '../casting/cast_manager.dart';
import '../catalog/catalog_models.dart';
import '../catalog/next_episode_service.dart';
import '../catalog/tmdb_catalog_service.dart';
import '../library/watch_history_service.dart';
import '../player/helpers/player_orientation.dart';
import '../player/player_manager.dart';
import '../player/screens/player_navigation.dart';
import '../services/app_settings.dart';
import '../services/parental/parental_controls.dart';
import '../services/parental/viewing_time_service.dart';
import 'embed_adblock.dart';
import 'embed_servers.dart';

const Color _gold = Color(0xffD4AF37);

/// Web player for the "Embed servers" playback source.
///
/// The video itself is drawn by the embed server's own page (inside a
/// WebView), so its seek bar, quality menu and subtitle picker are the
/// server's. Everything around it follows the native player: the same top
/// bar (gradient, back arrow, episode title over show title), the same
/// blurred-backdrop loading cover, landscape immersive mode and gold accent.
///
/// Watch progress, resume and the episode label come from the player's
/// `PLAYER_EVENT` messages (Vidfast, VidLink). Vidsrc documents no events, so
/// it has no resume or progress tracking. The Next-episode button works for
/// all three.
///
/// VidLink plays anime through MyAnimeList ids (see [EmbedUrls.resolve]). The
/// player then reports MAL's season / episode numbers, so this screen keeps
/// tracking the TMDB episode itself and ignores those numbers.
class EmbedPlayerScreen extends StatefulWidget {
  const EmbedPlayerScreen({
    super.key,
    required this.title,
    this.episode,
    this.startAt = Duration.zero,
  });

  final CatalogTitle title;
  final CatalogEpisode? episode;
  final Duration startAt;

  static bool _isOpen = false;

  /// True while the embed player screen is on top.
  static bool get isOpen => _isOpen;

  /// Runs the same gates the native player runs (parental controls, no
  /// casting), stops any native playback, then opens the screen.
  static Future<void> open(
    BuildContext context, {
    required CatalogTitle title,
    CatalogEpisode? episode,
    bool startOver = false,
    Duration? resumeAt,
  }) async {
    var pushed = false;
    try {
      pushed = await _open(
        context,
        title: title,
        episode: episode,
        startOver: startOver,
        resumeAt: resumeAt,
      );
    } finally {
      // The native player screen may have been closed for this screen (see
      // PlayerOrientation.beginHandoff). If no embed screen came after all,
      // give the orientation back. No-op when there was no hand-over.
      if (!pushed) PlayerOrientation.cancelHandoff();
    }
  }

  /// True once the screen was pushed (and has closed again).
  static Future<bool> _open(
    BuildContext context, {
    required CatalogTitle title,
    CatalogEpisode? episode,
    bool startOver = false,
    Duration? resumeAt,
  }) async {
    if (_isOpen) return false;

    // webview_flutter only has Android and iOS implementations.
    if (!(Platform.isAndroid || Platform.isIOS)) {
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(const SnackBar(
        content: Text('Embed servers are not available on this device. '
            'Switch Playback Source to Addons in Settings.'),
      ));
      return false;
    }

    if (CastManager.instance.isCasting) {
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(const SnackBar(
        content: Text('Disconnect from the TV to use embed servers.'),
      ));
      return false;
    }

    final id = title.type == CatalogType.movie
        ? 'm${title.tmdbId}'
        : 's${title.tmdbId}';
    if (!await ParentalControls.instance.authorizePlayback(titleId: id)) {
      return false;
    }

    final start = startOver
        ? Duration.zero
        : (resumeAt ??
            WatchHistoryService.instance.positionFor(title, episode) ??
            Duration.zero);

    // Never two players at once.
    try {
      await PlayerManager.instance.stop();
    } catch (_) {}

    if (!context.mounted) return false;
    _isOpen = true;
    try {
      await Navigator.of(context, rootNavigator: true).push(
        MaterialPageRoute<void>(
          settings: const RouteSettings(name: '/embed_player'),
          builder: (_) => EmbedPlayerScreen(
            title: title,
            episode: episode,
            startAt: start,
          ),
        ),
      );
    } finally {
      _isOpen = false;
      PlayerNavigation.notifyClosed();
    }
    return true;
  }

  @override
  State<EmbedPlayerScreen> createState() => _EmbedPlayerScreenState();
}

class _EmbedPlayerScreenState extends State<EmbedPlayerScreen>
    with WidgetsBindingObserver {
  late final WebViewController _web;
  late CatalogEpisode? _episode = widget.episode;
  late EmbedServer _server = AppSettings.embedServer.value;

  /// What is loaded right now (URL, and the MAL ids when VidLink plays anime).
  EmbedTarget? _target;

  /// VidLink anime: dubbed audio instead of subtitled. This session only.
  bool _dub = false;

  /// Bumped by every [_load], so a slow URL lookup can't overwrite a newer one.
  int _loadSeq = 0;

  /// An auto-advance to the next episode is already under way.
  bool _advancing = false;

  /// The page asked for its own fullscreen (its fullscreen button): the
  /// WebView hands us the widget to show, and a callback to leave it again.
  Widget? _webFullscreen;
  VoidCallback? _webFullscreenHidden;

  /// How many times the landscape lock was put back because the window
  /// came up portrait (reset as soon as it is landscape).
  int _reasserts = 0;

  int _posSec = 0;
  int _durSec = 0;
  bool _allowMainFrame = true;
  bool _loading = true;
  bool _barVisible = true;
  bool _blanked = false;
  Timer? _barTimer;
  Timer? _loadTimeout;

  // Loading-cover bookkeeping: the cover (blurred movie backdrop) stays up
  // until the player has really started playing, not merely until its first
  // message arrives. Before that the embed shows its own grey placeholder
  // with its logo, which is inside a cross-origin iframe and can't be styled.
  double? _coverPrevSec;
  double _coverAdvancedSec = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // Immersive + landscape lock, same as the native player. Also counts this
    // screen as the open player, so the native loading screen that closes a
    // moment later can no longer release the lock (that was why the embed
    // player stayed in portrait).
    PlayerOrientation.enter();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) PlayerOrientation.ensureLandscape();
    });

    // Parental screen time: count this as watching, and be able to stop the
    // picture when a time block locks the screen.
    final vt = ViewingTimeService.instance;
    vt.externalWatching.value = true;
    vt.onExternalPause = _blank;
    vt.onExternalResume = () => _load(startAt: _posSec);

    _posSec = widget.startAt.inSeconds;

    _web = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(Colors.black)
      ..addJavaScriptChannel('Bridge', onMessageReceived: _onBridge)
      ..setNavigationDelegate(NavigationDelegate(
        // Only our own page may load as the main frame, so an ad inside the
        // embed cannot redirect the whole screen somewhere else.
        onNavigationRequest: (request) =>
            (!request.isMainFrame || _allowMainFrame)
                ? NavigationDecision.navigate
                : NavigationDecision.prevent,
        onWebResourceError: (error) {
          assert(() {
            debugPrint('Embed WebView error: ${error.errorCode} '
                '${error.description} (main frame: ${error.isForMainFrame})');
            return true;
          }());
        },
        onPageFinished: (_) {
          _allowMainFrame = false;
          PlayerOrientation.ensureLandscape();
          // Vidsrc sends no events, so drop the cover after a short settle.
          if (_server == EmbedServer.vidsrc) {
            Future<void>.delayed(const Duration(seconds: 4), () {
              if (mounted) setState(() => _loading = false);
            });
          }
        },
      ));

    _showBar();
    unawaited(_init());
  }

  Future<void> _init() async {
    final platform = _web.platform;
    if (platform is AndroidWebViewController) {
      await platform.setMediaPlaybackRequiresUserGesture(false);
      // The page's own fullscreen button (VidLink, Vidsrc): without this the
      // WebView refuses every fullscreen request and the button does
      // nothing. The screen is already landscape + immersive, so the video
      // simply fills it.
      await platform.setCustomWidgetCallbacks(
        onShowCustomWidget: (Widget widget, void Function() onHidden) {
          if (!mounted) {
            onHidden();
            return;
          }
          setState(() {
            _webFullscreen = widget;
            _webFullscreenHidden = onHidden;
          });
          PlayerOrientation.ensureLandscape();
        },
        onHideCustomWidget: () {
          if (!mounted) return;
          setState(() {
            _webFullscreen = null;
            _webFullscreenHidden = null;
          });
        },
      );
      // A player inside an iframe often needs third-party cookies.
      final cookies = WebViewCookieManager().platform;
      if (cookies is AndroidWebViewCookieManager) {
        await cookies.setAcceptThirdPartyCookies(platform, true);
      }
      // The stock Android WebView announces itself ("; wv" and a
      // "Version/x.y" token). Embed players often refuse to start for
      // that, so present the same user agent as Chrome on Android.
      try {
        final ua = await _web.getUserAgent();
        if (ua != null && ua.isNotEmpty) {
          await _web.setUserAgent(ua
              .replaceAll('; wv', '')
              .replaceAll(RegExp(r'Version/\d+(\.\d+)*\s'), ''));
        }
      } catch (_) {}
    }
    if (!mounted) return;
    await _load(startAt: _posSec);
  }

  Future<void> _load({required int startAt}) async {
    if (!mounted) return;
    _blanked = false;
    setState(() => _loading = true);
    _armCoverTimeout();
    final seq = ++_loadSeq;
    // Ad blocker for this WebView only (no-op when switched off in Settings).
    // Re-applied on every load: it is idempotent, and it makes sure it is
    // still on the WebView's client after webview_flutter set its own.
    await EmbedAdBlock.install(_web, enabled: AppSettings.embedAdBlock.value);
    // VidLink plays anime through MyAnimeList ids, which can need a short
    // (cached) TMDB lookup, so the URL is worked out asynchronously.
    final target = await EmbedUrls.resolve(
      server: _server,
      title: widget.title,
      episode: _episode,
      startAtSeconds: startAt,
      dub: _dub,
    );
    // Stop if a newer load started meanwhile (Next, server switch...), or the
    // picture was blanked (app in the background / screen-time block): the
    // resume / unblock path loads again.
    if (!mounted || seq != _loadSeq || _blanked) return;
    assert(() {
      debugPrint('Embed URL: ${target.url}');
      return true;
    }());
    setState(() => _target = target);
    // Set right before navigating, so a late onPageFinished of the previous
    // page can't switch it off and block our own page.
    _allowMainFrame = true;
    // A real https base URL: with none, the page has an opaque "null"
    // origin and sends the iframe no Referer, which embed players can
    // reject (blank screen / nothing plays).
    await _web.loadHtmlString(
      EmbedUrls.wrapperHtml(target.url),
      baseUrl: EmbedUrls.pageBaseUrl,
    );
  }

  /// Starts counting playback progress from scratch and (re)starts the
  /// safety timeout for the loading cover.
  void _armCoverTimeout() {
    _coverPrevSec = null;
    _coverAdvancedSec = 0;
    _loadTimeout?.cancel();
    // If playback never starts, let the embed's own UI show through.
    _loadTimeout = Timer(const Duration(seconds: 20), () {
      if (mounted) setState(() => _loading = false);
    });
  }

  /// True once the player has played about a second of steady, forward
  /// progress. A single big jump (the player seeking to the resume point)
  /// does not count; counting starts again after it.
  bool _playbackHasStarted(double cur) {
    final prev = _coverPrevSec;
    _coverPrevSec = cur;
    if (prev == null) return false;
    final step = cur - prev;
    if (step > 0 && step <= 15) {
      _coverAdvancedSec += step;
    } else if (step.abs() > 15) {
      _coverAdvancedSec = 0;
    }
    return _coverAdvancedSec >= 1.0;
  }

  Future<void> _blank() async {
    _blanked = true;
    await _web.runJavaScript(
        "document.getElementById('p').src='about:blank'");
  }

  void _onBridge(JavaScriptMessage message) {
    Map<String, dynamic> json;
    try {
      json = Map<String, dynamic>.from(jsonDecode(message.message) as Map);
    } catch (_) {
      return;
    }
    if (json['type'] != 'PLAYER_EVENT' || json['data'] is! Map) return;
    final d = Map<String, dynamic>.from(json['data'] as Map);

    // A MyAnimeList page (VidLink anime) numbers seasons / episodes the MAL
    // way and may identify itself by MAL id, so neither can be compared with,
    // or adopted into, the TMDB episode this screen tracks.
    final viaMal = _target?.viaMal ?? false;

    // Ignore anything that is not about this title. (Vidfast sends `tmdbId`;
    // VidLink's docs name the field `mtmdbId`.)
    final rawId = d['tmdbId'] ?? d['mtmdbId'];
    final tmdb = rawId is num ? rawId.toInt() : null;
    if (!viaMal && tmdb != null && tmdb != widget.title.tmdbId) return;

    // The embed moved on by itself (its own Next button or auto-next).
    final rawSeason = d['season'];
    final rawEpisode = d['episode'];
    final s = rawSeason is num ? rawSeason.toInt() : null;
    final e = rawEpisode is num ? rawEpisode.toInt() : null;
    if (!viaMal &&
        widget.title.type == CatalogType.series &&
        s != null &&
        e != null &&
        (s != _episode?.season || e != _episode?.number)) {
      _adoptEpisode(s, e);
    }

    final cur = (d['currentTime'] as num?)?.toDouble() ?? 0;
    final dur = (d['duration'] as num?)?.toDouble() ?? 0;

    // Keep the backdrop cover until playback has actually started.
    if (_loading &&
        d['currentTime'] is num &&
        dur > 0 &&
        _playbackHasStarted(cur)) {
      _loadTimeout?.cancel();
      if (mounted) setState(() => _loading = false);
    }

    _posSec = cur.floor();
    _durSec = dur.floor();

    WatchHistoryService.instance.recordEmbed(
      title: widget.title,
      episode: _episode,
      posMs: _posSec * 1000,
      durMs: _durSec * 1000,
    );

    // VidLink has no auto-next option (Vidfast has), so when an episode ends
    // move on to the next one ourselves, like the native player does.
    if (d['event'] == 'ended' &&
        _server == EmbedServer.vidlink &&
        widget.title.type == CatalogType.series &&
        _episode != null &&
        !_advancing) {
      _advancing = true;
      unawaited(_next().whenComplete(() => _advancing = false));
    }
  }

  void _adoptEpisode(int season, int number) {
    // Save the episode that just ended before switching the label.
    WatchHistoryService.instance.endEmbed();
    if (!mounted) return;
    // The embed is now loading the next episode itself: cover it with the
    // backdrop again until that episode is really playing.
    _armCoverTimeout();
    setState(() {
      _loading = true;
      _episode = CatalogEpisode(
        season: season,
        number: number,
        name: 'Episode $number',
        overview: '',
      );
    });
    unawaited(() async {
      try {
        final eps =
            await TmdbCatalogService.episodes(widget.title.tmdbId, season);
        for (final x in eps) {
          if (x.number == number &&
              mounted &&
              _episode?.season == season &&
              _episode?.number == number) {
            setState(() => _episode = x);
            break;
          }
        }
      } catch (_) {}
    }());
  }

  Future<void> _next() async {
    final cur = _episode;
    if (cur == null) return;
    final next = await NextEpisodeService.findNext(widget.title, cur);
    if (!mounted) return;
    if (next == null) {
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        const SnackBar(content: Text('No next episode')),
      );
      return;
    }
    WatchHistoryService.instance.endEmbed();
    _posSec = 0;
    _durSec = 0;
    setState(() => _episode = next);
    await _load(startAt: 0);
  }

  /// VidLink anime: switch between subtitled and dubbed audio.
  Future<void> _toggleAudio() async {
    _showBar();
    setState(() => _dub = !_dub);
    await _load(startAt: _posSec);
  }

  Future<void> _pickServer() async {
    _showBar();
    final picked = await showModalBottomSheet<EmbedServer>(
      context: context,
      backgroundColor: const Color(0xFF1C1C1C),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final s in EmbedServer.values)
              ListTile(
                leading: Icon(
                  s == _server ? Icons.check_circle : Icons.circle_outlined,
                  color: s == _server ? _gold : Colors.white54,
                ),
                title: Text(
                  EmbedUrls.label(s),
                  style: const TextStyle(color: Colors.white),
                ),
                onTap: () => Navigator.of(ctx).pop(s),
              ),
          ],
        ),
      ),
    );
    if (picked == null || picked == _server || !mounted) return;
    // This session only; the default stays what Settings says.
    setState(() => _server = picked);
    await _load(startAt: _posSec);
  }

  void _showBar() {
    if (mounted) setState(() => _barVisible = true);
    _barTimer?.cancel();
    _barTimer = Timer(const Duration(seconds: 4), () {
      if (mounted) setState(() => _barVisible = false);
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused) {
      unawaited(_blank()); // no sound in the background
    } else if (state == AppLifecycleState.resumed) {
      PlayerOrientation.ensureLandscape();
      if (_blanked && !PlayerOrientation.isLeaving) {
        unawaited(_load(startAt: _posSec));
      }
    }
  }

  /// The window came up portrait although this screen is locked to
  /// landscape (something released the lock, or the rotation was dropped):
  /// ask for landscape again. Bounded, so a window that can't be landscape
  /// (split screen) is not asked forever.
  @override
  void didChangeMetrics() {
    if (!mounted || PlayerOrientation.isLeaving) return;
    if (PlayerOrientation.viewIsPortrait) {
      if (_reasserts < 3) {
        _reasserts++;
        PlayerOrientation.ensureLandscape();
      }
    } else {
      _reasserts = 0;
    }
  }

  /// Back pressed while the page is in its own fullscreen: leave that first.
  bool _closeWebFullscreen() {
    if (_webFullscreen == null) return false;
    final hide = _webFullscreenHidden;
    setState(() {
      _webFullscreen = null;
      _webFullscreenHidden = null;
    });
    try {
      hide?.call();
    } catch (_) {}
    return true;
  }

  /// The screen starts closing: silence the page right away, the phone may
  /// still take a moment to turn to portrait.
  void _prepareToLeave() {
    unawaited(_blank());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _barTimer?.cancel();
    _loadTimeout?.cancel();
    WatchHistoryService.instance.endEmbed();

    final vt = ViewingTimeService.instance;
    vt.externalWatching.value = false;
    vt.onExternalPause = null;
    vt.onExternalResume = null;

    // Same rules as the native player (PlayerOrientation): normally the exit
    // already turned the phone before the pop and this does nothing; if the
    // screen was closed another way it brings the system bars back and
    // releases the lock.
    PlayerOrientation.screenClosed(fullscreen: true);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = widget.title;
    final ep = _episode;

    return PlayerExitScope(
      isFullscreen: () => true,
      onExitStart: _prepareToLeave,
      onBack: _closeWebFullscreen,
      child: Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          Positioned.fill(child: WebViewWidget(controller: _web)),

          // The page's own fullscreen video (its fullscreen button).
          if (_webFullscreen != null)
            Positioned.fill(
              child: ColoredBox(color: Colors.black, child: _webFullscreen),
            ),

          // The web view takes every other touch, so a thin strip at the top
          // brings the bar back.
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            height: 56,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: _showBar,
            ),
          ),

          // Same look as the native player's top bar.
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: AnimatedOpacity(
              opacity: _barVisible ? 1 : 0,
              duration: const Duration(milliseconds: 200),
              child: IgnorePointer(
                ignoring: !_barVisible,
                child: Container(
                  padding: const EdgeInsets.fromLTRB(12, 16, 12, 10),
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [
                        Colors.black.withValues(alpha: 0.85),
                        Colors.transparent,
                      ],
                    ),
                  ),
                  child: Row(
                    children: [
                      IconButton(
                        iconSize: 24,
                        onPressed: () => Navigator.maybePop(context),
                        icon: const Icon(Icons.arrow_back,
                            color: Colors.white),
                      ),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              ep != null ? ep.name : t.title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 18,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            Text(
                              ep != null ? t.title : (t.year?.toString() ?? ''),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                color: Colors.white70,
                                fontSize: 12,
                              ),
                            ),
                          ],
                        ),
                      ),
                      if (ep != null)
                        IconButton(
                          iconSize: 24,
                          tooltip: 'Next episode',
                          onPressed: _next,
                          icon: const Icon(Icons.skip_next,
                              color: Colors.white),
                        ),
                      if (_target?.viaMal ?? false)
                        TextButton(
                          onPressed: _toggleAudio,
                          style: TextButton.styleFrom(
                            minimumSize: const Size(48, 40),
                            padding:
                                const EdgeInsets.symmetric(horizontal: 10),
                          ),
                          child: Text(
                            _dub ? 'DUB' : 'SUB',
                            style: const TextStyle(
                              color: _gold,
                              fontSize: 13,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                      IconButton(
                        iconSize: 24,
                        tooltip: 'Server',
                        onPressed: _pickServer,
                        icon: const Icon(Icons.dns_outlined,
                            color: Colors.white),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),

          if (_loading) Positioned.fill(child: _LoadingCover(title: t)),
        ],
      ),
      ),
    );
  }
}

/// Same cover the native player shows while loading: blurred backdrop, logo,
/// spinner, title.
class _LoadingCover extends StatelessWidget {
  const _LoadingCover({required this.title});

  final CatalogTitle title;

  @override
  Widget build(BuildContext context) {
    // Larger size than the usual card backdrop: this fills the whole screen.
    final backdrop = TmdbImages.backdrop(title.backdropPath, size: 'w1280');
    return Stack(
      fit: StackFit.expand,
      children: [
        const ColoredBox(color: Colors.black),
        if (backdrop != null)
          Image.network(
            backdrop,
            fit: BoxFit.cover,
            errorBuilder: (_, __, ___) => const SizedBox.shrink(),
          ),
        // Light blur and dim so the movie's backdrop is clearly recognisable
        // while the logo, spinner and title stay readable on top of it.
        BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 8, sigmaY: 8),
          child: Container(color: Colors.black.withValues(alpha: .45)),
        ),
        Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Image.asset('assets/images/nemesis_logo.png', width: 110),
              const SizedBox(height: 30),
              const CircularProgressIndicator(),
              const SizedBox(height: 24),
              Text(
                title.title,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 22,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 8),
              const Text(
                'Loading...',
                style: TextStyle(color: Colors.white70),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
