import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'addon_client.dart';
import 'addon_models.dart';
import '../torrent/torrent_engine.dart';
import 'default_addons.dart';

/// The list of installed addons, plus "ask them all for streams".
///
/// This is the piece that makes the app source-agnostic: the app never knows
/// where a stream comes from, it just asks every installed addon that
/// supports the title's id.
class AddonManager {
  AddonManager._();
  static final AddonManager instance = AddonManager._();

  static const String _prefsKey = 'namesis_addons_v1';

  /// Which default addon addresses have already been installed. This used to
  /// be ONE list for the whole device, so once the first profile had its
  /// defaults, every other profile (another account, or guest) was treated
  /// as "done" too and signed in to an empty addon list. It is now kept per
  /// profile: the key below plus the profile's scope id (see [_scopeId]).
  /// The bare key is the old, device-wide list, only read once to migrate.
  static const String _seededKey = 'namesis_default_addons_seeded_v1';
  static const String _seededMigratedKey =
      'namesis_default_addons_seeded_scoped_v2';

  /// The key CloudSync keeps the active profile's scope in
  /// ('guest' | 'u:<uid>'; absent before the first sign-in or guest start).
  static const String _scopePrefsKey = 'cloudsync_scope_v1';

  final ValueNotifier<List<AddonManifest>> addons = ValueNotifier(const []);

  Future<void>? _loading;
  Future<void>? _seeding;
  DateTime? _lastSeedAttempt;

  /// Call once at startup (and it is safe to call again, even at the same
  /// time: every caller gets the same load, so none returns before the saved
  /// addons are in).
  Future<void> load() => _loading ??= _doLoad();

  Future<void> _doLoad() async {
    await _loadStored();
    // Not awaited here: a slow or offline address must never hold up
    // startup. Callers that need the result use [whenReady].
    unawaited(_queueSeed());
  }

  /// Installs the default addons this profile does not have yet. Call it
  /// again whenever the active profile changed (signed in to another
  /// account, signed out, continued as guest): each profile gets its own
  /// defaults, and a profile that already has them costs no network. Calls
  /// run one after another and never throw.
  Future<void> reseedDefaults() async {
    await load();
    await _queueSeed();
  }

  Future<void> _queueSeed() {
    final previous = _seeding ?? Future<void>.value();
    final next = previous.catchError((Object _) {}).then((_) => _seedDefaults());
    _seeding = next;
    return next;
  }

  /// Completes once the saved addons are loaded AND the default addons have
  /// had their first install attempt (or [timeout] passed). Playback waits
  /// on this so a tap on Play right after launch never finds "no addon".
  Future<void> whenReady({
    Duration timeout = const Duration(seconds: 15),
  }) async {
    await load();
    // No stream addon: a default may not have been reachable earlier (for
    // example offline when the profile changed). Try again now instead of
    // failing with "no addon", unless one was tried a moment ago.
    final last = _lastSeedAttempt;
    if (!hasStreamAddons &&
        (last == null ||
            DateTime.now().difference(last) > const Duration(seconds: 30))) {
      unawaited(_queueSeed());
    }
    final seeding = _seeding;
    if (seeding != null) await seeding.timeout(timeout, onTimeout: () {});
  }

  Future<void> _loadStored() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_prefsKey);
      if (raw == null || raw.isEmpty) return;
      final decoded = jsonDecode(raw);
      if (decoded is! List) return;
      addons.value = decoded
          .whereType<Map>()
          .map((m) => AddonManifest.fromStored(Map<String, dynamic>.from(m)))
          .toList();
    } catch (e) {
      debugPrint('[AddonManager] failed to load addons: $e');
    }
  }

  /// The active profile's scope id, as CloudSync keeps it.
  String _scopeId(SharedPreferences prefs) =>
      prefs.getString(_scopePrefsKey) ?? 'none';

  /// Installs every address in [kDefaultAddonUrls] that has not been
  /// installed for the CURRENT profile before. An address is marked done
  /// only after it was reached, so a failed attempt is retried later, and
  /// an addon the person removed is not added back for that profile.
  Future<void> _seedDefaults() async {
    if (kDefaultAddonUrls.isEmpty) return;
    _lastSeedAttempt = DateTime.now();
    try {
      final prefs = await SharedPreferences.getInstance();
      final scope = _scopeId(prefs);
      final key = '$_seededKey:$scope';

      // One-time migration of the old device-wide list. It is only handed to
      // a profile that already has addons (an established one whose removals
      // should be respected); an empty profile, like the one that showed
      // "no addon installed", gets its defaults.
      if (!(prefs.getBool(_seededMigratedKey) ?? false)) {
        final legacy = prefs.getStringList(_seededKey);
        if (legacy != null &&
            addons.value.isNotEmpty &&
            prefs.getStringList(key) == null) {
          await prefs.setStringList(key, legacy);
        }
        await prefs.setBool(_seededMigratedKey, true);
      }

      final seeded = List<String>.from(prefs.getStringList(key) ?? []);
      var changed = false;
      for (final url in kDefaultAddonUrls) {
        if (seeded.contains(url)) continue;
        try {
          final manifest = await AddonClient.fetchManifest(url);
          // The person may have signed out or switched profile while the
          // address was being fetched. The answer then belongs to the old
          // profile: drop it, it is fetched again for the new one.
          if (_scopeId(prefs) != scope) break;
          if (!addons.value.any((a) => a.id == manifest.id)) {
            addons.value = [...addons.value, manifest];
            _lookups.clear(); // the set of addons changed
            await _save();
          }
          seeded.add(url);
          changed = true;
        } catch (e) {
          debugPrint('[AddonManager] default addon $url not installed: $e');
        }
      }
      if (changed) await prefs.setStringList(key, seeded);
    } catch (e) {
      debugPrint('[AddonManager] default addons failed: $e');
    }
  }

  Future<void> _save() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        _prefsKey,
        jsonEncode(addons.value.map((a) => a.toJson()).toList()),
      );
    } catch (e) {
      debugPrint('[AddonManager] failed to save addons: $e');
    }
  }

  /// Fetches the manifest at [url] and installs it. Re-adding the same addon
  /// (same id) replaces the old entry, which is how you refresh one after
  /// changing its address. Throws [AddonException] with a displayable message.
  Future<AddonManifest> add(String url) async {
    await load();
    final manifest = await AddonClient.fetchManifest(url);
    final next = [
      for (final a in addons.value)
        if (a.id != manifest.id) a,
      manifest,
    ];
    addons.value = next;
    _lookups.clear(); // answers from the old address are out of date
    await _save();
    return manifest;
  }

  Future<void> remove(String id) async {
    addons.value = addons.value.where((a) => a.id != id).toList();
    _lookups.clear();
    await _save();
  }

  bool get hasStreamAddons =>
      addons.value.any((a) => a.resources.contains('stream'));

  // ---- stream lookups (shared, remembered for a few minutes) ----

  /// How long a finished, successful lookup is reused. Short on purpose:
  /// direct links can carry tokens that expire.
  static const Duration _lookupTtl = Duration(minutes: 5);

  /// Lookups that are running or were successful recently, by title id.
  /// Several screens ask for the same title one after another (the download
  /// sheet, then the player, then the queue): they share one lookup instead
  /// of making a slow addon do the same work again each time.
  final Map<String, _StreamLookup> _lookups = {};

  /// The lookup for this title: the running one, a recent successful one,
  /// or a new one. [fresh] skips the remembered answer (a link that has
  /// expired must be asked for again).
  _StreamLookup _lookupFor(String type, String id, {bool fresh = false}) {
    final targets = addons.value
        .where((a) => a.supports('stream', type, id))
        .toList();
    // A change to the installed addons makes an earlier answer out of date.
    final signature = targets.map((a) => a.id).join('|');
    final key = '$type|$id';

    final existing = _lookups[key];
    if (existing != null) {
      // A running lookup is always shared. A finished one only while it is
      // recent, and never with a [fresh] caller.
      final reuse = existing.signature == signature &&
          (!existing.isDone || (!fresh && existing.isFresh(_lookupTtl)));
      if (reuse) return existing;
      _lookups.remove(key);
    }
    // Old answers nobody will reuse any more.
    _lookups.removeWhere((_, l) => l.isDone && !l.isFresh(_lookupTtl));

    final lookup = _StreamLookup(
      type: type,
      id: id,
      signature: signature,
      onFinished: (l) {
        // Only an answer worth remembering stays: every addon replied and at
        // least one had links. A failure or an empty answer is asked again
        // next time (an addon can fail once and work the next second).
        if ((l.failed || l.collected.isEmpty) && identical(_lookups[key], l)) {
          _lookups.remove(key);
        }
      },
    );
    _lookups[key] = lookup;
    lookup.start(targets);
    return lookup;
  }

  /// Asks every installed addon that supports this title for streams, all at
  /// once. Emits a growing, sorted list each time one addon answers, so the
  /// picker can show the quick ones immediately; closes when all have
  /// answered or failed.
  ///
  /// A title asked about again while its lookup is running, or within a few
  /// minutes of a successful one, reuses it: the stream starts with
  /// everything that has already arrived. Pass [fresh] to ask the addons
  /// again.
  Stream<List<AddonStream>> watchStreams(
    String type,
    String id, {
    bool fresh = false,
  }) =>
      _lookupFor(type, id, fresh: fresh).watch();

  /// Convenience for callers that only want the final merged list.
  ///
  /// With a [timeout], waits at most that long for the slow addons and
  /// returns what HAS arrived by then (a quick addon's links are not thrown
  /// away because a slow one is still busy). Without one, waits for all.
  Future<List<AddonStream>> streamsFor(
    String type,
    String id, {
    Duration? timeout,
    bool fresh = false,
  }) =>
      _lookupFor(type, id, fresh: fresh).result(timeout);

  Future<List<AddonSubtitle>> subtitlesFor(String type, String id) async {
    final targets =
        addons.value.where((a) => a.supports('subtitles', type, id)).toList();
    final lists = await Future.wait(
      targets.map((a) => AddonClient.fetchSubtitles(a, type, id)),
    );
    return lists.expand((l) => l).toList();
  }

  /// Highest resolution first; ties keep install order (sort is stable on the
  /// insertion index).
  static List<AddonStream> _sorted(List<AddonStream> input) {
    final indexed = input.asMap().entries.toList()
      ..sort((a, b) {
        final byHeight = b.value.height.compareTo(a.value.height);
        return byHeight != 0 ? byHeight : a.key.compareTo(b.key);
      });
    return indexed.map((e) => e.value).toList();
  }
}

/// One "ask every addon about this title" run, shared by everyone who asks
/// for the same title while it runs (and for a few minutes after, when it
/// was successful). See [AddonManager.watchStreams].
class _StreamLookup {
  _StreamLookup({
    required this.type,
    required this.id,
    required this.signature,
    required this.onFinished,
  });

  final String type;
  final String id;

  /// Which addons were asked; a different set means a different lookup.
  final String signature;
  final void Function(_StreamLookup) onFinished;

  final DateTime startedAt = DateTime.now();
  DateTime? _finishedAt;

  final List<AddonStream> collected = [];
  bool failed = false;

  int _answers = 0;
  final Completer<void> _done = Completer<void>();
  final List<StreamController<List<AddonStream>>> _listeners = [];

  bool get isDone => _done.isCompleted;

  bool isFresh(Duration ttl) {
    final at = _finishedAt;
    return at != null && DateTime.now().difference(at) < ttl;
  }

  void start(List<AddonManifest> targets) {
    if (targets.isEmpty) {
      _finish();
      return;
    }
    var pending = targets.length;
    for (final addon in targets) {
      AddonClient.fetchStreamsChecked(addon, type, id).then((r) {
        if (r.failed) failed = true;
        collected.addAll(r.streams);
        // A torrent is on offer: start (and tune) the local engine now,
        // while the person is still reading the list, so the first play
        // does not pay for a cold start.
        if (r.streams.any((s) => s.isTorrent)) {
          unawaited(TorrentEngine.instance.warmUp());
        }
        _answers++;
        final snapshot = AddonManager._sorted(collected);
        for (final c in List.of(_listeners)) {
          if (!c.isClosed) c.add(snapshot);
        }
      }).catchError((Object e) {
        failed = true;
        debugPrint('[AddonManager] ${addon.name} failed: $e');
      }).whenComplete(() {
        pending--;
        if (pending == 0) _finish();
      });
    }
  }

  void _finish() {
    if (_done.isCompleted) return;
    _finishedAt = DateTime.now();
    _done.complete();
    for (final c in List.of(_listeners)) {
      if (!c.isClosed) unawaited(c.close());
    }
    _listeners.clear();
    onFinished(this);
  }

  /// A stream for one listener: what has arrived so far (if any addon has
  /// answered), then every later answer, closing when all have answered.
  Stream<List<AddonStream>> watch() {
    late final StreamController<List<AddonStream>> controller;
    controller = StreamController<List<AddonStream>>(
      onListen: () {
        if (_answers > 0) controller.add(AddonManager._sorted(collected));
        if (isDone) {
          unawaited(controller.close());
        } else {
          _listeners.add(controller);
        }
      },
      onCancel: () {
        _listeners.remove(controller);
      },
    );
    return controller.stream;
  }

  /// The merged list once every addon has answered, or, after [timeout], what
  /// has arrived by then.
  Future<List<AddonStream>> result(Duration? timeout) async {
    if (!isDone) {
      if (timeout == null) {
        await _done.future;
      } else {
        await _done.future.timeout(timeout, onTimeout: () {});
      }
    }
    return AddonManager._sorted(collected);
  }
}
