import 'package:flutter/foundation.dart' show defaultTargetPlatform, TargetPlatform;
import 'package:flutter/material.dart';
import 'package:media_kit_video/media_kit_video.dart';
import '../../services/subtitle_appearance_settings.dart';
import '../models/subtitle_appearance.dart';
import '../player_manager.dart';
import 'custom_subtitle_overlay.dart';
import 'subtitle_style.dart';

class VideoSurface extends StatelessWidget {
  final VideoController controller;
  final PlayerManager manager;

  /// How the decoded frame is scaled to fill this widget's bounds.
  /// Defaults to the standard "fit inside, preserve aspect ratio"
  /// behavior; the bottom bar's scaling button cycles this value.
  final BoxFit fit;

  /// Whether to draw subtitle text at all — on by default, and now on
  /// for the PiP window too: on Android `CustomSubtitleOverlay` sizes
  /// text as a fraction of the visible video height, so it scales with
  /// whatever window it's in (full screen, portrait, or PiP).
  final bool showSubtitles;

  const VideoSurface({
    super.key,
    required this.controller,
    required this.manager,
    this.fit = BoxFit.contain,
    this.showSubtitles = true,
  });

  @override
  Widget build(BuildContext context) {
    // media_kit_video's built-in `SubtitleView` overlay is confirmed —
    // through extensive on-device testing (mpv decode verified correct
    // via `player.stream.subtitle`, hardware acceleration off, default
    // vs. custom video controls, even a loud debug background color
    // behind the text) — to paint literally nothing on this Android
    // setup, while working correctly everywhere else. The most likely
    // cause found was Android defaulting to Flutter's Impeller/Vulkan
    // rendering backend (confirmed via `flutter run` log:
    // "Using the Impeller rendering backend (Vulkan)"), a known source
    // of compositing issues with plugins that render through native
    // textures/surfaces. `CustomSubtitleOverlay` — a plain Flutter
    // `Text` widget with no native surface/texture involvement — is
    // used on Android only, since it's the one approach actually
    // proven, on this device, to put subtitle text on screen. Windows
    // (and any other non-Android platform) keeps the built-in overlay,
    // since it already renders correctly there.
    final useCustomOverlay = defaultTargetPlatform == TargetPlatform.android;

    // No `Positioned.fill` here — `Positioned` is only legal as a
    // *direct* child of `Stack`, and this widget doesn't control what
    // its caller puts around it. Its two actual call sites are (a)
    // nested inside `PlayerGestureLayer`'s `GestureDetector` (which
    // renders as a `Listener`, not a `Stack`) and (b) as a `Scaffold`
    // body for the PiP window (not a `Stack` either) — `Positioned`
    // was invalid in both. `SizedBox.expand` gets the same "fill
    // whatever space I'm given" behavior without requiring a specific
    // parent type; `PlayerGestureLayer`'s own legitimate
    // `Positioned.fill` (it IS a direct `Stack` child) already
    // establishes full-screen bounds above this, so constraints
    // reaching here are already correct.
    return SizedBox.expand(
      child: Stack(
        children: [
          // Non-Android built-in SubtitleView reads the ambient text
          // scale, so clamp it here too (same cap as the custom overlay).
          MediaQuery(
            data: MediaQuery.of(context).copyWith(
              textScaler: clampedSubtitleScaler(context),
            ),
            // Non-Android only (Android draws CustomSubtitleOverlay
            // instead) — still rebuilt on style changes so Windows etc.
            // honor the same customization.
            child: ValueListenableBuilder<SubtitleAppearance>(
              valueListenable: SubtitleAppearanceSettings.notifier,
              builder: (context, appearance, _) => Video(
            controller: controller,
            fit: fit,
            // This app renders its own controls and loading/buffering
            // UI (PlayerControlsLayer, LoadingOverlay, BufferingOverlay)
            // — without this, media_kit_video's default control layer
            // draws its own buffering spinner on top of/behind ours.
            controls: NoVideoControls,
            // Explicitly OFF on Android (CustomSubtitleOverlay draws
            // instead, see above) — omitting this was previously found
            // to NOT actually default to invisible, so it's set
            // explicitly either way to avoid relying on an unverified
            // default.
            subtitleViewConfiguration: SubtitleViewConfiguration(
              visible: showSubtitles && !useCustomOverlay,
              style: subtitleTextStyleFor(
                appearance,
                fontSize: kSubtitleTextStyle.fontSize! * appearance.sizeScale,
              ),
              padding: EdgeInsets.only(
                left: 24,
                right: 24,
                top: 24,
                bottom: 24 *
                    (appearance.bottomOffset / kSubtitleDefaultBottomOffset),
              ),
            ),
            ),
            ),
          ),
          if (showSubtitles && useCustomOverlay)
            CustomSubtitleOverlay(manager: manager, fit: fit),
        ],
      ),
    );
  }
}
