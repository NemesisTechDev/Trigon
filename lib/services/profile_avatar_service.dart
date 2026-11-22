import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../widgets/profile/avatar_presets.dart';
import 'profile_name_service.dart';

/// Which picture the signed-in person has.
///
/// Every account (Google, email, or guest) can pick one of the built-in
/// avatars ([AvatarPresets]) on the Edit Profile page. Picking none means
/// "default":
///
///  - Signed in with Google: the Google account's own photo (refreshed at
///    every sign-in / app start).
///  - Any other account: the plain person icon.
///
/// The choice is saved per account (Firebase uid, or a fixed id for guest
/// mode), so a different account on the same phone keeps its own picture.
/// State loads from disk on first use; until then listeners see "no avatar"
/// and rebuild when it arrives.
class ProfileAvatarService extends ChangeNotifier {
  ProfileAvatarService._() {
    _loaded = _load();
  }

  static final ProfileAvatarService instance = ProfileAvatarService._();

  static const _kCurrent = 'avatar_current_uid';
  static String _kGoogle(String uid) => 'avatar_google_$uid';
  static String _kPreset(String uid) => 'avatar_preset_$uid';

  late final Future<void> _loaded;

  String? _uid;
  String? _googleUrl; // null = not a Google account; '' = Google, no photo
  String? _presetId;

  /// Completes once the saved state has been read from disk.
  Future<void> get ready => _loaded;

  /// Id of the account that is signed in (or the guest id), if any. The same
  /// id keys the saved profile name, see [ProfileNameService].
  String? get uid => _uid;

  /// True for an account that signed in with Google.
  bool get isGoogle => _googleUrl != null;

  /// The Google photo to show, if this is a Google account that has one.
  String? get googlePhotoUrl =>
      (_googleUrl == null || _googleUrl!.isEmpty) ? null : _googleUrl;

  /// The avatar the person chose, or null for the default picture.
  AvatarPreset? get preset => AvatarPresets.byId(_presetId);

  /// Whether the avatar can be changed: signed in (or in guest mode).
  bool get canChoose => _uid != null;

  Future<void> _load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final uid = prefs.getString(_kCurrent);
      if (uid == null || uid.isEmpty) return;
      _uid = uid;
      _googleUrl = prefs.getString(_kGoogle(uid));
      _presetId = prefs.getString(_kPreset(uid));
      notifyListeners();
    } catch (e) {
      debugPrint('[ProfileAvatar] load failed: $e');
    }
  }

  /// Google serves its photos in a small size by default; asks for a
  /// sharper one (the avatar is shown up to ~100 dp).
  static String? _sharper(String? url) {
    if (url == null || url.isEmpty) return null;
    final sized = url.replaceFirst(RegExp(r'=s\d+(-c)?$'), '=s256-c');
    return sized;
  }

  /// Called after a sign-in and at app start with whatever the account
  /// provider says. [googlePhotoUrl] is only used when [isGoogle].
  Future<void> setUser({
    required String uid,
    required bool isGoogle,
    String? googlePhotoUrl,
  }) async {
    try {
      await _loaded;
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_kCurrent, uid);
      _uid = uid;
      if (isGoogle) {
        _googleUrl = _sharper(googlePhotoUrl) ?? '';
        await prefs.setString(_kGoogle(uid), _googleUrl!);
      } else {
        _googleUrl = null;
        await prefs.remove(_kGoogle(uid));
      }
      _presetId = prefs.getString(_kPreset(uid));
      notifyListeners();
    } catch (e) {
      debugPrint('[ProfileAvatar] setUser failed: $e');
    }
  }

  /// Guest mode (no account): the avatar is kept under a fixed id, with no
  /// Google photo.
  Future<void> setGuest() async {
    await setUser(uid: ProfileNameService.guestId, isGoogle: false);
  }

  /// Picks one of the built-in avatars, or [null] to go back to the default
  /// picture. Ignored when nobody is signed in.
  Future<void> choosePreset(String? id) async {
    if (!canChoose) return;
    final uid = _uid!;
    if (id != null && AvatarPresets.byId(id) == null) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      if (id == null) {
        await prefs.remove(_kPreset(uid));
      } else {
        await prefs.setString(_kPreset(uid), id);
      }
      _presetId = id;
      notifyListeners();
    } catch (e) {
      debugPrint('[ProfileAvatar] choose failed: $e');
    }
  }

  /// On sign-out: nobody is signed in, so no picture is shown. The saved
  /// choice stays on the phone for the next time that account signs in.
  Future<void> clearCurrent() async {
    try {
      await _loaded;
      _uid = null;
      _googleUrl = null;
      _presetId = null;
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_kCurrent);
      notifyListeners();
    } catch (e) {
      debugPrint('[ProfileAvatar] clear failed: $e');
    }
  }

  /// On account deletion: forget this account's picture and name as well.
  Future<void> forgetCurrent() async {
    try {
      await _loaded;
      final uid = _uid;
      if (uid != null) {
        final prefs = await SharedPreferences.getInstance();
        await prefs.remove(_kGoogle(uid));
        await prefs.remove(_kPreset(uid));
        await ProfileNameService.instance.forget(uid);
      }
    } catch (_) {}
    await clearCurrent();
  }
}
