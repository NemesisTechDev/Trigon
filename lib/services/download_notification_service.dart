import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:ui' show IsolateNameServer;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:path_provider/path_provider.dart';

import 'download_manager.dart';
import 'external_media_handler.dart';
import 'live_tv_reminder_service.dart';
import '../screens/main_nav/navigation_controller.dart';

const _gold = Color(0xffD4AF37);

/// Puts download activity in the device's notification shade — queued,
/// downloading (live progress + speed), paused, failed, and completed —
/// the same states [DownloadManager] already tracks for the in-app
/// Downloads page and the floating summary pill, just mirrored out to
/// the system tray the way Netflix/Spotify/Play Store do it.
///
/// Two Android channels, deliberately kept separate:
///  - [_progressChannelId]: silent, low-importance — this is the one
///    that updates every second or so while a transfer runs, and a
///    channel that pings on every one of those updates is exactly the
///    kind of thing people mute wholesale. Queued/downloading/paused
///    all live here, upserted onto the same notification id per item so
///    a transfer's whole lifecycle (until it finishes or fails) is one
///    notification that changes in place, not a stack of new ones.
///  - [_completeChannelId]: normal importance — the two moments a
///    person actually wants a ping for (a download finished, or one
///    needs attention because it failed), each posted as its own,
///    separate, swipeable notification.
///
/// The in-progress notifications share [_groupKey] with an aggregate
/// summary (`updateSummary`) so multiple in-flight downloads collapse
/// into one stack in the shade, the same way a stack of chat messages
/// does — expandable to the individual items, collapsed to one line
/// otherwise. Completed/failed notifications deliberately use
/// [_completeGroupKey] instead, a separate group with no summary of its
/// own: cancelling a group's summary also cancels every notification
/// sharing that group, and `updateSummary` cancels [_groupKey]'s summary
/// the instant no downloads are left active/queued — which, downloading
/// one at a time, is right after every completion. Sharing [_groupKey]
/// used to mean a completed/failed notification could get wiped out by
/// that same cancel a beat after being posted, before it was ever seen.
///
/// Tapping any notification from this service switches MainNavScreen to
/// its Downloads tab (rather than pushing a second DownloadsScreen over
/// everything, which hid the nav bar/rail and mini player), landing on
/// the Movies / TV Shows / Music sub-tab matching the item — carried in
/// each notification's payload. A tapped completed/failed notification
/// is also cleared from the shade. Full
/// pause/resume/retry/cancel controls already live there, so
/// there's no need to duplicate that as fiddly notification action
/// buttons that would silently stop doing anything the moment Android
/// has suspended the app process a transfer was quietly relying on
/// staying alive.
/// Name under which the main isolate registers the port that notification
/// buttons (Pause / Resume / Cancel) are forwarded to.
const String _kActionPortName = 'nemesis_download_notification_actions';

/// Runs when a Pause / Resume / Cancel button on a download notification is
/// tapped. The plugin calls this in a separate background isolate, which has
/// no access to the download manager, so it just forwards the action to the
/// main isolate (kept alive by the download service).
@pragma('vm:entry-point')
void downloadNotificationBackground(NotificationResponse response) {
  final action = response.actionId;
  if (action == null || action.isEmpty) return;
  IsolateNameServer.lookupPortByName(_kActionPortName)?.send(action);
}

class DownloadNotificationService {
  DownloadNotificationService._();
  static final DownloadNotificationService instance =
      DownloadNotificationService._();

  static const _progressChannelId = 'nemesis_downloads_progress';
  static const _completeChannelId = 'nemesis_downloads_complete';
  static const _groupKey = 'com.nemesis.app.downloads';
  // Deliberately separate from _groupKey: onCompleted/onFailed notifications
  // must outlive whatever's currently downloading, but _groupKey's summary
  // gets cancelled by updateSummary() the moment the active/queued count
  // hits zero — and cancelling a group's summary cancels every notification
  // sharing that group with it on Android. Keeping completed/failed
  // notifications on their own group means that cancel never touches them.
  static const _completeGroupKey = 'com.nemesis.app.downloads.complete';

  // Fixed id reserved for the group summary notification. `_idFor`
  // below always clears this value's low bit when masking a hash, so a
  // real per-item id can structurally never collide with it — no
  // separate collision check needed.
  static const _summaryId = 0x7ffffffe;

  final _plugin = FlutterLocalNotificationsPlugin();
  bool _initialized = false;

  /// Native side (DownloadNotifications.kt): draws the queued / running /
  /// paused notifications and reports taps on their Pause / Resume / Cancel
  /// buttons and on their body straight back here, in this isolate.
  static const MethodChannel _native =
      MethodChannel('com.nemesis.app/download_notifications');

  // Resolved once at init — the same app-documents "downloads/art_*.jpg"
  // cache DownloadManager._downloadImage writes/reads, so a poster
  // fetched for one episode is immediately available (no extra network
  // call) as another item's notification artwork, series art already
  // being shared across a season's episodes exactly like it is in the
  // Downloads page itself.
  String? _artCacheDir;

  // Per-id throttle so the ~2.5 progress ticks/sec DownloadManager
  // already rate-limits internally don't also hammer the OS with a
  // system-notification update every single one of them — Android
  // itself rate-limits notification updates similarly, so anything
  // faster than this just gets silently dropped by the system anyway.
  final Map<String, DateTime> _lastProgressPost = {};
  static const _progressThrottle = Duration(milliseconds: 1200);

  Future<void> init() async {
    if (_initialized) return;
    _initialized = true;

    try {
      final docsDir = await getApplicationDocumentsDirectory();
      _artCacheDir = '${docsDir.path}/downloads';
    } catch (_) {
      // Falls back to "no cached art" below if this ever fails — a
      // missing thumbnail is a cosmetic downgrade, not a reason to lose
      // download notifications entirely.
    }

    // Android-only app (see pubspec/project notes) — no iOS
    // InitializationSettings needed. 'ic_notification' is the same
    // status-bar-safe monochrome drawable audio_service already uses
    // for the "now playing" notification (see main.dart's
    // AudioServiceConfig.androidNotificationIcon), so no new native
    // asset is required for this service to draw its own icon.
    const androidInit = AndroidInitializationSettings('ic_notification');

    await _plugin.initialize(
      settings: const InitializationSettings(android: androidInit),
      onDidReceiveNotificationResponse: _onResponse,
      onDidReceiveBackgroundNotificationResponse:
          downloadNotificationBackground,
    );

    // Buttons on the notifications arrive here (see the top-level handler).
    final port = ReceivePort();
    IsolateNameServer.removePortNameMapping(_kActionPortName);
    IsolateNameServer.registerPortWithName(port.sendPort, _kActionPortName);
    port.listen((message) {
      if (message is String) _handleAction(message);
    });

    _native.setMethodCallHandler((call) async {
      final arg = call.arguments;
      switch (call.method) {
        case 'action':
          if (arg is String) _handleAction(arg);
          break;
        case 'open':
          _openDownloads(
            tab: (arg is String && arg.isNotEmpty) ? arg : null,
          );
          break;
      }
      return null;
    });

    final androidPlugin = _plugin.resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin>();

    await androidPlugin?.createNotificationChannel(
      const AndroidNotificationChannel(
        _progressChannelId,
        'Download progress',
        description: 'Queued, downloading, and paused downloads.',
        importance: Importance.low,
        playSound: false,
        enableVibration: false,
        showBadge: false,
      ),
    );

    await androidPlugin?.createNotificationChannel(
      const AndroidNotificationChannel(
        _completeChannelId,
        'Download updates',
        description: 'Lets you know when a download finishes or fails.',
        importance: Importance.defaultImportance,
      ),
    );

    // Cold start via tapping a notification: no live NavigatorState
    // exists yet at this point, so this just remembers the intent —
    // ExternalMediaHandler.init (called after the first frame, same as
    // this app's other "did the OS launch us for a reason" check)
    // handles the deep link itself; here it's enough to know a launch
    // came from this plugin at all before opening Downloads.
    final launchDetails = await _plugin.getNotificationAppLaunchDetails();
    if (launchDetails?.didNotificationLaunchApp ?? false) {
      final response = launchDetails?.notificationResponse;
      WidgetsBinding.instance.addPostFrameCallback((_) => _onResponse(response));
    }
  }

  // Payload format: "<downloads tab name>" for in-progress notifications
  // (which must stay in the shade after a tap — the transfer is still
  // running), "<downloads tab name>$_clearSuffix" for completed/failed
  // ones (which should disappear once tapped).
  static const _clearSuffix = ':clear';

  String _tabFor(DownloadKind kind) => switch (kind) {
        DownloadKind.movie => 'movies',
        DownloadKind.episode => 'shows',
        DownloadKind.song => 'music',
      };

  static const _pauseAction = 'pause:';
  static const _resumeAction = 'resume:';
  static const _cancelAction = 'cancel:';

  /// "pause:<download id>" and friends, from the notification buttons.
  void _handleAction(String action) {
    final manager = DownloadManager.instance;
    if (action.startsWith(_pauseAction)) {
      manager.pauseDownload(action.substring(_pauseAction.length));
    } else if (action.startsWith(_resumeAction)) {
      manager.resumeDownload(action.substring(_resumeAction.length));
    } else if (action.startsWith(_cancelAction)) {
      manager.cancelDownload(action.substring(_cancelAction.length));
    }
  }

  AndroidNotificationAction _button(String verb, String title, String id) =>
      AndroidNotificationAction(
        '$verb$id',
        title,
        // Handled quietly in the background: no screen opens, and the
        // notification stays (the manager updates or removes it itself).
        showsUserInterface: false,
        cancelNotification: false,
      );

  void _onResponse(NotificationResponse? response) {
    final action = response?.actionId;
    if (action != null && action.isNotEmpty) {
      _handleAction(action);
      return;
    }
    final payload = response?.payload;
    // The plugin is a singleton with ONE tap callback (this one), so Live
    // TV reminder taps arrive here too — hand them off before the
    // Downloads routing below would swallow them.
    if (LiveTvReminderService.isReminderPayload(payload)) {
      LiveTvReminderService.instance.handleTap(payload!);
      return;
    }
    final clear = payload != null && payload.endsWith(_clearSuffix);
    final tab = payload == null
        ? null
        : (clear
            ? payload.substring(0, payload.length - _clearSuffix.length)
            : payload);

    final id = response?.id;
    if (clear && id != null) unawaited(_plugin.cancel(id: id));

    _openDownloads(tab: (tab == null || tab.isEmpty) ? null : tab);
  }

  void _openDownloads({String? tab}) {
    // Anything sitting on the ROOT navigator above MainNavScreen (the
    // full-screen audio/video player, a sheet, a dialog) would hide the
    // Downloads tab even after switching to it — clear those first.
    // MainNavScreen itself is the first route, so it's never popped.
    ExternalMediaHandler.instance.navigatorKey.currentState
        ?.popUntil((route) => route.isFirst);
    NavigationController.instance.openDownloads(tab: tab);
  }

  // ────────────────────────────── Per-item ──────────────────────────────

  /// Stable positive id for [downloadId]'s ongoing (queued/downloading/
  /// paused) notification. [salt] gives the one-off "completed"/"failed"
  /// notification for the same download its own, distinct id, so it can
  /// be posted a beat before the ongoing one is cancelled without one
  /// clobbering the other mid-transition.
  int _idFor(String downloadId, [String salt = '']) =>
      ('$downloadId:$salt').hashCode & 0x7ffffffd;

  String? _artPathFor(String imageId) {
    final dir = _artCacheDir;
    if (dir == null) return null;
    final path = '$dir/art_$imageId.jpg';
    return File(path).existsSync() ? path : null;
  }

  AndroidBitmap<Object>? _largeIconFor(String imageId) {
    final dir = _artCacheDir;
    if (dir == null) return null;
    final path = '$dir/art_$imageId.jpg';
    if (!File(path).existsSync()) return null;
    return FilePathAndroidBitmap(path);
  }

  String _fmtBytes(int bytes) {
    if (bytes <= 0) return '0 MB';
    const kb = 1024;
    const mb = kb * 1024;
    const gb = mb * 1024;
    if (bytes >= gb) return '${(bytes / gb).toStringAsFixed(1)} GB';
    return '${(bytes / mb).toStringAsFixed(0)} MB';
  }

  String _fmtSpeed(double bps) {
    if (bps <= 0) return '';
    const kb = 1024;
    const mb = kb * 1024;
    if (bps >= mb) return '${(bps / mb).toStringAsFixed(1)} MB/s';
    return '${(bps / kb).toStringAsFixed(0)} KB/s';
  }

  Future<void> _showOngoing(
    DownloadTask task, {
    required String text,
    bool ongoing = false,
    bool showProgress = false,
    int progress = 0,
    bool indeterminate = false,
    List<AndroidNotificationAction> actions = const [],
  }) async {
    // Preferred: the native notification, whose buttons reach this app
    // directly. The plugin below is only the fallback when that is missing.
    if (Platform.isAndroid) {
      try {
        await _native.invokeMethod<bool>('show', {
          'id': _idFor(task.id),
          'title': task.title,
          'text': text,
          'progress': showProgress ? (indeterminate ? -2 : progress) : -1,
          'ongoing': ongoing,
          'tab': _tabFor(task.kind),
          'subText': task.subtitle.isNotEmpty ? task.subtitle : null,
          'largeIcon': _artPathFor(task.imageId),
          'group': _groupKey,
          'buttons': [
            for (final a in actions) {'id': a.id, 'label': a.title},
          ],
        });
        return;
      } on MissingPluginException {
        // fall through to the plugin
      } on PlatformException catch (e) {
        debugPrint('[DownloadNotifications] native show failed: ${e.message}');
      }
    }

    final details = AndroidNotificationDetails(
      _progressChannelId,
      'Download progress',
      channelDescription: 'Queued, downloading, and paused downloads.',
      importance: Importance.low,
      priority: Priority.low,
      onlyAlertOnce: true,
      ongoing: ongoing,
      autoCancel: !ongoing,
      showProgress: showProgress,
      maxProgress: 100,
      progress: progress,
      indeterminate: indeterminate,
      playSound: false,
      enableVibration: false,
      color: _gold,
      groupKey: _groupKey,
      category: AndroidNotificationCategory.progress,
      visibility: NotificationVisibility.public,
      subText: task.subtitle.isNotEmpty ? task.subtitle : null,
      largeIcon: _largeIconFor(task.imageId),
      styleInformation: BigTextStyleInformation(text),
      actions: actions,
    );

    await _plugin.show(
      id: _idFor(task.id),
      title: task.title,
      body: text,
      notificationDetails: NotificationDetails(android: details),
      payload: _tabFor(task.kind),
    );
  }

  void onQueued(DownloadTask task, int? position) {
    final text = position != null
        ? 'Waiting to download • #$position in queue'
        : 'Waiting to download';
    unawaited(_showOngoing(
      task,
      text: text,
      actions: [_button(_cancelAction, 'Cancel', task.id)],
    ));
  }

  void onStarted(DownloadTask task) {
    // Posted immediately (unthrottled) so the notification appears the
    // instant a transfer actually begins, rather than waiting for the
    // first throttled progress tick.
    _lastProgressPost[task.id] = DateTime.now();
    final hasTotal = task.totalBytes > 0;
    final text = hasTotal
        ? '0% • ${_fmtBytes(task.totalBytes)}'
        : 'Starting download…';
    unawaited(_showOngoing(
      task,
      text: text,
      ongoing: true,
      showProgress: true,
      indeterminate: !hasTotal,
      actions: _runningButtons(task),
    ));
  }

  List<AndroidNotificationAction> _runningButtons(DownloadTask task) => [
        _button(_pauseAction, 'Pause', task.id),
        _button(_cancelAction, 'Cancel', task.id),
      ];

  /// Called on every internal progress tick — throttled here so it only
  /// actually touches the system notification a couple of times a
  /// second at most.
  void onProgress(DownloadTask task) {
    // A tick that arrives after the download was paused, cancelled or failed
    // must not bring the running notification back.
    if (DownloadManager.instance.stateOf(task.id) != DownloadState.downloading) {
      return;
    }
    final now = DateTime.now();
    final last = _lastProgressPost[task.id];
    if (last != null && now.difference(last) < _progressThrottle) return;
    _lastProgressPost[task.id] = now;

    final hasTotal = task.totalBytes > 0;
    final percent = hasTotal
        ? ((task.downloadedBytes / task.totalBytes) * 100).clamp(0, 100).round()
        : 0;
    final speed = _fmtSpeed(task.speedBps);
    final text = hasTotal
        ? '$percent% • ${_fmtBytes(task.downloadedBytes)} of '
            '${_fmtBytes(task.totalBytes)}'
            '${speed.isNotEmpty ? ' • $speed' : ''}'
        : 'Downloading… ${_fmtBytes(task.downloadedBytes)}'
            '${speed.isNotEmpty ? ' • $speed' : ''}';

    unawaited(_showOngoing(
      task,
      text: text,
      ongoing: true,
      showProgress: true,
      progress: percent,
      indeterminate: !hasTotal,
      actions: _runningButtons(task),
    ));
  }

  void onPaused(DownloadTask task) {
    _lastProgressPost.remove(task.id);
    final hasTotal = task.totalBytes > 0;
    final percent = hasTotal
        ? ((task.downloadedBytes / task.totalBytes) * 100).clamp(0, 100).round()
        : 0;
    final text = hasTotal
        ? 'Paused • $percent% • ${_fmtBytes(task.downloadedBytes)} of '
            '${_fmtBytes(task.totalBytes)}'
        : 'Paused';
    unawaited(_showOngoing(
      task,
      text: text,
      showProgress: hasTotal,
      progress: percent,
      actions: [
        _button(_resumeAction, 'Resume', task.id),
        _button(_cancelAction, 'Cancel', task.id),
      ],
    ));
  }

  Future<void> onFailed(DownloadTask task) async {
    _lastProgressPost.remove(task.id);
    await _plugin.cancel(id: _idFor(task.id));

    final details = AndroidNotificationDetails(
      _completeChannelId,
      'Download updates',
      channelDescription: 'Lets you know when a download finishes or fails.',
      importance: Importance.defaultImportance,
      priority: Priority.defaultPriority,
      autoCancel: true,
      color: _gold,
      groupKey: _completeGroupKey,
      largeIcon: _largeIconFor(task.imageId),
      styleInformation: BigTextStyleInformation(
        task.error ?? 'Tap to open Downloads and try again.',
      ),
    );

    await _plugin.show(
      id: _idFor(task.id, 'failed'),
      title: "Couldn't download ${task.title}",
      body: task.error ?? 'Tap to open Downloads and try again.',
      notificationDetails: NotificationDetails(android: details),
      payload: '${_tabFor(task.kind)}$_clearSuffix',
    );
  }

  /// A deliberate cancel (or a queued/paused item dropped outright) —
  /// just clears whatever notification that download had, nothing else
  /// to say about it.
  void onCancelled(String downloadId) {
    _lastProgressPost.remove(downloadId);
    unawaited(_plugin.cancel(id: _idFor(downloadId)));
  }

  /// A record being deleted from the Downloads page — covers the edge
  /// case of a completed notification still sitting in the shade
  /// (person hasn't opened/swiped it) for something that's since been
  /// removed.
  void onDeleted(String downloadId) {
    unawaited(_plugin.cancel(id: _idFor(downloadId, 'done')));
  }

  Future<void> onCompleted({
    required String id,
    required DownloadKind kind,
    required String title,
    required String subtitle,
    String? posterPath,
  }) async {
    _lastProgressPost.remove(id);
    await _plugin.cancel(id: _idFor(id));

    final hasArt = posterPath != null && File(posterPath).existsSync();
    final icon = hasArt ? FilePathAndroidBitmap(posterPath) : null;

    final kindLabel = switch (kind) {
      DownloadKind.movie => 'Movie',
      DownloadKind.episode => 'Episode',
      DownloadKind.song => 'Song',
    };

    final details = AndroidNotificationDetails(
      _completeChannelId,
      'Download updates',
      channelDescription: 'Lets you know when a download finishes or fails.',
      importance: Importance.defaultImportance,
      priority: Priority.defaultPriority,
      // Tapping it opens Downloads AND removes it from the shade (also
      // cancelled explicitly in _onResponse). Swiping it away still
      // works as usual.
      autoCancel: true,
      color: _gold,
      groupKey: _completeGroupKey,
      largeIcon: icon,
      subText: subtitle.isNotEmpty ? subtitle : kindLabel,
      styleInformation: hasArt
          ? BigPictureStyleInformation(
              FilePathAndroidBitmap(posterPath),
              largeIcon: icon,
              contentTitle: title,
              summaryText: 'Available offline',
              htmlFormatContentTitle: false,
              htmlFormatSummaryText: false,
            )
          : const BigTextStyleInformation('Available offline'),
    );

    // Diagnosed via a temporary try/catch here: show() never threw, so
    // this notification was posting successfully and then getting wiped
    // out — not failing to post. Root cause was `groupKey: _groupKey`,
    // below: that's the same group the progress notifications and their
    // summary use, and Android cancels every notification in a group
    // when its summary is cancelled. updateSummary() cancels the
    // summary the moment no downloads are left active/queued — which,
    // downloading one at a time, is right after every completion — so
    // this notification (and any other still-lingering "done"/"failed"
    // ones sharing that group) vanished a beat after being shown,
    // before it was ever visible. `_completeGroupKey` below decouples
    // this notification's lifecycle from the progress group's summary
    // entirely, so it stays until the person dismisses it themselves as
    // intended.
    await _plugin.show(
      id: _idFor(id, 'done'),
      title: 'Download complete',
      body: title,
      notificationDetails: NotificationDetails(android: details),
      payload: '${_tabFor(kind)}$_clearSuffix',
    );
  }

  // ─────────────────────────────── Summary ───────────────────────────────

  /// Rolls every in-flight download into one collapsed "N downloading"
  /// notification, sharing [_groupKey] with the per-item ones above so
  /// Android stacks them together in the shade instead of listing each
  /// one loose. Cancelled outright once nothing is active or queued —
  /// there's nothing left to summarize.
  Future<void> updateSummary(DownloadManager manager) async {
    final active = manager.downloadingTasks;
    final queued = manager.queuedTasks;
    // Paused downloads count too. Cancelling a group's summary removes every
    // notification in the group, so a summary that disappeared when the last
    // running download was paused took the paused download's own
    // notification (and its Resume button) with it.
    final paused = manager.pausedTasks;
    final count = active.length + queued.length + paused.length;

    if (count == 0) {
      await _plugin.cancel(id: _summaryId);
      return;
    }

    final downloaded = manager.activeDownloadedBytes;
    final total = manager.activeTotalBytes;
    final hasTotal = total > 0;
    final percent =
        hasTotal ? ((downloaded / total) * 100).clamp(0, 100).round() : 0;

    final parts = <String>[
      if (active.isNotEmpty) '${active.length} downloading',
      if (queued.isNotEmpty) '${queued.length} queued',
      if (paused.isNotEmpty) '${paused.length} paused',
    ];
    final summaryText = parts.join(' • ');

    final titles = [...active, ...queued, ...paused].map((t) => t.title).toList();
    final lines = titles.take(5).toList();
    if (titles.length > 5) lines.add('+${titles.length - 5} more');

    final details = AndroidNotificationDetails(
      _progressChannelId,
      'Download progress',
      channelDescription: 'Queued, downloading, and paused downloads.',
      importance: Importance.low,
      priority: Priority.low,
      onlyAlertOnce: true,
      // Only while something is transferring or waiting; a summary of paused
      // downloads alone can be swiped away.
      ongoing: active.isNotEmpty || queued.isNotEmpty,
      showProgress: hasTotal && active.isNotEmpty,
      maxProgress: 100,
      progress: percent,
      indeterminate: active.isNotEmpty && !hasTotal,
      playSound: false,
      enableVibration: false,
      color: _gold,
      groupKey: _groupKey,
      setAsGroupSummary: true,
      category: AndroidNotificationCategory.progress,
      styleInformation: InboxStyleInformation(
        lines,
        contentTitle: 'Downloads',
        summaryText: summaryText,
      ),
    );

    await _plugin.show(
      id: _summaryId,
      title: 'Downloads',
      body: summaryText,
      notificationDetails: NotificationDetails(android: details),
    );
  }
}
