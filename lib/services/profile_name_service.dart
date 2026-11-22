import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../virtual/virtual_adapter.dart';
import 'account_store.dart';
import 'jellyfin_services/storage_service.dart';

/// The name the person chose for their profile on the Edit Profile page.
///
/// By default the app shows the account's own name (Google / Firebase display
/// name, or the part of the email before the "@"). A name typed on the Edit
/// Profile page replaces that. It is saved per account (Firebase uid, or
/// [guestId] for guest mode), so another account on the same phone keeps its
/// own name, and it survives signing out and back in.
///
/// Listeners are told whenever the name changes, so screens that show it (the
/// landscape side rail) can refresh.
class ProfileNameService extends ChangeNotifier {
  ProfileNameService._();

  static final ProfileNameService instance = ProfileNameService._();

  /// Key used instead of a Firebase uid while using the app as a guest.
  static const String guestId = 'guest';

  /// Longest name the Edit Profile field accepts.
  static const int maxLength = 30;

  static String _key(String id) => 'profile_name_$id';

  /// The name chosen for [id], or null when none was ever set.
  Future<String?> customNameFor(String id) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final value = prefs.getString(_key(id))?.trim();
      return (value == null || value.isEmpty) ? null : value;
    } catch (e) {
      debugPrint('[ProfileName] read failed: $e');
      return null;
    }
  }

  /// Saves [name] as the profile name of account [id] and makes every place
  /// that shows the current name use it straight away. Throws if the name
  /// could not be stored, so the caller can tell the person.
  Future<void> rename(String id, String name) async {
    final clean = name.trim();
    if (clean.isEmpty) {
      throw ArgumentError('A profile name cannot be empty.');
    }

    final prefs = await SharedPreferences.getInstance();
    final saved = await prefs.setString(_key(id), clean);
    if (!saved) throw StateError('Could not save the profile name.');

    // What Profile & Settings, the side rail and the quick-switch list read.
    await StorageService.saveUsername(clean);
    VirtualSession.username = clean;

    // A guest is not part of the quick-switch list; real accounts are, and
    // that list keeps its own copy of the name.
    if (id != guestId) await AccountStore.rememberCurrent();

    notifyListeners();
  }

  /// On account deletion: forget this account's chosen name as well.
  Future<void> forget(String id) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_key(id));
    } catch (_) {}
  }
}
