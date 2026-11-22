import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:path_provider/path_provider.dart';

import '../../services/app_settings.dart';
import '../../services/cache/nemesis_image_cache.dart';
import '../../services/download_manager.dart';
import '../../services/jellyfin_services/storage_service.dart';
import '../../services/subtitle_appearance_settings.dart';
import '../../services/update/update_service.dart';
import '../../player/models/subtitle_appearance.dart';
import '../../utils/responsive.dart';
import '../../utils/bottom_clearance.dart';
import '../../widgets/common/broom_icon.dart';
import '../../widgets/common/dustbin_icon.dart';
import '../../widgets/common/collapsing_screen_label.dart';
import '../../widgets/common/pressable.dart';
import '../../widgets/common/storage_usage_card.dart';
import 'parental_controls_screen.dart';
import '../../services/parental/parental_controls.dart';
import 'subtitle_style_screen.dart';

const _gold = Color(0xffD4AF37);
const _bg = Color(0xff161616);
const _cardBg = Color(0xff1F1F1F);

/// Every app-level setting lives here (as opposed to Profile & Settings,
/// which is about the signed-in account/server). Reached via the
/// "Settings" entry on Profile & Settings.
class AppSettingsScreen extends StatefulWidget {
  const AppSettingsScreen({super.key});

  @override
  State<AppSettingsScreen> createState() => _AppSettingsScreenState();
}

class _AppSettingsScreenState extends State<AppSettingsScreen> {
  bool _busy = false;

  // Lets _clearCache tell the storage breakdown card below to recompute
  // once clearing finishes, so its numbers reflect the freed space
  // immediately instead of staying stale until Settings is reopened.
  final _storageCardKey = GlobalKey<StorageUsageCardState>();

  /// Clears everything the app caches locally: cached images
  /// (CachedNetworkImage/flutter_cache_manager), the OS temp directory
  /// (also used as mpv's stream cache dir), and the Home/Live TV
  /// stale-while-revalidate payloads. Login and downloaded media are left
  /// untouched — this only clears content that can be safely re-fetched.
  Future<void> _clearCache() async {
    final confirmed = await _confirm(
      title: "Clear Cache",
      message: "This clears cached images and temporary data to free up "
          "space. Your downloads and login stay untouched.",
      confirmLabel: "Clear",
    );
    if (confirmed != true) return;

    final messenger = ScaffoldMessenger.of(context);
    setState(() => _busy = true);

    try {
      await DefaultCacheManager().emptyCache();
      await NemesisImageCache.instance.emptyCache();
      await _clearTemporaryDirectory();
      await StorageService.clearAppDataCache();

      if (!mounted) return;
      messenger.showSnackBar(
        const SnackBar(content: Text("Cache cleared")),
      );
      unawaited(_storageCardKey.currentState?.refresh());
    } catch (e) {
      if (!mounted) return;
      messenger.showSnackBar(
        const SnackBar(content: Text("Couldn't fully clear cache")),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Best-effort delete of every entry in the temp dir. Entries are
  /// removed one at a time so a single locked/in-use file can't abort
  /// the rest of the cleanup.
  Future<void> _clearTemporaryDirectory() async {
    try {
      final dir = await getTemporaryDirectory();
      if (!await dir.exists()) return;
      await for (final entity in dir.list()) {
        try {
          await entity.delete(recursive: true);
        } catch (_) {
          // Skip files that are locked/in use — non-fatal.
        }
      }
    } catch (_) {
      // No temp dir access on this platform/build — non-fatal.
    }
  }

  /// Deletes every downloaded movie, episode, and song, cancelling any
  /// still in progress. Cache and login are left untouched — mirrors
  /// _clearCache's confirm-dialog + snackbar + storage-card-refresh
  /// pattern, just pointed at DownloadManager instead of the caches.
  Future<void> _removeAllDownloads() async {
    final confirmed = await _confirm(
      title: "Remove All Downloads",
      message: "This deletes every downloaded movie, episode, and song "
          "from this device. This can't be undone.",
      confirmLabel: "Remove",
      destructive: true,
    );
    if (confirmed != true) return;

    final messenger = ScaffoldMessenger.of(context);
    setState(() => _busy = true);

    try {
      await DownloadManager.instance.deleteAllDownloads();

      if (!mounted) return;
      messenger.showSnackBar(
        const SnackBar(content: Text("All downloads removed")),
      );
      unawaited(_storageCardKey.currentState?.refresh());
    } catch (e) {
      if (!mounted) return;
      messenger.showSnackBar(
        const SnackBar(content: Text("Couldn't fully remove downloads")),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Settings > About > Check for Updates. Asks the in-app updater
  /// (UpdateService) for the newest release. When there is one, the same
  /// update popup the app shows on launch opens (it lives above the whole app,
  /// see UpdateGate); every other outcome is reported here.
  Future<void> _checkForUpdates() async {
    if (_busy) return;
    setState(() => _busy = true);

    final result = await UpdateService.instance.check(manual: true);

    if (!mounted) return;
    setState(() => _busy = false);

    switch (result.outcome) {
      case UpdateCheckOutcome.available:
        return; // the update popup is showing
      case UpdateCheckOutcome.upToDate:
        await _infoDialog(
          title: "You're up to date",
          message:
              "Trigon ${UpdateService.instance.currentVersion} is the latest version.",
        );
        return;
      case UpdateCheckOutcome.failed:
        await _infoDialog(
          title: "Couldn't check for updates",
          message: result.message ?? "Please try again in a moment.",
        );
        return;
      case UpdateCheckOutcome.notConfigured:
      case UpdateCheckOutcome.unsupported:
        await _infoDialog(
          title: "Updates unavailable",
          message: result.message ?? "Updates are not available here.",
        );
        return;
    }
  }

  Future<void> _infoDialog({required String title, required String message}) {
    return showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: _cardBg,
        title: Text(title, style: const TextStyle(color: Colors.white)),
        content: Text(message, style: const TextStyle(color: Colors.white70)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text("OK", style: TextStyle(color: _gold)),
          ),
        ],
      ),
    );
  }

  Future<bool?> _confirm({
    required String title,
    required String message,
    required String confirmLabel,
    bool destructive = false,
  }) {
    return showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: _cardBg,
        title: Text(title, style: const TextStyle(color: Colors.white)),
        content: Text(
          message,
          style: const TextStyle(color: Colors.white70),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text("Cancel", style: TextStyle(color: Colors.white54)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(
              confirmLabel,
              style: TextStyle(
                color: destructive ? Colors.redAccent : _gold,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
        ],
      ),
    );
  }

  String _qualityModeLabel(PlaybackQualityMode mode) {
    switch (mode) {
      case PlaybackQualityMode.dataSaver:
        return "Data Saver";
      case PlaybackQualityMode.standard:
        return "Default";
      case PlaybackQualityMode.maxQuality:
        return "Max Quality";
    }
  }

  String _qualityModeSubtitle(PlaybackQualityMode mode) {
    switch (mode) {
      case PlaybackQualityMode.dataSaver:
        return "Always streams at a reduced quality"
            "to save data, regardless of your connection";
      case PlaybackQualityMode.standard:
        return "Automatically adjusts video and music quality to your "
            "current network conditions";
      case PlaybackQualityMode.maxQuality:
        return "Always streams at the best available quality, "
            "regardless of your connection";
    }
  }

  /// Short one-line summary shown on the Settings row itself — same
  /// wording as the dialog's subtitle, just condensed to fit one line.
  String _qualityModeSummary(PlaybackQualityMode mode) {
    switch (mode) {
      case PlaybackQualityMode.dataSaver:
        return "Data Saver, always reduced quality";
      case PlaybackQualityMode.standard:
        return "Default, adapts to your network";
      case PlaybackQualityMode.maxQuality:
        return "Max Quality, always the best available";
    }
  }

  Future<void> _editPlaybackQualityMode() async {
    final current = AppSettings.playbackQualityMode.value;

    final selected = await showDialog<PlaybackQualityMode>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: _cardBg,
        title: const Text(
          "Streaming Quality",
          style: TextStyle(color: Colors.white),
        ),
        contentPadding: const EdgeInsets.symmetric(vertical: 12),
        content: SizedBox(
          width: double.maxFinite,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final mode in PlaybackQualityMode.values)
                RadioListTile<PlaybackQualityMode>(
                  value: mode,
                  groupValue: current,
                  activeColor: _gold,
                  onChanged: (value) => Navigator.pop(context, value),
                  title: Text(
                    _qualityModeLabel(mode),
                    style: const TextStyle(color: Colors.white),
                  ),
                  subtitle: Text(
                    _qualityModeSubtitle(mode),
                    style: const TextStyle(
                      color: Colors.white54,
                      fontSize: 12,
                    ),
                  ),
                ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text(
              "Cancel",
              style: TextStyle(color: Colors.white54),
            ),
          ),
        ],
      ),
    );

    if (selected != null && selected != current) {
      await AppSettings.setPlaybackQualityMode(selected);
    }
  }

  String _sourceModeLabel(PlaybackSourceMode mode) {
    switch (mode) {
      case PlaybackSourceMode.addons:
        return "Default";
      case PlaybackSourceMode.embed:
        return "Embed Servers";
    }
  }

  String _sourceModeSubtitle(PlaybackSourceMode mode) {
    switch (mode) {
      case PlaybackSourceMode.addons:
        return "Plays links in the native player, with its own "
            "quality options";
      case PlaybackSourceMode.embed:
        return "Plays server links in a web player. Quality is chosen in "
            "the server's own player";
    }
  }

  String _sourceModeSummary(PlaybackSourceMode mode) {
    switch (mode) {
      case PlaybackSourceMode.addons:
        return "Default, native player";
      case PlaybackSourceMode.embed:
        return "Embed servers, web player";
    }
  }

  String _embedServerLabel(EmbedServer server) {
    switch (server) {
      case EmbedServer.vidfast:
        return "Vidfast";
      case EmbedServer.vidsrc:
        return "Vidsrc";
      case EmbedServer.vidlink:
        return "VidLink";
    }
  }

  String _embedServerSubtitle(EmbedServer server) {
    switch (server) {
      case EmbedServer.vidfast:
        return "Supports resume, watch progress and next episode";
      case EmbedServer.vidsrc:
        return "No resume or watch progress tracking";
      case EmbedServer.vidlink:
        return "Rich in anime. Supports resume, watch progress and next episode";
    }
  }

  Future<void> _editPlaybackSourceMode() async {
    final current = AppSettings.playbackSourceMode.value;

    final selected = await showDialog<PlaybackSourceMode>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: _cardBg,
        title: const Text(
          "Playback Source",
          style: TextStyle(color: Colors.white),
        ),
        contentPadding: const EdgeInsets.symmetric(vertical: 12),
        content: SizedBox(
          width: double.maxFinite,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final mode in PlaybackSourceMode.values)
                RadioListTile<PlaybackSourceMode>(
                  value: mode,
                  groupValue: current,
                  activeColor: _gold,
                  onChanged: (value) => Navigator.pop(context, value),
                  title: Text(
                    _sourceModeLabel(mode),
                    style: const TextStyle(color: Colors.white),
                  ),
                  subtitle: Text(
                    _sourceModeSubtitle(mode),
                    style: const TextStyle(
                      color: Colors.white54,
                      fontSize: 12,
                    ),
                  ),
                ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text(
              "Cancel",
              style: TextStyle(color: Colors.white54),
            ),
          ),
        ],
      ),
    );

    if (selected != null && selected != current) {
      await AppSettings.setPlaybackSourceMode(selected);
    }
  }

  Future<void> _editEmbedServer() async {
    final current = AppSettings.embedServer.value;

    final selected = await showDialog<EmbedServer>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: _cardBg,
        title: const Text(
          "Embed Server",
          style: TextStyle(color: Colors.white),
        ),
        contentPadding: const EdgeInsets.symmetric(vertical: 12),
        content: SizedBox(
          width: double.maxFinite,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final server in EmbedServer.values)
                RadioListTile<EmbedServer>(
                  value: server,
                  groupValue: current,
                  activeColor: _gold,
                  onChanged: (value) => Navigator.pop(context, value),
                  title: Text(
                    _embedServerLabel(server),
                    style: const TextStyle(color: Colors.white),
                  ),
                  subtitle: Text(
                    _embedServerSubtitle(server),
                    style: const TextStyle(
                      color: Colors.white54,
                      fontSize: 12,
                    ),
                  ),
                ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text(
              "Cancel",
              style: TextStyle(color: Colors.white54),
            ),
          ),
        ],
      ),
    );

    if (selected != null && selected != current) {
      await AppSettings.setEmbedServer(selected);
    }
  }

  @override
  Widget build(BuildContext context) {
    // LabelCollapseScope: the "Settings" app bar slides away on scroll
    // down and returns on scroll up (see collapsing_screen_label.dart).
    return LabelCollapseScope(
      child: Scaffold(
      backgroundColor: _bg,
      // primary: false — CollapsibleAppBar supplies the status-bar inset
      // itself so the bar can collapse down to just that inset.
      appBar: CollapsibleAppBar(
        child: AppBar(
          primary: false,
          backgroundColor: _bg,
          title: const Text("Settings", style: TextStyle(color: Colors.white)),
        ),
      ),
      body: AbsorbPointer(
        absorbing: _busy,
        // Same tablet/TV max-width treatment as Profile & Settings —
        // see the comment there. No-op on phones since
        // constrainedContentWidth returns the full available width
        // below the 700 ceiling.
        child: Align(
          alignment: Alignment.topCenter,
          child: SizedBox(
            width: Responsive.constrainedContentWidth(context, maxWidth: 700),
            // BottomClearanceBuilder so the form's trailing padding
            // reactively clears the main nav's floating bottom bar
            // (mini player + tab bar in portrait) — MainNavScreen
            // paints that bar in a plain Stack, not a real
            // Scaffold.extendBody (see its own doc comment for why),
            // so nothing here happens automatically the way SafeArea
            // would for a system inset.
            child: BottomClearanceBuilder(
              builder: (context, bottomClearance) => ListView(
              padding: EdgeInsets.fromLTRB(
                20, 24, 20,
                40 + MediaQuery.paddingOf(context).bottom + bottomClearance,
              ),
              children: [
                _sectionLabel("Playback"),
            const SizedBox(height: 10),
            ValueListenableBuilder<bool>(
              valueListenable: AppSettings.autoQueueRecommendations,
              builder: (context, enabled, _) {
                return _toggleTile(
                  icon: Icons.queue_music,
                  label: "Auto-Queue Recommendations",
                  subtitle: enabled
                      ? "When a movie or tv show ends, similar titles are recommended to watch"
                      : "Playback stops when the queue ends",
                  value: enabled,
                  onChanged: (value) {
                    AppSettings.setAutoQueueRecommendations(value);
                  },
                );
              },
            ),
            const SizedBox(height: 24),
            _sectionLabel("Subtitles"),
            const SizedBox(height: 10),
            ValueListenableBuilder<SubtitleAppearance>(
              valueListenable: SubtitleAppearanceSettings.notifier,
              builder: (context, a, _) {
                return _settingsTile(
                  icon: Icons.closed_caption_outlined,
                  label: "Subtitle Style",
                  subtitle: a.isDefault
                      ? "Default, customize color, size, font and position"
                      : "Customized, applies in the player and on your TV",
                  onTap: () {
                    Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) => const SubtitleStyleScreen(),
                      ),
                    );
                  },
                );
              },
            ),
            const SizedBox(height: 24),
            _sectionLabel("Data Usage"),
            const SizedBox(height: 10),
            ValueListenableBuilder<PlaybackQualityMode>(
              valueListenable: AppSettings.playbackQualityMode,
              builder: (context, mode, _) {
                return _settingsTile(
                  icon: Icons.network_check,
                  label: "Streaming Quality",
                  subtitle: _qualityModeSummary(mode),
                  onTap: _editPlaybackQualityMode,
                );
              },
            ),
            const SizedBox(height: 10),
            ValueListenableBuilder<bool>(
              valueListenable: AppSettings.autoLinkSelection,
              builder: (context, enabled, _) {
                return _toggleTile(
                  icon: Icons.auto_awesome,
                  label: "Auto-Select Link",
                  subtitle: enabled
                      ? "Plays the best link for your streaming quality, "
                          "skipping the link list"
                      : "Shows the link list so you pick a link each time",
                  value: enabled,
                  onChanged: (value) {
                    AppSettings.setAutoLinkSelection(value);
                  },
                );
              },
            ),
            const SizedBox(height: 24),
            _sectionLabel("Playback Source"),
            const SizedBox(height: 10),
            ValueListenableBuilder<PlaybackSourceMode>(
              valueListenable: AppSettings.playbackSourceMode,
              builder: (context, source, _) {
                return Column(
                  children: [
                    _settingsTile(
                      icon: Icons.swap_horiz,
                      label: "Playback Source",
                      subtitle: _sourceModeSummary(source),
                      onTap: _editPlaybackSourceMode,
                    ),
                    if (source == PlaybackSourceMode.embed) ...[
                      const SizedBox(height: 10),
                      ValueListenableBuilder<EmbedServer>(
                        valueListenable: AppSettings.embedServer,
                        builder: (context, server, _) {
                          return _settingsTile(
                            icon: Icons.dns_outlined,
                            label: "Embed Server",
                            subtitle: _embedServerLabel(server),
                            onTap: _editEmbedServer,
                          );
                        },
                      ),
                      const SizedBox(height: 10),
                      ValueListenableBuilder<bool>(
                        valueListenable: AppSettings.embedAdBlock,
                        builder: (context, enabled, _) {
                          return _toggleTile(
                            icon: Icons.block,
                            label: "Block Embed Ads",
                            subtitle: enabled
                                ? "Blocks the ads embed servers try to show "
                                    "(applies the next time a video opens)"
                                : "Embed servers show their own ads",
                            value: enabled,
                            onChanged: (value) {
                              AppSettings.setEmbedAdBlock(value);
                            },
                          );
                        },
                      ),
                    ],
                  ],
                );
              },
            ),
            const SizedBox(height: 24),
            _sectionLabel("Family"),
            const SizedBox(height: 10),
            ValueListenableBuilder(
              valueListenable: ParentalControls.instance.settings,
              builder: (context, _, __) => ValueListenableBuilder(
                valueListenable: ParentalControls.instance.pausedUntil,
                builder: (context, _, __) => _settingsTile(
                  icon: Icons.shield_outlined,
                  label: "Parental Controls",
                  subtitle: ParentalControls.instance.summary,
                  onTap: () {
                    Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) => const ParentalControlsScreen(),
                      ),
                    );
                  },
                ),
              ),
            ),
            const SizedBox(height: 24),
            _sectionLabel("Storage"),
            const SizedBox(height: 10),
            StorageUsageCard(key: _storageCardKey),
            const SizedBox(height: 10),
            ValueListenableBuilder<bool>(
              valueListenable: AppSettings.shareUsageData,
              builder: (context, enabled, _) {
                return _toggleTile(
                  icon: Icons.insights_outlined,
                  label: "Share Usage Data",
                  subtitle: enabled
                      ? "Anonymous stats help improve the app"
                      : "No usage data is collected",
                  value: enabled,
                  onChanged: (value) {
                    AppSettings.setShareUsageData(value);
                  },
                );
              },
            ),
            const SizedBox(height: 10),
            ValueListenableBuilder<bool>(
              valueListenable: AppSettings.downloadWifiOnly,
              builder: (context, enabled, _) {
                return _toggleTile(
                  icon: Icons.wifi,
                  label: "Download on Wi-Fi Only",
                  subtitle: enabled
                      ? "Downloads wait for Wi-Fi and never use mobile data"
                      : "Downloads also use mobile data",
                  value: enabled,
                  onChanged: (value) {
                    AppSettings.setDownloadWifiOnly(value);
                  },
                );
              },
            ),
            const SizedBox(height: 10),
            _settingsTile(
              customIcon: const BroomIcon(size: 22),
              label: "Clear Cache",
              subtitle: "Free up space used by cached images and data",
              onTap: _clearCache,
            ),
            const SizedBox(height: 10),
            _settingsTile(
              customIcon: const DustbinIcon(
                size: 22,
                sweep: true,
                color: Colors.redAccent,
              ),
              label: "Remove All Downloads",
              subtitle: "Delete every downloaded movie, episode, and song",
              onTap: _removeAllDownloads,
              destructive: true,
            ),
            const SizedBox(height: 24),
            _sectionLabel("About"),
            const SizedBox(height: 10),
            ListenableBuilder(
              listenable: UpdateService.instance,
              builder: (context, _) {
                final updater = UpdateService.instance;
                final available = updater.info;
                final version = updater.currentVersion;
                final String subtitle;
                if (updater.checking) {
                  subtitle = "Checking for updates...";
                } else if (available != null) {
                  subtitle =
                      "Version ${available.latest.version} is available - tap to update";
                } else if (version.isEmpty) {
                  subtitle = "Look for a newer version of Trigon";
                } else {
                  subtitle = "You're on version $version";
                }
                return _settingsTile(
                  icon: available != null
                      ? Icons.system_update_alt_rounded
                      : Icons.cloud_download_outlined,
                  label: "Check for Updates",
                  subtitle: subtitle,
                  onTap: _checkForUpdates,
                );
              },
            ),
              ],
            ),
            ),
          ),
        ),
      ),
      ),
    );
  }

  Widget _sectionLabel(String text) {
    return Text(
      text.toUpperCase(),
      style: const TextStyle(
        color: Colors.white38,
        fontSize: 12,
        fontWeight: FontWeight.w600,
        letterSpacing: 0.8,
      ),
    );
  }

  Widget _settingsTile({
    IconData? icon,
    Widget? customIcon,
    required String label,
    required String subtitle,
    required VoidCallback onTap,
    bool destructive = false,
  }) {
    final color = destructive ? Colors.redAccent : Colors.white;

    return Pressable(
      onTap: onTap,
      borderRadius: BorderRadius.circular(14),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        decoration: BoxDecoration(
          color: _cardBg,
          borderRadius: BorderRadius.circular(14),
        ),
        child: Row(
          children: [
            customIcon ?? Icon(icon, color: color, size: 22),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    label,
                    style: TextStyle(
                      color: color,
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    subtitle,
                    style: const TextStyle(color: Colors.white38, fontSize: 12),
                  ),
                ],
              ),
            ),
            const Icon(Icons.chevron_right, color: Colors.white24, size: 20),
          ],
        ),
      ),
    );
  }

  /// Same visual shell as [_settingsTile], but with a Switch instead of
  /// a chevron, and the whole row toggles the switch when tapped.
  Widget _toggleTile({
    required IconData icon,
    required String label,
    required String subtitle,
    required bool value,
    required ValueChanged<bool> onChanged,
  }) {
    return Pressable(
      onTap: () => onChanged(!value),
      borderRadius: BorderRadius.circular(14),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        decoration: BoxDecoration(
          color: _cardBg,
          borderRadius: BorderRadius.circular(14),
        ),
        child: Row(
          children: [
            Icon(icon, color: Colors.white, size: 22),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    label,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    subtitle,
                    style: const TextStyle(color: Colors.white38, fontSize: 12),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Switch(
              value: value,
              onChanged: onChanged,
              activeColor: _gold,
            ),
          ],
        ),
      ),
    );
  }
}
