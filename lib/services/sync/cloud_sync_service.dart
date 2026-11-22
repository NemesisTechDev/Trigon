import 'dart:async';
import 'dart:convert';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart' as fb;
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../addons/addon_manager.dart';
import '../../addons/addon_models.dart';
import '../../library/source_preferences.dart';
import '../../library/watch_history_service.dart';
import '../../player/models/subtitle_appearance.dart';
import '../../player/player_manager.dart';
import '../../virtual/virtual_catalog.dart';
import '../../virtual/virtual_collection_favorites.dart';
import '../app_settings.dart';
import '../auth/auth_bootstrap.dart';
import '../equalizer_service.dart';
import '../favorite_service.dart';
import '../jellyfin_services/storage_service.dart';
import '../profile_avatar_service.dart';
import '../subtitle_appearance_settings.dart';

/// Account sync + guest mode.
///
/// TWO MODES, NEVER MIXED
///  - Guest ("Continue Without Account"): nothing is ever read from or
///    written to the cloud. Data lives in SharedPreferences only.
///  - Account: the same SharedPreferences keys are mirrored to Firestore at
///    users/{uid}/prefs/{docId}, one document per key, so watch progress,
///    watchlist, favorites, addons and settings follow the person to any
///    device.
///
/// Local keys always hold the data of exactly one scope (guest or one
/// account). Switching scope moves the outgoing data out of the way first
/// (guest data is kept in a stash, account data is wiped because the cloud
/// has it), so one person's data can never show up under another.
///
/// CONFLICTS: every document carries a revision number. A push is a
/// transaction: if someone else wrote since this device last synced, the two
/// versions are merged (union of history/lists/maps) instead of overwritten.
/// Device-only data (downloads, caches, on-device music, Live TV reminders,
/// torrent engine address) is deliberately not synced.
class CloudSync with WidgetsBindingObserver {
  CloudSync._();
  static final CloudSync instance = CloudSync._();

  // ---------------------------------------------------------------- keys
  static const _kScope = 'cloudsync_scope_v1'; // 'guest' | 'u:<uid>' | absent
  static const _kGuestActive = 'cloudsync_guest_active_v1';
  static const _kStash = 'cloudsync_stash_v1';
  static const _kMeta = 'cloudsync_meta_v1';
  static const _kJournal = 'cloudsync_journal_v1';
  static const _kPending = 'cloudsync_pending_v1';

  static const _watchIds = {'history', 'watchlist', 'watched', 'epprog'};
  static const _eqIds = {
    'eq_enabled', 'eq_selected', 'eq_custom', 'eq_hidden', 'eq_snap'
  };

  static final List<_Spec> _specs = [
    _Spec('history', 'namesis_history_v1', _Kind.string),
    _Spec('watchlist', 'namesis_watchlist_v1', _Kind.string),
    _Spec('watched', 'namesis_watched_v1', _Kind.string),
    _Spec('epprog', 'namesis_epprog_v1', _Kind.string),
    _Spec('people', 'vc_fav_people_v1', _Kind.string),
    _Spec('collections', 'vc_fav_collections_v1', _Kind.string),
    _Spec('source_prefs', 'namesis_source_prefs_v1', _Kind.string),
    _Spec('source_autopick', 'namesis_autopick_v1', _Kind.boolean),
    _Spec('addons', 'namesis_addons_v1', _Kind.string),
    _Spec('subtitle', 'subtitle_appearance_v1', _Kind.string),
    _Spec('eq_enabled', 'eq_enabled', _Kind.boolean),
    _Spec('eq_selected', 'eq_selected', _Kind.string),
    _Spec('eq_custom', 'eq_custom_presets', _Kind.string),
    _Spec('eq_hidden', 'eq_hidden_presets', _Kind.strings),
    _Spec('eq_snap', 'eq_snap_bands', _Kind.boolean),
    _Spec('auto_queue', 'auto_queue_recommendations_v1', _Kind.boolean),
    _Spec('quality_mode', 'playback_quality_mode_v1', _Kind.string),
    _Spec('auto_link', 'auto_link_selection_v1', _Kind.boolean),
    _Spec('avatar', null, _Kind.string), // avatar_preset_<uid>
  ];
  static final Map<String, _Spec> _byId = {for (final s in _specs) s.id: s};

  // ---------------------------------------------------------------- state
  bool _loaded = false;
  String? _scope;
  bool _guestActive = false;
  Map<String, dynamic> _stash = {};
  Map<String, dynamic>? _journal;

  String? _activeUid;
  int _gen = 0;
  StreamSubscription<QuerySnapshot<Map<String, dynamic>>>? _sub;
  Timer? _timer;
  Completer<void>? _firstSync;
  Future<void> _chain = Future.value();
  bool _observing = false;
  String _deviceId = '';

  final Map<String, _Meta> _meta = {};
  final Map<String, String> _seen = {};
  final Set<String> _dirty = {};
  final Map<String, DateTime> _lastPush = {};
  final Map<String, DateTime> _retryAt = {};

  bool get isGuestActive => _guestActive;
  String? get activeUid => _activeUid;

  /// Guest data kept aside while an account is signed in (offered once to
  /// the person right after sign-in, see [importGuestData]).
  bool get hasGuestStash => _stash.isNotEmpty;

  // ============================================================ public API

  /// Guest mode: no cloud, everything local.
  Future<void> startGuest() async {
    await _ensureLoaded();
    await _stopSync();
    final scope = _scope;
    if (scope != null && scope.startsWith('u:')) {
      await _transition('toGuest', prev: scope);
    } else {
      await _setScope('guest');
    }
    await _setGuestActive(true);
    // Guest mode is its own profile: make sure it has the default addons.
    unawaited(AddonManager.instance.reseedDefaults());
  }

  /// True (and the guest session is re-armed) when the person left the app
  /// in guest mode.
  Future<bool> resumeGuestIfActive() async {
    await _ensureLoaded();
    await _finishJournal();
    if (!_guestActive) return false;
    await startGuest();
    return true;
  }

  /// Starts syncing for a verified, signed-in account. Safe to call twice.
  Future<void> startAccount(fb.User user,
      {Duration wait = const Duration(seconds: 6)}) async {
    if (!AuthBootstrap.ready) return;
    await _ensureLoaded();
    final uid = user.uid;
    if (_activeUid == uid && _sub != null) {
      await _awaitFirst(wait);
      return;
    }
    await _stopSync();
    await _finishJournal();
    if (_scope != 'u:$uid') {
      await _transition('toAccount', prev: _scope ?? 'legacy', uid: uid);
    }
    await _setGuestActive(false);
    await _begin(uid);
    await _awaitFirst(wait);
    // Each account has its own addon list. A new (or just-switched-to)
    // account arrives with none, so give it the default addons. Done after
    // the first sync so an account whose cloud copy already has addons keeps
    // exactly those; the merge adds, never replaces.
    unawaited(AddonManager.instance.reseedDefaults());
  }

  /// Sign-out: pushes what it can, then hands the device back to guest
  /// scope (account data wiped, guest data restored).
  Future<void> endSession() async {
    await _ensureLoaded();
    await _setGuestActive(false);
    final scope = _scope;
    final isAccount = scope != null && scope.startsWith('u:');
    if (!isAccount && _activeUid == null) return;

    await _stopPlayerQuickly();

    final uid = _activeUid ?? scope!.substring(2);
    if (_activeUid != null) {
      // Changes that could not be pushed in time are kept on this device
      // (see _savePending) and go up the next time this account signs in, so
      // a slow connection must not hold the sign-out for long.
      try {
        await flush().timeout(const Duration(seconds: 4));
      } catch (_) {}
      await _savePending(uid);
    }
    // Do not wait long for an in-flight push: once sync is stopped it never
    // touches local data again (see _pushOne / _onSnapshot).
    await _stopSync(settle: const Duration(seconds: 3));
    await _transition('toGuest', prev: 'u:$uid');
  }

  /// Stops playback, but never waits more than a moment for the server to
  /// acknowledge the "stopped" report: on a slow connection that report was
  /// the first thing to make sign-out feel stuck. The stop itself carries on
  /// in the background.
  Future<void> _stopPlayerQuickly() async {
    try {
      await PlayerManager.instance
          .stop()
          .timeout(const Duration(seconds: 2), onTimeout: () {});
    } catch (_) {}
  }

  /// Pushes pending local changes now (also runs on app background).
  Future<void> flush() async {
    if (_activeUid == null) return;
    await _locked(() async {
      _scan();
      await _pushDirty(force: true);
    });
  }

  /// Merges the guest data kept aside into the signed-in account.
  /// Account values win on single settings; lists/history are united.
  Future<bool> importGuestData() async {
    if (_activeUid == null || _stash.isEmpty) return false;
    final changed = <String>{};
    await _locked(() async {
      final p = await SharedPreferences.getInstance();
      for (final e in _stash.entries) {
        final s = _byId[e.key];
        if (s == null || s.id == 'avatar') continue;
        final theirs = _decode(e.value);
        final mine = _readLive(p, s);
        final merged = mine == null ? theirs : _merge(s.id, mine, theirs);
        if (_canon(merged) != _canon(mine)) {
          await _writeLive(p, s, merged);
          changed.add(s.id);
        }
      }
      _stash = {};
      await p.remove(_kStash);
      _scan();
    });
    await _reloadApp(changed);
    unawaited(flush());
    return true;
  }

  /// Deletes the account's cloud data (call right before deleting the
  /// Firebase user). Throws if the cloud could not be reached, so the
  /// account is never half-deleted silently.
  Future<void> deleteCloudData(fb.User user) async {
    final uid = user.uid;
    await _stopSync();
    try {
      final col = FirebaseFirestore.instance
          .collection('users')
          .doc(uid)
          .collection('prefs');
      final snap = await col
          .get(const GetOptions(source: Source.server))
          .timeout(const Duration(seconds: 20));
      for (var i = 0; i < snap.docs.length; i += 400) {
        final batch = FirebaseFirestore.instance.batch();
        for (final d in snap.docs.skip(i).take(400)) {
          batch.delete(d.reference);
        }
        await batch.commit().timeout(const Duration(seconds: 20));
      }
      final p = await SharedPreferences.getInstance();
      final pending = _readJsonMap(p.getString(_kPending));
      if (pending.remove(uid) != null) {
        await p.setString(_kPending, jsonEncode(pending));
      }
    } catch (e) {
      debugPrint('[CloudSync] cloud delete failed: $e');
      unawaited(startAccount(user));
      rethrow;
    }
  }

  // ======================================================== lifecycle hook

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (_activeUid == null) return;
    if (state == AppLifecycleState.resumed) {
      unawaited(_locked(() async {
        _scan();
        await _pushDirty(force: true);
      }));
    } else if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.inactive ||
        state == AppLifecycleState.detached) {
      unawaited(flush());
    }
  }

  // ============================================================== loading

  Future<void> _ensureLoaded() async {
    if (_loaded) return;
    final p = await SharedPreferences.getInstance();
    _scope = p.getString(_kScope);
    _guestActive = p.getBool(_kGuestActive) ?? false;
    _stash = _readJsonMap(p.getString(_kStash));
    final j = _readJsonMap(p.getString(_kJournal));
    _journal = j.isEmpty ? null : j;
    _deviceId = await StorageService.getOrCreateDeviceId();
    _loaded = true;
  }

  Future<void> _setScope(String? s) async {
    final p = await SharedPreferences.getInstance();
    _scope = s;
    if (s == null) {
      await p.remove(_kScope);
    } else {
      await p.setString(_kScope, s);
    }
  }

  Future<void> _setGuestActive(bool v) async {
    final p = await SharedPreferences.getInstance();
    _guestActive = v;
    if (v) {
      await p.setBool(_kGuestActive, true);
    } else {
      await p.remove(_kGuestActive);
    }
  }

  // ======================================================== transitions
  //
  // Journaled so a crash half-way is finished on the next start instead of
  // leaving one scope's data under another.

  Future<void> _transition(String op, {required String prev, String? uid}) async {
    _journal = {'op': op, 'prev': prev, 'uid': uid, 'done': 0};
    await _saveJournal();
    await _finishJournal();
  }

  Future<void> _saveJournal() async {
    final p = await SharedPreferences.getInstance();
    if (_journal == null) {
      await p.remove(_kJournal);
    } else {
      await p.setString(_kJournal, jsonEncode(_journal));
    }
  }

  Future<void> _finishJournal() async {
    final j = _journal;
    if (j == null) return;
    final op = j['op'] as String;
    final prev = j['prev'] as String;
    final uid = j['uid'] as String?;
    final prevUid = prev.startsWith('u:') ? prev.substring(2) : null;
    var done = (j['done'] as num).toInt();
    final p = await SharedPreferences.getInstance();

    Future<void> stage(int i, Future<void> Function() body) async {
      if (done > i) return;
      await body();
      done = i + 1;
      j['done'] = done;
      await _saveJournal();
    }

    await _stopPlayerQuickly();

    if (op == 'toAccount') {
      await stage(0, () async {
        if (prev == 'guest') {
          final snap = _snapshotLive(p, null);
          if (snap.isNotEmpty) {
            _stash = snap;
            await p.setString(_kStash, jsonEncode(snap));
          }
        }
      });
      await stage(1, () async {
        if (prev != 'legacy') await _wipeLive(p, prevUid);
        final pending = _readJsonMap(p.getString(_kPending));
        final mine = pending[uid];
        if (mine is Map) {
          for (final e in mine.entries) {
            final s = _byId[e.key];
            if (s != null) await _writeLive(p, s, _decode(e.value), uid: uid);
          }
        }
      });
      await stage(2, () async {
        final pending = _readJsonMap(p.getString(_kPending));
        if (pending.remove(uid) != null) {
          await p.setString(_kPending, jsonEncode(pending));
        }
        await p.remove(_kMeta);
        await _setScope('u:$uid');
      });
    } else {
      await stage(0, () async {
        if (prevUid != null) await _wipeLive(p, prevUid);
      });
      await stage(1, () async {
        if (prevUid != null) {
          for (final e in _stash.entries) {
            final s = _byId[e.key];
            if (s != null) await _writeLive(p, s, _decode(e.value));
          }
        }
      });
      await stage(2, () async {
        _stash = {};
        await p.remove(_kStash);
        await p.remove(_kMeta);
        await _setScope('guest');
      });
    }

    _journal = null;
    await _saveJournal();
    _meta.clear();
    _seen.clear();
    _dirty.clear();
    await _reloadApp(_byId.keys.toSet());
  }

  Map<String, dynamic> _snapshotLive(SharedPreferences p, String? uid) {
    final out = <String, dynamic>{};
    for (final s in _specs) {
      if (s.id == 'avatar') continue;
      final v = _readLive(p, s, uid: uid);
      if (v != null) out[s.id] = _encode(v);
    }
    return out;
  }

  Future<void> _wipeLive(SharedPreferences p, String? uid) async {
    for (final s in _specs) {
      final k = s.keyFor(uid);
      if (k != null) await p.remove(k);
    }
    // Caches built from the outgoing data (Home's Continue Watching etc.).
    try {
      await StorageService.clearAppDataCache();
    } catch (_) {}
  }

  Future<void> _savePending(String uid) async {
    if (_dirty.isEmpty) return;
    final p = await SharedPreferences.getInstance();
    final pending = _readJsonMap(p.getString(_kPending));
    final mine = <String, dynamic>{};
    for (final id in _dirty) {
      final s = _byId[id];
      if (s == null) continue;
      final v = _readLive(p, s, uid: uid);
      if (v != null) mine[id] = _encode(v);
    }
    if (mine.isEmpty) return;
    pending[uid] = mine;
    await p.setString(_kPending, jsonEncode(pending));
  }

  // ========================================================== sync engine

  Future<void> _begin(String uid) async {
    _activeUid = uid;
    final gen = ++_gen;
    _meta.clear();
    _seen.clear();
    _dirty.clear();
    final p = await SharedPreferences.getInstance();
    _cachedPrefs = p;
    final saved = _readJsonMap(p.getString(_kMeta));
    if (saved['uid'] == uid && saved['k'] is Map) {
      (saved['k'] as Map).forEach((k, v) {
        if (v is Map) {
          _meta[k.toString()] = _Meta(
              (v['r'] as num?)?.toInt() ?? 0, v['b'] as String?);
        }
      });
    }
    _firstSync = Completer<void>();
    if (!_observing) {
      WidgetsBinding.instance.addObserver(this);
      _observing = true;
    }
    final col = FirebaseFirestore.instance
        .collection('users')
        .doc(uid)
        .collection('prefs');
    _sub = col.snapshots().listen(
      (snap) => unawaited(_locked(() => _onSnapshot(gen, snap))),
      onError: (Object e) {
        debugPrint('[CloudSync] listen error: $e');
        // Offline / rules problem: stay usable, local data keeps working.
        if (_firstSync?.isCompleted == false) _firstSync!.complete();
      },
    );
    _timer = Timer.periodic(const Duration(seconds: 6), (_) {
      if (gen != _gen) return;
      unawaited(_locked(() async {
        if (gen != _gen) return;
        _scan();
        await _pushDirty();
      }));
    });
  }

  Future<void> _awaitFirst(Duration wait) async {
    final c = _firstSync;
    if (c == null || c.isCompleted) return;
    try {
      await c.future.timeout(wait);
    } catch (_) {}
  }

  Future<void> _stopSync({Duration settle = const Duration(seconds: 20)}) async {
    _gen++;
    _activeUid = null;
    await _sub?.cancel();
    _sub = null;
    _timer?.cancel();
    _timer = null;
    _firstSync = null;
    // Let any in-flight step finish before data is moved around.
    try {
      await _chain.timeout(settle);
    } catch (_) {}
  }

  Future<T> _locked<T>(Future<T> Function() f) {
    final c = Completer<T>();
    _chain = _chain.then((_) async {
      try {
        c.complete(await f());
      } catch (e, st) {
        c.completeError(e, st);
      }
    });
    return c.future;
  }

  Future<void> _onSnapshot(
      int gen, QuerySnapshot<Map<String, dynamic>> snap) async {
    if (gen != _gen) return;
    final p = await SharedPreferences.getInstance();
    _cachedPrefs = p;
    final applied = <String>{};
    final seenDocs = <String>{};
    for (final d in snap.docs) {
      seenDocs.add(d.id);
      final s = _byId[d.id];
      if (s == null) continue;
      try {
        if (_applyRemote(p, s, d.data())) applied.add(s.id);
      } catch (e) {
        debugPrint('[CloudSync] apply ${s.id} failed: $e');
      }
    }
    if (_firstSync != null && !_firstSync!.isCompleted) {
      // Keys the cloud has never seen: upload what is here.
      for (final s in _specs) {
        if (seenDocs.contains(s.id)) continue;
        if (_readLive(p, s) != null) _dirty.add(s.id);
      }
    }
    await _saveMeta(p);
    if (applied.isNotEmpty) await _reloadApp(applied);
    _scan();
    if (_firstSync != null && !_firstSync!.isCompleted) {
      _firstSync!.complete();
    }
  }

  /// Returns true when the local value was replaced.
  bool _applyRemote(SharedPreferences p, _Spec s, Map<String, dynamic> data) {
    final rev = (data['rev'] as num?)?.toInt() ?? 0;
    final m = _meta.putIfAbsent(s.id, () => _Meta(0, null));
    if (rev <= 0 || rev <= m.rev) return false;

    final Object? remote;
    if (data['del'] == true) {
      remote = null;
    } else {
      final r = _coerce(s, data['v']);
      if (identical(r, _invalid)) return false;
      remote = r;
    }

    final cur = _readLive(p, s);
    if (_canon(remote) == _canon(cur)) {
      m.rev = rev;
      m.base = _hash(cur);
      _seen[s.id] = _canon(cur);
      return false;
    }
    final dirty = m.base == null ? cur != null : _hash(cur) != m.base;
    final next = dirty && cur != null ? _merge(s.id, cur, remote) : remote;
    m.rev = rev;
    m.base = _hash(remote);
    unawaited(_writeLive(p, s, next));
    _seen[s.id] = _canon(next);
    if (_hash(next) != m.base) {
      _dirty.add(s.id);
    } else {
      _dirty.remove(s.id);
    }
    return true;
  }

  /// Notices local edits (services write SharedPreferences directly).
  void _scan() {
    final uid = _activeUid;
    if (uid == null) return;
    final p = _cachedPrefs;
    if (p == null) {
      SharedPreferences.getInstance().then((v) => _cachedPrefs = v);
      return;
    }
    for (final s in _specs) {
      final cur = _readLive(p, s);
      final c = _canon(cur);
      if (_seen[s.id] == c) continue;
      _seen[s.id] = c;
      final m = _meta[s.id];
      final dirty = m == null || m.base == null
          ? cur != null
          : _hash(cur) != m.base;
      if (dirty) {
        _dirty.add(s.id);
      } else {
        _dirty.remove(s.id);
      }
    }
  }

  SharedPreferences? _cachedPrefs;

  Duration _gap(String id) => _watchIds.contains(id)
      ? const Duration(seconds: 20)
      : const Duration(seconds: 4);

  Future<void> _pushDirty({bool force = false}) async {
    final uid = _activeUid;
    if (uid == null || _dirty.isEmpty) return;
    final now = DateTime.now();
    for (final id in _dirty.toList()) {
      if (_activeUid != uid) return;
      if (!force) {
        final last = _lastPush[id];
        if (last != null && now.difference(last) < _gap(id)) continue;
        final retry = _retryAt[id];
        if (retry != null && now.isBefore(retry)) continue;
      }
      try {
        await _pushOne(uid, _byId[id]!);
        _retryAt.remove(id);
      } catch (e) {
        debugPrint('[CloudSync] push $id failed: $e');
        _retryAt[id] = DateTime.now().add(const Duration(seconds: 30));
      }
      _lastPush[id] = DateTime.now();
    }
  }

  Future<void> _pushOne(String uid, _Spec s) async {
    final p = await SharedPreferences.getInstance();
    _cachedPrefs = p;
    final m = _meta.putIfAbsent(s.id, () => _Meta(0, null));
    final start = _readLive(p, s);
    final isDirty = m.base == null ? start != null : _hash(start) != m.base;
    if (!isDirty) {
      _dirty.remove(s.id);
      return;
    }
    if (start is String && utf8.encode(start).length > 800000) {
      debugPrint('[CloudSync] ${s.id} too large to sync, skipped');
      _dirty.remove(s.id);
      return;
    }

    final ref = FirebaseFirestore.instance
        .collection('users')
        .doc(uid)
        .collection('prefs')
        .doc(s.id);
    final startRev = m.rev;
    final res = await FirebaseFirestore.instance.runTransaction<_Pushed>(
      (tx) async {
        final snap = await tx.get(ref);
        final data = snap.data();
        final remoteRev = (data?['rev'] as num?)?.toInt() ?? 0;
        Object? write = start;
        if (data != null && remoteRev != startRev) {
          final r = data['del'] == true ? null : _coerce(s, data['v']);
          if (!identical(r, _invalid) && _canon(r) != _canon(start)) {
            write = start == null ? r : _merge(s.id, start, r);
          }
        }
        tx.set(ref, {
          'rev': remoteRev + 1,
          'dev': _deviceId,
          'ts': FieldValue.serverTimestamp(),
          if (write == null) 'del': true else 'v': write,
        });
        return _Pushed(write, remoteRev + 1);
      },
      timeout: const Duration(seconds: 15),
      maxAttempts: 3,
    );

    if (_activeUid != uid) return;
    final cur = _readLive(p, s);
    Object? applied = cur;
    if (_canon(cur) == _canon(start)) {
      applied = res.value;
    } else if (_canon(res.value) != _canon(start)) {
      applied = cur == null ? res.value : _merge(s.id, cur, res.value);
    }
    if (_canon(applied) != _canon(cur)) {
      await _writeLive(p, s, applied);
      await _reloadApp({s.id});
    }
    m.rev = res.rev;
    m.base = _hash(res.value);
    _seen[s.id] = _canon(applied);
    if (_hash(applied) != m.base) {
      _dirty.add(s.id);
    } else {
      _dirty.remove(s.id);
    }
    await _saveMeta(p);
  }

  Future<void> _saveMeta(SharedPreferences p) async {
    final uid = _activeUid;
    if (uid == null) return;
    await p.setString(
      _kMeta,
      jsonEncode({
        'uid': uid,
        'k': {
          for (final e in _meta.entries) e.key: {'r': e.value.rev, 'b': e.value.base}
        },
      }),
    );
  }

  // ======================================================== local storage

  Object? _readLive(SharedPreferences p, _Spec s, {String? uid}) {
    final k = s.keyFor(uid ?? _activeUid ?? _scopeUid);
    if (k == null) return null;
    final v = p.get(k);
    if (v == null) return null;
    switch (s.kind) {
      case _Kind.string:
        return v is String ? v : null;
      case _Kind.boolean:
        return v is bool ? v : null;
      case _Kind.strings:
        return v is List ? v.map((e) => e.toString()).toList() : null;
    }
  }

  String? get _scopeUid {
    final s = _scope;
    return s != null && s.startsWith('u:') ? s.substring(2) : null;
  }

  Future<void> _writeLive(SharedPreferences p, _Spec s, Object? v,
      {String? uid}) async {
    final k = s.keyFor(uid ?? _activeUid ?? _scopeUid);
    if (k == null) return;
    if (v == null) {
      await p.remove(k);
    } else if (v is String) {
      await p.setString(k, v);
    } else if (v is bool) {
      await p.setBool(k, v);
    } else if (v is List) {
      await p.setStringList(k, v.map((e) => e.toString()).toList());
    }
  }

  static final Object _invalid = Object();

  Object? _coerce(_Spec s, Object? v) {
    if (v == null) return _invalid;
    switch (s.kind) {
      case _Kind.string:
        return v is String ? v : _invalid;
      case _Kind.boolean:
        return v is bool ? v : _invalid;
      case _Kind.strings:
        return v is List ? v.map((e) => e.toString()).toList() : _invalid;
    }
  }

  dynamic _encode(Object v) => v is bool
      ? {'t': 'b', 'v': v}
      : v is List
          ? {'t': 'l', 'v': v}
          : {'t': 's', 'v': v};

  Object? _decode(dynamic e) {
    if (e is! Map) return null;
    final v = e['v'];
    switch (e['t']) {
      case 'b':
        return v is bool ? v : null;
      case 'l':
        return v is List ? v.map((x) => x.toString()).toList() : null;
      default:
        return v is String ? v : null;
    }
  }

  static Map<String, dynamic> _readJsonMap(String? raw) {
    if (raw == null || raw.isEmpty) return {};
    try {
      final d = jsonDecode(raw);
      return d is Map ? Map<String, dynamic>.from(d) : {};
    } catch (_) {
      return {};
    }
  }

  static String _canon(Object? v) => v == null
      ? 'n'
      : v is bool
          ? 'b:$v'
          : v is List
              ? 'l:${jsonEncode(v)}'
              : 's:$v';

  static String _hash(Object? v) {
    final bytes = utf8.encode(_canon(v));
    var a = 0x811c9dc5, b = 0x01000193 ^ 0x5bd1e995;
    for (final x in bytes) {
      a = ((a ^ x) * 0x01000193) & 0xFFFFFFFF;
      b = ((b + x) * 0x5bd1e995 + (b >> 13)) & 0xFFFFFFFF;
    }
    return '${a.toRadixString(16)}-${b.toRadixString(16)}-${bytes.length}';
  }

  // ============================================================== merging
  //
  // [a] wins on single values; collections are united so no device's
  // additions are lost.

  Object? _merge(String id, Object a, Object? b) {
    if (b == null) return a;
    try {
      switch (id) {
        case 'history':
          return _mergeHistory(a as String, b as String);
        case 'watchlist':
          return _mergeKeyedList(
              a as String, b as String, (m) => '${m['type']}:${m['tmdbId']}');
        case 'addons':
          return _mergeKeyedList(a as String, b as String, (m) => '${m['id']}');
        case 'eq_custom':
          return _mergeKeyedList(a as String, b as String, (m) => '${m['id']}');
        case 'watched':
          return _mergeWatched(a as String, b as String);
        case 'epprog':
          return _mergeEpProg(a as String, b as String);
        case 'people':
        case 'collections':
          return _mergeMap(a as String, b as String, 1 << 30);
        case 'source_prefs':
          return _mergeMap(a as String, b as String, 200);
        case 'eq_hidden':
          return {...(a as List), ...(b as List)}.map((e) => '$e').toList();
      }
    } catch (e) {
      debugPrint('[CloudSync] merge $id failed: $e');
    }
    return a;
  }

  static String _mergeHistory(String a, String b) {
    final out = <String, Map>{};
    String key(Map m) {
      final t = m['title'];
      return t is Map ? '${t['type']}:${t['tmdbId']}' : '';
    }

    for (final src in [jsonDecode(a), jsonDecode(b)]) {
      for (final e in (src as List).whereType<Map>()) {
        final k = key(e);
        if (k.isEmpty) continue;
        final old = out[k];
        final t = (e['updatedAtMs'] as num?)?.toInt() ?? 0;
        if (old == null || t > ((old['updatedAtMs'] as num?)?.toInt() ?? 0)) {
          out[k] = e;
        }
      }
    }
    final list = out.values.toList()
      ..sort((x, y) => ((y['updatedAtMs'] as num?) ?? 0)
          .compareTo((x['updatedAtMs'] as num?) ?? 0));
    // Same cap as WatchHistoryService, so a sync never trims the stored
    // history below what Continue Watching needs for its refills.
    return jsonEncode(list.take(200).toList());
  }

  static String _mergeKeyedList(
      String a, String b, String Function(Map) key) {
    final seen = <String>{};
    final out = <Map>[];
    for (final src in [jsonDecode(a), jsonDecode(b)]) {
      for (final e in (src as List).whereType<Map>()) {
        if (seen.add(key(e))) out.add(e);
      }
    }
    return jsonEncode(out);
  }

  static String _mergeWatched(String a, String b) {
    final out = <String, List<String>>{};
    for (final src in [jsonDecode(a), jsonDecode(b)]) {
      (src as Map).forEach((k, v) {
        final l = out.putIfAbsent(k.toString(), () => []);
        for (final e in (v as List)) {
          if (!l.contains('$e')) l.add('$e');
        }
      });
    }
    return jsonEncode(out);
  }

  static String _mergeEpProg(String a, String b) {
    final out = <String, Map<String, dynamic>>{};
    for (final src in [jsonDecode(a), jsonDecode(b)]) {
      (src as Map).forEach((k, v) {
        if (v is! Map) return;
        final m = out.putIfAbsent(k.toString(), () => {});
        v.forEach((ek, ev) {
          final old = m[ek.toString()];
          if (old == null ||
              (ev is List &&
                  old is List &&
                  ((ev[0] as num) > (old[0] as num)))) {
            m[ek.toString()] = ev;
          }
        });
      });
    }
    while (out.length > 80) {
      out.remove(out.keys.first);
    }
    return jsonEncode(out);
  }

  static String _mergeMap(String a, String b, int cap) {
    final out = <String, dynamic>{};
    (jsonDecode(b) as Map).forEach((k, v) => out[k.toString()] = v);
    (jsonDecode(a) as Map).forEach((k, v) {
      out.remove(k.toString());
      out[k.toString()] = v;
    });
    while (out.length > cap) {
      out.remove(out.keys.first);
    }
    return jsonEncode(out);
  }

  // ======================================================= app reload hooks

  Future<void> _try(Future<void> Function() f) async {
    try {
      await f();
    } catch (e) {
      debugPrint('[CloudSync] reload step failed: $e');
    }
  }

  /// Makes already-running services pick up values that were just written.
  Future<void> _reloadApp(Set<String> ids) async {
    if (ids.isEmpty) return;
    final p = await SharedPreferences.getInstance();
    var favorites = false;

    if (ids.any(_watchIds.contains)) {
      await _try(() => WatchHistoryService.instance.reloadFromStorage());
      favorites = true;
    }
    if (ids.contains('people')) {
      await _try(() => VirtualCatalog.reloadFavoritePeople());
      favorites = true;
    }
    if (ids.contains('collections')) {
      await _try(() => VirtualCollectionFavorites.reload());
      favorites = true;
    }
    if (ids.contains('source_prefs') || ids.contains('source_autopick')) {
      await _try(() => SourcePreferences.instance.reloadFromStorage());
    }
    if (ids.contains('addons')) {
      await _try(() async {
        final raw = p.getString('namesis_addons_v1');
        final list = <AddonManifest>[];
        if (raw != null && raw.isNotEmpty) {
          final d = jsonDecode(raw);
          if (d is List) {
            for (final m in d.whereType<Map>()) {
              list.add(AddonManifest.fromStored(Map<String, dynamic>.from(m)));
            }
          }
        }
        AddonManager.instance.addons.value = list;
      });
    }
    if (ids.contains('subtitle')) {
      SubtitleAppearanceSettings.notifier.value =
          SubtitleAppearance.tryDecode(p.getString('subtitle_appearance_v1')) ??
              SubtitleAppearance.defaults;
    }
    if (ids.any(_eqIds.contains)) {
      await _try(() => EqualizerService.instance.reloadFromStorage());
    }
    if (ids.contains('auto_queue')) {
      AppSettings.autoQueueRecommendations.value =
          p.getBool('auto_queue_recommendations_v1') ?? true;
    }
    if (ids.contains('quality_mode')) {
      final stored = p.getString('playback_quality_mode_v1');
      AppSettings.playbackQualityMode.value =
          PlaybackQualityMode.values.firstWhere((m) => m.name == stored,
              orElse: () => PlaybackQualityMode.standard);
    }
    if (ids.contains('auto_link')) {
      AppSettings.autoLinkSelection.value =
          p.getBool('auto_link_selection_v1') ?? true;
    }
    if (ids.contains('avatar')) await _try(_reloadAvatar);
    if (favorites) FavoriteService.notifyChanged();
  }

  Future<void> _reloadAvatar() async {
    if (!AuthBootstrap.ready) return;
    final u = fb.FirebaseAuth.instance.currentUser;
    if (u == null) return;
    var isGoogle = false;
    String? photo = u.photoURL;
    for (final pr in u.providerData) {
      if (pr.providerId == 'google.com') {
        isGoogle = true;
        if (photo == null || photo.isEmpty) photo = pr.photoURL;
      }
    }
    await ProfileAvatarService.instance
        .setUser(uid: u.uid, isGoogle: isGoogle, googlePhotoUrl: photo);
  }
}

enum _Kind { string, boolean, strings }

class _Spec {
  final String id;
  final String? _key;
  final _Kind kind;
  const _Spec(this.id, this._key, this.kind);

  String? keyFor(String? uid) {
    if (_key != null) return _key;
    return uid == null ? null : 'avatar_preset_$uid';
  }
}

class _Meta {
  int rev;
  String? base;
  _Meta(this.rev, this.base);
}

class _Pushed {
  final Object? value;
  final int rev;
  _Pushed(this.value, this.rev);
}
