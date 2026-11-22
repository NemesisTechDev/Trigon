import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter/foundation.dart' show defaultTargetPlatform, TargetPlatform;
import 'package:cached_network_image/cached_network_image.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:media_kit/media_kit.dart';
import 'package:audio_service/audio_service.dart';
import 'package:permission_handler/permission_handler.dart';
import 'screens/main_nav/main_nav_screen.dart';
import 'screens/login/login_screen.dart';
import 'virtual/virtual_playback.dart';
import 'widgets/splash/nemesis_splash_screen.dart';
import 'widgets/splash/splash_mark.dart';
import 'player/player_manager.dart';
import 'player/services/nemesis_audio_handler.dart';
import 'utils/app_fonts.dart';
import 'utils/responsive.dart';
import 'utils/page_transitions.dart';

import 'services/auth/auth_bootstrap.dart';
import 'services/jellyfin_services/auth_service.dart';
import 'services/jellyfin_services/storage_service.dart';
import 'services/jellyfin_services/jellyfin_client.dart';
import 'services/jellyfin_services/media_service.dart';
import 'services/cache/nemesis_image_cache.dart';
import 'services/download_manager.dart';
import 'services/launch_state.dart';
import 'services/download_notification_service.dart';
import 'services/live_tv_reminder_service.dart';
import 'services/analytics_service.dart';
import 'services/app_settings.dart';
import 'services/parental/parental_controls.dart';
import 'services/parental/viewing_time_service.dart';
import 'services/local_music_service.dart';
import 'services/external_media_handler.dart';
import 'services/notification_navigation_handler.dart';
import 'services/update/update_service.dart';
import 'widgets/update/update_gate.dart';
import 'casting/cast_manager.dart';
import 'casting/playback_coordinator.dart';
import 'casting/cast_subtitle_style_sync.dart';
import 'casting/transports/dlna_transport.dart';
import 'casting/transports/google_cast_transport.dart';

// Publishes the lock-screen/notification "now playing" widget. Created
// once at startup — see NemesisAudioHandler's doc comment for why this
// exists separately from PlayerManager.
late final NemesisAudioHandler audioHandler;

/// ### Landscape fullscreen — native Android setup required
/// The `SystemChrome` calls below (edge-to-edge mode + transparent bar
/// colors) are the Dart-side half of this and were already in place.
/// A visible system-bar strip *plus* letterboxing on the sides in
/// landscape — rather than just one or the other — means Android
/// itself isn't treating the window as edge-to-edge/full-bleed at all;
/// `SystemChrome` alone can't override that. Two things to check in
/// the native Android project (outside `lib/`, so not something a
/// `lib/`-only zip can carry):
///
/// 1. **`android/app/src/main/AndroidManifest.xml`** — look for a
///    `<meta-data android:name="android.max_aspect" .../>` tag (or
///    `android:name="android.max_aspect_ratio"`). This is a legacy tag
///    from old Flutter/Android templates that caps the aspect ratio
///    the app is allowed to render at — the OS letterboxes anything
///    wider than the cap instead of stretching to fill it, which
///    matches the side-bar symptom exactly. Delete the tag entirely.
///    Also confirm `MainActivity`'s `<activity>` entry doesn't set
///    `android:screenOrientation="portrait"` (should be `unspecified`
///    or `fullSensor`) and isn't missing
///    `android:resizeableActivity="true"`.
///
/// 2. **`android/app/src/main/res/values/styles.xml`** — in both
///    `LaunchTheme` and `NormalTheme`, add:
///    ```xml
///    <item name="android:windowDrawsSystemBarBackgrounds">true</item>
///    <item name="android:statusBarColor">@android:color/transparent</item>
///    <item name="android:navigationBarColor">@android:color/transparent</item>
///    <item name="android:windowLayoutInDisplayCutoutMode">shortEdges</item>
///    ```
///    Without these, the theme's own opaque bar backgrounds win over
///    the transparent colors `SystemChrome` sets at runtime — this is
///    the most common reason the runtime call alone doesn't stick.
///
/// 3. **`android/app/src/main/kotlin/.../MainActivity.kt`** — for
///    belt-and-suspenders edge-to-edge on every Android version/OEM
///    skin, add to `MainActivity`'s `onCreate` (same class that
///    already extends `AudioServiceActivity` for the notification
///    widget — just add this line inside its existing `onCreate`, no
///    new class needed):
///    ```kotlin
///    override fun onCreate(savedInstanceState: Bundle?) {
///        super.onCreate(savedInstanceState)
///        WindowCompat.setDecorFitsSystemWindows(window, false)
///    }
///    ```
///    (`androidx.core.view.WindowCompat` — already on the classpath via
///    Flutter's default AndroidX setup.)
///
/// 4. **The stretched flash during rotation** is a separate, also
///    native-only issue: it's Android's *default* rotation animation
///    (`windowRotationAnimation="rotate"`), which scales/stretches the
///    old frame to the new orientation's bounds while the Activity
///    redraws — that stretch *is* the transition, not a bug in this
///    app's layout. `MainActivity` already declares
///    `android:configChanges="orientation|screenSize|..."` (per
///    `pip_helper.dart`'s doc comment), which is exactly what
///    `windowRotationAnimation="seamless"` requires to work (it leaves
///    the old frame fixed in place with no scaling/rotation while the
///    new one draws underneath, instead of stretching it) — so this is
///    a one-line addition once `AndroidManifest.xml` and `MainActivity`
///    are already set up, which they are. In both `LaunchTheme` and
///    `NormalTheme` in `android/app/src/main/res/values/styles.xml`:
///    ```xml
///    <item name="android:windowRotationAnimation">seamless</item>
///    ```
///    `seamless` needs API 26+; on the (unlikely, given PiP/edge-to-edge
///    already require modern Android) chance `minSdkVersion` is below
///    26, put that line in `android/app/src/main/res/values-v26/styles.xml`
///    instead (same `LaunchTheme`/`NormalTheme` block, new file/folder)
///    so older devices silently keep the default and never see an
///    unsupported attribute.
void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Whether Android recreated the app after killing its process (then the
  // splash animation is skipped and the last tab is restored), and
  // remembering the selected tab for that case. See LaunchState.
  await LaunchState.init();
  LaunchState.trackTab();

  // In-app updates: reads the installed version and restores a known
  // "you must update" block (so going offline can't get around it) before the
  // first frame. Never throws and is time-boxed - see UpdateService.init.
  try {
    await UpdateService.instance.init().timeout(const Duration(seconds: 5));
  } catch (e) {
    debugPrint('Update service init failed: $e');
  }

  // NAMESIS PRIME: Flutter's default decoded-image memory cache (100 MB)
  // is filled by a handful of large backdrops/logos, so posters already
  // seen were thrown out and had to be read and decoded again (blank
  // squares) after leaving a screen. Allow more; Flutter itself empties
  // this cache automatically when Android signals memory pressure.
  PaintingBinding.instance.imageCache
    ..maximumSizeBytes = 300 * 1024 * 1024
    ..maximumSize = 3000;

  // Decode the embedded splash mark before anything else so the Flutter
  // splash can draw it on its very first frame, in the same spot the
  // native splash drew it (see SplashMark). A few ms; never throws.
  await SplashMark.preload();

  // Resolves Responsive.isTV once, before the first frame, via Android's
  // leanback system feature — not inferred from screen size (see
  // Responsive's own doc comments for why). Every TV-specific branch
  // added across this app's responsive migration (Home's larger row
  // cards and hero, Live TV's overscan-safe padding, etc.) reads
  // Responsive.isTV, which silently defaults to false until this call
  // completes — so this has to run before anything that might check it.
  try {
    await Responsive.resolveDeviceClass().timeout(const Duration(seconds: 5));
  } catch (e) {
    debugPrint('Device class check failed: $e');
  }

  // Firebase (Auth + App Check). Guarded and time-limited inside, so it can
  // never crash or hang startup; if it fails, sign-in simply reports
  // "unavailable" and nobody is let in.
  await AuthBootstrap.init();

  // Outside the video player (which manages its own immersive/edge-to-
  // edge mode per orientation via DisplayHelper/FullscreenHelper), the
  // app never told Android how to draw its system bars at all — it was
  // just inheriting whatever the OS defaults to. That default draws
  // content full-bleed in portrait but reserves solid space for the
  // system bars in landscape, which is why only portrait looked
  // fullscreen. Setting edge-to-edge with transparent bars once here,
  // globally, makes every screen draw full-bleed behind the system
  // bars in both orientations, matching what the player already does.
  SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
  SystemChrome.setSystemUIOverlayStyle(
    const SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      systemNavigationBarColor: Colors.transparent,
      systemNavigationBarDividerColor: Colors.transparent,
      statusBarIconBrightness: Brightness.light,
      systemNavigationBarIconBrightness: Brightness.light,
    ),
  );

  // NAMESIS PRIME: every step below that can fail on some phones is
  // guarded, so a problem in one of them can never leave the app stuck on
  // the splash screen - runApp() is always reached.
  try {
    MediaKit.ensureInitialized();
    PlayerManager.instance.initialize();
  } catch (e, st) {
    debugPrint('Player engine failed to start: $e\n$st');
  }

  // Android 13+ (API 33+) requires this to be granted at runtime before
  // any notification can be posted — including audio_service's
  // foreground "now playing" notification, which is what the lock-screen
  // widget is built on. Declaring android.permission.POST_NOTIFICATIONS
  // in AndroidManifest.xml (already done) only makes the permission
  // available to request; it does not grant it. `flutter run` debug
  // builds install via `adb install -g`, which auto-grants every
  // manifest-declared runtime permission — masking the fact that this
  // was never actually being requested. A manually installed release
  // APK doesn't get that auto-grant, so without this call the
  // permission sits denied and AudioService.init below silently fails
  // to post the notification, even though playback itself works fine.
  // Guarded to Android only — iOS has no equivalent runtime prompt for
  // this and permission_handler's Permission.notification is a no-op
  // there anyway, but being explicit avoids relying on that.
  try {
  audioHandler = await AudioService.init(
    builder: () => NemesisAudioHandler(),
    config: const AudioServiceConfig(
      androidNotificationChannelId: 'com.nemesis.app.audio',
      androidNotificationChannelName: 'Playback',
      // NOT androidNotificationOngoing: true here — audio_service's own
      // AudioServiceConfig constructor has a compile-time assert that
      // androidNotificationOngoing: true can only be paired with
      // androidStopForegroundOnPause: true (an "ongoing"/undismissable
      // notification only makes sense while the service is guaranteed
      // to still be in the foreground). Since androidStopForegroundOnPause
      // is deliberately false below, keeping androidNotificationOngoing
      // at its default false is required, not optional — the previous
      // combination of true+false is exactly what "Evaluation of this
      // constant expression throws an exception" was pointing at: the
      // const AudioServiceConfig(...) below failing its own assert at
      // compile time. This static flag therefore stays false, and the
      // "ongoing while playing, hideable while paused" behavior is
      // applied dynamically instead: NemesisAudioHandler flips
      // FLAG_ONGOING_EVENT on the notification through the
      // com.nemesis.app/media_notification channel in MainActivity.kt.
      androidNotificationOngoing: false,
      // `true` (the old value) tears down the foreground service the
      // instant playback pauses for *any* reason — including a
      // transient mid-stream rebuffer, not just the person deliberately
      // hitting pause. Losing foreground-service status is exactly what
      // strips this app of its Doze/App-Standby exemption; if that
      // happens to land while the screen is off, Android can suspend
      // the process before mpv finishes refilling its buffer and
      // resumes on its own, which is what turns a normal short stall
      // into playback that never comes back. `false` keeps the
      // notification (and the foreground-service exemption that comes
      // with it) alive through pauses — matching Spotify/YouTube
      // Music's own behavior, where the notification persists after you
      // tap pause and only goes away once you swipe it away or fully
      // stop playback.
      androidStopForegroundOnPause: false,
      androidNotificationIcon: 'drawable/ic_notification',
    ),
  ).timeout(const Duration(seconds: 10));
  } catch (e, st) {
    // The lock-screen widget is optional; the app is not.
    debugPrint('AudioService failed to start: $e\n$st');
    audioHandler = NemesisAudioHandler();
  }

  // Tapping the notification above should reopen the audio player for
  // a song, same as most music apps — but keep doing exactly what it
  // already did (just foreground the app) for a movie/episode/live
  // channel. See NotificationNavigationHandler's own doc comment for
  // why this can't just be a config flag on AudioServiceConfig above.
  _safeInit('notification navigation', NotificationNavigationHandler.instance.init);

  // Sets up the download notification channels before anything can
  // possibly post to them — awaited (unlike the loads below) since it's
  // just a couple of cheap platform-channel calls, and every download
  // state change from this point on assumes the channels already exist.
  try {
    await DownloadNotificationService.instance.init()
        .timeout(const Duration(seconds: 8));
  } catch (e) {
    // Desktop (Windows) has no notification settings configured; the app
    // must still start.
    debugPrint('Download notifications unavailable: $e');
  }

  // Must come after the line above: it reuses the plugin instance the
  // download service already initialized (see LiveTvReminderService).
  unawaited(LiveTvReminderService.instance.init().catchError((Object e) {
    debugPrint('Live TV reminders unavailable: $e');
  }));

  // Loads persisted download records from disk so the Downloads page,
  // and every DownloadButton across the app, know what's already been
  // downloaded before the first frame ever needs that info.
  unawaited(DownloadManager.instance.init());

  // Registers the Google Cast transport (Phase 5 of the casting system).
  // Safe to register this early — GoogleCastTransport doesn't touch the native Cast SDK at
  // all until its discover()/connect() is actually called (see
  // GoogleCastTransport._ensureContextInitialized's doc comment), so
  // this line itself does no native init and costs nothing at startup.
  _safeInit('cast: google', () =>
      CastManager.instance.registerTransport(GoogleCastTransport()));

  // UPnP/DLNA MediaRenderers (LG webOS, Samsung Tizen, Sony, Philips, Roku,
  // AV receivers…, and the Trigon TV receiver app). Like Google Cast above, registering is synchronous
  // and touches no network — SSDP only starts when the device picker opens.
  _safeInit('cast: dlna', () =>
      CastManager.instance.registerTransport(DlnaTransport()));

  // Casting Phase 8 — starts the local/remote playback coordinator
  // listening to CastManager.instance.activeSession. Registered after
  // every transport above so it's watching before any connect() could
  // possibly resolve, though in practice the exact ordering doesn't
  // matter — see PlaybackCoordinator.init's own doc comment.
  _safeInit('playback coordinator', PlaybackCoordinator.instance.init);

  // Pushes the user's subtitle style (Settings > Subtitle Style) to the
  // TV live while casting — see CastSubtitleStyleSync.
  _safeInit('cast subtitle sync', CastSubtitleStyleSync.instance.init);

  // Loads persisted app settings (e.g. auto-queue recommendations) into
  // memory before the first frame, same reasoning as downloads above —
  // and PlayerManager needs to read these synchronously mid-playback.
  unawaited(AppSettings.load());
  unawaited(AnalyticsService.init());

  // Loads the Local Files toggle plus local favorites/exclusions, so
  // the Music screen's "On This Device" chip appears immediately for
  // anyone who already has the setting on, instead of popping in a
  // moment after the screen first paints.
  unawaited(LocalMusicService.instance.init());

  runApp(const NemesisApp());

  // Runtime permission dialogs used to be awaited BEFORE runApp, so a phone
  // that never answered them (or showed no dialog) froze the app on the
  // splash. They are asked after the first screen is up instead.
  WidgetsBinding.instance.addPostFrameCallback((_) {
    unawaited(_requestAndroidStartupPermissions());
  });

  // Looks for a new version in the background while the splash plays. An
  // optional update popup waits for the first real screen
  // (UpdateService.markUiReady); a mandatory one shows straight away.
  WidgetsBinding.instance.addPostFrameCallback((_) {
    unawaited(UpdateService.instance.checkOnLaunch());
  });

  // "Open With"/"Play With" support (see ExternalMediaHandler): needs a
  // live NavigatorState to push the player screen onto, which only
  // exists once MaterialApp has actually built — so this waits for the
  // very first frame rather than running inline with everything above.
  WidgetsBinding.instance.addPostFrameCallback((_) {
    unawaited(ExternalMediaHandler.instance.init());
  });
}
// A focused TextField (e.g. the search bar) keeps its keyboard
// connection alive even while a route is pushed on top of it, since
// nothing ever tells it to give up focus. That's invisible for an
// instant pop (button tap, hardware back) because the covering route
// disappears in one frame. But an interactive back gesture — iOS-style
// edge swipe, or Android's predictive-back preview — drags that
// underlying screen back into view frame-by-frame *before* the pop is
// ever committed, so the still-focused field reattaches its input
// connection mid-drag and the keyboard animates in alongside it,
// producing the jank Benson is seeing. `didStartUserGesture` is the
// one NavigatorObserver hook that fires the instant such a gesture
// begins, before any preview frame is drawn, so clearing focus there
// stops the keyboard from ever entering the picture instead of
// reacting to it after the fact.
class _BackGestureFocusObserver extends NavigatorObserver {
  @override
  void didStartUserGesture(Route route, Route? previousRoute) {
    FocusManager.instance.primaryFocus?.unfocus();
  }
}

// google_fonts fetches each distinct font weight it's asked for lazily,
// the first time that weight is actually used to paint text — and only
// triggers a relayout once the fetch+registration completes. With
// nothing warming this up, the *first* screen to render text (Home, in
// practice) is where those fetches land, so the first scroll/interaction
// eats one hitch per distinct weight as each finishes: chivoTextTheme
// alone requests several (it maps a handful of ThemeData.dark().textTheme
// styles to different Chivo weights), plus AppFonts.dosis's two weights,
// plus the LIVE TV card's one-off GoogleFonts.montserrat — a handful of
// hitches total, tapering off as each weight finishes and gets cached,
// which matches "stuttering reduces after a bit, but a couple remain."
// Kicking every one of them off here — during the startup spinner, where
// a brief wait is expected and invisible as jank — means by the time any
// real screen renders, every weight is already fetched and cached, so
// there's nothing left to trigger a mid-scroll relayout later.
//
// Bounded with a timeout and swallowed on error: this is a nice-to-have
// (avoid a handful of one-time layout hitches), not something startup
// should ever be blocked on indefinitely. Without the timeout, a stalled
// or unreachable font fetch (flaky network, DNS hiccup, corporate/VPN
// filtering fonts.gstatic.com, etc.) meant getStartScreen() never
// returned and the app sat on the spinner forever. If this times out or
// errors, GoogleFonts silently falls back to the platform default font
// for whichever weights didn't finish — same as it always did before
// this warmup existed — and the app proceeds normally; only that weight
// still risks a one-time hitch on its actual first use later.
Future<void> _warmUpFonts() async {
  try {
    GoogleFonts.chivoTextTheme(ThemeData.dark().textTheme);
    AppFonts.dosis(fontSize: 1);
    AppFonts.dosis(fontSize: 1, fontWeight: FontWeight.bold);
    GoogleFonts.montserrat(fontWeight: FontWeight.w700);
    await GoogleFonts.pendingFonts().timeout(const Duration(seconds: 4));
  } catch (_) {
    // Timed out, or a fetch itself failed — don't let font warmup block
    // startup. See the doc comment above.
  }
}

/// Gets the first real screen's heavy assets decoded while the splash is
/// still on screen, so the hand-off lands on a screen that's already warm
/// instead of decoding images mid-crossfade (which is what made the first
/// seconds after the splash stutter).
///
///  * Setup / Login: the logo they show.
///  * Home (signed in): the first few hero backdrops from yesterday's cached
///    Home payload — the very same URLs HomeScreen precaches, so they hit the
///    same image-cache entries.
///
/// Deliberately gentle so the splash animation never drops frames: it waits
/// for the first frame plus a short beat, then decodes ONE image at a time
/// (decoding runs off the UI thread; sequencing just stops several large
/// decodes from landing in the same frame). Every step is best-effort.
Future<void> _warmUpFirstScreen({required bool loggedIn}) async {
  try {
    await WidgetsBinding.instance.endOfFrame;
    await Future<void>.delayed(const Duration(milliseconds: 600));

    final providers = <ImageProvider>[
      const AssetImage('assets/images/nemesis_logo.png'),
    ];

    if (loggedIn) {
      final cached = await StorageService.getHomeCache();
      if (cached != null) {
        final decoded = jsonDecode(cached);
        final featured = decoded is Map ? decoded['featuredItems'] : null;
        if (featured is List) {
          for (final item in featured.take(4)) {
            final id = item is Map ? item['Id'] : null;
            if (id == null) continue;
            providers.add(CachedNetworkImageProvider(
              MediaService.getImageUrl(id, type: 'Backdrop', maxWidth: 1200),
              cacheManager: NemesisImageCache.instance,
            ));
          }
        }
      }
    }

    for (final provider in providers) {
      final ctx = ExternalMediaHandler.instance.navigatorKey.currentContext;
      if (ctx == null || !ctx.mounted) return;
      await precacheImage(provider, ctx).catchError((Object _) {});
    }
  } catch (_) {
    // Warm-up is a nicety; the screens load fine without it.
  }
}

// Flat app-wide text size reduction applied in NemesisApp's builder,
// on top of (not instead of) the device accessibility clamp. 1.0 = no
// change; 0.85 = every word ~15% smaller. Tune this one number to
// adjust the whole app's font size at once.
const double _kAppFontScale = 0.85;

class NemesisApp extends StatelessWidget {
  const NemesisApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      navigatorKey: ExternalMediaHandler.instance.navigatorKey,
      // Clamps the device's own font/display-size accessibility setting
      // to a narrow band around 1.0 for the whole app. Nemesis's screens
      // are hand-built with fixed-height Columns/Stacks (the audio
      // player's Spacer-sandwiched body, BackdropHeader's magic-number
      // logo offset, BottomClearance's fixed 56/72 estimates, the
      // library/sort chip rows' fixed-height SizedBoxes) rather than
      // dynamic/scrolling text layouts — none of that was ever designed
      // to absorb a much larger ambient text scale, and a device set to
      // a larger font/display size blows every one of those fixed
      // numbers out (cropped audio player, overlapping backdrop logo,
      // page content rendering under the bottom nav bar, clipped chip
      // labels). Clamping here is the single global guard for all of
      // that; the individual fixed-size spots are still worth hardening
      // over time, but this stops today's worst breakage immediately.
      // 0.9–1.15 still lets genuinely low-vision users get a little
      // more size than default without re-breaking these layouts the
      // way an unclamped 1.3-2.0+ scale does.
      //
      // _kAppFontScale is applied on top of that, as a flat app-wide
      // reduction independent of the device's accessibility setting.
      // Both a Text() with an explicit fontSize and one that just
      // inherits chivoTextTheme size render through this same ambient
      // TextScaler, so multiplying it here shrinks every word in the
      // app by the same constant factor with a single change, rather
      // than editing every TextStyle individually.
      builder: (context, child) {
        final clamped = MediaQuery.textScalerOf(context)
            .clamp(minScaleFactor: 0.9, maxScaleFactor: 1.15);
        final scaled = TextScaler.linear(clamped.scale(1.0) * _kAppFontScale);
        return MediaQuery(
          data: MediaQuery.of(context).copyWith(textScaler: scaled),
          // The update popup sits above every screen, dialog and the player,
          // so a mandatory update can't be bypassed (see UpdateGate).
          child: UpdateGate(child: child!),
        );
      },
      // selectorDropdownRouteObserver is NOT registered here — it's
      // attached to MainNavScreen's nested content Navigator instead
      // (see the comment on that Navigator's `observers:`). A single
      // RouteObserver instance can only ever be attached to one live
      // Navigator at a time; registering it on both this root Navigator
      // and the content Navigator was throwing 'observer.navigator ==
      // null' the moment the second one (content) tried to mount,
      // since the root Navigator — which is always alive from app
      // startup through Setup/Login/Home — claimed it first.
      navigatorObservers: [_BackGestureFocusObserver()],
      debugShowCheckedModeBanner: false,
      title: "Trigon",
      theme: ThemeData.dark().copyWith(
        // Chivo becomes the app-wide default: any Text() that doesn't
        // set its own fontFamily inherits this through the ambient
        // DefaultTextStyle, so this one change reskins every screen's
        // body/UI text without touching each widget individually.
        // Dosis is applied explicitly per-widget at the handful of
        // "hero" spots (see AppFonts.dosis in utils/app_fonts.dart).
        textTheme: GoogleFonts.chivoTextTheme(ThemeData.dark().textTheme),
        // Material 3's default AppBar tints itself toward a lighter
        // "surface tint" color once content scrolls underneath it —
        // every plain AppBar screen (TV Guide, Favorites, All/Favorite
        // Channels, ...) was visibly turning grey while scrolling
        // because of this. Flattening it here keeps every app bar
        // exactly the solid background color it was given, scrolled or
        // not, instead of patching each screen individually.
        appBarTheme: const AppBarTheme(
          scrolledUnderElevation: 0,
          surfaceTintColor: Colors.transparent,
        ),
        // Light slide + parallax for every pushed page (see
        // NemesisPageTransitionsBuilder) instead of the platform's
        // fade/zoom, which re-composites two full pages per frame.
        pageTransitionsTheme: nemesisPageTransitionsTheme,
      ),
      home: const StartupScreen(),

      routes: {
        // There is no server setup screen any more; anything that still
        // navigates to it (e.g. "Disconnect Server") lands on the login.
        "/setup": (_) => const LoginScreen(),
        "/login": (_) => const LoginScreen(),
        "/home": (_) => MainNavScreen(),
      },
    );
  }
}

void _safeInit(String name, void Function() run) {
  try {
    run();
  } catch (e, st) {
    debugPrint('Startup step "$name" failed: $e\n$st');
  }
}

/// Notification + battery-optimisation prompts (Android only). Never throws.
Future<void> _requestAndroidStartupPermissions() async {
  try {
  if (defaultTargetPlatform == TargetPlatform.android) {
      final notificationStatus = await Permission.notification.status;
      if (!notificationStatus.isGranted) {
        // If this comes back permanently denied, the OS will silently
        // no-op every future .request() call — no dialog, ever again —
        // until the person manually flips the notification toggle for
        // this app in system Settings, or fully uninstalls (not just
        // reinstalls/updates) it. That state survives an APK update, so
        // anyone who denied the prompt on an earlier release build (from
        // before this permission was even being requested, or just a
        // reflexive "Deny" tap) will see the notification/lock-screen
        // widget still missing on a newer release build tested over that
        // same install, even with this exact request in place. Not
        // auto-redirecting to Settings from here deliberately — doing
        // that unconditionally on every cold start while denied would
        // pull the person out of the app every single time they open it,
        // for a feature (the notification widget) playback doesn't
        // actually depend on to function.
        await Permission.notification.request();
      }
  
      // Without this, "background playback stops after a while / when the
      // phone sleeps" is largely Android's Doze/App-Standby power
      // management doing exactly what it's designed to do: once the screen
      // has been off for a stretch, an app that isn't exempted gets its
      // network access and CPU work throttled or suspended outright,
      // which — for a *streaming* player specifically — starves mpv of new
      // data mid-buffer and it never recovers on its own. A foreground
      // service (which AudioService.init below sets up) is supposed to be
      // Doze-exempt on stock Android, but manufacturers' own battery
      // managers (and even stock Android's stricter "restricted" App
      // Standby bucket) can still override that for an app the person
      // hasn't explicitly told the OS to leave alone. Requesting this
      // upfront asks the person, once, to add Nemesis to that exempt list
      // — same permission Spotify/YouTube Music/Jellyfin's own official
      // app all request for the same reason. It's a one-tap system dialog,
      // not a runtime permission the OS silently denies, so it's safe to
      // ask unconditionally rather than gating it behind a settings toggle
      // first.
      //
      // Requires `<uses-permission
      // android:name="android.permission.REQUEST_IGNORE_BATTERY_OPTIMIZATIONS" />`
      // in AndroidManifest.xml.
      final batteryStatus = await Permission.ignoreBatteryOptimizations.status;
      if (!batteryStatus.isGranted) {
        await Permission.ignoreBatteryOptimizations.request();
      }

      // CAST DISCOVERY FIX (no Google Cast devices ever listed): on Android
      // 13+ the Cast SDK can only find Chromecasts / Google TVs on the
      // local network once this runtime permission is granted. Nothing in
      // the app ever asked for it, so discovery silently returned nothing.
      // Result is ignored on purpose: on Android 12 and below there is
      // nothing to grant, and a denial just leaves casting where it was.
      //
      // Requires `<uses-permission
      // android:name="android.permission.NEARBY_WIFI_DEVICES"
      // android:usesPermissionFlags="neverForLocation" />` in
      // AndroidManifest.xml.
      try {
        final nearbyStatus = await Permission.nearbyWifiDevices.status;
        if (!nearbyStatus.isGranted) {
          await Permission.nearbyWifiDevices.request();
        }
      } catch (e) {
        debugPrint('Nearby devices permission prompt failed: $e');
      }
    }
  } catch (e) {
    debugPrint('Startup permission prompts failed: $e');
  }
}

/// How long after the splash starts the optional start-up warm-ups (fonts,
/// first-screen images) may still delay the hand-off. The splash's single
/// shimmer ends at about 4.9 s (80 + 380 + 120 ms lead-in + 4320 ms sweep),
/// so this leaves it a safety margin to hand off right when the shimmer ends.
const Duration _kOptionalWarmupBudget = Duration(milliseconds: 4500);

class StartupScreen extends StatelessWidget {
  const StartupScreen({super.key});

  /// Never leaves the splash hanging: every step is guarded, and after 30 s
  /// the app moves on to the login screen regardless.
  Future<Widget> getStartScreen() async {
    try {
      return await _startScreen().timeout(const Duration(seconds: 30));
    } catch (e, st) {
      debugPrint('Startup failed, showing login: $e\n$st');
      UpdateService.instance.markUiReady();
      return const LoginScreen();
    }
  }

  Future<T?> _step<T>(String name, Future<T> Function() run, int seconds) async {
    try {
      return await run().timeout(Duration(seconds: seconds));
    } catch (e) {
      debugPrint('Startup step "$name" failed: $e');
      return null;
    }
  }

  Future<Widget> _startScreen() async {
    // Started with the splash. The splash plays exactly one shimmer (about
    // 4.9 s) and hands off as soon as it ends if this future is done by then;
    // anything still pending after that just holds the finished mark. The
    // optional warm-ups below therefore only get the time up to
    // [_kOptionalWarmupBudget], so they never push the hand-off past the end
    // of that shimmer.
    final clock = Stopwatch()..start();
    Duration budgetLeft([Duration cap = _kOptionalWarmupBudget]) {
      final left = _kOptionalWarmupBudget - clock.elapsed;
      if (left.isNegative) return Duration.zero;
      return left < cap ? left : cap;
    }

    // Runs concurrently with the checks below (and with JellyfinClient.init
    // further down, itself a network call) so this adds ~zero extra wait
    // in practice — but every branch awaits it before returning, so no
    // screen ever gets a chance to paint text before its fonts are ready.
    final fontWarmup = _warmUpFonts();

    // Started now, runs in the background while the splash plays; see
    // _warmUpFirstScreen. Bounded below so it can never hold up the hand-off.
    var loggedIn = false;

    // NAMESIS PRIME: no server setup. The virtual server (TMDB) is always
    // "connected"; the only gate is the placeholder login screen. The
    // services below must be running before the first screen asks for data.
    await _step('virtual bootstrap', VirtualBootstrap.init, 15);
    // Parental Controls must be loaded before any screen asks for data, so
    // the very first lists are already filtered.
    await _step('parental controls', ParentalControls.instance.load, 10);
    unawaited(ViewingTimeService.instance.init());
    await _step('client init', JellyfinClient.init, 15);
    // The gate is a real Firebase session (still valid, verified email), not
    // just "some token is stored".
    final signedIn =
        await _step<bool>('session', AuthService.restoreSession, 15) ?? false;

    Widget next;
    if (!signedIn) {
      next = const LoginScreen();
    } else {
      loggedIn = true;
      await LaunchState.restoreTab();
      next = MainNavScreen();
    }

    // Best-effort and time-boxed (see the budget note above): fonts already
    // cached on disk resolve at once; a slow or offline font fetch can no
    // longer hold the hand-off back (google_fonts falls back to the system
    // font for whatever did not finish, as _warmUpFonts documents).
    await fontWarmup.timeout(budgetLeft(), onTimeout: () {});
    await _warmUpFirstScreen(loggedIn: loggedIn).timeout(
      budgetLeft(const Duration(milliseconds: 1800)),
      onTimeout: () {},
    );
    // The splash is about to hand off: an available (optional) update may
    // now pop up on the first real screen.
    UpdateService.instance.markUiReady();
    return next;
  }

  @override
  Widget build(BuildContext context) {
    // NemesisSplashScreen owns the shimmer and the hand-off; it calls
    // getStartScreen() itself and crossfades into whatever it resolves to
    // (Setup/Login/Home) once that future has resolved AND the shimmer has
    // finished its sweep (it never exits mid-shimmer). This replaces the
    // previous bare Scaffold+CircularProgressIndicator placeholder with the
    // branded splash.
    return NemesisSplashScreen(
      future: getStartScreen,
      quick: LaunchState.restored,
    );
  }
}